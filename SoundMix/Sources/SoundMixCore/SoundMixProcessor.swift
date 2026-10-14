import Foundation
import os

/// Everything that defines how a bed is folded to stereo.
public struct ProcessorConfiguration: Equatable, Sendable {
    public var layout: LayoutPreset
    public var recipe: MatrixRecipe
    public var headroomMode: HeadroomMode
    public var manualGainDB: Double
    public var swapOutputs: Bool
    public var globalPEQ: PEQProfile
    public var speakerPEQLeft: PEQProfile
    public var speakerPEQRight: PEQProfile
    public var limiter: TruePeakLimiter.Settings
    /// `nil` lets the processor align the dry path to the LFE filter's DC group delay.
    public var lfeDelayOverrideSamples: Int?

    public init(layout: LayoutPreset = .nativeBed,
                recipe: MatrixRecipe = .reference,
                headroomMode: HeadroomMode = .powerPreserving,
                manualGainDB: Double = 0,
                swapOutputs: Bool = false,
                globalPEQ: PEQProfile = .flat,
                speakerPEQLeft: PEQProfile = .flat,
                speakerPEQRight: PEQProfile = .flat,
                limiter: TruePeakLimiter.Settings = .init(),
                lfeDelayOverrideSamples: Int? = nil) {
        self.layout = layout
        self.recipe = recipe
        self.headroomMode = headroomMode
        self.manualGainDB = manualGainDB
        self.swapOutputs = swapOutputs
        self.globalPEQ = globalPEQ
        self.speakerPEQLeft = speakerPEQLeft
        self.speakerPEQRight = speakerPEQRight
        self.limiter = limiter
        self.lfeDelayOverrideSamples = lfeDelayOverrideSamples
    }

    /// The matrix this configuration produces, restricted to the channels the
    /// layout actually feeds, before any trim.
    public var effectiveMatrix: SoundMixMatrix {
        recipe.matrix().restricted(to: layout.activeChannels)
    }

    /// The automatic trim in dB that `headroomMode` asks for.
    public var automaticTrimDB: Double {
        let m = effectiveMatrix
        switch headroomMode {
        case .none:            return 0
        case .peakSafe:        return m.worstCasePeakGain > 1 ? -m.worstCasePeakGainDB : 0
        case .powerPreserving: return m.uncorrelatedGain > 1 ? -m.uncorrelatedGainDB : 0
        }
    }

    public var totalTrimDB: Double { automaticTrimDB + manualGainDB }
}

/// The real-time downmix engine. One instance owns all filter state.
///
/// Signal flow, matching the original renderer's ordering so existing PEQ
/// profiles behave the same, with the limiter added at the end:
///
/// ```
/// device in → input map → bed[16]
///                          ├── LFE → (Butterworth LP | dry | off) → ×coef ─┐
///                          └── everything else → matrix → dry L/R → delay ─┤
///                                                                           ▼
///              global PEQ (both channels) → swap → speaker PEQ L/R → limiter → out
/// ```
private final class ProcessorRenderState: @unchecked Sendable {

    // Audio-thread state -----------------------------------------------------
    private var sampleRate: Double = 48_000
    private var coefficients: [Double] = Array(repeating: 0, count: BedChannel.count * 2)
    private var inputMap: [Int] = Array(repeating: -1, count: BedChannel.count)   // 0-based, -1 = unmapped
    private var swap = false

    private let lfeFilter = BiquadChain()
    private var lfeEnabled = false
    private let globalLeft = BiquadChain(), globalRight = BiquadChain()
    private let speakerLeft = BiquadChain(), speakerRight = BiquadChain()
    private let limiter = TruePeakLimiter()

    private var dryDelay: [Double] = []            // interleaved L,R
    private var dryDelayFrames = 0
    private var dryDelayIndex = 0

    private var bed = [Double](repeating: 0, count: BedChannel.count)
    private var snapshotPeaks = [Double](repeating: -.infinity, count: BedChannel.count)
    private var bedMeters = [LevelMeter](repeating: LevelMeter(), count: BedChannel.count)
    private var meterLeft = LevelMeter(), meterRight = LevelMeter()
    private var appliedTrimDB: Double = 0
    private var underruns = 0

    // Shared state -----------------------------------------------------------
    // os_unfair_lock must live at a fixed address. Taking `&someStoredProperty`
    // does not guarantee one — the optimiser is free to hand the call a
    // temporary copy, which silently removes the mutual exclusion. Allocating
    // the locks once pins them for the object's lifetime.
    private let snapshotLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    private var snapshotStorage = RenderSnapshot(bedPeakDB: [])
    public private(set) var configuration = ProcessorConfiguration()

    public init() {}

    deinit {
        snapshotLock.deinitialize(count: 1); snapshotLock.deallocate()
    }

    // MARK: - Setup

