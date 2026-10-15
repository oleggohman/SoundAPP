import SwiftUI

@MainActor
enum ResponsePlotTraces {
    static func make(model: AppModel, rate: Double,
                     global: PEQProfile, speakers: (left: PEQProfile, right: PEQProfile),
                     mode: AppModel.PlotMode) -> [ResponseCurve.Trace] {
        func eqAsProfile(_ side: EQProfile.Side) -> PEQProfile {
            var p = global
            let speaker = side == .left ? speakers.left : speakers.right
            p.filters += speaker.filters
            p.preampDB += speaker.preampDB
            return p
        }
        guard model.hasMeasurement else {
            // Nothing measured: just show what the filters themselves do.
            var out: [ResponseCurve.Trace] = [
                .fromProfile("Global", CZ.Color.blue, global, sampleRate: rate),
                .fromProfile("Speaker L", CZ.Color.purple, speakers.left, sampleRate: rate),
                .fromProfile("Speaker R", CZ.Color.pink, speakers.right,
                             sampleRate: rate, dashed: true),
            ]
            if let t = model.target {
                out.insert(.init(label: "Target · \(t.name)", color: CZ.Color.red,
                                 points: t.normalized().sampled(), dashed: true), at: 0)
            }
            return out
        }

        let errorMode = model.canShowErrorView && mode == .errorVsTarget
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
                name: "", points: m.corrected(by: eqAsProfile(side).cascade(sampleRate: rate), sampleRate: rate))
            out.append(.init(label: "Result \(side.short)",
                             color: side == .left ? CZ.Color.purple : CZ.Color.pink,
                             points: shape(corrected),
                             dashed: side == .right,
                             emphasised: true))
        }

        // The EQ curve is only meaningful on absolute axes.
        if !errorMode {
            let sameEQ = speakers.left == speakers.right
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

}
