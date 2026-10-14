import Foundation

// Minimal harness so the DSP can be verified without Xcode or a test rig.
var failures = 0, checks = 0

func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok { print("  ok   \(label)") }
    else { failures += 1; print("  FAIL \(label) \(detail())") }
}

func near(_ a: Double, _ b: Double, _ tol: Double, _ label: String) {
    checks += 1
    if abs(a - b) <= tol { print("  ok   \(label)  (\(fmt(a)))") }
    else { failures += 1; print("  FAIL \(label): got \(fmt(a)) expected \(fmt(b)) ±\(tol)") }
}

func fmt(_ v: Double) -> String {
    v.isFinite ? String(format: "%.6f", v) : (v < 0 ? "-inf" : "inf")
}

func section(_ name: String) { print("\n── \(name)") }

let sr = 48_000.0

// MARK: - Parity with the original binary

section("Matrix parity with the shipped renderer")
do {
    let m = MatrixRecipe.parity.matrix()
    near(m[.l].left, 1.0, 1e-12, "FL → L is unity")
    near(m[.l].right, 0.0, 1e-12, "FL → R is silent")
    near(m[.r].right, 1.0, 1e-12, "FR → R is unity")
    near(m[.c].left, 0.70710678, 1e-7, "FC → L matches 0.70710678")
    near(m[.c].right, 0.70710678, 1e-7, "FC → R matches 0.70710678")
    // The constant recovered from _main at 0x100002780 (0x40021DFDD6042E0D).
    near(m[.lfe].left, 2.26464431, 1e-6, "LFE coefficient matches the binary")
    near(m[.lfe].right, 2.26464431, 1e-6, "LFE coefficient is the same on R")
    for ch in [BedChannel.ls, .lrs, .lw, .ltf, .ltm, .ltr] {
        near(m[ch].left, 1.0, 1e-12, "\(ch.shortName) → L is unity (original behaviour)")
        near(m[ch].right, 0.0, 1e-12, "\(ch.shortName) → R is silent")
    }
    for ch in [BedChannel.rs, .rrs, .rw, .rtf, .rtm, .rtr] {
        near(m[ch].right, 1.0, 1e-12, "\(ch.shortName) → R is unity (original behaviour)")
    }
}

section("Headroom analysis exposes the original's overload")
do {
    let m = MatrixRecipe.parity.matrix()
    // 7 left-side channels at 1.0, centre at 0.7071, LFE at 2.2646.
    near(m.worstCasePeakGain, 7 + 0.70710678 + 2.26464431, 1e-6, "parity worst-case L1 gain")
    check(m.worstCasePeakGainDB > 19.5 && m.worstCasePeakGainDB < 20.5,
          "parity can reach ~+20 dB", "got \(fmt(m.worstCasePeakGainDB)) dB")
    // The original ships a -9.5 dB preamp default, which does not cover this.
    check(m.worstCasePeakGainDB > 9.5,
          "the original's -9.5 dB default cannot prevent clipping")

    let ref = MatrixRecipe.reference.matrix()
    check(ref.worstCasePeakGainDB < m.worstCasePeakGainDB,
          "reference fold has less worst-case gain than parity",
          "\(fmt(ref.worstCasePeakGainDB)) vs \(fmt(m.worstCasePeakGainDB))")
}

section("Automatic trim actually removes the overload")
do {
    for mode in [HeadroomMode.peakSafe, .powerPreserving] {
        var cfg = ProcessorConfiguration()
        cfg.recipe = .parity
        cfg.layout = .nativeBed
        cfg.headroomMode = mode
        let trimmed = cfg.effectiveMatrix.scaled(by: SoundMixMatrix.linear(cfg.automaticTrimDB))
        switch mode {
        case .peakSafe:
            near(trimmed.worstCasePeakGain, 1.0, 1e-9, "peak-safe trim lands exactly at unity L1")
        case .powerPreserving:
            near(trimmed.uncorrelatedGain, 1.0, 1e-9, "power-preserving trim lands at unity L2")
        case .none: break
        }
    }
}

section("Layout restriction changes the trim")
do {
    var a = ProcessorConfiguration(); a.recipe = .parity; a.layout = .nativeBed
    var b = ProcessorConfiguration(); b.recipe = .parity
    b.layout = LayoutPreset.all.first { $0.name == "5.1" }!
    a.headroomMode = .peakSafe; b.headroomMode = .peakSafe
    check(b.automaticTrimDB > a.automaticTrimDB,
          "a 5.1 source needs less trim than a full 9.1.6 bed",
          "5.1 \(fmt(b.automaticTrimDB)) dB vs 9.1.6 \(fmt(a.automaticTrimDB)) dB")
}

