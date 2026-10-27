// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The model's replies of a stored minutes run, played back through the app's own minutes code with no model: `llm-eval --tasks
/// minutes-replay` re-runs validation, the item filter and the owner rules on recorded replies, so the deterministic parts can be tuned in
/// seconds on development meetings. EVALUATION ONLY; public transcripts and their stored results only. What needs a real model (the
/// prompts, the closing request) is not replayed: those calls get an empty answer.
public struct ReplayedReplies: Sendable {
    /// The block extracts of a map-reduce run, in order, and whether the model's reply was cut off at the token limit (the run then
    /// split the block in halves, and the replay is cut off in the same place so it splits it in the same way).
    public var blocks: [(reply: String, truncated: Bool)]
    /// The reply of the one call that writes the minutes (or, on a small window, the digest).
    public var final: String
    /// The reply of the closing request, when the run made one.
    public var closing: String?
    public var contextTokens: Int

    /// One recorded reply for a run in one call (the tests; a result file is read with `init(resultFile:)`).
    public static func single(_ reply: String, contextTokens: Int) -> ReplayedReplies {
        ReplayedReplies(blocks: [], final: reply, closing: nil, contextTokens: contextTokens)
    }

    init(blocks: [(reply: String, truncated: Bool)], final: String, closing: String?, contextTokens: Int) {
        self.blocks = blocks
        self.final = final
        self.closing = closing
        self.contextTokens = contextTokens
    }

    /// Reads a result file written by `MinutesEvaluation.run` (`replies`, `calls`, `contextTokens`). A reply with a title is the minutes (or
    /// the digest), one with a summary and no title is a block extract, one with only decisions and tasks is the closing request's.
    public init?(resultFile data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let replies = object["replies"] as? [String], !replies.isEmpty else { return nil }
        // The calls that produced a reply, in order (a call that threw produced none).
        let finish = ((object["calls"] as? [[String: Any]]) ?? []).map { $0["finishReason"] as? String ?? "" }.filter { $0 != "error" }
        func keys(_ reply: String) -> Set<String> {
            guard let a = reply.firstIndex(of: "{"), let z = reply.lastIndex(of: "}"), a < z,
                  let o = try? JSONSerialization.jsonObject(with: Data(reply[a...z].utf8)) as? [String: Any] else { return [] }
            return Set(o.keys)
        }
        var blocks: [(reply: String, truncated: Bool)] = []
        var final: String?
        var closing: String?
        for (i, reply) in replies.enumerated() {
            let k = keys(reply)
            let truncated = i < finish.count && finish[i] == "length"
            if k.contains("title") { final = reply }
            else if k.contains("summary") || k.contains("topics") || (k.isEmpty && final == nil) { blocks.append((reply, truncated)) }
            else if k.contains("decisions") || k.contains("tasks") { closing = reply }
        }
        guard let final else { return nil }
        // A one-call run has no block extracts; a run by blocks has them all ahead of the digest.
        let diagnostics = object["diagnostics"] as? [String: Any]
        self.blocks = (diagnostics?["blocks"] as? Int ?? 0) > 0 ? blocks : []
        self.final = final
        self.closing = closing
        contextTokens = object["contextTokens"] as? Int ?? 0
    }
}

/// Answers each call of the minutes with the recorded reply of its kind.
final class ReplayChat: ChatModel, @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [(reply: String, truncated: Bool)]
    private let final: String
    private let closing: String?
    private let context: Int
    /// The model that answers the final request (the digest) for real; the block extracts and the closing reply stay recorded
    /// (`--replay-live`: the digest and the summary can be tuned without re-running the blocks).
    private let live: (any ChatModel)?

    init(_ replies: ReplayedReplies, live: (any ChatModel)? = nil) {
        self.live = live
        blocks = replies.blocks
        final = replies.final
        closing = replies.closing
        context = replies.contextTokens
    }

    var contextTokens: Int? { get async { context } }

    static let emptyExtract = #"{"summary":"","topics":[],"decisions":[],"tasks":[],"entities":[],"open_questions":[]}"#
    static let emptyItems = #"{"decisions":[],"tasks":[]}"#

    func chat(_ messages: [ChatMessage], _ options: ChatOptions, onProgress: (@Sendable (Int) -> Void)?) async throws -> ChatResult {
        let last = messages.last?.content ?? ""
        let reply: String
        var truncated = false
        if last.hasPrefix("This is ONLY one block") {
            let next = lock.withLock { blocks.isEmpty ? (reply: Self.emptyExtract, truncated: false) : blocks.removeFirst() }
            reply = next.reply
            truncated = next.truncated
        } else if last.contains("This is the end of the meeting") || last.contains("The meeting ends with segments") || last.hasPrefix("List the decisions and tasks of segments") {
            reply = closing ?? Self.emptyItems
        } else if let live {
            return try await live.chat(messages, options, onProgress: onProgress)
        } else {
            reply = final
        }
        return ChatResult(content: reply, promptTokens: 0, cachedTokens: 0, completionTokens: 0, finishReason: truncated ? .length : .stop)
    }
}

extension EvaluationModel {
    /// A model of `kind` ("apple" or "integrated") with the context window of the recorded run, answering from its recorded replies.
    static func replay(kind: String, replies: ReplayedReplies, liveFinal: Bool = false) -> EvaluationModel {
        EvaluationModel(name: (kind == "apple" ? "Apple on-device language model" : "Gemma 4 E4B-it") + (liveFinal ? " (replayed blocks)" : " (replayed replies)"), kind: kind) {
            if liveFinal, kind == "apple" {
                let apple = AppleChatModel()
                return (ReplayChat(replies, live: apple), replies.contextTokens, { apple.supports($0) }, apple.availability == .available ? nil : String(describing: apple.availability))
            }
            return (ReplayChat(replies), replies.contextTokens, nil, nil)
        }
    }
}
