import SwiftUI
import UniformTypeIdentifiers

// MARK: - Devices

struct DevicesPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: CZ.Spacing.md) {
            if let note = MicrophoneAccess.explanation(for: model.micStatus) {
                CZCard(title: "Microphone access") {
                    CZAlert(kind: model.micStatus == .notDetermined ? .info : .error, message: note)
                    if model.micStatus == .denied {
                        CZButton(title: "Open System Settings", icon: "gear",
                                 variant: .secondary, size: .small) { MicrophoneAccess.openSettings() }
                    }
                }
            }

            CZCard(title: "Input",
                   subtitle: "The interface carrying the bed. \(model.layout.name) needs \(model.layout.requiredInputChannels) channels.") {
                CZSelect(label: "Input device",
                         selection: $model.inputUID,
                         options: model.compatibleInputs.map { ($0.uid, deviceTitle($0)) })
                if let d = model.inputDevice {
                    DeviceDetail(device: d, needed: model.layout.requiredInputChannels, isInput: true)
                    DeviceVolumeView(device: d, isInput: true).id("input-\(d.id)")
                }
            }

            CZCard(title: "Output",
                   subtitle: "The stereo pair the bed folds down to. Devices with more than two outputs are fine — the first pair is used.") {
                CZSelect(label: "Output device",
                         selection: $model.outputUID,
                         options: model.compatibleOutputs.map { ($0.uid, deviceTitle($0)) })
                if let d = model.outputDevice {
                    DeviceDetail(device: d, needed: 2, isInput: false)
                    DeviceVolumeView(device: d, isInput: false).id("output-\(d.id)")
                }
                CZToggleRow(title: "Swap physical left and right",
                            subtitle: "Also flips which half of a stereo speaker-EQ file goes to which speaker.",
                            isOn: $model.swapOutputs)
            }

            CZCard(title: "Engine") {
                HStack(alignment: .top, spacing: CZ.Spacing.lg) {
                    CZSelect(label: "Frames per buffer",
                             selection: $model.framesPerBuffer,
                             options: [32, 64, 128, 256, 512, 1024].map { ($0, "\($0)") },
                             help: "Smaller is lower latency and more CPU.")
                        .frame(width: 180)
                    CZField(label: "Device-clock safety buffer", text: $model.safetyBufferText,
                            suffix: "ms",
                            help: "Absorbs drift between the two devices' clocks.",
                            width: 180)
                    Spacer()
                }
                HStack {
                    CZToggleRow(title: "Show devices that cannot be used",
                                subtitle: "Lists interfaces with too few channels for the current layout.",
                                isOn: $model.showIncompatibleDevices)
                    Spacer(minLength: CZ.Spacing.xl)
                    CZButton(title: "Rescan", icon: "arrow.clockwise",
                             variant: .secondary, size: .small) { model.refreshDevices() }
                }
            }

            CZCard(title: "System audio",
                   subtitle: "Channel counts, sample rates and aggregate devices are set by macOS, not here.") {
                HStack(spacing: CZ.Spacing.sm) {
                    CZButton(title: "Sound settings", icon: "speaker.wave.2",
                             variant: .secondary, size: .small) { SystemLinks.openSoundSettings() }
                    CZButton(title: "Audio MIDI Setup", icon: "pianokeys",
                             variant: .secondary, size: .small) { SystemLinks.openAudioMIDISetup() }
                    CZButton(title: "Microphone privacy", icon: "mic",
                             variant: .transparent, size: .small) { SystemLinks.openMicrophoneSettings() }
                    Spacer()
                }
                Text("Use Audio MIDI Setup to change a device's channel count or sample rate, or to build an aggregate device when the bed and the speakers live on different interfaces.")
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deviceTitle(_ d: AudioDevice) -> String {
        var parts = [d.name]
        parts.append("· \(d.channelSummary)")
        if !d.transportType.isEmpty { parts.append("· \(d.transportType)") }
        return parts.joined(separator: " ")
    }
}

private struct DeviceVolumeView: View {
    let device: AudioDevice
    let isInput: Bool
    @State private var volume = DeviceVolume.State(value: nil, writable: false, channelControls: 0)
    @State private var error: String?
    @State private var dragging = false

    private var channels: Int { isInput ? device.inputChannels : device.outputChannels }
    private var title: String { isInput ? "Input device volume" : "Output device volume" }

