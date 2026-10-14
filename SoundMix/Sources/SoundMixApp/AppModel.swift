import SwiftUI
import Combine
import AppKit

@MainActor
final class AppModel: ObservableObject {

    // Devices
    @Published var devices: [AudioDevice] = []
    @Published var inputUID: String = ""
    @Published var outputUID: String = ""
    @Published var showIncompatibleDevices = false

    // Downmix
    @Published var layoutName: String = LayoutPreset.nativeBed.name
    @Published var recipeName: String = MatrixRecipe.reference.name
    @Published var customRecipe: MatrixRecipe = .reference
    @Published var headroomMode: HeadroomMode = .powerPreserving
    @Published var manualGainText: String = "0"
    @Published var swapOutputs = false

    // LFE (edited on the working recipe)
    @Published var lfeMode: LFEMode = .off
    @Published var lfeCutoffText: String = "120"
    @Published var lfeOrder: Int = 4
    @Published var lfeGainText: String = "0"

    // Limiter
    @Published var limiterEnabled = true
    @Published var limiterCeilingText: String = "-1.0"
    @Published var limiterReleaseText: String = "80"

    // PEQ
    @Published var globalPEQText: String = ""
    @Published var speakerPEQText: String = ""
    @Published var peqWarnings: [String] = []

    // EQ profile library
    @Published var profiles: [EQProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var profileNameDraft: String = ""
    @Published var profileNotesDraft: String = ""
    /// A/B: force both EQ stages flat without losing the text.
    @Published var eqBypassed = false
    @Published var profileDirty = false
    @Published var speakerSectionCollapsed = false
    /// The earphone curves paired with the current EQ, one per ear.
    @Published var measurementLeft: FrequencyResponse?
    @Published var measurementRight: FrequencyResponse?
    /// The reference curve the correction aims at.
    @Published var target: FrequencyResponse?
    @Published var measurementError: String?
    /// How the Response plot is drawn once a target is loaded.
    @Published var plotMode: PlotMode = .errorVsTarget
    /// Curves the viewer has switched off in the Response plot.
    @Published var hiddenTraces: Set<String> = []

    enum PlotMode: String, CaseIterable, Codable, Identifiable {
        case absolute, errorVsTarget
        var id: String { rawValue }
        var label: String { self == .absolute ? "Absolute" : "Error vs target" }
        var explanation: String {
            self == .absolute
                ? "Measured, target and result on shared axes, levelled over 200 Hz – 2 kHz."
                : "The target becomes a flat line and everything is drawn as deviation from it, so how close you are is read directly off the zero line."
        }
    }

    // Offline file rendering
    @Published var sourceInfo: OfflineRenderer.SourceInfo?
    @Published var fileLayoutName: String?
    @Published var outputBitDepth: Int = 24
    @Published var renderProgress: Double?
    @Published var renderResult: OfflineRenderer.Result?
    @Published var renderError: String?
    private var activeRenderer: OfflineRenderer?

    // Engine options
    @Published var framesPerBuffer: Int = 128
    @Published var safetyBufferText: String = "20"

    // Runtime
    @Published var state: EngineState = .stopped
    @Published var snapshot = RenderSnapshot()
    @Published var log: [String] = []
    @Published var errorMessage: String?
    @Published var micStatus: MicrophoneAccess.Status = MicrophoneAccess.status

    let directory = AudioDeviceDirectory()
    let engine = SoundMixEngine()
    let library = EQProfileLibrary()
    private var meterTimer: Timer?

    init() {
        devices = directory.devices
        inputUID = devices.first(where: { $0.isDefaultInput && $0.hasInput })?.uid
            ?? devices.first(where: \.hasInput)?.uid ?? ""
        outputUID = devices.first(where: { $0.isDefaultOutput })?.uid
            ?? devices.first(where: \.hasOutput)?.uid ?? ""

        directory.onChange = { [weak self] list in
            guard let self else { return }
            self.devices = list
            self.append("Audio device list changed — \(list.count) devices present.")
        }
        engine.onStateChange = { [weak self] s in
            guard let self else { return }
            self.state = s
            if case .failed(let message) = s {
                self.errorMessage = message
                self.append("Stopped: \(message)")
            }
        }
        engine.onLog = { [weak self] line in self?.append(line) }

        load()
        profiles = library.profiles
        if let id = selectedProfileID, let p = profiles.first(where: { $0.id == id }) {
            profileNameDraft = p.name
            profileNotesDraft = p.notes
        }

        startMeterTimer()
        append("SoundMix ready.")
    }

    // MARK: - Derived

    var inputDevice: AudioDevice? { devices.first { $0.uid == inputUID } }
    var outputDevice: AudioDevice? { devices.first { $0.uid == outputUID } }

    var layout: LayoutPreset {
        LayoutPreset.all.first { $0.name == layoutName } ?? .nativeBed
    }

    var availableRecipes: [MatrixRecipe] { MatrixRecipe.builtIns }

    /// The recipe with the live LFE edits folded in.
    var workingRecipe: MatrixRecipe {
        var r = availableRecipes.first { $0.name == recipeName } ?? .reference
        r.lfeMode = lfeMode
        r.lfeCutoffHz = Double(lfeCutoffText) ?? r.lfeCutoffHz
        r.lfeFilterOrder = lfeOrder
        r.lfeGainDB = Double(lfeGainText) ?? r.lfeGainDB
        return r
    }

    var globalProfile: PEQProfile {
        guard !eqBypassed, !globalPEQText.isEmpty else { return .flat }
        return APOParser.parse(globalPEQText).firstProfile
    }
    var speakerProfiles: (left: PEQProfile, right: PEQProfile) {
        guard !eqBypassed, !speakerPEQText.isEmpty else { return (.flat, .flat) }
        let doc = APOParser.parse(speakerPEQText)
        // The physical-left speaker gets channel 0 unless the outputs are swapped,
        // matching how the original launcher flips the CH selection.
        let a = doc.profile(forChannel: 0), b = doc.profile(forChannel: 1)
        return swapOutputs ? (b, a) : (a, b)
    }

    var configuration: ProcessorConfiguration {
        let speakers = speakerProfiles
        return ProcessorConfiguration(
            layout: layout,
            recipe: workingRecipe,
            headroomMode: headroomMode,
            manualGainDB: Double(manualGainText) ?? 0,
            swapOutputs: swapOutputs,
            globalPEQ: globalProfile,
            speakerPEQLeft: speakers.left,
            speakerPEQRight: speakers.right,
            limiter: TruePeakLimiter.Settings(
                ceilingDB: Double(limiterCeilingText) ?? -1,
                lookaheadMS: 2,
                releaseMS: Double(limiterReleaseText) ?? 80,
                enabled: limiterEnabled))
    }

    var limiterStatus: String {
        guard state.isRunning else { return "Stopped" }
        guard engine.processor.configuration.limiter.enabled else { return "Off" }
        return snapshot.gainReductionDB > 0.05
            ? String(format: "−%.1f dB", snapshot.gainReductionDB) : "Ready · 0 dB"
    }

    var gainBreakdown: String {
        let cfg = configuration
        return String(format: "Matrix trim %+.1f dB · manual %+.1f dB · global EQ preamp %+.1f dB · speaker preamps L %+.1f / R %+.1f dB. EQ filters add their own frequency-dependent boosts and cuts.",
                      cfg.automaticTrimDB, cfg.manualGainDB, cfg.globalPEQ.preampDB,
                      cfg.speakerPEQLeft.preampDB, cfg.speakerPEQRight.preampDB)
    }

    func adjustManualGain(by delta: Double) {
        let value = Double(manualGainText) ?? 0
        guard value.isFinite else { return }
        manualGainText = String(format: "%.1f", min(24, max(-60, value + delta)))
        applyLive()
    }

    var engineOptions: SoundMixEngine.Options {
        .init(framesPerBuffer: framesPerBuffer,
              safetyBufferMS: Double(safetyBufferText) ?? 20)
    }

    var compatibleInputs: [AudioDevice] {
        let needed = layout.requiredInputChannels
        return devices.filter { $0.hasInput && (showIncompatibleDevices || $0.inputChannels >= needed) }
    }
    var compatibleOutputs: [AudioDevice] {
        devices.filter { $0.hasOutput && (showIncompatibleDevices || $0.outputChannels >= 2) }
    }

    var startBlockedReason: String? {
        guard let input = inputDevice else { return "Select an input device." }
        guard let output = outputDevice else { return "Select an output device." }
        let needed = layout.requiredInputChannels
        if input.inputChannels < needed {
            return "“\(input.name)” has \(input.inputChannels) input channels; \(layout.name) needs \(needed)."
        }
        if output.outputChannels < 2 {
            return "“\(output.name)” cannot play stereo."
        }
        return nil
    }

    // MARK: - Transport

    func start() {
        errorMessage = nil
        guard inputDevice != nil, outputDevice != nil else { return }

        // Every Core Audio input counts as a microphone to macOS. Ask first;
        // opening the capture unit without authorisation simply blocks.
        if MicrophoneAccess.status == .notDetermined {
            append("Requesting microphone access — macOS requires it for any audio input device.")
        }
        MicrophoneAccess.request { [weak self] status in
            guard let self else { return }
            self.micStatus = status
            guard status.canCapture else {
                self.errorMessage = MicrophoneAccess.explanation(for: status)
                self.append("Cannot start: microphone access is \(status).")
                return
            }
            self.launch()
        }
    }

    private var runningEngineSettings: EngineSettings?

    private func launch() {
        guard let input = inputDevice, let output = outputDevice else { return }
        do {
            try engine.start(input: input, output: output,
                             configuration: configuration, options: engineOptions)
            runningEngineSettings = currentEngineSettings
        } catch {
            runningEngineSettings = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func stop() {
        engine.stop()
        runningEngineSettings = nil
    }

    /// The settings that are baked into the open audio units. Changing any of
    /// them cannot be done on the fly — the units have to be reopened.
    struct EngineSettings: Equatable {
        var inputUID: String
        var outputUID: String
        var framesPerBuffer: Int
        var safetyBufferMS: Double
    }

    var currentEngineSettings: EngineSettings {
        EngineSettings(inputUID: inputUID, outputUID: outputUID,
                       framesPerBuffer: framesPerBuffer,
                       safetyBufferMS: Double(safetyBufferText) ?? 20)
    }

    /// True when the open stream no longer matches the chosen devices or buffering.
    var needsRestartToApply: Bool {
        guard state.isRunning, let running = runningEngineSettings else { return false }
        return running != currentEngineSettings
    }

    /// Plain-language reason a restart is required, for the transport bar.
    var restartReason: String? {
        guard let running = runningEngineSettings, needsRestartToApply else { return nil }
        let now = currentEngineSettings
        var parts: [String] = []
        if running.inputUID != now.inputUID { parts.append("input device") }
        if running.outputUID != now.outputUID { parts.append("output device") }
        if running.framesPerBuffer != now.framesPerBuffer { parts.append("buffer size") }
        if running.safetyBufferMS != now.safetyBufferMS { parts.append("safety buffer") }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        return "Changing the \(list) reopens the audio stream."
    }

    /// Hot-applies what can be changed while streaming, and reopens the stream
    /// for the things that cannot. Before, this only pushed DSP parameters, so
    /// a device or buffer change silently did nothing until you stopped and
    /// started by hand.
    func applyLive() {
        guard state.isRunning else { return }
        if needsRestartToApply {
            append("Reopening the audio stream to apply the new device or buffer settings…")
            engine.stop()
            launch()
            return
        }
        engine.apply(configuration)
        append(String(format: "Applied · trim %+.1f dB · worst case %+.1f dB",
                      configuration.totalTrimDB,
                      configuration.effectiveMatrix.worstCasePeakGainDB))
    }

    func syncRecipeEditors() {
        let r = availableRecipes.first { $0.name == recipeName } ?? .reference
        lfeMode = r.lfeMode
        lfeCutoffText = String(format: "%.0f", r.lfeCutoffHz)
        lfeOrder = r.lfeFilterOrder
        lfeGainText = String(format: "%.2f", r.lfeGainDB)
    }

    func refreshDevices() {
        directory.refresh()
        devices = directory.devices
        append("Rescanned Core Audio devices — \(devices.count) present.")
    }

    func reloadPEQWarnings() {
        var w: [String] = []
        if !globalPEQText.isEmpty { w += APOParser.parse(globalPEQText).warnings.map { "Global PEQ: \($0)" } }
        if !speakerPEQText.isEmpty { w += APOParser.parse(speakerPEQText).warnings.map { "Speaker EQ: \($0)" } }
        peqWarnings = Array(w.prefix(6))
    }

    private func append(_ line: String) {
        let stamp = Self.formatter.string(from: Date())
        log.append("[\(stamp)] \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func clearLog() { log.removeAll() }

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private var telemetryTick = 0

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.state.isRunning else { return }
                self.snapshot = self.engine.processor.snapshot()
                self.telemetryTick += 1
                if self.telemetryTick % 15 == 0 { Telemetry.capture(self).write() }
            }
        }
    }

    /// Shown on the Speaker correction header while it is folded away.
    var speakerSectionSummary: String {
        guard !speakerPEQText.isEmpty else { return "none" }
        let s = speakerProfiles
        let l = s.left.activeFilterCount, r = s.right.activeFilterCount
        if l == 0 && r == 0 { return "none" }
        return l == r ? "\(l) filters per speaker" : "L \(l) · R \(r) filters"
    }

    // MARK: - EQ profile library

    var selectedProfile: EQProfile? {
        guard let id = selectedProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Peak boost of what is currently in the editors — the headroom a profile costs.
    var editorPeakBoostDB: Double {
        let rate = state.isRunning ? engine.currentSampleRate : 48_000
        let draft = EQProfile(name: "", globalText: globalPEQText, speakerText: speakerPEQText)
        return draft.peakBoostDB(sampleRate: rate)
    }

    func refreshProfiles() {
        library.reload()
        profiles = library.profiles
    }

    func selectProfile(_ profile: EQProfile) {
        selectedProfileID = profile.id
        profileNameDraft = profile.name
        profileNotesDraft = profile.notes
        globalPEQText = profile.globalText
        speakerPEQText = profile.speakerText
        measurementLeft = profile.measurementLeft
        measurementRight = profile.measurementRight
        target = profile.target
        profileDirty = false
        reloadPEQWarnings()
        applyLive()
        append("Loaded EQ profile “\(profile.name)”.")
    }

    func newProfile() {
        do {
            let name = uniqueNewName()
            let p = try library.save(EQProfile(name: name,
                                           globalText: globalPEQText,
                                           speakerText: speakerPEQText,
                                           measurementLeft: measurementLeft,
                                           measurementRight: measurementRight,
                                           target: target))
            refreshProfiles()
            selectedProfileID = p.id
            profileNameDraft = p.name
            profileNotesDraft = p.notes
            profileDirty = false
            append("Created EQ profile “\(name)”.")
        } catch {
            errorMessage = error.localizedDescription
            append("EQ profile operation failed: \(error.localizedDescription)")
        }
    }

    private func uniqueNewName() -> String {
        let existing = Set(profiles.map(\.name))
        if !existing.contains("Untitled") { return "Untitled" }
        var n = 2
        while existing.contains("Untitled \(n)") { n += 1 }
        return "Untitled \(n)"
    }

    func saveSelectedProfile() {
        do {
            guard var p = selectedProfile else { newProfile(); return }
            p.name = profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? p.name : profileNameDraft
            p.notes = profileNotesDraft
            p.globalText = globalPEQText
            p.speakerText = speakerPEQText
            p.measurementLeft = measurementLeft
            p.measurementRight = measurementRight
            p.target = target
            let saved = try library.save(p)
            refreshProfiles()
            selectedProfileID = saved.id
            profileDirty = false
            append("Saved EQ profile “\(saved.name)”.")
        } catch {
            errorMessage = error.localizedDescription
            append("EQ profile operation failed: \(error.localizedDescription)")
        }
    }

    func duplicateSelectedProfile() {
        do {
            guard let p = selectedProfile else { return }
            let copy = try library.duplicate(p)
            refreshProfiles()
            selectedProfileID = copy.id
            profileNameDraft = copy.name
            append("Duplicated to “\(copy.name)”.")
        } catch {
            errorMessage = error.localizedDescription
            append("EQ profile operation failed: \(error.localizedDescription)")
        }
    }

    func deleteSelectedProfile() {
        do {
            guard let p = selectedProfile else { return }
            try library.delete(p)
            refreshProfiles()
            selectedProfileID = profiles.first?.id
            if let next = selectedProfile {
                profileNameDraft = next.name
                profileNotesDraft = next.notes
            } else {
                profileNameDraft = ""
                profileNotesDraft = ""
            }
            append("Deleted EQ profile “\(p.name)”.")
        } catch {
            errorMessage = error.localizedDescription
            append("EQ profile operation failed: \(error.localizedDescription)")
        }
    }

    func importProfile(text: String, name: String, asSpeakerCorrection: Bool) {
        do {
            let p = try library.importAPO(text: text, name: name, asSpeakerCorrection: asSpeakerCorrection)
            refreshProfiles()
            selectProfile(p)
            append("Imported “\(name)” as \(asSpeakerCorrection ? "speaker correction" : "global PEQ").")
        } catch {
            errorMessage = error.localizedDescription
            append("EQ profile operation failed: \(error.localizedDescription)")
        }
    }

    func markProfileDirty() {
        guard let p = selectedProfile else { return }
        profileDirty = p.globalText != globalPEQText
            || p.speakerText != speakerPEQText
            || p.measurementLeft != measurementLeft
            || p.measurementRight != measurementRight
            || p.target != target
    }

    // MARK: Offline file rendering

    /// The layout used for a file render — the file's own suggestion unless
    /// it has been overridden.
    var fileLayout: LayoutPreset {
        if let name = fileLayoutName, let l = LayoutPreset.all.first(where: { $0.name == name }) {
            return l
        }
        return sourceInfo?.suggestedLayout ?? .nativeBed
    }

    var isRendering: Bool { renderProgress != nil }

    var fileRenderBlockedReason: String? {
        guard let info = sourceInfo else { return "Choose a multichannel file." }
        let needed = fileLayout.requiredInputChannels
        if info.channels < needed {
            return "The file has \(info.channels) channel\(info.channels == 1 ? "" : "s"); \(fileLayout.name) needs \(needed)."
        }
        return nil
    }

    func chooseSourceFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a multichannel audio file to fold down to stereo."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adoptSourceFile(url)
    }

    func adoptSourceFile(_ url: URL) {
        renderResult = nil
        renderError = nil
        do {
            let info = try OfflineRenderer.inspect(url)
            sourceInfo = info
            fileLayoutName = info.suggestedLayout?.name
            append(String(format: "Opened “%@” — %d ch, %.0f Hz, %.1f s.",
                          url.lastPathComponent, info.channels, info.sampleRate, info.duration))
        } catch {
            sourceInfo = nil
            renderError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Where the stereo file goes: alongside the source, clearly named.
    func suggestedOutputURL(for info: OfflineRenderer.SourceInfo) -> URL {
        let base = info.url.deletingPathExtension().lastPathComponent
        return info.url.deletingLastPathComponent()
            .appendingPathComponent("\(base) (stereo).wav")
    }

    func renderFile() {
        guard let info = sourceInfo, fileRenderBlockedReason == nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedOutputURL(for: info).lastPathComponent
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.message = "Where should the stereo render go?"
        guard panel.runModal() == .OK, let out = panel.url else { return }

        // The file render uses the same configuration as live playback, with
        // the layout the file itself calls for.
        var cfg = configuration
        cfg.layout = fileLayout

        let renderer = OfflineRenderer()
        activeRenderer = renderer
        renderProgress = 0
        renderResult = nil
        renderError = nil
        let depth = outputBitDepth
        let source = info.url
        append("Rendering “\(source.lastPathComponent)” → “\(out.lastPathComponent)”…")

        Task.detached(priority: .userInitiated) {
            do {
                let result = try renderer.render(input: source, output: out,
                                                 configuration: cfg, bitDepth: depth) { p in
                    Task { @MainActor in self.renderProgress = p }
                }
                await MainActor.run {
                    self.renderProgress = nil
                    self.renderResult = result
                    self.activeRenderer = nil
                    self.append(String(format: "Rendered %.1f s in %.2f s (%.0f× real time) · peak %.1f / %.1f dBFS · limiter %.1f dB · %d clipped",
                                       result.duration, result.renderTime, result.speedFactor,
                                       result.peakLeftDB, result.peakRightDB,
                                       result.maxGainReductionDB, result.clippedSamples))
                }
            } catch {
                await MainActor.run {
                    self.renderProgress = nil
                    self.activeRenderer = nil
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.renderError = message
                    self.append("Render failed: \(message)")
                }
            }
        }
    }

    func cancelRender() {
        activeRenderer?.cancel()
        append("Cancelling render…")
    }

    func revealRenderResult() {
        guard let r = renderResult else { return }
        NSWorkspace.shared.activateFileViewerSelecting([r.outputURL])
    }

    // MARK: Earphone measurement

    var hasMeasurement: Bool { measurementLeft != nil || measurementRight != nil }

    func measurement(_ side: EQProfile.Side) -> FrequencyResponse? {
        side == .left ? measurementLeft : measurementRight
    }

    private func setMeasurement(_ value: FrequencyResponse?, for side: EQProfile.Side) {
        if side == .left { measurementLeft = value } else { measurementRight = value }
    }

    /// Load a measured response for one ear, exported from AutoEQ,
    /// oratory1990, a squig.link database or REW.
    ///
    /// A file with three columns (`frequency left right`) fills both ears at
    /// once, which is how most IEM measurements are published.
    func loadMeasurement(for side: EQProfile.Side) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a measured response for the \(side.label.lowercased()) ear. A three-column file fills both ears at once."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            measurementError = "Could not read \(url.lastPathComponent)."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent

        if let pair = FrequencyResponse.parsePair(text, name: name) {
            measurementLeft = pair.left.normalized()
            measurementRight = pair.right.normalized()
            measurementError = nil
            markProfileDirty()
            append(String(format: "Loaded “%@” as a matched pair — %d points per ear, %.0f Hz to %.0f Hz.",
                          name, pair.left.points.count, pair.left.range.low, pair.left.range.high))
            return
        }

        guard let parsed = FrequencyResponse.parse(text, name: name) else {
            measurementError = "\(url.lastPathComponent) does not look like a measurement — expected at least eight lines of “frequency level”, optionally with a third column for the right ear."
            return
        }
        setMeasurement(parsed.normalized(), for: side)
        measurementError = nil
        markProfileDirty()
        let r = parsed.range
        append(String(format: "Loaded %@ measurement “%@” — %d points, %.0f Hz to %.0f Hz.",
                      side.label.lowercased(), name, parsed.points.count, r.low, r.high))
    }

    func clearMeasurement(_ side: EQProfile.Side) {
        setMeasurement(nil, for: side)
        measurementError = nil
        markProfileDirty()
    }

    /// Exchange the two ears. A measurement imported before the split, or a
    /// file picked into the wrong slot, lands on the correct side without
    /// re-uploading it.
    func swapMeasurements() {
        let l = measurementLeft
        measurementLeft = measurementRight
        measurementRight = l
        markProfileDirty()
        append("Swapped the left and right earphone curves.")
    }

    /// Move one ear's curve to the other side, leaving this one empty.
    func moveMeasurement(from side: EQProfile.Side) {
        guard let curve = measurement(side) else { return }
        let other: EQProfile.Side = side == .left ? .right : .left
        setMeasurement(curve, for: other)
        setMeasurement(nil, for: side)
        markProfileDirty()
        append("Moved the curve to the \(other.label.lowercased()) ear.")
    }

    /// Load a reference target — JM-1, a Harman variant, or a house curve.
    /// Nothing about the shape is assumed; it comes entirely from the file.
    func loadTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a target curve (frequency and level per line). JM-1 and the Harman targets are published in this format."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            measurementError = "Could not read \(url.lastPathComponent)."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard let parsed = FrequencyResponse.parse(text, name: name) else {
            measurementError = "\(url.lastPathComponent) does not look like a target curve — expected at least eight lines of “frequency level”."
            return
        }
        target = parsed.normalized()
        measurementError = nil
        markProfileDirty()
        let r = parsed.range
        append(String(format: "Loaded target “%@” — %d points, %.0f Hz to %.0f Hz.",
                      name, parsed.points.count, r.low, r.high))
    }

    func clearTarget() {
        target = nil
        markProfileDirty()
    }

    /// True only when there is both a target and something to measure
    /// against it. The error view is meaningless otherwise.
    var canShowErrorView: Bool { target != nil && hasMeasurement }

    /// Worst deviation of the corrected result from the target (or from its own
    /// mean when no target is loaded), across both ears.
    func resultDeviationDB() -> Double {
        let rate = state.isRunning ? engine.currentSampleRate : 48_000
        var worst = 0.0
        for side in EQProfile.Side.allCases {
            guard let m = measurement(side) else { continue }
            let corrected = m.corrected(by: combinedEQCascade(side), sampleRate: rate)
            guard !corrected.isEmpty else { continue }
            if let t = target {
                let curve = FrequencyResponse(name: "", points: corrected).normalized()
                let ref = t.normalized()
                for p in curve.points {
                    worst = max(worst, abs(p.db - ref.magnitudeDB(at: p.hz)))
                }
            } else {
                let mean = corrected.reduce(0) { $0 + $1.db } / Double(corrected.count)
                worst = max(worst, corrected.reduce(0.0) { max($0, abs($1.db - mean)) })
            }
        }
        return worst
    }

    func clearAllMeasurements() {
        measurementLeft = nil
        measurementRight = nil
        measurementError = nil
        markProfileDirty()
    }

    /// Copy one ear's curve to the other, for a measurement published as a
    /// single averaged response.
    func mirrorMeasurement(from side: EQProfile.Side) {
        guard let source = measurement(side) else { return }
        let other: EQProfile.Side = side == .left ? .right : .left
        setMeasurement(FrequencyResponse(name: source.name, points: source.points), for: other)
        markProfileDirty()
        append("Copied the \(side.label.lowercased()) measurement to the \(other.label.lowercased()) ear.")
    }

    /// Everything the EQ does to one output, as a single cascade — the curve
    /// added to that ear's measurement. Global PEQ hits both; the speaker
    /// correction differs per side.
    func combinedEQCascade(_ side: EQProfile.Side) -> BiquadCascade {
        let rate = state.isRunning ? engine.currentSampleRate : 48_000
        let global = globalProfile.cascade(sampleRate: rate)
        let speaker = (side == .left ? speakerProfiles.left : speakerProfiles.right)
            .cascade(sampleRate: rate)
        return BiquadCascade(sections: global.sections + speaker.sections,
                             preGain: global.preGain * speaker.preGain)
    }

    // MARK: Portable import / export

    func exportProfiles(_ list: [EQProfile], suggestedName: String) {
        guard !list.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).\(EQProfileLibrary.fileExtension)"
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.message = list.count == 1
            ? "Export this EQ profile."
            : "Export all \(list.count) EQ profiles as one file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.exportData(list).write(to: url)
            append("Exported \(list.count) EQ profile\(list.count == 1 ? "" : "s") to \(url.lastPathComponent).")
        } catch {
            errorMessage = "Could not export: \(error.localizedDescription)"
        }
    }

    func exportSelectedAsAPO(speakerCorrection: Bool) {
        guard let p = selectedProfile else { return }
        let text = library.exportAPO(p, speakerCorrection: speakerCorrection)
        guard !text.isEmpty else {
            errorMessage = "That profile has no \(speakerCorrection ? "speaker correction" : "global PEQ") to export."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(p.name)\(speakerCorrection ? " speaker" : "").txt"
        panel.allowsOtherFileTypes = true
        panel.message = "Export as REW / Equalizer APO text."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            append("Exported “\(p.name)” as APO text.")
        } catch {
            errorMessage = "Could not export: \(error.localizedDescription)"
        }
    }

    func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.message = "Import SoundMix EQ exports (.smeq) or REW / Equalizer APO text files."
        guard panel.runModal() == .OK else { return }
        var imported: [EQProfile] = []
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            do {
                imported += try library.importData(data, fallbackName: base)
            } catch {
                errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        refreshProfiles()
        if let first = imported.first { selectProfile(first) }
        if !imported.isEmpty {
            append("Imported \(imported.count) EQ profile\(imported.count == 1 ? "" : "s").")
        }
    }

    func revealProfileFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([library.folderURL])
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var inputUID, outputUID, layoutName, recipeName: String
        var headroomMode: HeadroomMode
        var manualGainText: String
        var swapOutputs: Bool
        var lfeMode: LFEMode
        var lfeCutoffText, lfeGainText: String
        var lfeOrder: Int
        var limiterEnabled: Bool
        var limiterCeilingText, limiterReleaseText: String
        var globalPEQText, speakerPEQText: String
        var framesPerBuffer: Int
        var safetyBufferText: String
        var selectedProfileID: UUID?
        var eqBypassed: Bool?
        var speakerSectionCollapsed: Bool?
    }

    private static var settingsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundMix", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("settings.json")
    }

    func save() {
        let s = Stored(inputUID: inputUID, outputUID: outputUID, layoutName: layoutName,
                       recipeName: recipeName, headroomMode: headroomMode,
                       manualGainText: manualGainText, swapOutputs: swapOutputs,
                       lfeMode: lfeMode, lfeCutoffText: lfeCutoffText, lfeGainText: lfeGainText,
                       lfeOrder: lfeOrder, limiterEnabled: limiterEnabled,
                       limiterCeilingText: limiterCeilingText, limiterReleaseText: limiterReleaseText,
                       globalPEQText: globalPEQText, speakerPEQText: speakerPEQText,
                       framesPerBuffer: framesPerBuffer, safetyBufferText: safetyBufferText,
                       selectedProfileID: selectedProfileID, eqBypassed: eqBypassed,
                       speakerSectionCollapsed: speakerSectionCollapsed)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: Self.settingsURL) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.settingsURL),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        // Only restore a device selection that still exists, so a stale saved
        // path can never silently point at something that is gone.
        if devices.contains(where: { $0.uid == s.inputUID }) { inputUID = s.inputUID }
        if devices.contains(where: { $0.uid == s.outputUID }) { outputUID = s.outputUID }
        layoutName = s.layoutName
        recipeName = s.recipeName
        headroomMode = s.headroomMode
        manualGainText = s.manualGainText
        swapOutputs = s.swapOutputs
        lfeMode = s.lfeMode
        lfeCutoffText = s.lfeCutoffText
        lfeGainText = s.lfeGainText
        lfeOrder = s.lfeOrder
        limiterEnabled = s.limiterEnabled
        limiterCeilingText = s.limiterCeilingText
        limiterReleaseText = s.limiterReleaseText
        globalPEQText = s.globalPEQText
        speakerPEQText = s.speakerPEQText
        framesPerBuffer = s.framesPerBuffer
        safetyBufferText = s.safetyBufferText
        selectedProfileID = s.selectedProfileID
        eqBypassed = s.eqBypassed ?? false
        speakerSectionCollapsed = s.speakerSectionCollapsed ?? false
    }
}
