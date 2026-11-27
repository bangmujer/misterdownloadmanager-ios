import Foundation

// MARK: - Token usage reported by the provider for one answer
//
// OpenAI-shape gateways report it in the `usage` object of the final
// streamed chunk (only when the request asks for it via
// stream_options.include_usage); Gemini reports `usageMetadata` in
// its final chunk; Claude reports `message_start` / `message_delta`
// usage events. Not every gateway returns usage at all — when it is
// absent the message simply shows no usage line, never a guess.
// Persisted on AIChatMessage so history keeps its numbers.

struct AIUsage: Codable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    /// Tokens served from the prompt cache (OpenAI cached_tokens,
    /// Gemini cachedContentTokenCount, Claude cache_read_input_tokens).
    var cachedInputTokens: Int = 0
    /// Tokens written to the cache (Claude cache_creation_input_tokens).
    var cacheWriteTokens: Int = 0
    /// Thinking/reasoning output tokens (OpenAI reasoning_tokens,
    /// Gemini thoughtsTokenCount).
    var reasoningTokens: Int = 0
    /// How many API requests produced this answer (agent mode runs
    /// several rounds; plain chat is 1).
    var requests: Int = 1
    /// Wall-clock seconds for the whole turn, measured client-side.
    var durationSeconds: Double = 0

    var totalTokens: Int { inputTokens + outputTokens }
    /// Input tokens that were neither served from nor written to the
    /// cache (the reference sheet's "Uncached input").
    var uncachedInputTokens: Int { max(0, inputTokens - cachedInputTokens - cacheWriteTokens) }
    var tokensPerSecond: Double {
        durationSeconds > 0 && outputTokens > 0 ? Double(outputTokens) / durationSeconds : 0
    }
    var hasData: Bool { inputTokens > 0 || outputTokens > 0 }

    /// Field-wise sum across API rounds (agent mode). Duration is left
    /// to the caller, which measures the whole turn.
    static func + (lhs: AIUsage, rhs: AIUsage) -> AIUsage {
        AIUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            requests: lhs.requests + rhs.requests,
            durationSeconds: lhs.durationSeconds
        )
    }

    /// Absorb one streamed chunk's usage. Within a single response the
    /// numbers are cumulative totals, so each field takes the newest
    /// (largest) value seen — Claude's start event carries the input
    /// side and its delta events the growing output side, which the
    /// same rule merges correctly.
    mutating func absorb(_ next: AIUsage) {
        inputTokens = max(inputTokens, next.inputTokens)
        outputTokens = max(outputTokens, next.outputTokens)
        cachedInputTokens = max(cachedInputTokens, next.cachedInputTokens)
        cacheWriteTokens = max(cacheWriteTokens, next.cacheWriteTokens)
        reasoningTokens = max(reasoningTokens, next.reasoningTokens)
    }

    /// Usage carried by one SSE JSON chunk, if any. Returns nil for
    /// text-only chunks.
    static func chunkUsage(provider: AIProvider, json: [String: Any]) -> AIUsage? {
        switch provider {
        case .chatgpt, .custom, .balitech:
            guard let usage = json["usage"] as? [String: Any] else { return nil }
            return fromOpenAIUsage(usage)
        case .gemini:
            guard let meta = json["usageMetadata"] as? [String: Any] else { return nil }
            return AIUsage(
                inputTokens: meta["promptTokenCount"] as? Int ?? 0,
                outputTokens: meta["candidatesTokenCount"] as? Int ?? 0,
                cachedInputTokens: meta["cachedContentTokenCount"] as? Int ?? 0,
                reasoningTokens: meta["thoughtsTokenCount"] as? Int ?? 0
            )
        case .claude:
            let type = json["type"] as? String ?? ""
            if type == "message_start",
               let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                return fromClaudeUsage(usage)
            }
            if type == "message_delta",
               let usage = json["usage"] as? [String: Any] {
                return fromClaudeUsage(usage)
            }
            return nil
        case .meta:
            return nil
        }
    }

    private static func fromOpenAIUsage(_ usage: [String: Any]) -> AIUsage? {
        let input = usage["prompt_tokens"] as? Int ?? 0
        let output = usage["completion_tokens"] as? Int ?? 0
        guard input > 0 || output > 0 else { return nil }
        let details = usage["prompt_tokens_details"] as? [String: Any] ?? [:]
        let completionDetails = usage["completion_tokens_details"] as? [String: Any] ?? [:]
        return AIUsage(
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: details["cached_tokens"] as? Int ?? 0,
            reasoningTokens: completionDetails["reasoning_tokens"] as? Int ?? 0
        )
    }

    private static func fromClaudeUsage(_ usage: [String: Any]) -> AIUsage? {
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let read = usage["cache_read_input_tokens"] as? Int ?? 0
        let write = usage["cache_creation_input_tokens"] as? Int ?? 0
        guard input > 0 || output > 0 || read > 0 || write > 0 else { return nil }
        return AIUsage(
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: read,
            cacheWriteTokens: write
        )
    }

    /// Indonesian grouping format: 12.375, like the reference sheet.
    static func formatted(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// One-line caption under a bubble: "12.375 token · ↑ 11.400 · ↓ 975 · 17,6 token/dtk".
    var caption: String {
        var parts = ["\(Self.formatted(totalTokens)) token"]
        if inputTokens > 0 { parts.append("↑ \(Self.formatted(inputTokens))") }
        if outputTokens > 0 { parts.append("↓ \(Self.formatted(outputTokens))") }
        if tokensPerSecond > 0 {
            let speed = String(format: "%.1f", tokensPerSecond).replacingOccurrences(of: ".", with: ",")
            parts.append("\(speed) token/dtk")
        }
        return parts.joined(separator: " · ")
    }
}
