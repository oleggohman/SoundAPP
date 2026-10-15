import Foundation

/// Published reference data shipped with the app; no network access at runtime.
public enum BuiltInTarget: String, CaseIterable, Identifiable {
    case jm1 = "jm1-harman"
    case harmanIEM = "harman-iem-2019"
    case iefNeutral = "ief-neutral"
    case iefNeutralBass = "ief-neutral-bass"

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .jm1: return "JM-1 · Harman filters"
        case .harmanIEM: return "Harman IEM 2019"
        case .iefNeutral: return "IEF / Crinacle Neutral"
        case .iefNeutralBass: return "IEF / Crinacle Neutral + bass"
        }
    }
    public func load(from directory: URL) throws -> FrequencyResponse {
        let text = try String(contentsOf: directory.appendingPathComponent(rawValue + ".csv"), encoding: .utf8)
        guard let response = FrequencyResponse.parse(text, name: name),
              response.points.count >= 8, response.range.low <= 200, response.range.high >= 2000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return response
    }
    public static func bundledDirectory(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("Targets", isDirectory: true)
    }
}