// MARK: - Filters

section("Butterworth low-pass design")
do {
    let fc = 125.0
    let c = BiquadDesign.butterworthLowPass(frequency: fc, order: 4, sampleRate: sr)
    check(c.sections.count == 2, "4th order is two biquads", "got \(c.sections.count)")
    near(c.magnitudeDB(at: fc, sampleRate: sr), -3.0103, 0.05, "−3 dB at the cutoff")
    near(c.magnitudeDB(at: fc / 8, sampleRate: sr), 0.0, 0.05, "flat three octaves below")
    // 24 dB/octave: one octave up from cutoff is about −24 dB below the −3 dB point.
    let oneOctave = c.magnitudeDB(at: fc * 2, sampleRate: sr)
    near(oneOctave, -24.1, 0.6, "≈ −24 dB one octave above the cutoff")
    let twoOctaves = c.magnitudeDB(at: fc * 4, sampleRate: sr)
    near(twoOctaves - oneOctave, -24.0, 0.8, "slope is 24 dB/octave")

    for order in [1, 2, 3, 5, 6, 8] {
        let cc = BiquadDesign.butterworthLowPass(frequency: 200, order: order, sampleRate: sr)
        near(cc.magnitudeDB(at: 200, sampleRate: sr), -3.0103, 0.1, "order \(order) is −3 dB at cutoff")
        near(cc.magnitudeDB(at: 10, sampleRate: sr), 0.0, 0.05, "order \(order) is flat in the passband")
    }

    let tau = c.groupDelay(at: 0, sampleRate: sr)
    check(tau > 0 && tau < sr, "DC group delay is sane", "\(fmt(tau)) samples")
    print("       → 125 Hz / 4th order DC group delay = \(fmt(tau)) samples (\(fmt(tau / sr * 1000)) ms)")
}

section("Peaking and shelving filters")
do {
    let pk = BiquadDesign.peaking(frequency: 1000, q: 1.41, gainDB: 6, sampleRate: sr)
    near(pk.magnitudeDB(at: 1000, sampleRate: sr), 6.0, 0.02, "peaking hits its gain at Fc")
    near(pk.magnitudeDB(at: 20, sampleRate: sr), 0.0, 0.1, "peaking is flat far below")
    let ls = BiquadDesign.lowShelf(frequency: 200, q: 0.707, gainDB: -6, sampleRate: sr)
    near(ls.magnitudeDB(at: 10, sampleRate: sr), -6.0, 0.2, "low shelf reaches its gain at DC")
    near(ls.magnitudeDB(at: 10_000, sampleRate: sr), 0.0, 0.2, "low shelf is flat up top")
    let hs = BiquadDesign.highShelf(frequency: 4000, q: 0.707, gainDB: 4, sampleRate: sr)
    near(hs.magnitudeDB(at: 20_000, sampleRate: sr), 4.0, 0.4, "high shelf reaches its gain up top")
    near(hs.magnitudeDB(at: 50, sampleRate: sr), 0.0, 0.2, "high shelf is flat down low")
}

// MARK: - PEQ file compatibility

section("REW / Equalizer APO parsing")
do {
    let text = """
    Preamp: -6.3 dB
    Filter 1: ON PK Fc 1000 Hz Gain -3.0 dB Q 1.41
    Filter 2: ON LSC Fc 105 Hz Gain 4.5 dB Q 0.70
    Filter 3: OFF HS Fc 10000 Hz Gain -2 dB Q 0.71
    Filter 4: ON None
    # a comment
    """
    let doc = APOParser.parse(text)
    let p = doc.firstProfile
    near(p.preampDB, -6.3, 1e-9, "preamp parsed")
    check(p.filters.count == 3, "three filters parsed", "got \(p.filters.count)")
    check(p.activeFilterCount == 2, "one filter is OFF", "active \(p.activeFilterCount)")
    check(p.filters[0].kind == .peaking && p.filters[0].frequency == 1000, "PK parsed")
    check(p.filters[1].kind == .lowShelf && p.filters[1].gainDB == 4.5, "LSC parsed")
    check(p.filters[2].kind == .highShelf && !p.filters[2].enabled, "OFF HS parsed")
    near(p.magnitudeDB(at: 1000, sampleRate: sr), -6.3 - 3.0, 0.25, "response matches preamp + filter")

    let stereo = """
    Preamp: -2 dB l
    Filter 1: ON PK Fc 500 Hz Gain 3 dB Q 1 l
    Preamp: -4 dB r
    Filter 1: ON PK Fc 500 Hz Gain -3 dB Q 1 r
    """
    let sdoc = APOParser.parse(stereo)
    near(sdoc.profile(forChannel: 0).preampDB, -2, 1e-9, "left channel preamp")
    near(sdoc.profile(forChannel: 1).preampDB, -4, 1e-9, "right channel preamp")
    near(sdoc.profile(forChannel: 0).filters[0].gainDB, 3, 1e-9, "left filter gain")
    near(sdoc.profile(forChannel: 1).filters[0].gainDB, -3, 1e-9, "right filter gain")
}

