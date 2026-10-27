// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The parts of the live notes that can be switched on or off, so the evaluation can take the notes of the same meeting with the request and
/// the checks as they shipped and with the harness of this phase (`llm-eval --live old|new`). Every part is deterministic: no model call is
/// added, and a reply that cannot be read is repaired in Swift, never asked for again.
public struct LiveHarness: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The instruction shows empty shapes (no "…" and no "Me | name | null" to copy) and says what a decision and a task are.
    public static let shape = LiveHarness(rawValue: 1)
    /// A note whose text is its cited line copied (over 0.8 of the words, and over 40 characters), or has no word in it, is dropped.
    public static let copies = LiveHarness(rawValue: 2)
    /// A note that repeats an earlier note of the meeting (same words; or most of the same words and within 5 segments) is dropped.
    public static let repeats = LiveHarness(rawValue: 4)
    /// "Me" stays as a task's owner only when the cited line is the user's own; the placeholder "Me | name | null" is no owner.
    public static let owners = LiveHarness(rawValue: 8)
    /// A reply that is not JSON is put right in Swift (segment tags, a cut at the limit closed at its last finished note) before the call fails;
    /// a cut reply is read as it is instead of asked for again.
    public static let repair = LiveHarness(rawValue: 16)

    /// Every part. The small window (Apple) runs all of it; the integrated model runs `checks` only (see `shipped(integrated:)`).
    public static let shipped: LiveHarness = [.shape, .copies, .repeats, .owners, .repair]
    /// The checks and the repair, with the request left as it was.
    public static let checks: LiveHarness = [.copies, .repeats, .owners, .repair]

    /// What `--live new` runs for a backend. The empty shapes and the "never copy a line" rule change what Apple's model writes (it stops copying
    /// lines into decisions and tasks); on the integrated model, which does not copy, the same rule halved the points and left almost no decisions or
    /// tasks on the development meetings, so it keeps its request and gets the checks. In the app, Apple's model runs the whole set and the integrated
    /// model its request as it was: see `LiveHarnessRelease`.
    public static func shipped(integrated: Bool) -> LiveHarness { integrated ? .checks : .shipped }
    /// The live notes as they shipped before this item.
    public static let legacy: LiveHarness = []

    /// "old" / "legacy", "new" / "shipped" (every part; `llm-eval` reads "new" as `shipped(integrated:)` instead), "checks", or a comma list of `shape`, `copies`, `repeats`, `owners`, `repair`.
    public static func parse(_ text: String) -> LiveHarness? {
        switch text.lowercased() {
        case "old", "legacy", "none": return .legacy
        case "new", "shipped", "all": return .shipped
        default:
            var out: LiveHarness = []
            for word in text.lowercased().split(separator: ",") {
                switch word {
                case "new", "shipped": out.formUnion(.shipped)
                case "old", "legacy": break
                case "checks": out.formUnion(.checks)
                case "shape": out.insert(.shape)
                case "copies": out.insert(.copies)
                case "repeats": out.insert(.repeats)
                case "owners": out.insert(.owners)
                case "repair": out.insert(.repair)
                default: return nil
                }
            }
            return out
        }
    }

    /// For the traces.
    public var names: String {
        let parts = [contains(.shape) ? "shape" : nil, contains(.copies) ? "copies" : nil, contains(.repeats) ? "repeats" : nil,
                     contains(.owners) ? "owners" : nil, contains(.repair) ? "repair" : nil].compactMap { $0 }
        return parts.isEmpty ? "legacy" : parts.joined(separator: "+")
    }
}

/// Which live-notes harness the app runs, by backend. The blind comparison on the sealed test meetings: Apple's model runs it (every
/// unit preferred it); the integrated model showed no difference and keeps the live notes it had.
public enum LiveHarnessRelease {
    public static func harness(integrated: Bool) -> LiveHarness { integrated ? .legacy : .shipped(integrated: false) }
}

extension LLMService {
    func liveHarness(for chat: ChatProvider) -> LiveHarness { liveHarnessOverride ?? (chat.releasedHarness ? LiveHarnessRelease.harness(integrated: chat.integrated) : .legacy) }

    /// Evaluation only: forces the live-notes harness (`nil` = the release choice).
    func setLiveHarness(_ harness: LiveHarness?) { liveHarnessOverride = harness }
}

/// What the checks of a live tick know: the text of the segments, which of them are the user's, and the notes of the earlier ticks.
public struct LiveCheck: Sendable {
    public enum Kind: Sendable { case point, decision, task }
    public struct Earlier: Sendable {
        public var kind: Kind
        public var text: String
        public var segment: Int64?
        public init(kind: Kind, text: String, segment: Int64?) { self.kind = kind; self.text = text; self.segment = segment }
    }

    public var harness: LiveHarness
    public var lines: [Int64: String]
    public var mine: Set<Int64>
    public var earlier: [Earlier]

    public init(harness: LiveHarness, lines: [Int64: String] = [:], mine: Set<Int64> = [], earlier: [Earlier] = []) {
        self.harness = harness
        self.lines = lines
        self.mine = mine
        self.earlier = earlier
    }

    /// Share of the words two texts have in common (twice the shared over the sum), on words of 4 letters or more, numbers, and pairs of
    /// characters of the languages without spaces.
    static let copyShare = 0.8
    static let copyCharacters = 40
    static let repeatShare = 0.7
    static let repeatSegments: Int64 = 5

    static func key(_ text: String) -> Set<String> {
        Set(OpenQuestionChecks.words(text).filter { w in
            w.count >= 4 || w.contains(where: \.isNumber) || w.unicodeScalars.contains { $0.value >= 0x3040 }
        })
    }

    static func dice(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return 2 * Double(a.intersection(b).count) / Double(a.count + b.count)
    }

    /// A text with no letter or number in it ("…", "-") says nothing.
    static func isEmpty(_ text: String) -> Bool { !text.contains { $0.isLetter || $0.isNumber } }

    func copiesItsLine(_ text: String, segment: Int64) -> Bool {
        guard harness.contains(.copies), text.count > Self.copyCharacters, let line = lines[segment] else { return false }
        return Self.dice(Self.key(text), Self.key(line)) > Self.copyShare
    }

    func repeatsEarlier(_ text: String, kind: Kind, segment: Int64, kept: [Earlier]) -> Bool {
        guard harness.contains(.repeats) else { return false }
        let norm = TextKeys.norm(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let k = Self.key(text)
        for other in earlier + kept where other.kind == kind {
            if TextKeys.norm(other.text).trimmingCharacters(in: .whitespacesAndNewlines) == norm { return true }
            guard let at = other.segment, abs(at - segment) <= Self.repeatSegments else { continue }
            if Self.dice(k, Self.key(other.text)) >= Self.repeatShare { return true }
        }
        return false
    }

    /// The owner the model wrote, kept as the checks allow: "Me" only on the user's own line; a placeholder is no owner.
    func owner(_ proposed: String?, segment: Int64) -> String? {
        guard let proposed else { return nil }
        guard harness.contains(.owners) else { return proposed }
        if proposed.contains("|") { return nil }
        if proposed.lowercased() == "me", !mine.contains(segment) { return nil }
        return proposed
    }
}
