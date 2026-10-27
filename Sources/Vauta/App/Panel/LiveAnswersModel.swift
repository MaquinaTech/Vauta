// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Foundation
import Observation
import SwiftUI

/// The Answers card of the panel: up to three answers (the newest open, the others folded to their question), fed by the detector. A
/// question that is still being answered is only a small spinner in the card's header: it never adds a row, so the card does not
/// change height while the person reads.
/// The model only holds what the card shows; the stored questions belong to the meeting (`detected_questions`).
@MainActor
@Observable
final class LiveAnswersModel {
    /// The most rows the panel keeps; older ones leave the panel (they stay with the meeting).
    static let capacity = 3

    /// Newest first.
    private(set) var rows: [AnswerRow] = []
    /// Questions the detector is answering now (they have no row; the header shows that something is going on).
    private(set) var working: [AnsweringRow] = []
    /// The row shown open. The newest answer opens by itself; a tap or Return opens another.
    private(set) var openID: UUID?
    private(set) var keptIDs: Set<UUID> = []
    private(set) var pause: LiveAnswerPause?
    /// Rows the person stopped or dismissed: whatever the detector still says about them is ignored.
    private(set) var closedIDs: Set<UUID> = []
    /// The row whose text was just copied (for a moment).
    private(set) var copiedID: UUID?
    /// The first-run hint is waiting for an answer.
    var showsHint = false {
        didSet { if !showsHint { hintWasOnScreen = false } }
    }
    /// The hint was on screen (not below the fold of the scrolling part) at some moment of this recording.
    private(set) var hintWasOnScreen = false

    @ObservationIgnored var onKeep: ((AnswerRow, Bool) -> Void)?
    @ObservationIgnored var onDismiss: ((AnswerRow) -> Void)?
    @ObservationIgnored var onStop: ((UUID) -> Void)?
    @ObservationIgnored var onTurnOff: (() -> Void)?
    /// Whether "Protect meeting text from copying" is on (it is by default).
    @ObservationIgnored var copyProtected: () -> Bool = { true }
    @ObservationIgnored private var copiedTask: Task<Void, Never>?
    @ObservationIgnored var onOpenInAsk: ((AnswerRow) -> Void)?
    @ObservationIgnored var onOpenMoment: ((AutoAnswerContent.Cite) -> Void)?
    @ObservationIgnored var onOpenDocument: ((AutoAnswerContent.Cite) -> Void)?
    @ObservationIgnored var onHintAnswered: ((Bool) -> Void)?
    @ObservationIgnored var announce: (String) -> Void = { text in
        var spoken = AttributedString(text)
        spoken.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(spoken).post()
    }

    /// A pause the person cannot learn about anywhere else: the channel warnings already say when the transcript is behind, but nothing
    /// else says that there is no model, or that the Mac is too warm, or that no source is on. Without this, a paused feature looks
    /// the same as one that is working until its first answer.
    private var pauseNeedsCard: Bool {
        guard let pause else { return false }
        return pause != .transcriptBehind
    }

    /// A card exists: an answer, the first-run hint, or a pause that nothing else shows. A row that is still being worked on never
    /// appears alone, because most questions end without an answer and a card that comes and goes is noise.
    private var hasCard: Bool {
        showsHint || !rows.isEmpty || pauseNeedsCard
    }

    /// The pause line, on a card that is there for another reason or alone when nothing else says that the feature is paused.
    var visiblePause: LiveAnswerPause? { hasCard ? pause : nil }

    /// The spinner in the header: only on a card that is there, never alone.
    var isWorking: Bool { hasCard && !working.isEmpty }

    var hasContent: Bool { hasCard }
    var isVisible: Bool { hasContent }