// MARK: - Limiter

section("True-peak limiter holds its ceiling")
do {
    for ceiling in [-1.0, -0.3, -3.0] {
        let lim = TruePeakLimiter(sampleRate: sr,
                                  settings: .init(ceilingDB: ceiling, lookaheadMS: 2, releaseMS: 60))
        var worst = -200.0
        // A loud sine well over full scale, plus a hard transient burst.
        for n in 0..<24_000 {
            let t = Double(n) / sr
            var drive = 2.0 * sin(2 * .pi * 440 * t)
            if n % 6000 == 0 { drive = 4.0 }
            var l = drive, r = drive * 0.8
            lim.process(&l, &r)
            if n > 500 {   // let the look-ahead prime
                worst = max(worst, 20 * log10(max(abs(l), abs(r), 1e-9)))
            }
        }
        check(worst <= ceiling + 0.15,
              "ceiling \(fmt(ceiling)) dB respected", "peak reached \(fmt(worst)) dB")
    }

    let lim = TruePeakLimiter(sampleRate: sr, settings: .init(ceilingDB: -1, lookaheadMS: 2))
    var quietMax = 0.0
    for n in 0..<4800 {
        var l = 0.1 * sin(2 * .pi * 100 * Double(n) / sr), r = l
        lim.process(&l, &r)
        if n > 300 { quietMax = max(quietMax, abs(l)) }
    }
    near(quietMax, 0.1, 0.002, "quiet material passes through untouched")
}

// MARK: - End to end

