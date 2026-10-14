import SwiftUI
import UniformTypeIdentifiers

/// Fold a multichannel file to stereo offline. Uses the same matrix, LFE path,
/// EQ and limiter as live playback, so what you hear monitoring is what the
/// file gets.
struct FilePanel: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: CZ.Spacing.md) {
            sourceCard
            if model.sourceInfo != nil { settingsCard }
            if let error = model.renderError { CZAlert(kind: .error, message: error) }
            if let result = model.renderResult { resultCard(result) }
        }
    }

    // MARK: Source

    private var sourceCard: some View {
        CZCard(title: "Source",
               subtitle: "WAV, AIFF, CAF, FLAC or anything else Core Audio reads. The channel order is the same 9.1.6 bed order the live path uses.") {
            dropZone
            if let info = model.sourceInfo {
                HStack(spacing: CZ.Spacing.sm) {
                    CZPill(text: "\(info.channels) ch", tint: CZ.Color.blue)
                    CZPill(text: "\(Int(info.sampleRate)) Hz", tint: CZ.Color.mediumGray)
                    CZPill(text: durationText(info.duration), tint: CZ.Color.mediumGray)
                    if let l = info.suggestedLayout {
                        CZPill(text: "looks like \(l.name)", tint: CZ.Color.purple)
                    }
                    Spacer()
                    CZButton(title: "Choose another…", variant: .transparent, size: .small) {
                        model.chooseSourceFile()
                    }
                }
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: CZ.Spacing.sm) {
            Image(systemName: model.sourceInfo == nil ? "waveform.badge.plus" : "waveform")
                .font(.system(size: 26))
                .foregroundStyle(dropTargeted ? CZ.Color.blue : CZ.Color.mediumBlue)
            Text(model.sourceInfo?.url.lastPathComponent ?? "Drop a multichannel file here")
                .font(CZ.Typography.subtitle)
                .foregroundStyle(CZ.Color.defaultText)
                .lineLimit(1)
                .truncationMode(.middle)
            if model.sourceInfo == nil {
                CZButton(title: "Choose file…", icon: "folder", variant: .secondary, size: .small) {
                    model.chooseSourceFile()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CZ.Spacing.xl)
        .background(dropTargeted ? CZ.Color.lightestBlue : CZ.Color.paleBlue)
        .overlay(
            RoundedRectangle(cornerRadius: CZ.Radius.medium)
                .strokeBorder(dropTargeted ? CZ.Color.blue : CZ.Color.lightBlue,
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
        .animation(CZ.Motion.quick, value: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.adoptSourceFile(url) }
            }
            return true
        }
    }

    // MARK: Settings and render

    private var settingsCard: some View {
        CZCard(title: "Render") {
            HStack(alignment: .top, spacing: CZ.Spacing.lg) {
                CZSelect(label: "Source layout",
                         selection: Binding(get: { model.fileLayout.name },
                                            set: { model.fileLayoutName = $0 }),
                         options: LayoutPreset.all.map { ($0.name, "\($0.name) · \($0.requiredInputChannels) ch") },
                         help: "Which bed slot each file channel feeds.")
                    .frame(width: 220)
                CZSelect(label: "Output bit depth", selection: $model.outputBitDepth,
                         options: [(16, "16-bit"), (24, "24-bit"), (32, "32-bit float")])
                    .frame(width: 160)
                Spacer()
            }

            Text("Using “\(model.configuration.recipe.name)” · trim \(String(format: "%+.2f dB", model.configuration.totalTrimDB)) · limiter \(model.limiterEnabled ? String(format: "on at %.1f dBTP", model.configuration.limiter.ceilingDB) : "off")\(model.eqBypassed ? " · EQ bypassed" : "")")
                .font(CZ.Typography.caption)
                .foregroundStyle(CZ.Color.mediumGray)

            if let reason = model.fileRenderBlockedReason, model.sourceInfo != nil {
                CZAlert(kind: .warning, message: reason)
            }

            if let progress = model.renderProgress {
                VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(CZ.Color.lightestGray)
                            Capsule().fill(CZ.Color.blue)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        Text("\(Int(progress * 100))%")
                            .font(CZ.Typography.mono(11))
                            .foregroundStyle(CZ.Color.mediumGray)
                        Spacer()
                        CZButton(title: "Cancel", variant: .transparent, size: .small) {
                            model.cancelRender()
                        }
                    }
                }
            } else {
                HStack {
                    Spacer()
                    CZButton(title: "Render to stereo…", icon: "square.and.arrow.down",
                             variant: .primary,
                             isEnabled: model.fileRenderBlockedReason == nil) {
                        model.renderFile()
                    }
                }
            }
        }
    }

    private func resultCard(_ r: OfflineRenderer.Result) -> some View {
        CZCard(title: "Done") {
            HStack(alignment: .top, spacing: CZ.Spacing.xl) {
                stat("Peak", String(format: "%.1f / %.1f dBFS", r.peakLeftDB, r.peakRightDB))
                stat("Limiter", r.maxGainReductionDB > 0.05
                     ? String(format: "−%.1f dB", r.maxGainReductionDB) : "never engaged")
                stat("Clipped samples", "\(r.clippedSamples)")
                stat("Speed", String(format: "%.0f× real time", r.speedFactor))
                Spacer()
            }
            HStack(spacing: CZ.Spacing.sm) {
                Text(r.outputURL.lastPathComponent)
                    .font(CZ.Typography.mono(11))
                    .foregroundStyle(CZ.Color.mediumGray)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                CZButton(title: "Show in Finder", icon: "folder",
                         variant: .secondary, size: .small) { model.revealRenderResult() }
            }
            if r.clippedSamples > 0 {
                CZAlert(kind: .warning,
                        message: "\(r.clippedSamples) samples reached full scale. Turn the limiter on, or pick a peak-safe headroom mode, and render again.")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
            Text(value).font(CZ.Typography.mono(13)).foregroundStyle(CZ.Color.darkBlue)
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return m > 0 ? "\(m)m \(s)s" : String(format: "%.1fs", seconds)
    }
}