    func apply(_ event: LiveAnswerEvent) {
        switch event {
        case .answering(let row):
            guard !closedIDs.contains(row.id), !working.contains(where: { $0.id == row.id }) else { return }
            working.append(row)
        case .answer(let row):
            guard !closedIDs.contains(row.id) else { return }
            working.removeAll { $0.id == row.id }
            // The row the person opened to read stays open: the new answer opens only when nothing is open, or the open row is the
            // newest one (or the one being replaced), and otherwise waits folded at the top.
            let opensNew = openID == nil || openID == rows.first?.id || openID == row.id
            if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i] = row } else { rows.insert(row, at: 0) }
            if opensNew { openID = row.id }
            trim()
            // Only that an answer is there: what it says could be heard by others through the speakers.
            announce(String(localized: "Answer available", comment: "VoiceOver announcement: a live answer to a question heard in the meeting appeared in the panel; it never reads the answer itself"))
        case .withdrawn(let id):
            working.removeAll { $0.id == id }
            rows.removeAll { $0.id == id }
            if openID == id { openID = newestAnswerID }
        case .paused(let reason):
            pause = reason
        }
    }

    private var newestAnswerID: UUID? {
        rows.first?.id
    }

    private func trim() {
        if rows.count > Self.capacity { rows.removeLast(rows.count - Self.capacity) }
        if let openID, !rows.contains(where: { $0.id == openID }) { self.openID = newestAnswerID }
    }

    func reset() {
        rows = []
        working = []
        openID = nil
        keptIDs = []
        pause = nil
        closedIDs = []
        hintWasOnScreen = false
        copiedID = nil
        copiedTask?.cancel()
    }

    func toggleOpen(_ id: UUID) { openID = openID == id ? nil : id }
    func isOpen(_ id: UUID) -> Bool { openID == id }

    func dismiss(_ id: UUID) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        rows.removeAll { $0.id == id }
        closedIDs.insert(id)
        if openID == id { openID = newestAnswerID }
        keptIDs.remove(id)
        onDismiss?(row)
    }

    /// The spinner in the header: the answers being found stop, the detector cancels them, and whatever it still says about them is
    /// ignored.
    func stopWorking() {
        let stopped = working
        working = []
        for row in stopped {
            closedIDs.insert(row.id)
            onStop?(row.id)
        }
    }

    func isKept(_ id: UUID) -> Bool { keptIDs.contains(id) }

    func toggleKeep(_ id: UUID) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        let now = !keptIDs.contains(id)
        if now { keptIDs.insert(id) } else { keptIDs.remove(id) }
        onKeep?(row, now)
    }

    /// The text to copy for a row, or nil when copy protection is on (the row then says why).
    func copyableText(_ id: UUID) -> String? {
        guard let row = rows.first(where: { $0.id == id }) else { return nil }
        guard !copyProtected() else { return nil }
        copiedID = id
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copiedID = nil
        }
        return Self.plainText(row)
    }

    /// The Copy button: the same text, to the pasteboard.
    func copy(_ id: UUID) {
        guard let text = copyableText(id) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func openInAsk(_ id: UUID) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        onOpenInAsk?(row)
    }

    /// The hint reached the screen: only then can it count as seen.
    func hintAppeared() { if showsHint { hintWasOnScreen = true } }

    /// Whether the recording that ended told the person about the feature: the hint was shown and was on screen (or was answered).
    var hintCountsAsSeen: Bool { hintWasOnScreen }

    func answerHint(accepted: Bool) {
        showsHint = false
        onHintAnswered?(accepted)
    }

    /// "Turn Off" on the first-run hint: the feature goes off at once and the hint counts as seen.
    func turnOffFromHint() {
        showsHint = false
        onHintAnswered?(false)
        onTurnOff?()
    }

    /// The question, the answer and where it was verified, as text to paste.
    static func plainText(_ row: AnswerRow) -> String {
        var parts = [row.question, row.content.answer]
        let sources = row.content.exportSources()
        if !sources.isEmpty { parts.append(sources.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n") + "\n"
    }
}

extension AutoAnswerContent.Cite {
    /// "12:03" for a moment of a meeting (hours only when needed).
    var momentLabel: String { ElapsedTime.stamp(t ?? 0) }
}