    public func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        for i in bedMeters.indices { bedMeters[i].configure(sampleRate: sampleRate) }
        meterLeft.configure(sampleRate: sampleRate)
        meterRight.configure(sampleRate: sampleRate)
        limiter.update(settings: configuration.limiter, sampleRate: sampleRate)
        rebuild(configuration)
    }

    /// Apply immediately on the current thread. Only for offline use and setup.
    public func applyNow(_ config: ProcessorConfiguration) {
        rebuild(config)
    }

    private func rebuild(_ config: ProcessorConfiguration) {
        configuration = config

        let trimDB = config.totalTrimDB
        appliedTrimDB = trimDB
        let trim = SoundMixMatrix.linear(trimDB)
        let matrix = config.effectiveMatrix.scaled(by: trim)

        for ch in BedChannel.allCases {
            coefficients[ch.rawValue * 2] = matrix[ch].left
            coefficients[ch.rawValue * 2 + 1] = matrix[ch].right
        }

        for ch in BedChannel.allCases {
            let slot = config.layout.map[ch.rawValue]
            inputMap[ch.rawValue] = slot > 0 ? slot - 1 : -1
        }

        swap = config.swapOutputs

        // LFE path.
        switch config.recipe.lfeMode {
        case .off:
            lfeEnabled = false
            lfeFilter.update(BiquadCascade())
        case .dry:
            lfeEnabled = true
            lfeFilter.update(BiquadCascade())
        case .lowPass:
            lfeEnabled = true
            lfeFilter.update(BiquadDesign.butterworthLowPass(
                frequency: config.recipe.lfeCutoffHz,
                order: config.recipe.lfeFilterOrder,
                sampleRate: sampleRate))
        }

        // Align the dry path with the LFE filter so the bass sums in phase.
        let autoDelay: Int
        if config.recipe.lfeMode == .lowPass, lfeEnabled {
            let tau = lfeFilter.cascade.groupDelay(at: 0, sampleRate: sampleRate)
            autoDelay = max(0, Int(tau.rounded()))
        } else {
            autoDelay = 0
        }
        let frames = max(1, config.lfeDelayOverrideSamples ?? autoDelay)
        if frames != dryDelayFrames {
            dryDelayFrames = frames
            dryDelay = Array(repeating: 0, count: frames * 2)
            dryDelayIndex = 0
        }

        globalLeft.update(config.globalPEQ.cascade(sampleRate: sampleRate))
        globalRight.update(config.globalPEQ.cascade(sampleRate: sampleRate))
        speakerLeft.update(config.speakerPEQLeft.cascade(sampleRate: sampleRate))
        speakerRight.update(config.speakerPEQRight.cascade(sampleRate: sampleRate))
        limiter.update(settings: config.limiter, sampleRate: sampleRate)
    }

    func inheritHistory(from previous: ProcessorRenderState) {
        lfeFilter.inheritHistory(from: previous.lfeFilter)
        globalLeft.inheritHistory(from: previous.globalLeft)
        globalRight.inheritHistory(from: previous.globalRight)
        speakerLeft.inheritHistory(from: previous.speakerLeft)
        speakerRight.inheritHistory(from: previous.speakerRight)
        limiter.inheritHistory(from: previous.limiter)
        if dryDelay.count == previous.dryDelay.count {
            for i in dryDelay.indices { dryDelay[i] = previous.dryDelay[i] }
            dryDelayIndex = previous.dryDelayIndex
        }
        for i in bedMeters.indices { bedMeters[i] = previous.bedMeters[i] }
        meterLeft = previous.meterLeft; meterRight = previous.meterRight
        underruns = previous.underruns
    }

    public func reset() {
        lfeFilter.reset(); globalLeft.reset(); globalRight.reset()
        speakerLeft.reset(); speakerRight.reset(); limiter.reset()
        for i in dryDelay.indices { dryDelay[i] = 0 }
        dryDelayIndex = 0
        for i in bedMeters.indices { bedMeters[i].reset() }
        meterLeft.reset(); meterRight.reset()
        underruns = 0
    }

    public func noteUnderrun() { underruns += 1 }

    /// Total added latency of the processing chain, in milliseconds.
    public var latencyMS: Double {
        (Double(dryDelayFrames == 1 ? 0 : dryDelayFrames) + Double(limiter.latencySamples))
            / sampleRate * 1000
    }

    // MARK: - Render

    /// Fold `frames` of interleaved input into interleaved stereo output.
    public func process(input: UnsafePointer<Float>, inputChannels: Int, frames: Int,
                        output: UnsafeMutablePointer<Float>) {
        for f in 0..<frames {
            let base = f * inputChannels

            for c in 0..<BedChannel.count {
                let slot = inputMap[c]
                let v = (slot >= 0 && slot < inputChannels) ? Double(input[base + slot]) : 0
                bed[c] = v
                bedMeters[c].accumulate(v)
            }

            // Dry sum: everything except LFE.
            var dryL = 0.0, dryR = 0.0
            for c in 0..<BedChannel.count where c != BedChannel.lfe.rawValue {
                let v = bed[c]
                if v == 0 { continue }
                dryL += v * coefficients[c * 2]
                dryR += v * coefficients[c * 2 + 1]
            }

            // Delay the dry path by the LFE filter's group delay.
            var outL: Double, outR: Double
            if dryDelayFrames > 1 {
                let idx = dryDelayIndex * 2
                outL = dryDelay[idx]
                outR = dryDelay[idx + 1]
                dryDelay[idx] = dryL
                dryDelay[idx + 1] = dryR
                dryDelayIndex = (dryDelayIndex + 1) % dryDelayFrames
            } else {
                outL = dryL
                outR = dryR
            }

            if lfeEnabled {
                let lfeRaw = bed[BedChannel.lfe.rawValue]
                let lfe = lfeFilter.cascade.sections.isEmpty ? lfeRaw : lfeFilter.process(lfeRaw)
                outL += lfe * coefficients[BedChannel.lfe.rawValue * 2]
                outR += lfe * coefficients[BedChannel.lfe.rawValue * 2 + 1]
            }

            // Global PEQ, applied to both channels before the swap.
            if !globalLeft.cascade.isTransparent {
                outL = globalLeft.process(outL)
                outR = globalRight.process(outR)
            }

            if swap { Swift.swap(&outL, &outR) }

            // Speaker correction, applied to the physical outputs after the swap.
            if !speakerLeft.cascade.isTransparent { outL = speakerLeft.process(outL) }
            if !speakerRight.cascade.isTransparent { outR = speakerRight.process(outR) }

            limiter.process(&outL, &outR)

            meterLeft.accumulate(outL)
            meterRight.accumulate(outR)

            output[f * 2] = Float(outL)
            output[f * 2 + 1] = Float(outR)
        }

        publishSnapshot()
    }

    private func publishSnapshot() {
        guard os_unfair_lock_trylock(snapshotLock) else { return }
        defer { os_unfair_lock_unlock(snapshotLock) }
        for i in snapshotPeaks.indices { snapshotPeaks[i] = bedMeters[i].peakDB }
        let snap = RenderSnapshot(
            bedPeakDB: [],
            outputPeakDB: (meterLeft.peakDB, meterRight.peakDB),
            outputRMSDB: (meterLeft.rmsDB, meterRight.rmsDB),
            clipLeft: meterLeft.clipCount,
            clipRight: meterRight.clipCount,
            gainReductionDB: limiter.takeGainReductionDB(),
            appliedTrimDB: appliedTrimDB,
            latencyMS: latencyMS,
            sampleRate: sampleRate,
            isRunning: true,
            underruns: underruns)
        snapshotStorage = snap
    }

    public func snapshot() -> RenderSnapshot {
        os_unfair_lock_lock(snapshotLock)
        var s = snapshotStorage
        // Allocate the public array only on the snapshot reader's thread.
        s.bedPeakDB = snapshotPeaks.map { $0 }
        os_unfair_lock_unlock(snapshotLock)
        return s
    }

    public func markStopped() {
        os_unfair_lock_lock(snapshotLock)
        snapshotStorage.isRunning = false
        os_unfair_lock_unlock(snapshotLock)
    }
}

