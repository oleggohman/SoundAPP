import SwiftUI

/// Log-frequency magnitude plot. Traces are plain point lists, so a parametric
/// EQ, a measured earphone curve and the sum of the two can share one set of
/// axes — which is the only way to see whether a correction actually lands.
///
/// Hovering reads exact values off every visible curve at the cursor
/// frequency; clicking a legend entry hides that curve, because six traces at
/// once is more than anyone can read.
struct ResponseCurve: View {

    struct Trace: Identifiable {
        let id = UUID()
        var label: String
        var color: Color
        var points: [FrequencyResponse.Point]
        var dashed: Bool = false
        var emphasised: Bool = false

        /// Build a trace by sampling a filter cascade.
        static func fromProfile(_ label: String, _ color: Color, _ profile: PEQProfile,
                                sampleRate: Double, dashed: Bool = false,
                                emphasised: Bool = false) -> Trace {
            let cascade = profile.cascade(sampleRate: sampleRate)
            let points = ResponseCurve.grid.map {
                FrequencyResponse.Point(hz: $0, db: cascade.magnitudeDB(at: $0, sampleRate: sampleRate))
            }
            return Trace(label: label, color: color, points: points,
                         dashed: dashed, emphasised: emphasised)
        }

        /// Value at a frequency, interpolated in log-frequency like the curves
        /// themselves, so the readout matches what is drawn.
        func value(at hz: Double) -> Double? {
            guard let first = points.first, let last = points.last else { return nil }
            if hz <= first.hz { return first.db }
            if hz >= last.hz { return last.db }
            var lo = 0, hi = points.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if points[mid].hz <= hz { lo = mid } else { hi = mid }
            }
            let a = points[lo], b = points[hi]
            guard b.hz > a.hz, a.hz > 0 else { return a.db }
            let t = log10(hz / a.hz) / log10(b.hz / a.hz)
            return a.db + (b.db - a.db) * t
        }
    }

    var traces: [Trace]
    var height: CGFloat = 190
    /// Shades ±this many dB around the zero line, for reading error plots.
    var toleranceBandDB: Double? = nil
    /// Labels of traces the viewer has switched off.
    @Binding var hidden: Set<String>

    @State private var hoverHz: Double?

    private static let minHz = 20.0
    private static let maxHz = 20_000.0
    private static let gridHz: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]
    /// Fixed so the panel cannot stretch across the plot.
    private static let readoutWidth: CGFloat = 164
    static let grid: [Double] = (0...220).map {
        minHz * pow(maxHz / minHz, Double($0) / 220)
    }

    private var visible: [Trace] { traces.filter { !hidden.contains($0.label) } }

    private var range: ClosedRange<Double> {
        var lo = -6.0, hi = 6.0
        for t in visible {
            for p in t.points where p.db.isFinite { lo = min(lo, p.db); hi = max(hi, p.db) }
        }
        let step = (hi - lo) > 40 ? 6.0 : 3.0
        return (floor((lo - 2) / step) * step)...(ceil((hi + 2) / step) * step)
    }

    private func x(_ f: Double, _ w: CGFloat) -> CGFloat {
        CGFloat(log10(max(f, Self.minHz) / Self.minHz) / log10(Self.maxHz / Self.minHz)) * w
    }
    private func frequency(atX px: CGFloat, _ w: CGFloat) -> Double {
        guard w > 0 else { return Self.minHz }
        let t = min(max(Double(px / w), 0), 1)
        return Self.minHz * pow(Self.maxHz / Self.minHz, t)
    }
    private func y(_ db: Double, _ h: CGFloat, _ r: ClosedRange<Double>) -> CGFloat {
        let t = (db - r.lowerBound) / (r.upperBound - r.lowerBound)
        return h - CGFloat(min(max(t, 0), 1)) * h
    }

    var body: some View {
        let r = range
        let span = r.upperBound - r.lowerBound
        let step = span > 40 ? 12.0 : (span > 20 ? 6.0 : 3.0)

        VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .topLeading) {
                    if let tol = toleranceBandDB {
                        let top = y(tol, h, r), bottom = y(-tol, h, r)
                        Rectangle()
                            .fill(CZ.Color.red.opacity(0.08))
                            .frame(height: max(0, bottom - top))
                            .offset(y: top)
                    }
                    ForEach(Array(stride(from: r.lowerBound, through: r.upperBound, by: step)), id: \.self) { db in
                        let yy = y(db, h, r)
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: w, y: yy))
                        }
                        .stroke(abs(db) < 1e-9 ? CZ.Color.mutedGray : CZ.Color.lightestGray,
                                lineWidth: abs(db) < 1e-9 ? 1 : 0.5)
                        if abs(db) > 1e-9 {
                            Text(String(format: "%+.0f", db))
                                .font(CZ.Typography.mono(8))
                                .foregroundStyle(CZ.Color.lightGray)
                                .offset(x: 2, y: yy - 9)
                        }
                    }
                    ForEach(Self.gridHz, id: \.self) { f in
                        let xx = x(f, w)
                        Path { p in
                            p.move(to: CGPoint(x: xx, y: 0)); p.addLine(to: CGPoint(x: xx, y: h))
                        }
                        .stroke(CZ.Color.lightestGray, lineWidth: 0.5)
                    }

                    ForEach(visible) { trace in
                        Path { p in
                            for (i, point) in trace.points.enumerated() {
                                let pt = CGPoint(x: x(point.hz, w), y: y(point.db, h, r))
                                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                            }
                        }
                        .stroke(trace.color,
                                style: StrokeStyle(lineWidth: trace.emphasised ? 2.6 : 1.8,
                                                   lineCap: .round,
                                                   dash: trace.dashed ? [4, 3] : []))
                    }

                    // Crosshair and per-curve dots at the cursor frequency.
                    if let hz = hoverHz {
                        let xx = x(hz, w)
                        Path { p in
                            p.move(to: CGPoint(x: xx, y: 0)); p.addLine(to: CGPoint(x: xx, y: h))
                        }
                        .stroke(CZ.Color.mediumGray, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        ForEach(visible) { trace in
                            if let v = trace.value(at: hz) {
                                Circle()
                                    .fill(trace.color)
                                    .frame(width: 5, height: 5)
                                    .position(x: xx, y: y(v, h, r))
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverHz = frequency(atX: location.x, w)
                    case .ended: hoverHz = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let hz = hoverHz {
                        // Sit on whichever side the cursor is not, so the panel
                        // never covers the part of the curve being read.
                        readout(hz)
                            .offset(x: x(hz, w) < w / 2 ? max(8, w - Self.readoutWidth - 8) : 8,
                                    y: 6)
                    }
                }
            }
            .frame(height: height)
            .padding(.vertical, CZ.Spacing.xs)
            .background(CZ.Color.white)
            .overlay(RoundedRectangle(cornerRadius: CZ.Radius.medium)
                .strokeBorder(CZ.Color.ghostGray, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))

            legend
        }
    }

    /// Values at the cursor. Deliberately small and opaque: it floats over the
    /// curves, so it has to stay out of the way and still be readable.
    private func readout(_ hz: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(hz >= 1000 ? String(format: "%.2f kHz", hz / 1000) : String(format: "%.0f Hz", hz))
                .font(CZ.Typography.mono(10))
                .foregroundStyle(CZ.Color.darkBlue)
                .padding(.bottom, 1)
            ForEach(visible) { t in
                if let v = t.value(at: hz) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(t.color)
                            .frame(width: 8, height: 2.5)
                        Text(t.label)
                            .font(CZ.Typography.mono(9))
                            .foregroundStyle(CZ.Color.mediumGray)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%+.1f", v))
                            .font(CZ.Typography.mono(9))
                            .foregroundStyle(CZ.Color.darkBlue)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: Self.readoutWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CZ.Radius.tiny)
                .fill(CZ.Color.white)
                .shadow(color: CZ.Color.black.opacity(0.10), radius: 4, y: 1))
        .overlay(RoundedRectangle(cornerRadius: CZ.Radius.tiny)
            .strokeBorder(CZ.Color.ghostGray, lineWidth: 1))
        .allowsHitTesting(false)
    }

    /// Clicking an entry hides or restores that curve.
    private var legend: some View {
        HStack(spacing: CZ.Spacing.md) {
            ForEach(traces) { t in
                let off = hidden.contains(t.label)
                Button {
                    if off { hidden.remove(t.label) } else { hidden.insert(t.label) }
                } label: {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(off ? CZ.Color.mutedGray : t.color)
                            .frame(width: 14, height: t.emphasised ? 3 : 2.5)
                        Text(t.label)
                            .font(CZ.Typography.caption)
                            .foregroundStyle(off ? CZ.Color.mutedGray : CZ.Color.mediumGray)
                            .strikethrough(off, color: CZ.Color.mutedGray)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(off ? "Show \(t.label)" : "Hide \(t.label)")
            }
            Spacer()
            HStack(spacing: CZ.Spacing.sm) {
                ForEach([20.0, 100.0, 1000.0, 10_000.0], id: \.self) { f in
                    Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))")
                        .font(CZ.Typography.mono(8))
                        .foregroundStyle(CZ.Color.lightGray)
                }
                Text("Hz").font(CZ.Typography.mono(8)).foregroundStyle(CZ.Color.lightGray)
            }
        }
    }
}