    var body: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.sm) {
            HStack {
                Text(title).font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
                Spacer()
                Text(volume.value.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unavailable")
                    .font(CZ.Typography.mono(12))
            }
            Slider(value: Binding(get: { volume.value ?? 0 }, set: { value in
                do {
                    try DeviceVolume.set(value, device: device.id, isInput: isInput, channels: channels)
                    volume = DeviceVolume.read(device: device.id, isInput: isInput, channels: channels)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                    refresh()
                }
            }), in: 0...1, onEditingChanged: { dragging = $0 })
                .disabled(!volume.writable)
                .accessibilityLabel(title)
                .tint(CZ.Color.blue)
            Text(volume.writable
                 ? "Changes macOS volume for this device, including other apps.\(volume.channelControls > 0 ? " Links writable channel controls while preserving balance." : "")"
                 : "This device does not expose writable macOS volume. Use its hardware controls, source-app volume, or SoundMix manual gain under Downmix.")
                .font(CZ.Typography.caption).foregroundStyle(CZ.Color.mediumGray)
                .fixedSize(horizontal: false, vertical: true)
            if let error { CZAlert(kind: .error, message: error) }
        }
        .task {
            while !Task.isCancelled {
                if !dragging { refresh() }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
    }

    private func refresh() {
        volume = DeviceVolume.read(device: device.id, isInput: isInput, channels: channels)
    }
}

private struct DeviceDetail: View {
    let device: AudioDevice
    let needed: Int
    let isInput: Bool

    private var available: Int { isInput ? device.inputChannels : device.outputChannels }
    private var ok: Bool { available >= needed }

    var body: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.sm) {
            HStack(spacing: CZ.Spacing.sm) {
                CZPill(text: "\(available) ch", tint: ok ? CZ.Color.blue : CZ.Color.red)
                CZPill(text: "\(Int(device.nominalSampleRate)) Hz", tint: CZ.Color.mediumGray)
                if !device.transportType.isEmpty { CZPill(text: device.transportType, tint: CZ.Color.mediumGray) }
                if device.isDefaultInput { CZPill(text: "system input", tint: CZ.Color.purple) }
                if device.isDefaultOutput { CZPill(text: "system output", tint: CZ.Color.purple) }
            }
            if !ok {
                CZAlert(kind: .error,
                        message: "“\(device.name)” exposes \(available) \(isInput ? "input" : "output") channel\(available == 1 ? "" : "s") but \(needed) are needed.")
            }
        }
    }
}

// MARK: - Downmix

struct SoundMixPanel: View {
    @EnvironmentObject var model: AppModel

    private var config: ProcessorConfiguration { model.configuration }
    private var matrix: SoundMixMatrix { config.effectiveMatrix }

