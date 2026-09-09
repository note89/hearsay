import Foundation
import FoundationModels

/// Apple's on-device language model (macOS 26). Nothing leaves the machine.
public final class FoundationModelsPolisher: Polisher {
    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(instructions: PolishPrompt.instructions(for: .plain, intensity: .full)).prewarm()
    }

    public func polish(_ spoken: String, style: WritingStyle, intensity: PolishIntensity, context: PolishContext) async -> PolishVerdict {
        guard isAvailable else { return .keepRaw(.modelUnavailable) }
        let session = LanguageModelSession(instructions: PolishPrompt.instructions(for: style, intensity: intensity))
        do {
            let response = try await session.respond(
                to: PolishPrompt.user(spoken: spoken, context: context),
                options: GenerationOptions(sampling: .greedy)
            )
            return PolishGuard.verdict(spoken: spoken, candidate: response.content)
        } catch {
            return .keepRaw(.failed(String(describing: error)))
        }
    }

}