section("Processor end to end")
do {
    let frames = 512
    let channels = 16

    func run(_ cfg: ProcessorConfiguration, fill: (Int, Int) -> Float) -> (peak: Double, lastL: Double, lastR: Double) {
        let proc = SoundMixProcessor()
        proc.applyNow(cfg)
        proc.prepare(sampleRate: sr)
        proc.applyNow(cfg)
        var input = [Float](repeating: 0, count: frames * channels)
        var output = [Float](repeating: 0, count: frames * 2)
        var peak = 0.0, lastL = 0.0, lastR = 0.0
        for block in 0..<20 {
            for f in 0..<frames {
                for c in 0..<channels { input[f * channels + c] = fill(block * frames + f, c) }
            }
            input.withUnsafeBufferPointer { inPtr in
                output.withUnsafeMutableBufferPointer { outPtr in
                    proc.process(input: inPtr.baseAddress!, inputChannels: channels,
                                 frames: frames, output: outPtr.baseAddress!)
                }
            }
            if block > 2 {
                for f in 0..<frames {
                    peak = max(peak, Double(abs(output[f * 2])), Double(abs(output[f * 2 + 1])))
                }
            }
            lastL = Double(output[(frames - 1) * 2])
            lastR = Double(output[(frames - 1) * 2 + 1])
        }
        return (peak, lastL, lastR)
    }

    // Worst case the original cannot survive: full scale on every bed channel.
    var parity = ProcessorConfiguration(layout: .nativeBed, recipe: .parity,
                                        headroomMode: .peakSafe, manualGainDB: 0)
    parity.limiter = .init(ceilingDB: -1, lookaheadMS: 2, enabled: true)
    let hostile = run(parity) { n, _ in Float(0.95 * sin(2 * .pi * 220 * Double(n) / sr)) }
    check(hostile.peak <= pow(10, -1.0 / 20) + 0.01,
          "full-scale 9.1.6 bed stays under the −1 dBTP ceiling",
          "peak \(fmt(20 * log10(hostile.peak))) dB")

    // The same hostile input without any protection, to show what the original does.
    var raw = ProcessorConfiguration(layout: .nativeBed, recipe: .parity,
                                     headroomMode: .none, manualGainDB: -9.5)
    raw.limiter = .init(enabled: false)
    let unprotected = run(raw) { n, _ in Float(0.95 * sin(2 * .pi * 220 * Double(n) / sr)) }
    check(unprotected.peak > 1.0,
          "the original's −9.5 dB preamp alone still overloads",
          "peak \(fmt(20 * log10(unprotected.peak))) dBFS")

    // Routing: a DC-ish signal on device channel 1 only must land on L only.
    var routing = ProcessorConfiguration(layout: .nativeBed, recipe: .reference,
                                         headroomMode: .none, manualGainDB: 0)
    routing.limiter = .init(enabled: false)
    let onlyLeft = run(routing) { _, c in c == 0 ? 0.5 : 0 }
    near(onlyLeft.lastL, 0.5, 1e-6, "channel 1 reaches L at unity")
    near(onlyLeft.lastR, 0.0, 1e-9, "channel 1 does not reach R")

    // Swap must exchange the outputs.
    var swapped = routing
    swapped.swapOutputs = true
    let sw = run(swapped) { _, c in c == 0 ? 0.5 : 0 }
    near(sw.lastR, 0.5, 1e-6, "swap moves channel 1 to R")
    near(sw.lastL, 0.0, 1e-9, "swap clears L")

    // Centre must arrive at −3.01 dB on both outputs.
    let centre = run(routing) { _, c in c == 2 ? 0.5 : 0 }
    near(centre.lastL, 0.5 * 0.70710678, 1e-6, "centre → L at −3.01 dB")
    near(centre.lastR, 0.5 * 0.70710678, 1e-6, "centre → R at −3.01 dB")

    // An unmapped bed slot must be silent.
    var stereoOnly = routing
    stereoOnly.layout = LayoutPreset.all.first { $0.name == "2.0 stereo" }!
    let muted = run(stereoOnly) { _, c in c == 4 ? 0.9 : 0 }   // device ch 5 = Ls, unmapped in 2.0
    near(muted.lastL, 0.0, 1e-9, "unmapped channel is silent on L")
    near(muted.lastR, 0.0, 1e-9, "unmapped channel is silent on R")
}

section("Layout presets are well formed")
do {
    for p in LayoutPreset.all {
        check(p.map.count == 16, "\(p.name) has 16 slots")
        let used = p.map.filter { $0 > 0 }
        check(Set(used).count == used.count, "\(p.name) maps each device channel at most once")
        check(p.requiredInputChannels <= 16, "\(p.name) needs ≤ 16 device channels")
    }
    let f714 = LayoutPreset.all.first { $0.name == "7.1.4" }!
    check(f714.activeChannels.contains(.ltr) && f714.activeChannels.contains(.rtr),
          "7.1.4 uses top-rear, not top-middle (the original mapped these to Ltm/Rtm)")
}