    var body: some View {
        VStack(spacing: CZ.Spacing.md) {
            CZCard(title: "Source layout",
                   subtitle: "Which bed slots the device channels feed. Unmapped slots stay silent.") {
                CZSelect(label: "Layout", selection: $model.layoutName,
                         options: LayoutPreset.all.map { ($0.name, "\($0.name)  ·  \($0.requiredInputChannels) ch") })
                ChannelMapStrip(layout: model.layout)
            }

            CZCard(title: "Matrix",
                   subtitle: (model.availableRecipes.first { $0.name == model.recipeName })?.notes ?? "") {
                CZSelect(label: "Downmix recipe", selection: $model.recipeName,
                         options: model.availableRecipes.map { ($0.name, $0.name) })
                    .onChange(of: model.recipeName) { _, _ in model.syncRecipeEditors() }
                MatrixTable(matrix: matrix, layout: model.layout)
            }

            CZCard(title: "Headroom",
                   subtitle: "The original app ships a blunt −9.5 dB preamp. These numbers are computed from the matrix you actually selected.") {
                CZSelect(label: "Automatic trim", selection: $model.headroomMode,
                         options: HeadroomMode.allCases.map { ($0, $0.label) },
                         help: model.headroomMode.explanation)
                HStack(alignment: .top, spacing: CZ.Spacing.xl) {
                    stat("Worst-case gain", String(format: "%+.2f dB", matrix.worstCasePeakGainDB),
                         "Every mapped channel at full scale at once.")
                    stat("Uncorrelated gain", String(format: "%+.2f dB", matrix.uncorrelatedGainDB),
                         "Realistic level change for normal material.")
                    stat("Automatic trim", String(format: "%+.2f dB", config.automaticTrimDB), nil)
                    stat("Total applied", String(format: "%+.2f dB", config.totalTrimDB), nil)
                }
                HStack(alignment: .bottom, spacing: CZ.Spacing.md) {
                    CZField(label: "Additional manual gain", text: $model.manualGainText, suffix: "dB", width: 160)
                    Button("−1 dB") { model.adjustManualGain(by: -1) }
                    Button("+1 dB") { model.adjustManualGain(by: 1) }
                }
                Text(model.gainBreakdown)
                    .font(CZ.Typography.caption).foregroundStyle(CZ.Color.mediumGray)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The limiter only reduces peaks. Use small gain steps for quiet material; buttons apply immediately during playback.")
                    .font(CZ.Typography.caption).foregroundStyle(CZ.Color.mediumGray)
                    .fixedSize(horizontal: false, vertical: true)
                if matrix.worstCasePeakGainDB > 0 && model.headroomMode == .none && !model.limiterEnabled {
                    CZAlert(kind: .warning,
                            message: String(format: "With no automatic trim and no limiter this matrix can reach %+.1f dB — the same overload the original app has.", matrix.worstCasePeakGainDB + (Double(model.manualGainText) ?? 0)))
                }
            }

            CZCard(title: "LFE",
                   subtitle: "The original fixes this at a 4th-order 125 Hz Butterworth with a +7.100 dB coefficient. Here it is adjustable, and the dry path is delayed to the filter's own group delay so the bass still sums in phase.") {
                HStack(alignment: .top, spacing: CZ.Spacing.lg) {
                    CZSelect(label: "Mode", selection: $model.lfeMode,
                             options: LFEMode.allCases.map { ($0, $0.label) })
                        .frame(width: 200)
                    CZField(label: "Cut-off", text: $model.lfeCutoffText, suffix: "Hz", width: 120)
                        .disabled(model.lfeMode != .lowPass)
                    CZSelect(label: "Slope", selection: $model.lfeOrder,
                             options: [(2, "12 dB/oct"), (4, "24 dB/oct"), (6, "36 dB/oct"), (8, "48 dB/oct")])
                        .frame(width: 150)
                        .disabled(model.lfeMode != .lowPass)
                    CZField(label: "LFE gain", text: $model.lfeGainText, suffix: "dB", width: 120)
                        .disabled(model.lfeMode == .off)
                    Spacer()
                }
                if model.lfeMode == .lowPass {
                    let cascade = BiquadDesign.butterworthLowPass(
                        frequency: Double(model.lfeCutoffText) ?? 120,
                        order: model.lfeOrder,
                        sampleRate: model.state.isRunning ? model.engine.currentSampleRate : 48_000)
                    let tau = cascade.groupDelay(at: 0, sampleRate: model.state.isRunning ? model.engine.currentSampleRate : 48_000)
                    Text(String(format: "Dry path delayed %.0f samples (%.2f ms) to match the filter.",
                                tau, tau / (model.state.isRunning ? model.engine.currentSampleRate : 48_000) * 1000))
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.mediumGray)
                }
            }

            CZCard(title: "True-peak limiter",
                   subtitle: "Catches inter-sample peaks with 4× oversampled detection and a look-ahead window, so the matrix can run at a useful level instead of being trimmed into the floor.") {
                CZToggleRow(title: "Enable limiter",
                            subtitle: "Adds \(String(format: "%.0f", 2.0)) ms of latency.",
                            isOn: $model.limiterEnabled)
                HStack(alignment: .top, spacing: CZ.Spacing.lg) {
                    CZField(label: "Ceiling", text: $model.limiterCeilingText, suffix: "dBTP", width: 140)
                    CZField(label: "Release", text: $model.limiterReleaseText, suffix: "ms", width: 140)
                    Spacer()
                }
                .disabled(!model.limiterEnabled)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
            Text(value).font(CZ.Typography.mono(16)).foregroundStyle(CZ.Color.darkBlue)
            if let note {
                Text(note).font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChannelMapStrip: View {
    @EnvironmentObject var model: AppModel
    let layout: LayoutPreset

    /// Below this a slot counts as silent, so an idle bed does not look busy.
    private let floorDB = -60.0

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
        VStack(alignment: .leading, spacing: CZ.Spacing.sm) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(BedChannel.allCases, id: \.rawValue) { ch in
                    cell(ch)
                }
            }
            HStack(spacing: CZ.Spacing.sm) {
                Text(model.state.isRunning
                     ? "Live input level per bed slot."
                     : "Levels appear once the renderer is running.")
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
                Spacer()
                if model.state.isRunning {
                    let live = BedChannel.allCases.filter {
                        layout.map[$0.rawValue] > 0 && model.snapshot.bedPeakDB[$0.rawValue] > floorDB
                    }
                    CZPill(text: "\(live.count) of \(layout.activeChannels.count) carrying signal",
                           tint: live.isEmpty ? CZ.Color.mediumGray : CZ.Color.blue)
                }
            }
        }
    }

    private func cell(_ ch: BedChannel) -> some View {
        let slot = layout.map[ch.rawValue]
        let mapped = slot > 0
        let db = model.snapshot.bedPeakDB[ch.rawValue]
        let live = model.state.isRunning && mapped && db > floorDB
        let fraction = live ? min(max((db - floorDB) / (0 - floorDB), 0), 1) : 0

        return VStack(spacing: 2) {
            Text(ch.shortName)
                .font(CZ.Typography.mono(10))
                .foregroundStyle(mapped ? CZ.Color.darkBlue : CZ.Color.lightGray)
                .lineLimit(1)
            Text(mapped ? "ch \(slot)" : "—")
                .font(CZ.Typography.mono(9))
                .foregroundStyle(mapped ? CZ.Color.blue : CZ.Color.mutedGray)

            // Live level for this slot.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(CZ.Color.mutedGray.opacity(mapped ? 0.45 : 0.2))
                    Capsule()
                        .fill(db > -1 ? CZ.Color.red : (db > -6 ? CZ.Color.orange : CZ.Color.blue))
                        .frame(width: max(fraction > 0 ? 3 : 0, geo.size.width * fraction))
                        .animation(CZ.Motion.instant, value: fraction)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 4)

            Text(live ? String(format: "%.0f", db) : " ")
                .font(CZ.Typography.mono(8))
                .foregroundStyle(CZ.Color.mediumGray)
                .frame(height: 9)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(mapped ? (live ? CZ.Color.lightestBlue : CZ.Color.paleBlue) : CZ.Color.lightestGray)
        .overlay(
            RoundedRectangle(cornerRadius: CZ.Radius.tiny)
                .strokeBorder(live ? CZ.Color.blue.opacity(0.55) : Color.clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.tiny))
    }
}

private struct MatrixTable: View {
    let matrix: SoundMixMatrix
    let layout: LayoutPreset

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bed channel").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
                Spacer()
                Text("→ L").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray).frame(width: 84, alignment: .trailing)
                Text("→ R").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray).frame(width: 84, alignment: .trailing)
            }
            .padding(.vertical, CZ.Spacing.xs)
            Divider().overlay(CZ.Color.ghostGray)
            ForEach(BedChannel.allCases, id: \.rawValue) { ch in
                let mapped = layout.map[ch.rawValue] > 0
                let v = matrix[ch]
                HStack {
                    Text(ch.shortName)
                        .font(CZ.Typography.mono(11))
                        .frame(width: 38, alignment: .leading)
                    Text(ch.longName)
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.lightGray)
                    Spacer()
                    cell(v.left)
                    cell(v.right)
                }
                .foregroundStyle(mapped ? CZ.Color.defaultText : CZ.Color.mutedGray)
                .opacity(mapped ? 1 : 0.5)
                .padding(.vertical, 3)
            }
        }
    }

    private func cell(_ gain: Double) -> some View {
        let db = SoundMixMatrix.dB(abs(gain))
        return Text(abs(gain) < 1e-9 ? "—" : String(format: "%@%.2f dB", gain < 0 ? "ø " : "", db))
            .font(CZ.Typography.mono(11))
            .foregroundStyle(abs(gain) < 1e-9 ? CZ.Color.mutedGray
                             : (db > 0 ? CZ.Color.orange : CZ.Color.darkBlue))
            .frame(width: 84, alignment: .trailing)
    }
}

