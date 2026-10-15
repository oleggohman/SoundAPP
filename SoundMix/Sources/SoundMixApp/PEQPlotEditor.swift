import SwiftUI
import AppKit

/// Owns a separate native full-screen window, keeping the main controls available.
@MainActor
final class PEQPlotWindow: NSObject, NSWindowDelegate {
    static let shared = PEQPlotWindow()
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "SoundMix — PEQ editor"
        window.minSize = NSSize(width: 1040, height: 720)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.contentView = NSHostingView(rootView: PEQPlotEditor(model: model, close: { [weak self] in
            self?.window?.close()
        }).preferredColorScheme(.light))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }
    func windowWillClose(_ notification: Notification) { window = nil }
}

struct PEQPlotEditor: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var draft: PEQEditDraft
    @State private var stage: PEQEditDraft.Stage = .global
    @State private var selected: Int? = nil
    @State private var hiddenEQ: Set<String> = []
    @State private var hiddenPreview: Set<String> = []
    @State private var mode: AppModel.PlotMode
    @State private var message: String?
    private let originalProfileID: UUID?
    private let gainExtent: Double

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        let draft = PEQEditDraft(global: model.globalPEQText, speaker: model.speakerPEQText,
                                 swapsOutputs: model.swapOutputs)
        _draft = State(initialValue: draft)
        _mode = State(initialValue: model.plotMode)
        originalProfileID = model.selectedProfileID
        gainExtent = max(24, PEQEditDraft.Stage.allCases.flatMap { draft.profile($0).filters }
            .map { abs($0.gainDB) }.filter(\.isFinite).max() ?? 24) + 6
    }

    private var profile: PEQProfile { draft.profile(stage) }
    private var rate: Double { model.state.isRunning ? model.engine.currentSampleRate : 48_000 }
    private var maxFrequency: Double { min(20_000, rate * 0.49) }
    private var selectedFilter: PEQFilter? {
        guard let selected, profile.filters.indices.contains(selected) else { return nil }
        return profile.filters[selected]
    }
    private var conflict: Bool {
        model.globalPEQText != draft.originalGlobal || model.speakerPEQText != draft.originalSpeaker
            || model.selectedProfileID != originalProfileID || model.swapOutputs != draft.swapsOutputs
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 12) {
                header
                if !draft.warnings.isEmpty {
                    Text("This EQ contains unsupported directives. Edit those in the text editor before using graphical edits: " + draft.warnings.joined(separator: "; "))
                        .foregroundStyle(CZ.Color.red)
                }
                if conflict {
                    Text("The active profile changed in the main window. Close and reopen this editor to use the current profile.")
                        .foregroundStyle(CZ.Color.red)
                }
                if model.eqBypassed {
                    Text("EQ is bypassed. This is a preview of your filters; turn bypass off in the main window to hear applied changes.")
                        .foregroundStyle(CZ.Color.orange)
                }
                ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EQ gain (dB) · drag points vertically for gain · frequency locked")
                            .font(.system(size: 14, weight: .medium))
                        ResponseCurve(traces: [
                            .fromProfile("Reference · before edits", CZ.Color.orange,
                                         draft.referenceProfile(stage), sampleRate: rate, dashed: true),
                            .fromProfile("Draft · \(stage.rawValue)", CZ.Color.blue,
                                         profile, sampleRate: rate, emphasised: true)],
                                      height: max(180, (geo.size.height - 350) * 0.6), hidden: $hiddenEQ,
                                      editPoints: profile.filters.enumerated().map {
                                          .init(id: $0.offset, frequency: $0.element.frequency,
                                                gainDB: $0.element.gainDB, enabled: $0.element.enabled)
                                      }, selectedPoint: selected, fixedRange: -gainExtent...gainExtent,
                                      showsReadout: false,
                                      onSelectPoint: { selected = $0 },
                                      onChangeGain: { index, gain in
                                          guard !conflict else { return }
                                          selected = index
                                          draft.setGain(gain, at: index, for: stage)
                                          message = nil
                                      }, referenceLineDB: 0)
                            .disabled(!draft.warnings.isEmpty || conflict)
                        HStack {
                            Text(mode == .errorVsTarget && model.canShowErrorView
                                 ? "Draft result · deviation from target (dB)" : "Draft result · normalized response / EQ gain (dB)")
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            if model.canShowErrorView {
                                Picker("View", selection: $mode) {
                                    ForEach(AppModel.PlotMode.allCases) { Text($0.label).tag($0) }
                                }.labelsHidden().frame(width: 200)
                            }
                        }
                        ResponseCurve(traces: ResponsePlotTraces.make(model: model, rate: rate,
                                          global: draft.profile(.global),
                                          speakers: (draft.profile(.left), draft.profile(.right)), mode: mode),
                                      height: max(120, (geo.size.height - 350) * 0.4),
                                      toleranceBandDB: model.canShowErrorView && mode == .errorVsTarget ? 3 : nil,
                                      hidden: $hiddenPreview)
                    }
                    inspector.frame(width: 240)
                }
                .padding(.vertical, 4)
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CZ.Color.paleBlue)
            .foregroundStyle(CZ.Color.darkBlue)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("PEQ plot editor").font(.system(size: 24, weight: .semibold))
                Text("Preview changes here, then Apply to update the current EQ. Save the profile in the main window to keep it in your library.")
                    .font(.system(size: 12))
            }
            Spacer()
            Picker("Edit", selection: $stage) {
                ForEach(PEQEditDraft.Stage.allCases) { Text($0.rawValue).tag($0) }
            }.frame(width: 210)
                .onChange(of: stage) { _, _ in selected = nil; hiddenEQ.removeAll() }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Add band", systemImage: "plus") {
                    var p = profile
                    p.filters.append(PEQFilter(frequency: 1000, gainDB: 0, q: 1))
                    draft.setProfile(p, for: stage)
                    selected = p.filters.count - 1
                }
                Button("Delete", systemImage: "trash") {
                    guard let selected, profile.filters.indices.contains(selected) else { return }
                    var p = profile
                    p.filters.remove(at: selected)
                    draft.setProfile(p, for: stage)
                    self.selected = nil
                }.disabled(selectedFilter == nil)
            }
            numberField("Preamp (dB)", value: profile.preampDB, limits: -60...24) { value in
                var p = profile; p.preampDB = value; draft.setProfile(p, for: stage)
            }
            if let filter = selectedFilter {
                Divider()
                Text("Band \((selected ?? 0) + 1)").font(.headline)
                Toggle("Enabled", isOn: Binding(get: { filter.enabled }, set: { value in updateFilter { $0.enabled = value } }))
                Picker("Type", selection: Binding(get: { filter.kind }, set: { value in updateFilter { $0.kind = value } })) {
                    Text("Peak").tag(PEQFilter.Kind.peaking)
                    Text("Low shelf").tag(PEQFilter.Kind.lowShelf)
                    Text("High shelf").tag(PEQFilter.Kind.highShelf)
                }
                numberField("Frequency (Hz)", value: filter.frequency, limits: 20...maxFrequency) { value in updateFilter { $0.frequency = value } }
                numberField("Gain (dB)", value: filter.gainDB, limits: -24...24) { value in updateFilter { $0.gainDB = value } }
                numberField("Q", value: filter.q, limits: 0.1...20) { value in updateFilter { $0.q = value } }
                Slider(value: Binding(get: { filter.q }, set: { value in updateFilter { $0.q = value } }), in: 0.1...20)
                    .accessibilityLabel("Band Q")
            } else {
                Text("Select a numbered point, or add a band. Drag vertically to change gain; horizontal movement is ignored. Use the frequency field for deliberate frequency edits and Q to set bandwidth.")
                    .font(.system(size: 14))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(profile.filters.enumerated()), id: \.offset) { index, filter in
                        Button {
                            selected = index
                        } label: {
                            Text(String(format: "%d · %.0f Hz · %+.1f dB%@", index + 1, filter.frequency, filter.gainDB, filter.enabled ? "" : " · OFF"))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(selected == index ? CZ.Color.blue : CZ.Color.darkBlue)
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 180)
        }.disabled(!draft.warnings.isEmpty || conflict)
    }

    private func numberField(_ title: String, value: Double, limits: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            TextField(title, value: Binding(get: { value }, set: { newValue in
                guard newValue.isFinite else { return }
                set(min(limits.upperBound, max(limits.lowerBound, newValue)))
            }), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
    }

    private var footer: some View {
        HStack {
            Text(message ?? "Changes are a draft. Applying rewrites edited EQ text in APO format.")
                .font(.system(size: 12))
            Spacer()
            Button("Reset") {
                draft.reset()
                selected = nil
                message = "Unapplied edits reset."
            }
            .disabled(!draft.hasChanges || conflict)
            .help("Discard all edits since opening the editor or the last Apply")
            Button(draft.hasChanges ? "Cancel" : "Close", action: close).keyboardShortcut(.cancelAction)
            Button("Apply") { apply(closeAfter: false) }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.hasChanges || !draft.warnings.isEmpty || conflict)
            Button("Apply & close") { apply(closeAfter: true) }
                .disabled(!draft.hasChanges || !draft.warnings.isEmpty || conflict)
        }
    }

    private func apply(closeAfter: Bool) {
        guard !conflict, draft.warnings.isEmpty else { return }
        guard model.applyPEQDraft(draft) else {
            message = "The EQ changed in the main window. Close and reopen this editor."
            return
        }
        draft.acceptChanges()
        message = "Applied. You can keep editing; Save in the main window saves the profile to the library."
        if closeAfter { close() }
    }

    private func updateFilter(_ edit: (inout PEQFilter) -> Void) {
        guard let selected, profile.filters.indices.contains(selected), !conflict else { return }
        var p = profile
        edit(&p.filters[selected])
        draft.setProfile(p, for: stage)
        message = nil
    }
}
