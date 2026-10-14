import Foundation
import AVFoundation

var failures = 0, checks = 0
func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok { print("  ok   \(label)") } else { failures += 1; print("  FAIL \(label) \(detail())") }
}
func near(_ a: Double, _ b: Double, _ tol: Double, _ label: String) {
    checks += 1
    if abs(a - b) <= tol { print("  ok   \(label)  (\(fmt(a)))") }
    else { failures += 1; print("  FAIL \(label): got \(fmt(a)) expected \(fmt(b)) ±\(tol)") }
}
func fmt(_ v: Double) -> String { v.isFinite ? String(format: "%.4f", v) : (v < 0 ? "-inf" : "inf") }
func section(_ s: String) { print("\n── \(s)") }

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("soundmix-offline-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let sr = 48_000.0

/// Write a multichannel WAV where channel i holds a sine at a known amplitude.
func writeSource(channels: Int, seconds: Double, amplitude: (Int) -> Double,
                 name: String) throws -> URL {
    let url = tmp.appendingPathComponent(name)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sr,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = file.processingFormat
    let total = Int(seconds * sr)
    let block = 4096
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
    var n = 0
    while n < total {
        let count = min(block, total - n)
        buf.frameLength = AVAudioFrameCount(count)
        for c in 0..<channels {
            let plane = buf.floatChannelData![c]
            let amp = amplitude(c)
            let freq = 110.0 * Double(c + 2)
            for f in 0..<count {
                plane[f] = Float(amp * sin(2 * .pi * freq * Double(n + f) / sr))
            }
        }
        try file.write(from: buf)
        n += count
    }
    return url
}

/// Read a stereo file back and report peak per channel plus frame count.
func analyse(_ url: URL) throws -> (peakL: Double, peakR: Double, frames: Int, channels: Int, rate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
    var pl = 0.0, pr = 0.0, frames = 0
    while true {
        buf.frameLength = 0
        if file.framePosition >= file.length { break }
        do { try file.read(into: buf) } catch { break }
        let n = Int(buf.frameLength)
        if n == 0 { break }
        if let d = buf.floatChannelData {
            for f in 0..<n {
                pl = max(pl, abs(Double(d[0][f])))
                if format.channelCount > 1 { pr = max(pr, abs(Double(d[1][f]))) }
            }
        }
        frames += n
    }
    return (pl, pr, frames, Int(format.channelCount), format.sampleRate)
}

func db(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -.infinity }

section("Inspecting a source file")
let src16 = try! writeSource(channels: 16, seconds: 1.0,
                             amplitude: { _ in 0.25 }, name: "bed16.wav")
do {
    let info = try OfflineRenderer.inspect(src16)
    check(info.channels == 16, "channel count read", "\(info.channels)")
    near(info.sampleRate, sr, 1e-9, "sample rate read")
    near(info.duration, 1.0, 0.01, "duration read")
    check(info.suggestedLayout?.name == "9.1.6", "suggests 9.1.6 for a 16-channel file",
          info.suggestedLayout?.name ?? "nil")

    let src6 = try! writeSource(channels: 6, seconds: 0.2, amplitude: { _ in 0.1 }, name: "bed6.wav")
    let info6 = try OfflineRenderer.inspect(src6)
    check(info6.suggestedLayout?.name == "5.1", "suggests 5.1 for a 6-channel file",
          info6.suggestedLayout?.name ?? "nil")
}

section("Rendering reproduces the matrix exactly")
do {
    // Front left only, so the expected output is unambiguous.
    let src = try! writeSource(channels: 16, seconds: 0.5,
                               amplitude: { $0 == 0 ? 0.5 : 0 }, name: "frontleft.wav")
    var cfg = ProcessorConfiguration(layout: .nativeBed, recipe: .reference,
                                     headroomMode: .none, manualGainDB: 0)
    cfg.limiter = .init(enabled: false)
    let out = tmp.appendingPathComponent("fl-out.wav")
    let r = try OfflineRenderer().render(input: src, output: out, configuration: cfg, bitDepth: 32)
    let a = try analyse(out)
    check(a.channels == 2, "output is stereo", "\(a.channels)")
    near(a.rate, sr, 1e-9, "output keeps the sample rate")
    near(a.peakL, 0.5, 0.002, "front left arrives at unity on L")
    near(a.peakR, 0.0, 1e-4, "front left does not reach R")
    check(r.clippedSamples == 0, "no clipping", "\(r.clippedSamples)")
    print("       → rendered \(String(format: "%.2f", r.duration))s in \(String(format: "%.3f", r.renderTime))s (\(String(format: "%.0f", r.speedFactor))× real time)")

    // Centre must land at -3.01 dB on both.
    let srcC = try! writeSource(channels: 16, seconds: 0.5,
                                amplitude: { $0 == 2 ? 0.5 : 0 }, name: "centre.wav")
    let outC = tmp.appendingPathComponent("c-out.wav")
    _ = try OfflineRenderer().render(input: srcC, output: outC, configuration: cfg, bitDepth: 32)
    let ac = try analyse(outC)
    near(db(ac.peakL) - db(0.5), -3.0103, 0.05, "centre folds to L at −3.01 dB")
    near(db(ac.peakR) - db(0.5), -3.0103, 0.05, "centre folds to R at −3.01 dB")
}

section("Headroom and the limiter on a hostile file")
do {
    // Every channel at full scale at once — the case the original app clips on.
    let src = try! writeSource(channels: 16, seconds: 0.5,
                               amplitude: { _ in 0.95 }, name: "hostile.wav")

    var unprotected = ProcessorConfiguration(layout: .nativeBed, recipe: .parity,
                                             headroomMode: .none, manualGainDB: -9.5)
    unprotected.limiter = .init(enabled: false)
    let outRaw = tmp.appendingPathComponent("hostile-raw.wav")
    let rRaw = try OfflineRenderer().render(input: src, output: outRaw,
                                            configuration: unprotected, bitDepth: 32)
    check(rRaw.peakLeftDB > 0, "the original's −9.5 dB preamp overloads on this file",
          "peak \(fmt(rRaw.peakLeftDB)) dBFS")

    var safe = ProcessorConfiguration(layout: .nativeBed, recipe: .parity,
                                      headroomMode: .peakSafe, manualGainDB: 0)
    safe.limiter = .init(ceilingDB: -1, lookaheadMS: 2, releaseMS: 80, enabled: true)
    let outSafe = tmp.appendingPathComponent("hostile-safe.wav")
    let rSafe = try OfflineRenderer().render(input: src, output: outSafe,
                                             configuration: safe, bitDepth: 32)
    check(rSafe.peakLeftDB <= -0.85, "peak-safe trim plus limiter holds the ceiling",
          "peak \(fmt(rSafe.peakLeftDB)) dBFS")
    check(rSafe.clippedSamples == 0, "no clipped samples", "\(rSafe.clippedSamples)")
}

section("Layout and error handling")
do {
    let src6 = tmp.appendingPathComponent("bed6.wav")
    var cfg = ProcessorConfiguration(layout: .nativeBed, recipe: .reference)
    cfg.limiter = .init(enabled: false)
    var threw = false
    do {
        _ = try OfflineRenderer().render(input: src6,
                                         output: tmp.appendingPathComponent("bad.wav"),
                                         configuration: cfg)
    } catch { threw = true
        check("\(error)".contains("6") || (error as? LocalizedError)?.errorDescription?.contains("6") == true,
              "the error names the file's channel count",
              (error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
    check(threw, "a 6-channel file against a 9.1.6 layout is refused")

    // The same file with a matching layout renders fine.
    cfg.layout = LayoutPreset.all.first { $0.name == "5.1" }!
    let out = tmp.appendingPathComponent("ok51.wav")
    let r = try OfflineRenderer().render(input: src6, output: out, configuration: cfg)
    check(r.frames > 0, "5.1 file renders against the 5.1 layout", "\(r.frames) frames")
    let a = try analyse(out)
    check(a.channels == 2 && a.frames > 0, "and produces a stereo file")

    var missing = false
    do { _ = try OfflineRenderer.inspect(tmp.appendingPathComponent("nope.wav")) }
    catch { missing = true }
    check(missing, "a missing file is reported rather than crashing")
}

section("Output bit depth")
do {
    let src = tmp.appendingPathComponent("bed16.wav")
    var cfg = ProcessorConfiguration(layout: .nativeBed, recipe: .reference)
    cfg.limiter = .init(enabled: false)
    for depth in [16, 24, 32] {
        let out = tmp.appendingPathComponent("depth\(depth).wav")
        _ = try OfflineRenderer().render(input: src, output: out, configuration: cfg, bitDepth: depth)
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int) ?? 0
        check(size > 1000, "\(depth)-bit output written", "\(size) bytes")
    }
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("Offline rendering verified.")
