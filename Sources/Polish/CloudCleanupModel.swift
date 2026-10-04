import Foundation

public enum CloudCleanupModel: String, CaseIterable, Codable, Sendable {
    case glmFlash = "z-ai/glm-5.3-flash"
    case geminiFlash = "google/gemini-3.8-flash"
    case geminiLite = "google/gemini-3.5-flash-lite"

    public static let recommended = Self.glmFlash

    public var label: String {
        switch self {
        case .glmFlash: return "GLM 5.3 Flash"
        case .geminiFlash: return "Gemini 3.8 Flash"
        case .geminiLite: return "Gemini 3.5 Flash-Lite"
        }
    }

    public var priceLabel: String {
        switch self {
        case .glmFlash: return "$0.15 input / $0.50 output per million tokens"
        case .geminiFlash: return "$0.75 input / $3.75 output per million tokens"
        case .geminiLite: return "$0.30 input / $2.50 output per million tokens"
        }
    }

    var reasoning: [String: Any] {
        switch self {
        case .glmFlash: return ["effort": "low", "exclude": true]
        case .geminiFlash: return ["effort": "low", "exclude": true]
        case .geminiLite: return ["effort": "minimal", "exclude": true]
        }
    }

    var provider: [String: Any] {
        let prices: (Double, Double)
        switch self {
        case .glmFlash: prices = (0.15, 0.50)
        case .geminiFlash: prices = (0.75, 3.75)
        case .geminiLite: prices = (0.30, 2.50)
        }
        return ["sort": "throughput", "max_price": ["prompt": prices.0, "completion": prices.1]]
    }
}
