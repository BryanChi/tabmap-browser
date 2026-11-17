import Foundation
import TabMapCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Gives a row of the map a short name and a one-sentence description.
/// Uses Apple's on-device language model (macOS 26 with Apple Intelligence) when it is available,
/// and otherwise names the row from its page titles. Nothing leaves the Mac either way.
@MainActor
final class TrailNamer {
    /// True when the on-device model can be used right now.
    var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    func label(for trail: Trail) async -> (name: String, summary: String, usedModel: Bool) {
        let fallback = TrailLabelHeuristic.label(for: trail)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let reply = await askModel(TrailLabelText.prompt(for: trail)),
           let parsed = TrailLabelText.parse(reply) {
            return (parsed.name, parsed.summary ?? fallback.summary, true)
        }
        #endif
        return (fallback.name, fallback.summary, false)
    }

    #if canImport(FoundationModels)
    /// One fresh session per request, so groups never bleed into each other. Nil on any failure or refusal.
    @available(macOS 26.0, *)
    private func askModel(_ prompt: String) async -> String? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: TrailLabelText.instructions)
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 80)
        do {
            let response = try await session.respond(to: prompt, options: options)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
    #endif
}