// MARK: - Output EQ

struct OutputEQPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: CZ.Spacing.md) {
            ProfileLibraryCard()
            ResponseCard()

            CZCard(title: "User / global PEQ",
                   subtitle: "Applied to both channels before the left/right swap, exactly where the original app applies it.") {
                PEQEditor(text: $model.globalPEQText, profile: model.globalProfile)
                    .onChange(of: model.globalPEQText) { _, _ in
                        model.reloadPEQWarnings(); model.markProfileDirty()
                    }
                HStack(spacing: CZ.Spacing.sm) {
                    CZButton(title: "Load text file…", icon: "square.and.arrow.down",
                             variant: .secondary, size: .small) { load(into: $model.globalPEQText) }
                    CZButton(title: "Export as APO…", icon: "square.and.arrow.up",
                             variant: .transparent, size: .small,
                             isEnabled: model.selectedProfile != nil) {
                        model.exportSelectedAsAPO(speakerCorrection: false)
                    }
                    CZButton(title: "Clear", variant: .transparent, size: .small) {
                        model.globalPEQText = ""
                        model.reloadPEQWarnings(); model.markProfileDirty(); model.applyLive()
                    }
                }
            }

            CZDisclosureCard(title: "Speaker correction",
                             subtitle: "Applied per physical speaker after the swap. A stereo file's `l` and `r` sections map to the left and right speaker, and follow the swap when it is on.",
                             summary: model.speakerSectionSummary,
                             collapsed: $model.speakerSectionCollapsed) {
                PEQEditor(text: $model.speakerPEQText, profile: model.speakerProfiles.left)
                    .onChange(of: model.speakerPEQText) { _, _ in
                        model.reloadPEQWarnings(); model.markProfileDirty()
                    }
                HStack(spacing: CZ.Spacing.sm) {
                    CZButton(title: "Load text file…", icon: "square.and.arrow.down",
                             variant: .secondary, size: .small) { load(into: $model.speakerPEQText) }
                    CZButton(title: "Export as APO…", icon: "square.and.arrow.up",
                             variant: .transparent, size: .small,
                             isEnabled: model.selectedProfile != nil) {
                        model.exportSelectedAsAPO(speakerCorrection: true)
                    }
                    CZButton(title: "Clear", variant: .transparent, size: .small) {
                        model.speakerPEQText = ""
                        model.reloadPEQWarnings(); model.markProfileDirty(); model.applyLive()
                    }
                }
            }

