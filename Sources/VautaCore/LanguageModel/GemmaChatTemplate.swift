// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Builds the token ids of a Gemma 4 chat prompt structurally (no Jinja), for the message shapes Vauta sends:
///
///     <bos><|turn>system\n{content}<turn|>\n<|turn>user\n{content}<turn|>\n … <|turn>model\n
///
/// Content is trimmed and tokenised as literal text: a transcript line that contains `<turn|>` or `<|turn>` is ordinary
/// text and never becomes a control token. Control tokens enter only here. Thinking is off (no `<|think|>`).
/// `tools/language-model/verify-chat-template.py` renders 40 message lists with the pinned Jinja template and checks them.
public struct GemmaChatTemplate: Sendable {
    public static let turnStart: Int32 = 105
    public static let turnEnd: Int32 = 106
    public static let bos: Int32 = 2

    private let tokenizer: GemmaTokenizer

    public init(tokenizer: GemmaTokenizer) { self.tokenizer = tokenizer }

    /// The role name the template uses.
    static func role(_ r: String) -> String { r == "assistant" ? "model" : r }

    /// Ids for the messages followed by the generation prompt. Also returns the number of leading ids that the messages before
    /// the last one take (the shareable prefix: the last message is the question or instruction).
    public func ids(_ messages: [ChatMessage]) -> (ids: [Int32], prefixLength: Int) {
        var out: [Int32] = [Self.bos]
        var prefix = out.count
        for (i, m) in messages.enumerated() {
            if i == messages.count - 1 { prefix = out.count }
            let body = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Self.turnStart)
            out += tokenizer.encodeLiteral(Self.role(m.role) + "\n" + body)
            out.append(Self.turnEnd)
            out += tokenizer.encodeLiteral("\n")
        }
        out.append(Self.turnStart)
        out += tokenizer.encodeLiteral("model\n")
        return (out, prefix)
    }
}

/// Turns generated token bytes into text as complete UTF-8 sequences arrive.
public struct StreamingDecoder: Sendable {
    private var pending: [UInt8] = []
    public init() {}

    /// Adds bytes; returns the text that is complete so far (a split multi-byte character waits for its remaining bytes).
    public mutating func append(_ bytes: [UInt8]) -> String {
        pending += bytes
        var cut = pending.count
        // Hold back an incomplete trailing sequence (at most 3 bytes).
        var back = 0
        var i = pending.count - 1
        while i >= 0, back < 4 {
            let b = pending[i]
            if b & 0xC0 == 0x80 { back += 1; i -= 1; continue }
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if need > back + 1 { cut = i }
            break
        }
        let head = Array(pending[0..<cut])
        pending = Array(pending[cut...])
        return String(decoding: head, as: UTF8.self)
    }

    /// The rest, with replacement characters for a broken tail.
    public mutating func finish() -> String {
        defer { pending = [] }
        return String(decoding: pending, as: UTF8.self)
    }
}
