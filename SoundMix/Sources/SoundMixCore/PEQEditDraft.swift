import Foundation

/// Isolated graphical edits. Untouched documents retain their original text.
public struct PEQEditDraft {
    public enum Stage: String, CaseIterable, Identifiable {
        case global = "Global", left = "Speaker L", right = "Speaker R"
        public var id: String { rawValue }
    }
    public let originalGlobal: String
    public let originalSpeaker: String
    public let swapsOutputs: Bool
    private var global: APOParser.Document
    private var speaker: APOParser.Document
    private var changedGlobal = false
    private var changedSpeaker = false

    public init(global: String, speaker: String, swapsOutputs: Bool) {
        originalGlobal = global
        originalSpeaker = speaker
        self.swapsOutputs = swapsOutputs
        self.global = APOParser.parse(global)
        self.speaker = APOParser.parse(speaker)
    }

    public var warnings: [String] { global.warnings + speaker.warnings }
    public var hasChanges: Bool { globalText != originalGlobal || speakerText != originalSpeaker }
    private func channel(_ stage: Stage) -> Int {
        if stage == .global { return global.channels.keys.min() ?? 0 }
        return (stage == .left) != swapsOutputs ? 0 : 1
    }
    public func profile(_ stage: Stage) -> PEQProfile {
        stage == .global ? global.firstProfile : speaker.profile(forChannel: channel(stage))
    }
    public mutating func setProfile(_ profile: PEQProfile, for stage: Stage) {
        guard warnings.isEmpty, profile != self.profile(stage) else { return }
        if stage == .global {
            global.channels[channel(stage)] = profile
            changedGlobal = true
        } else {
            // Materialize both fallbacks before editing one ear so the other ear is preserved.
            let left = speaker.profile(forChannel: 0), right = speaker.profile(forChannel: 1)
            speaker.channels[0] = left
            speaker.channels[1] = right
            speaker.channels[channel(stage)] = profile
            changedSpeaker = true
        }
    }
    /// Dragging only adjusts gain; frequency, Q and the other bands stay unchanged.
    public mutating func setGain(_ gain: Double, at index: Int, for stage: Stage) {
        guard gain.isFinite else { return }
        var p = profile(stage)
        guard p.filters.indices.contains(index) else { return }
        p.filters[index].gainDB = min(24, max(-24, gain))
        setProfile(p, for: stage)
    }
    public func referenceProfile(_ stage: Stage) -> PEQProfile {
        PEQEditDraft(global: originalGlobal, speaker: originalSpeaker, swapsOutputs: swapsOutputs).profile(stage)
    }
    public mutating func reset() {
        self = PEQEditDraft(global: originalGlobal, speaker: originalSpeaker, swapsOutputs: swapsOutputs)
    }
    /// Called after Apply succeeds so subsequent Reset only discards unapplied edits.
    public mutating func acceptChanges() {
        self = PEQEditDraft(global: globalText, speaker: speakerText, swapsOutputs: swapsOutputs)
    }
    public func combined(_ side: Stage) -> PEQProfile {
        var p = profile(.global)
        let ear = profile(side)
        p.filters += ear.filters
        p.preampDB += ear.preampDB
        return p
    }
    public var globalText: String { changedGlobal ? Self.text(global) : originalGlobal }
    public var speakerText: String { changedSpeaker ? Self.text(speaker) : originalSpeaker }

    private static func text(_ document: APOParser.Document) -> String {
        document.channels.keys.sorted().map { channel in
            let p = document.channels[channel]!
            func number(_ value: Double) -> String {
                String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
            }
            var lines = ["Channel: \(channel + 1)", "Preamp: \(number(p.preampDB)) dB"]
            for (index, filter) in p.filters.enumerated() {
                let kind = filter.kind == .peaking ? "PK" : (filter.kind == .lowShelf ? "LSC" : "HSC")
                lines.append("Filter \(index + 1): \(filter.enabled ? "ON" : "OFF") \(kind) Fc \(number(filter.frequency)) Hz Gain \(number(filter.gainDB)) dB Q \(number(filter.q))")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