            if !model.peqWarnings.isEmpty {
                CZCard(title: "Parser notes") {
                    ForEach(model.peqWarnings, id: \.self) { w in
                        Text("· \(w)").font(CZ.Typography.caption).foregroundStyle(CZ.Color.orange)
                    }
                }
            }
        }
    }

    private func load(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.message = "Choose a REW / Equalizer APO text file."
        if panel.runModal() == .OK, let url = panel.url,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            binding.wrappedValue = text
            model.reloadPEQWarnings()
            model.markProfileDirty()
            model.applyLive()
        }
    }
}

// MARK: Profile library

private struct ProfileLibraryCard: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmingDelete = false

    var body: some View {
        CZCard(title: "Profile library",
               subtitle: "One file per profile in a folder you can back up or share. A profile holds both the global PEQ and the speaker correction.") {
            HStack(alignment: .top, spacing: CZ.Spacing.lg) {
                list
                detail
            }
            toolbar
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.profiles.isEmpty {
                VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
                    Text("No profiles yet")
                        .font(CZ.Typography.bodySmall).foregroundStyle(CZ.Color.mediumGray)
                    Text("Create one from whatever is in the editors below, or import a file.")
                        .font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(CZ.Spacing.md)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.profiles) { profile in
                            ProfileRow(profile: profile,
                                       selected: profile.id == model.selectedProfileID) {
                                model.selectProfile(profile)
                            }
                        }
                    }
                    .padding(CZ.Spacing.xs)
                }
                .frame(height: 188)
            }
        }
        .frame(width: 290)
        .background(CZ.Color.lightestGray)
        .overlay(RoundedRectangle(cornerRadius: CZ.Radius.medium)
            .strokeBorder(CZ.Color.ghostGray, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.sm) {
            CZField(label: "Profile name", text: $model.profileNameDraft)
            CZField(label: "Notes", text: $model.profileNotesDraft)

            // The earphone curves belong to the profile, one per ear.
            VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
                HStack {
                    Text("Earphone response")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.mediumGray)
                    Spacer()
                    if model.measurementLeft != nil && model.measurementRight != nil {
                        CZButton(title: "Swap L/R", icon: "arrow.left.arrow.right",
                                 variant: .transparent, size: .small) {
                            model.swapMeasurements()
                        }
                    }
                    if model.hasMeasurement {
                        CZButton(title: "Remove both", variant: .transparent, size: .small) {
                            model.clearAllMeasurements()
                        }
                    }
                }
                ForEach(EQProfile.Side.allCases) { side in
                    EarSlot(side: side)
                }
                if !model.hasMeasurement {
                    Text("A three-column file (frequency, left, right) fills both ears at once.")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.lightGray)
                }

                HStack(spacing: CZ.Spacing.sm) {
                    Text("Target")
                        .font(CZ.Typography.mono(11))
                        .foregroundStyle(model.target == nil ? CZ.Color.mutedGray : CZ.Color.darkBlue)
                        .frame(width: 42, alignment: .leading)
                    if let t = model.target {
                        CZPill(text: t.name, tint: CZ.Color.red)
                        Text(String(format: "%.0f Hz – %.0f kHz", t.range.low, t.range.high / 1000))
                            .font(CZ.Typography.caption)
                            .foregroundStyle(CZ.Color.lightGray)
                        Spacer()
                        CZButton(title: "Replace…", variant: .transparent, size: .small) {
                            model.loadTarget()
                        }
                        CZButton(title: "Remove", variant: .transparent, size: .small) {
                            model.clearTarget()
                        }
                    } else {
                        Text("none — deviation is measured against the curve's own mean")
                            .font(CZ.Typography.caption)
                            .foregroundStyle(CZ.Color.lightGray)
                        Spacer()
                        CZButton(title: "Upload target…", icon: "target",
                                 variant: .secondary, size: .small) { model.loadTarget() }
                    }
                }
            }

            HStack(spacing: CZ.Spacing.sm) {
                if model.profileDirty {
                    CZPill(text: "unsaved changes", tint: CZ.Color.orange)
                } else if model.selectedProfile != nil {
                    CZPill(text: "saved", tint: CZ.Color.mediumGray)
                }
                if let p = model.selectedProfile {
                    Text("Modified \(Self.stamp.string(from: p.modified))")
                        .font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
                }
                Spacer()
                CZButton(title: model.selectedProfile == nil ? "Create" : "Save",
                         icon: "tray.and.arrow.down", variant: .primary, size: .small) {
                    model.saveSelectedProfile()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolbar: some View {
        HStack(spacing: CZ.Spacing.sm) {
            CZButton(title: "New", icon: "plus", variant: .secondary, size: .small) {
                model.newProfile()
            }
            CZButton(title: "Duplicate", icon: "plus.square.on.square",
                     variant: .secondary, size: .small,
                     isEnabled: model.selectedProfile != nil) { model.duplicateSelectedProfile() }
            CZButton(title: confirmingDelete ? "Confirm delete" : "Delete",
                     icon: "trash", variant: confirmingDelete ? .danger : .transparent, size: .small,
                     isEnabled: model.selectedProfile != nil) {
                if confirmingDelete { model.deleteSelectedProfile(); confirmingDelete = false }
                else { confirmingDelete = true }
            }
            Divider().frame(height: 18)
            CZButton(title: "Import…", icon: "square.and.arrow.down",
                     variant: .secondary, size: .small) { model.importProfiles() }
            CZButton(title: "Export…", icon: "square.and.arrow.up",
                     variant: .secondary, size: .small,
                     isEnabled: model.selectedProfile != nil) {
                if let p = model.selectedProfile { model.exportProfiles([p], suggestedName: p.name) }
            }
            CZButton(title: "Export all", variant: .transparent, size: .small,
                     isEnabled: !model.profiles.isEmpty) {
                model.exportProfiles(model.profiles, suggestedName: "SoundMix EQ profiles")
            }
            Spacer()
            CZButton(title: "Show folder", icon: "folder",
                     variant: .transparent, size: .small) { model.revealProfileFolder() }
        }
        .onChange(of: model.selectedProfileID) { _, _ in confirmingDelete = false }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

private struct EarSlot: View {
    @EnvironmentObject var model: AppModel
    let side: EQProfile.Side

    var body: some View {
        let curve = model.measurement(side)
        HStack(spacing: CZ.Spacing.sm) {
            Text(side.short)
                .font(CZ.Typography.mono(11))
                .foregroundStyle(curve == nil ? CZ.Color.mutedGray : CZ.Color.darkBlue)
                .frame(width: 14, alignment: .leading)
            if let curve {
                CZPill(text: curve.name, tint: side == .left ? CZ.Color.purple : CZ.Color.pink)
                Text(String(format: "%.0f Hz – %.0f kHz · %d pts",
                            curve.range.low, curve.range.high / 1000, curve.points.count))
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
                    .lineLimit(1)
                Spacer()
                if model.measurement(side == .left ? .right : .left) == nil {
                    CZButton(title: "Copy to \(side == .left ? "R" : "L")",
                             variant: .transparent, size: .small) {
                        model.mirrorMeasurement(from: side)
                    }
                    CZButton(title: "Move to \(side == .left ? "R" : "L")",
                             variant: .transparent, size: .small) {
                        model.moveMeasurement(from: side)
                    }
                }
                CZButton(title: "Replace…", variant: .transparent, size: .small) {
                    model.loadMeasurement(for: side)
                }
                CZButton(title: "Remove", variant: .transparent, size: .small) {
                    model.clearMeasurement(side)
                }
            } else {
                Text("no \(side.label.lowercased()) curve")
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
                Spacer()
                CZButton(title: "Upload…", icon: "waveform.path.ecg",
                         variant: .secondary, size: .small) {
                    model.loadMeasurement(for: side)
                }
            }
        }
    }
}

private struct ProfileRow: View {
    let profile: EQProfile
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(CZ.Typography.body(13, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? CZ.Color.invertedText : CZ.Color.defaultText)
                    .lineLimit(1)
                Text(profile.summary)
                    .font(CZ.Typography.caption)
                    .foregroundStyle(selected ? CZ.Color.lightBlue : CZ.Color.lightGray)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CZ.Spacing.sm + 2)
            .padding(.vertical, 7)
            .background(selected ? CZ.Color.darkBlue
                                 : (hovering ? CZ.Color.paleBlue : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.tiny + 2))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(CZ.Motion.quick, value: hovering)
    }
}

private struct ResponseCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let rate = model.state.isRunning ? model.engine.currentSampleRate : 48_000
        let boost = model.editorPeakBoostDB
        CZCard(title: "Response",
               subtitle: !model.hasMeasurement
                   ? "What the current profile does across the band, before it reaches the limiter. Load an earphone measurement to see the correction against the curve it is correcting."
                   : "The measured curve, the EQ applied to it, and the result you will actually hear.") {

            ResponseCurve(traces: traces(rate: rate),
                          toleranceBandDB: (model.canShowErrorView
                                            && model.plotMode == .errorVsTarget) ? 3 : nil,
                          hidden: $model.hiddenTraces)

            if let error = model.measurementError {
                CZAlert(kind: .error, message: error)
            }
            if model.target != nil && !model.hasMeasurement {
                CZAlert(kind: .info,
                        message: "This profile has a target but no earphone measurement, so there is nothing to compare against — the plot can only show the filters themselves. Upload a measured curve above, or select the profile your measurements are on.")
            }

            HStack(spacing: CZ.Spacing.sm) {
                ForEach(EQProfile.Side.allCases) { side in
                    if let m = model.measurement(side) {
                        CZPill(text: "\(side.short) \(m.name)",
                               tint: side == .left ? CZ.Color.purple : CZ.Color.pink)
                    } else {
                        CZButton(title: "Upload \(side.short)…", icon: "waveform.path.ecg",
                                 variant: .secondary, size: .small) {
                            model.loadMeasurement(for: side)
                        }
                    }
                }
                if model.hasMeasurement {
                    CZButton(title: "Remove", variant: .transparent, size: .small) {
                        model.clearAllMeasurements()
                    }
                }
                Spacer()
                Text("Managed per profile, in the library above.")
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
            }

            Divider().overlay(CZ.Color.ghostGray)

            HStack(alignment: .center, spacing: CZ.Spacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Peak boost").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
                    Text(boost > -100 ? String(format: "%+.1f dB", boost) : "—")
                        .font(CZ.Typography.mono(14))
                        .foregroundStyle(boost > 0 ? CZ.Color.orange : CZ.Color.darkBlue)
                }
                if model.hasMeasurement {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Result deviation").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
                        Text(String(format: "±%.1f dB", model.resultDeviationDB()))
                            .font(CZ.Typography.mono(14))
                            .foregroundStyle(CZ.Color.darkBlue)
                    }
                    Text(model.target == nil
                         ? "How far the corrected curve still swings, 20 Hz to 20 kHz, worst ear. Lower is flatter."
                         : "Worst departure from the target, 20 Hz to 20 kHz, across both ears. The shaded band is ±3 dB.")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.lightGray)
                        .fixedSize(horizontal: false, vertical: true)
                } else if boost > 0 {
                    Text("This profile adds gain, so it eats into the headroom the matrix trim left you. The limiter will catch it.")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.mediumGray)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.target != nil && model.hasMeasurement {
                    CZSelect(label: "View", selection: $model.plotMode,
                             options: AppModel.PlotMode.allCases.map { ($0, $0.label) },
                             help: model.plotMode.explanation)
                        .frame(width: 210)
                }
                CZToggleRow(title: "Bypass EQ", subtitle: "A/B against no correction.",
                            isOn: $model.eqBypassed)
                    .frame(width: 230)
                    .onChange(of: model.eqBypassed) { _, _ in model.applyLive() }
            }
        }
    }

    private func traces(rate: Double) -> [ResponseCurve.Trace] {
        guard model.hasMeasurement else {
            // Nothing measured: just show what the filters themselves do.
            var out: [ResponseCurve.Trace] = [
                .fromProfile("Global", CZ.Color.blue, model.globalProfile, sampleRate: rate),
                .fromProfile("Speaker L", CZ.Color.purple, model.speakerProfiles.left, sampleRate: rate),
                .fromProfile("Speaker R", CZ.Color.pink, model.speakerProfiles.right,
                             sampleRate: rate, dashed: true),
            ]
            if let t = model.target {
                out.insert(.init(label: "Target · \(t.name)", color: CZ.Color.red,
                                 points: t.normalized().sampled(), dashed: true), at: 0)
            }
            return out
        }

        let errorMode = model.canShowErrorView && model.plotMode == .errorVsTarget
        let reference = model.target?.normalized()

        /// In error mode every curve is drawn as its distance from the target.
        func shape(_ curve: FrequencyResponse) -> [FrequencyResponse.Point] {
            guard errorMode, let reference else { return curve.normalized().sampled() }
            return curve.normalized().difference(from: reference)
        }

        var out: [ResponseCurve.Trace] = []

        // The target itself: a shaped line in absolute mode, the zero line in error mode.
        if let reference {
            out.append(.init(label: errorMode
                                ? "\(reference.name) — flattened to 0"
                                : "Target · \(reference.name)",
                             color: CZ.Color.red,
                             points: errorMode
                                ? ResponseCurve.grid.map { .init(hz: $0, db: 0) }
                                : reference.sampled(),
                             dashed: true))
        }

        for side in EQProfile.Side.allCases {
            guard let m = model.measurement(side) else { continue }
            out.append(.init(label: "Measured \(side.short)",
                             color: CZ.Color.lightGray,
                             points: shape(m),
                             dashed: side == .right))
        }

        for side in EQProfile.Side.allCases {
            guard let m = model.measurement(side) else { continue }
            let corrected = FrequencyResponse(
                name: "", points: m.corrected(by: model.combinedEQCascade(side), sampleRate: rate))
            out.append(.init(label: "Result \(side.short)",
                             color: side == .left ? CZ.Color.purple : CZ.Color.pink,
                             points: shape(corrected),
                             dashed: side == .right,
                             emphasised: true))
        }

        // The EQ curve is only meaningful on absolute axes.
        if !errorMode {
            let sameEQ = model.speakerProfiles.left == model.speakerProfiles.right
            if sameEQ {
                out.append(.fromProfile("EQ", CZ.Color.blue, eqAsProfile(.left),
                                        sampleRate: rate, dashed: true))
            } else {
                out.append(.fromProfile("EQ L", CZ.Color.blue, eqAsProfile(.left),
                                        sampleRate: rate, dashed: true))
                out.append(.fromProfile("EQ R", CZ.Color.mediumBlue, eqAsProfile(.right),
                                        sampleRate: rate, dashed: true))
            }
        }
        return out
    }

    /// The combined EQ for one ear, expressed as a profile so the plot can
    /// sample it the same way as the others.
    private func eqAsProfile(_ side: EQProfile.Side) -> PEQProfile {
        var p = model.globalProfile
        let speaker = side == .left ? model.speakerProfiles.left : model.speakerProfiles.right
        p.filters += speaker.filters
        p.preampDB += speaker.preampDB
        return p
    }

}