section("EQ profile library")
do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dmx-eq-tests-\(UUID().uuidString)")
    let lib = EQProfileLibrary(directory: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    check(lib.profiles.isEmpty, "a fresh library is empty")

    let apo = """
    Preamp: -3.0 dB
    Filter 1: ON PK Fc 60 Hz Gain 4 dB Q 0.9
    Filter 2: ON HSC Fc 8000 Hz Gain -2.5 dB Q 0.7
    """
    let saved = try! lib.save(EQProfile(name: "Desk", globalText: apo))
    check(lib.profiles.count == 1, "saving adds one profile")
    check(lib.profile(named: "Desk") != nil, "profile is findable by name")
    check(saved.globalProfile.activeFilterCount == 2, "profile exposes its parsed filters")

    // One file per profile, on disk, readable.
    let files = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
    check(files.count == 1 && files[0].hasSuffix(".json"), "one JSON file per profile", "\(files)")

    // Reload from disk must reproduce it.
    let lib2 = EQProfileLibrary(directory: tmp)
    check(lib2.profiles.count == 1 && lib2.profiles[0].name == "Desk",
          "profiles survive a reload from disk")

    // Peak boost drives the headroom warning.
    near(saved.peakBoostDB(sampleRate: sr), 1.0, 0.6, "peak boost accounts for preamp plus filter")

    // Duplicate never collides.
    let copy = try! lib.duplicate(saved)
    check(copy.name == "Desk copy", "duplicate gets a free name", copy.name)
    check(copy.id != saved.id, "duplicate gets a new id")
    let copy2 = try! lib.duplicate(saved)
    check(copy2.name == "Desk copy 2", "second duplicate increments", copy2.name)

    // Export → import round trip.
    let data = try! lib.exportData(lib.profiles)
    let target = EQProfileLibrary(directory: tmp.appendingPathComponent("other"))
    let imported = try! target.importData(data, fallbackName: "bundle")
    check(imported.count == 3, "bundle round-trips every profile", "got \(imported.count)")
    check(target.profile(named: "Desk")?.globalText == apo, "profile text survives the round trip")
    check(imported.allSatisfy { p in !lib.profiles.contains { $0.id == p.id } },
          "import always assigns fresh ids so nothing is overwritten")

    // Importing the same bundle twice must not clobber the first copy.
    let again = try! target.importData(data, fallbackName: "bundle")
    check(target.profiles.count == 6, "re-importing adds rather than replaces", "\(target.profiles.count)")
    check(again.contains { $0.name == "Desk 2" }, "a colliding name is numbered",
          again.map(\.name).joined(separator: ","))

    // Raw APO text is accepted too.
    let fromText = try! target.importData(Data(apo.utf8), fallbackName: "Harman")
    check(fromText.count == 1 && fromText[0].name == "Harman", "APO text imports as a profile")
    check(fromText[0].globalProfile.activeFilterCount == 2, "imported APO keeps its filters")

    // Rubbish is rejected rather than silently creating an empty profile.
    var rejected = false
    do { _ = try target.importData(Data([0xFF, 0xFE, 0x00]), fallbackName: "junk") }
    catch { rejected = true }
    check(rejected, "unreadable input is rejected")

    // APO text output round-trips through the parser.
    let text = saved.globalProfile.apoText()
    let reparsed = APOParser.parse(text).firstProfile
    near(reparsed.preampDB, -3.0, 1e-6, "exported APO keeps the preamp")
    check(reparsed.activeFilterCount == 2, "exported APO keeps both filters")
    near(reparsed.filters[0].frequency, 60, 1e-6, "exported APO keeps Fc")
    near(reparsed.filters[1].gainDB, -2.5, 1e-6, "exported APO keeps gain")

    try! lib.delete(saved)
    check(lib.profile(named: "Desk") == nil, "delete removes the profile")
}

