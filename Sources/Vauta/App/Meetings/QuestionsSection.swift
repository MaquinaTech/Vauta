// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The questions Vauta heard in the meeting (live answers): what each became, with its verified answer and where it was verified.
/// Collapsed by default. Only the ones the person keeps are exported and searched.
struct QuestionsSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: MeetingsModel
    let meeting: MeetingStore.Meeting

    var body: some View {
        if !model.detectedQuestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { model.questionsExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Detected questions", comment: "Meeting page: heading of the section that lists the questions Vauta heard in the meeting and what it answered").font(.headline)
                        Text(verbatim: "\(model.detectedQuestions.count)").font(.callout).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(model.questionsExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(model.questionsExpanded ? Text("expanded") : Text("collapsed"))
                Text("Heard during the recording. Only the ones you keep are exported or searched.", comment: "Meeting page, Detected questions: a line under the heading that tells them apart from the minutes’ open questions")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                if model.questionsExpanded {
                    VStack(alignment: .leading, spacing: PaneLayout.item + 4) {
                        ForEach(model.detectedQuestions) { question in
                            QuestionRow(model: model, meeting: meeting, question: question)
                        }
                    }
                    .padding(.top, PaneLayout.item)
                }
            }
        }
    }
}

private struct QuestionRow: View {
    @Bindable var model: MeetingsModel
    let meeting: MeetingStore.Meeting
    let question: DetectedQuestion
    /// "Remove" takes effect after a few seconds, so a mistake can be undone; leaving the page keeps the question.
    @ViewLocalState private var removed = false

    var body: some View {
        if removed { removedRow } else { row }
    }

    private var removedRow: some View {
        HStack(spacing: 10) {
            Text("Removed", comment: "Meeting page, Questions: the question is about to be deleted; the Undo button next to it brings it back").font(.callout).foregroundStyle(.secondary)
            Button("Undo") { removed = false }.buttonStyle(.link).font(.callout)
            Spacer()
        }
        .padding(.leading, SourceBadge.columnWidth + 8)
        .task(id: removed) {
            guard removed else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, removed else { return }
            await model.removeQuestion(question)
        }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "questionmark.bubble").foregroundStyle(.secondary).frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
                ProtectedText(question.text)
                Spacer(minLength: 4)
                TimeButton(t: question.t) { model.open(meeting: meeting.id, at: question.t) }
            }
            if let answer = question.answer {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.secondary).frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
                        .help(LiveAnswersText.canBeWrong)
                    ProtectedText(answer.answer)
                }
                ForEach(Array(answer.labels.enumerated()), id: \.offset) { _, cite in
                    HStack(spacing: 6) {
                        Image(systemName: QuestionsGlyphs.symbol(cite.kind)).font(.caption).frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
                        Text(QuestionsGlyphs.label(cite)).font(.caption).foregroundStyle(.secondary)
                        chips(for: cite, in: answer)
                    }
                }
            }
            HStack(spacing: 10) {
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 0)
                if question.answer != nil {
                    // The state is the button itself (pin and word), so the status line does not say it a second time.
                    Button { Task { await model.setQuestionKept(question, kept: !question.kept) } } label: {
                        Label(question.kept ? "Kept" : "Keep", systemImage: question.kept ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel(question.kept ? Text("Kept: remove from kept questions", comment: "VoiceOver label of the Kept button on a detected question: pressing it stops keeping the question with the meeting") : Text("Keep this answer with the meeting", comment: "VoiceOver label of the Keep button on a detected question: pressing it keeps the question and its answer with the meeting"))
                    .accessibilityAddTraits(question.kept ? .isSelected : [])
                }
                Button("Remove") { removed = true }.buttonStyle(.link).fixedSize()
            }
            .font(.callout)
            .padding(.leading, SourceBadge.columnWidth + 8)
        }
        .accessibilityElement(children: .contain)
    }

    /// What became of the question: shown with the answer, hidden, or never answered; and, apart, that a source it cited was deleted.
    private var status: String {
        var parts: [String] = []
        switch question.outcome {
        case .answered:
            if question.dismissed { parts.append(String(localized: "Dismissed", comment: "Meeting page, Questions: the person dismissed the answer card")) }
            else if !question.kept, !question.shown { parts.append(Self.notShown) }
        case .rateLimited, .stale, .stopped:
            // With an answer written, only the card was missing; without one, nothing was worked out.
            parts.append(question.answer == nil
                         ? String(localized: "Not answered", comment: "Meeting page, Questions: the question was heard but no answer was worked out for it (the card limits were reached, or the recording or live answers stopped first)")
                         : Self.notShown)
        case .noAnswer, .failed, .superseded:
            parts.append(String(localized: "No answer found", comment: "Meeting page, Questions: nothing in the sources answered the question"))
        }
        if question.sourceRemoved {
            parts.append(String(localized: "A source was removed", comment: "Meeting page, Questions: a past meeting or document that one of the answer's citations pointed to was deleted since"))
        }
        return parts.joined(separator: " · ")
    }

    private static let notShown = String(localized: "Not shown", comment: "Meeting page, Questions: the answer was ready but no card was shown for it")

    /// The moments of this meeting or of a past one that the answer cites, and the document passage, each one opens.
    @ViewBuilder private func chips(for cite: AutoAnswerContent.Cite, in answer: AutoAnswerContent) -> some View {
        let same = answer.claims.flatMap(\.cites).filter { $0.labelKey == cite.labelKey }
        switch cite.kind {
        case .thisMeeting, .pastMeeting:
            let target = cite.kind == .thisMeeting ? meeting.id : cite.meetingID
            ForEach(Array(Set(same.compactMap(\.t).map { Int($0) })).sorted().prefix(3), id: \.self) { second in
                if let target {
                    TimeButton(t: Double(second)) { model.open(meeting: target, at: Double(second)) }
                }
            }
        case .document:
            if let citation = cite.documentCitation {
                Button { model.openDocument(citation) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.link)
                    .accessibilityLabel(cite.fileName.flatMap { $0.isEmpty ? nil : Text(verbatim: $0) } ?? Text("Document", comment: "VoiceOver, brief: what a line is; a file or a passage of one"))
                    .accessibilityHint(Text("Opens the document at this passage", comment: "Hint of a citation chip that opens a document"))
            }
        }
    }
}