private struct PEQEditor: View {
    @Binding var text: String
    let profile: PEQProfile

    var body: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.sm) {
            TextEditor(text: $text)
                .font(CZ.Typography.mono(11))
                .scrollContentBackground(.hidden)
                .padding(CZ.Spacing.sm)
                .frame(height: 120)
                .background(CZ.Color.lightestGray)
                .overlay(RoundedRectangle(cornerRadius: CZ.Radius.medium)
                    .strokeBorder(CZ.Color.mutedGray, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
            HStack(spacing: CZ.Spacing.sm) {
                CZPill(text: "\(profile.activeFilterCount) active filters", tint: CZ.Color.blue)
                CZPill(text: String(format: "preamp %+.1f dB", profile.preampDB), tint: CZ.Color.mediumGray)
                Spacer()
                Text("REW / Equalizer APO format")
                    .font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
            }
        }
    }
}

// MARK: - Monitor

struct MonitorPanel: View {
    @EnvironmentObject var model: AppModel

    private let topRow: [BedChannel] = [.ltf, .rtf, .ltm, .rtm, .ltr, .rtr]
    private let bedRow: [BedChannel] = [.l, .r, .c, .lfe, .lw, .rw, .ls, .rs, .lrs, .rrs]

    var body: some View {
        VStack(spacing: CZ.Spacing.md) {
            CZCard(title: "Output") {
                CZMeterBar(label: "L", db: model.snapshot.outputPeakDB.0,
                           rmsDB: model.snapshot.outputRMSDB.0, clipped: model.snapshot.clipLeft > 0)
                CZMeterBar(label: "R", db: model.snapshot.outputPeakDB.1,
                           rmsDB: model.snapshot.outputRMSDB.1, clipped: model.snapshot.clipRight > 0)
                HStack(spacing: CZ.Spacing.lg) {
                    stat("Stereo limiter", model.limiterStatus)
                    stat("Clips", "\(model.snapshot.clipLeft + model.snapshot.clipRight)")
                    stat("Buffer underruns", "\(model.snapshot.underruns)")
                    stat("Chain latency", String(format: "%.1f ms", model.snapshot.latencyMS))
                    Spacer()
                }
            }

            CZCard(title: "Height layer") {
                HStack(spacing: CZ.Spacing.sm) { cells(topRow) }
            }

            CZCard(title: "Bed layer") {
                HStack(spacing: CZ.Spacing.sm) { cells(bedRow) }
            }
        }
    }

    private func cells(_ channels: [BedChannel]) -> some View {
        ForEach(channels, id: \.rawValue) { ch in
            CZChannelCell(name: ch.shortName,
                          db: model.snapshot.bedPeakDB[ch.rawValue],
                          active: model.layout.map[ch.rawValue] > 0)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
            Text(value).font(CZ.Typography.mono(13)).foregroundStyle(CZ.Color.darkBlue)
        }
    }
}

// MARK: - Log

struct LogPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        CZCard {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(CZ.Typography.mono(11))
                                .foregroundStyle(CZ.Color.mediumGray)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 420)
                .onChange(of: model.log.count) { _, count in
                    withAnimation(CZ.Motion.quick) { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            HStack {
                Spacer()
                CZButton(title: "Clear", variant: .transparent, size: .small) { model.clearLog() }
            }
        }
    }
}