section("Earphone measurement files")
do {
    // AutoEQ / oratory1990 style CSV with a header.
    let csv = """
    frequency,raw
    20.0,6.2
    50,5.0
    100,3.0
    200,1.0
    500,0.0
    1000,-1.0
    2000,2.0
    5000,-4.0
    10000,-8.0
    20000,-12.0
    """
    guard let m = FrequencyResponse.parse(csv, name: "Test IEM") else {
        check(false, "CSV measurement parses"); fatalError("parse failed")
    }
    check(m.points.count == 10, "every data row parsed", "got \(m.points.count)")
    near(m.range.low, 20, 1e-9, "lowest frequency")
    near(m.range.high, 20_000, 1e-9, "highest frequency")
    near(m.magnitudeDB(at: 1000), -1.0, 1e-9, "exact point returns its value")
    // Log-midpoint between 100 Hz (3 dB) and 200 Hz (1 dB) is ~141 Hz → 2 dB.
    near(m.magnitudeDB(at: (100 * 200).squareRoot()), 2.0, 1e-6, "interpolates in log frequency")
    near(m.magnitudeDB(at: 5), 6.2, 1e-9, "holds the endpoint below the measured range")
    near(m.magnitudeDB(at: 40_000), -12.0, 1e-9, "holds the endpoint above the measured range")

    // Whitespace and tab separated, with comments, must parse the same way.
    let txt = """
    # Generated by something
    * another comment style
    20.0\t6.2
    50 5.0
    100;3.0
    200 1.0
    500 0.0
    1000 -1.0
    2000 2.0
    5000 -4.0
    10000 -8.0
    20000 -12.0
    """
    let m2 = FrequencyResponse.parse(txt, name: "Mixed")
    check(m2 != nil && m2!.points.count == 10, "tab, space, semicolon and comments all handled",
          "got \(m2?.points.count ?? -1)")

    // Normalisation anchors the arbitrary absolute level.
    let norm = m.normalized(low: 200, high: 2_000)
    let band = [1.0, 0.0, -1.0, 2.0]                     // 200, 500, 1000, 2000 Hz
    let mean = band.reduce(0, +) / Double(band.count)
    near(norm.magnitudeDB(at: 500), 0.0 - mean, 1e-9, "normalisation subtracts the band mean")
    check(abs(norm.magnitudeDB(at: 1000) - (-1.0 - mean)) < 1e-9, "normalisation shifts the whole curve")

    // A flat EQ leaves the measurement alone.
    let flat = PEQProfile.flat.cascade(sampleRate: sr)
    let untouched = m.corrected(by: flat, sampleRate: sr)
    near(untouched.first(where: { $0.hz > 990 && $0.hz < 1010 })?.db ?? 99,
         m.magnitudeDB(at: untouched.first(where: { $0.hz > 990 && $0.hz < 1010 })!.hz),
         1e-6, "flat EQ leaves the curve unchanged")

    // A corrective filter must reduce the deviation it targets.
    let fix = PEQProfile(preampDB: 0, filters: [
        PEQFilter(kind: .peaking, frequency: 5000, gainDB: 4, q: 1.0),
    ])
    let corrected = m.corrected(by: fix.cascade(sampleRate: sr), sampleRate: sr)
    let before = m.magnitudeDB(at: 5000)
    let after = corrected.min(by: { abs($0.hz - 5000) < abs($1.hz - 5000) })!.db
    check(after > before, "a +4 dB filter lifts the dip at 5 kHz",
          "before \(fmt(before)) after \(fmt(after))")
    near(after - before, 4.0, 0.3, "the lift matches the filter gain")

    // Rubbish must be rejected, not turned into an empty curve.
    check(FrequencyResponse.parse("hello\nworld\n", name: "junk") == nil,
          "non-numeric text is rejected")
    check(FrequencyResponse.parse("20 1\n30 2\n", name: "tiny") == nil,
          "too few points is rejected")

    // The measurement travels with its EQ profile.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dmx-fr-tests-\(UUID().uuidString)")
    let lib = EQProfileLibrary(directory: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let withCurve = try! lib.save(EQProfile(name: "IEM", globalText: "Preamp: -2 dB", measurementLeft: m))
    check(withCurve.summary.contains("measured"), "a paired profile says so in its summary",
          withCurve.summary)
    let reloaded = EQProfileLibrary(directory: tmp).profiles.first
    check(reloaded?.measurementLeft?.points.count == 10, "measurement survives save and reload")
    near(reloaded?.measurementLeft?.magnitudeDB(at: 2000) ?? 99, 2.0, 1e-9, "its values survive too")

    // And through an export/import round trip.
    let data = try! lib.exportData(lib.profiles)
    let target = EQProfileLibrary(directory: tmp.appendingPathComponent("out"))
    let back = try! target.importData(data, fallbackName: "x")
    check(back.first?.measurementLeft?.points.count == 10, "measurement survives export and import")

    // Profiles saved before measurements existed must still load.
    let legacy = Data("""
    {"id":"\(UUID().uuidString)","name":"Legacy","notes":"","globalText":"Preamp: -1 dB",
     "speakerText":"","created":"2026-01-01T00:00:00Z","modified":"2026-01-01T00:00:00Z"}
    """.utf8)
    let legacyImported = try? target.importData(legacy, fallbackName: "legacy")
    check(legacyImported?.first?.measurementLeft == nil, "a profile without a measurement still loads")
    check(legacyImported?.first?.name == "Legacy", "and keeps its name")
}

section("Per-ear measurements and target curves")
do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dmx-ears-\(UUID().uuidString)")
    let lib = EQProfileLibrary(directory: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // A three-column export fills both ears at once.
    let pairText = """
    freq,L,R
    20,6.0,5.0
    50,4.0,3.5
    100,2.0,1.5
    200,1.0,0.5
    500,0.0,0.0
    1000,-1.0,-1.5
    2000,2.0,1.0
    5000,-4.0,-5.0
    10000,-8.0,-9.0
    20000,-12.0,-13.0
    """
    guard let pair = FrequencyResponse.parsePair(pairText, name: "IEM") else {
        check(false, "three-column file parses as a pair"); fatalError("no pair")
    }
    check(pair.left.points.count == 10 && pair.right.points.count == 10,
          "both ears parsed", "\(pair.left.points.count)/\(pair.right.points.count)")
    near(pair.left.magnitudeDB(at: 1000), -1.0, 1e-9, "left column read")
    near(pair.right.magnitudeDB(at: 1000), -1.5, 1e-9, "right column read")
    check(pair.left.name.hasSuffix("L") && pair.right.name.hasSuffix("R"),
          "the ears are named", "\(pair.left.name) / \(pair.right.name)")

    // A third column that is phase must NOT be read as the right ear.
    // This is the shape that actually slipped through: values sweeping far
    // beyond any level curve.
    var phaseText = "frequency,raw,phase\n"
    for i in 0..<60 {
        let hz = 20.0 * pow(10, Double(i) / 60 * 3)
        let raw = 3.0 * sin(Double(i) / 4)
        let phase = 180.0 * sin(Double(i) / 2) + (i % 7 == 0 ? 120 : 0)
        phaseText += "\(hz),\(raw),\(phase)\n"
    }
    check(FrequencyResponse.parsePair(phaseText, name: "phase") == nil,
          "a phase column is rejected as a right ear")
    check(FrequencyResponse.parse(phaseText, name: "phase") != nil,
          "the same file still parses as a single curve")

    // Even without a header, wild values are refused.
    var headerless = ""
    for i in 0..<60 {
        let hz = 20.0 * pow(10, Double(i) / 60 * 3)
        headerless += "\(hz),\(3.0 * sin(Double(i) / 4)),\(170.0 * sin(Double(i) / 2))\n"
    }
    check(FrequencyResponse.parsePair(headerless, name: "nohdr") == nil,
          "a headerless third column that swings wildly is refused")

    // A genuine pair without a header is still accepted.
    var realPair = ""
    for i in 0..<60 {
        let hz = 20.0 * pow(10, Double(i) / 60 * 3)
        let l = 3.0 * sin(Double(i) / 4)
        realPair += "\(hz),\(l),\(l + 1.2)\n"
    }
    check(FrequencyResponse.parsePair(realPair, name: "real") != nil,
          "two ears that track each other are accepted without a header")

    // And a header naming the ears is believed even when they differ a lot.
    var labelled = "frequency,L,R\n"
    for i in 0..<60 {
        let hz = 20.0 * pow(10, Double(i) / 60 * 3)
        labelled += "\(hz),\(3.0 * sin(Double(i) / 4)),\(3.0 * sin(Double(i) / 4) - 11)\n"
    }
    check(FrequencyResponse.parsePair(labelled, name: "labelled") != nil,
          "a header naming L and R is trusted")

    // A two-column file must NOT be mistaken for a pair.
    let mono = "20,6.0\n50,4.0\n100,2.0\n200,1.0\n500,0.0\n1000,-1.0\n2000,2.0\n5000,-4.0\n10000,-8.0"
    check(FrequencyResponse.parsePair(mono, name: "mono") == nil,
          "a two-column file is not treated as a pair")
    check(FrequencyResponse.parse(mono, name: "mono") != nil,
          "but it still parses as a single curve")

    // Both ears and a target survive a save/reload.
    let target = FrequencyResponse.parse(mono, name: "JM-1")!
    let saved = try! lib.save(EQProfile(name: "IEM + target",
                                   globalText: "Preamp: -3 dB",
                                   measurementLeft: pair.left,
                                   measurementRight: pair.right,
                                   target: target))
    check(saved.hasMeasurement, "profile reports a measurement")
    check(saved.summary.contains("measured L+R"), "summary names both ears", saved.summary)
    check(saved.summary.contains("vs JM-1"), "summary names the target", saved.summary)

    let reloaded = EQProfileLibrary(directory: tmp).profiles.first
    near(reloaded?.measurementLeft?.magnitudeDB(at: 2000) ?? 99, 2.0, 1e-9, "left ear reloads")
    near(reloaded?.measurementRight?.magnitudeDB(at: 2000) ?? 99, 1.0, 1e-9, "right ear reloads")
    check(reloaded?.target?.name == "JM-1", "target reloads", reloaded?.target?.name ?? "nil")

    // One ear alone is allowed.
    let oneEar = try! lib.save(EQProfile(name: "One ear", measurementLeft: pair.left))
    check(oneEar.hasMeasurement && oneEar.measurementRight == nil, "a single ear is valid")
    check(oneEar.summary.contains("one ear"), "summary says so", oneEar.summary)
    check(oneEar.anyMeasurement != nil, "anyMeasurement falls back to whichever side exists")

    // Profiles written before the split used a single `measurement` key.
    let legacy = Data("""
    {"id":"\(UUID().uuidString)","name":"Legacy IEM","notes":"","globalText":"",
     "speakerText":"","created":"2026-01-01T00:00:00Z","modified":"2026-01-01T00:00:00Z",
     "measurement":{"name":"Old curve","points":[
       {"hz":20,"db":6},{"hz":50,"db":4},{"hz":100,"db":2},{"hz":200,"db":1},
       {"hz":500,"db":0},{"hz":1000,"db":-1},{"hz":2000,"db":2},{"hz":5000,"db":-4},
       {"hz":10000,"db":-8},{"hz":20000,"db":-12}]}}
    """.utf8)
    let migrated = try! lib.importData(legacy, fallbackName: "legacy")
    check(migrated.first?.measurementLeft?.name == "Old curve",
          "a legacy single measurement migrates to the left ear",
          migrated.first?.measurementLeft?.name ?? "nil")
    check(migrated.first?.measurementRight == nil, "and leaves the right ear empty")
    near(migrated.first?.measurementLeft?.magnitudeDB(at: 1000) ?? 99, -1.0, 1e-9,
         "the migrated curve keeps its values")

    // Difference against a target is what the error view draws.
    let flat = FrequencyResponse(name: "flat", points: (0...20).map {
        .init(hz: 20 * pow(10, Double($0) / 20 * 3), db: 0)
    })
    let diff = pair.left.difference(from: flat)
    check(!diff.isEmpty, "difference produces a curve", "\(diff.count) points")
    let at1k = diff.min { abs($0.hz - 1000) < abs($1.hz - 1000) }!
    near(at1k.db, pair.left.magnitudeDB(at: at1k.hz), 1e-9,
         "difference from a flat target equals the curve itself")

    // A perfect correction reads as zero error.
    let selfDiff = pair.left.difference(from: pair.left)
    check(selfDiff.allSatisfy { abs($0.db) < 1e-9 }, "a curve minus itself is zero everywhere")
}


section("Limiter channel isolation and live handoff")
do {
    let a = TruePeakLimiter(), b = TruePeakLimiter()
    var maxDifference = 0.0
    for n in 0..<10000 {
        var l = 1.2 * sin(Double(n) * 0.91), r = 0.7 * cos(Double(n) * 0.27)
        var swappedL = r, swappedR = l
        a.process(&l, &r); b.process(&swappedL, &swappedR)
        maxDifference = max(maxDifference, abs(l - swappedR), abs(r - swappedL))
    }
    near(maxDifference, 0, 1e-12, "limiter is invariant under channel exchange")
    let control = SoundMixProcessor(), edited = SoundMixProcessor()
    let cfg = ProcessorConfiguration()
    for p in [control, edited] { p.applyNow(cfg); p.prepare(sampleRate: 48000) }
    var input = [Float](repeating: 0.25, count: 128 * 16)
    var x = [Float](repeating: 0, count: 256), y = x
    control.process(input: &input, inputChannels: 16, frames: 128, output: &x)
    edited.process(input: &input, inputChannels: 16, frames: 128, output: &y)
    edited.apply(cfg)
    control.process(input: &input, inputChannels: 16, frames: 128, output: &x)
    edited.process(input: &input, inputChannels: 16, frames: 128, output: &y)
    check(x == y, "prepared handoff preserves filter and delay history")
}

section("Half-sample true peaks")
do {
    let limiter = TruePeakLimiter()
    var energy = 0.0
    // These sample values are below the ceiling, but the reconstructed sine is not.
    for n in 0..<30000 {
        var l = 1.2 * sin(.pi * 0.5 * Double(n) + .pi / 4), r = l
        limiter.process(&l, &r)
        if n >= 29000 { energy += l * l }
    }
    let reconstructedPeakDB = 20 * log10(sqrt(2 * energy / 1000))
    check(reconstructedPeakDB <= -0.99, "half-sample peaks respect -1 dBTP ceiling", "peak \(reconstructedPeakDB)")
}

section("Profile write failures")
do {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! Data("not a directory".utf8).write(to: path)
    defer { try? FileManager.default.removeItem(at: path) }
    let lib = EQProfileLibrary(directory: path)
    do {
        _ = try lib.save(EQProfile(name: "Must fail"))
        check(false, "failed profile save throws")
    } catch { check(true, "failed profile save throws") }
    check(lib.profiles.isEmpty, "failed save does not claim persistence")
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("All DSP checks passed.")