/// Control-thread preparation with a nonblocking handoff to the audio thread.
/// Replaced states are retained until the next control-thread update, so their
/// arrays and filters are never destroyed by the real-time callback.
public final class SoundMixProcessor: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    private var current = ProcessorRenderState()
    private var pending: ProcessorRenderState?
    private var retired: ProcessorRenderState?
    private var sampleRate: Double = 48_000
    public init() {}
    deinit { lock.deinitialize(count: 1); lock.deallocate() }

    private func readState() -> ProcessorRenderState {
        os_unfair_lock_lock(lock)
        let state = current
        os_unfair_lock_unlock(lock)
        return state
    }
    public var configuration: ProcessorConfiguration { readState().configuration }
    public var latencyMS: Double { readState().latencyMS }

    // Setup/reset APIs require the stream to be stopped.
    public func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        current.prepare(sampleRate: sampleRate)
    }
    public func applyNow(_ config: ProcessorConfiguration) {
        pending = nil; retired = nil
        current.applyNow(config)
    }
    public func reset() { current.reset() }
    public func markStopped() { readState().markStopped() }
    public func snapshot() -> RenderSnapshot { readState().snapshot() }

    /// Queue a configuration change. Safe to call from any thread; the audio
    /// thread picks it up at the start of its next block.
    public func apply(_ config: ProcessorConfiguration) {
        let next = ProcessorRenderState()
        next.applyNow(config)
        next.prepare(sampleRate: sampleRate)
        os_unfair_lock_lock(lock)
        retired = nil
        pending = next
        os_unfair_lock_unlock(lock)
    }

    public func noteUnderrun() { current.noteUnderrun() }
    public func process(input: UnsafePointer<Float>, inputChannels: Int, frames: Int,
                        output: UnsafeMutablePointer<Float>) {
        if os_unfair_lock_trylock(lock) {
            if let next = pending, retired == nil {
                next.inheritHistory(from: current)
                retired = current
                current = next
                pending = nil
            }
            os_unfair_lock_unlock(lock)
        }
        current.process(input: input, inputChannels: inputChannels, frames: frames, output: output)
    }
}
