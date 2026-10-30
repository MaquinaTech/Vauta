// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Ask: the answer, its claims checked against the transcript, and citations
/// that jump to the exact moment.
struct AskView: View {
    @Bindable var model: AskModel
    let meetings: MeetingsModel
    let recorder: RecorderModel
    let onOpenSettings: () -> Void
    /// Goes to Settings → Documents.
    var onOpenDocuments: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    /// Bumped when an answer arrives: the question field takes the keyboard back for a follow-up.
    @ViewLocalState private var focusRequest = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PaneLayout.section) {
                HStack(spacing: 10) {
                    // Vauta's sphere next to the question, quiet (the progress line has its own while it writes the answer).
                    VautaOrb(mode: .muted, diameter: 22, showsOrbit: false, carriesGlyph: false)
                    Text(headerTitle).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                }
                NoCopyField(title: String(localized: "What did we decide about…? Who was handling…?", comment: "Placeholder of the Ask field"),
                            text: $model.question,
                            accessibilityLabel: String(localized: "Question", comment: "Accessibility label of the Ask field"),
                            takesInitialFocus: true, focusRequest: focusRequest) {
                    submit()
                }
                // The question stays as asked while the answer is written: the highlights belong to it.
                .disabled(model.busy)
                if let period = model.offeredTimeScope { timeScopeToggle(period) }
                if let mode = recorder.searchModel.askMode { searchModeLabel(mode) }
                // While it works, the progress and Stop take the row of the scope and the Ask button, so no
                // empty band sits between the question and what is happening.
                if model.busy {
                    progress
                } else {
                    scopeRow
                    // Where to look, once the person added a source: everywhere, only meetings or only documents.
                    if hasDocumentSources && model.scope != .documents { scopePicker }
                }
                if let note = model.indexingNote, hasDocumentSources {
                    Label(note, systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(.secondary)
                }
                if showsExamples && recorder.searchModel.offersDownload { searchModelOffer }
                if showsExamples { examples }
                if showsDocumentsHint { documentsHint }
                if let answer = model.answer { answerView(answer) }
                if model.needsModel {
                    noModelCallout
                } else if let failure = model.failure {
                    failureCallout(failure)
                }
                if let note = model.note {
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                if let coverage = model.coverage, let text = AskModel.coverageText(coverage) {
                    Label(text, systemImage: "text.magnifyingglass").font(.callout).foregroundStyle(.secondary)
                }
                if showsNoPassages { noPassages }
                if !model.passages.isEmpty { passages }
                if !model.documentPassages.isEmpty { documentPassages }
                // Without a model nothing is ever shown as verified: only the passages that match.
                (model.showsStored && model.answer != nil
                    ? Text("This answer was found during the recording; no model was asked again. It stays with the meeting if “Keep detected questions” is on when the recording ends, or if you keep it.", comment: "Ask footer under an answer opened from a card of the recording: it is the stored answer, no model ran, and it stays with the meeting if the setting Keep detected questions is on when the recording ends or when the person keeps it")
                    : recorder.llmStatus.configured && !model.needsModel
                    ? footerWithChecks
                    : Text("Questions aren’t saved."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        // Vauta's colours glow faintly behind the question, as behind a meeting.
        .background(alignment: .top) { PanelGlow(isRecording: false).frame(height: 280).opacity(0.7) }
        .onAppear {
            if model.meetingID == nil { model.meetingID = meetings.selectedID }
            // The first question should not wait for the search model to load.
            recorder.searchModel.preload()
        }
        // VoiceOver: say when the answer or the reason there is none arrives, with the words that are on screen.
        .onChange(of: model.answer?.answer) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        // VoiceOver: the question was sent; the model may take a while.
        .onChange(of: model.busy) { _, busy in
            if busy { AccessibilityNotification.Announcement(progressText).post() } else { focusRequest += 1 }
        }
        .onChange(of: announcement) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }

    /// How Ask finds passages (by meaning, keywords while indexing, keywords): a button to Settings → Models.
    private func searchModeLabel(_ mode: SearchModelModel.AskMode) -> some View {
        let text = SearchModelText.askLabel(mode)
        return Button(action: onOpenSettings) {
            HStack(spacing: 4) {
                Label(text, systemImage: SearchModelText.askSymbol(mode))
                // It opens Settings: a chevron says so without a hover.
                Image(systemName: "chevron.forward").font(.caption2.weight(.semibold)).accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .help(SearchModelText.askHelp(mode))
        .accessibilityLabel(Text(text))
        .accessibilityHint(Text(SearchModelText.askHelp(mode)))
    }

    /// One line, shown until closed: the optional search model exists.
    private var searchModelOffer: some View {
        HStack(spacing: 6) {
            Button(action: onOpenSettings) { Label(SearchModelText.askOffer, systemImage: "sparkle.magnifyingglass") }
                .buttonStyle(.link)
            Spacer(minLength: 0)
            IconButton(label: String(localized: "Dismiss", comment: "Accessibility label of a button that closes a hint"), systemImage: "xmark") {
                recorder.searchModel.offerDismissed = true
            }
        }
        .font(.callout)
    }

    /// What is said for a result with no written answer: the same title and detail as the callout or the note on screen.
    private var announcement: String? {
        if model.needsModel {
            let parts = Self.askUnavailableParts(recorder.llmStatus)
            return [parts.title.droppingFinalStop, parts.detail].compactMap { $0 }.joined(separator: ". ")
        }
        if let failure = model.failure { return "\(Self.failureTitle). \(failure)" }
        if showsNoPassages { return Self.noPassagesTitle }
        return model.note
    }

    private static var failureTitle: String {
        String(localized: "The model couldn’t answer", comment: "Ask: title of the notice when the model failed; the error is its detail")
    }

    private static var noPassagesTitle: String {
        String(localized: "No passages match your question", comment: "Ask: nothing matched the question in the meetings")
    }

    /// Nothing matched and there is no written answer to show instead: say so, and what to try.
    private var showsNoPassages: Bool {
        !model.busy && model.answer == nil && model.passages.isEmpty && model.documentPassages.isEmpty && model.needsModel
    }

    private var noPassages: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.noPassagesTitle).font(.headline).accessibilityAddTraits(.isHeader)
            Text(model.answeredThisMeeting ? "Try other words, or search in all meetings." : "Try other words.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// What Ask is about: the meetings, the documents or both, as the scope says (only once the person added a source).
    private var headerTitle: String { Self.headerTitle(scope: shownScope, hasDocumentSources: hasDocumentSources) }

    /// The scope the card on screen belongs to: the scope of the answer while there is one, else the one chosen now. The title and the
    /// footer say what the answer was checked against, so they must not follow a picker that changed afterwards.
    private var shownScope: KnowledgeScope {
        model.answer != nil || !model.passages.isEmpty || !model.documentPassages.isEmpty ? model.answeredScope : model.scope
    }

    static func headerTitle(scope: KnowledgeScope, hasDocumentSources: Bool) -> String {
        guard hasDocumentSources else { return String(localized: "Ask about your meetings", comment: "Title of the Ask tab") }
        switch scope {
        case .meetings: return String(localized: "Ask about your meetings", comment: "Title of the Ask tab")
        case .documents: return String(localized: "Ask about your documents", comment: "Title of the Ask tab when Ask looks only in the documents the person added")
        case .everywhere: return String(localized: "Ask about your meetings and documents", comment: "Title of the Ask tab when Ask looks in meetings and in the documents the person added")
        }
    }

    private var showsExamples: Bool {
        !model.busy && model.answer == nil && model.note == nil && model.passages.isEmpty && model.documentPassages.isEmpty && !model.needsModel && model.failure == nil
    }

    /// Questions built from the user's own meetings and people, to start from.
    private var examples: some View {
        var questions: [String] = []
        if hasDocumentSources, model.scope == .documents {
            // Only the documents are searched: the examples are about them, not about meetings.
            if let name = model.documents?.snapshot.sources.first?.source.displayName {
                questions.append(String(localized: "What is in “\(name)”?", comment: "Ask example question about the documents; the argument is the name of a folder or file the person added"))
            }
            questions.append(String(localized: "What do my documents say about deadlines?", comment: "Ask example question about the documents"))
            return examplesList(questions)
        }
        if let title = meetings.meetings.first?.displayTitle {
            questions.append(String(localized: "What did we decide in “\(title)”?", comment: "Ask example question; the argument is a meeting title"))
        }
        if let person = meetings.people.first(where: { !$0.isSelf }) {
            questions.append(String(localized: "What does \(person.displayName) have open?", comment: "Ask example question; the argument is a person's name"))
        }
        questions.append(String(localized: "Which questions are still open?", comment: "Ask example question"))
        return examplesList(questions)
    }

    private func examplesList(_ questions: [String]) -> some View {
        VStack(alignment: .leading, spacing: PaneLayout.item) {
            Text("Try asking").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(questions, id: \.self) { question in
                Button(question) {
                    // Asks right away: a click that only filled the field looked like it did nothing.
                    model.question = question
                    submit()
                }
                    .buttonStyle(AskExampleStyle())
            }
        }
    }

    /// One callout: why there is no answer (title, then what to do), and the same set-up buttons as the minutes.
    private var noModelCallout: some View {
        let parts = Self.askUnavailableParts(recorder.llmStatus)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The same icon column as the minutes' notice, so the text starts at the same x in both tabs.
            StatusSymbol.warning.image.frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
            NoticeText(title: parts.title, detail: parts.detail) { ModelSetUpButtons(fallback: onOpenSettings) }
        }
        .font(.callout)
        .noticeCard(tint: .orange)
        .accessibilityElement(children: .contain)
    }

    /// The model failed: what happened and its reason. Asking again is the Ask Question button, so it is not repeated here.
    private func failureCallout(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusSymbol.warning.image.frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
            NoticeText(title: Self.failureTitle, detail: reason) {
                HStack(spacing: 6) {
                    // The server may be the problem: the Models pane is where it is checked.
                    Button(SettingsModel.Pane.models.openTitle, action: onOpenSettings).controlSize(.small)
                }
            }
        }
        .font(.callout)
        .noticeCard(tint: .orange)
        .accessibilityElement(children: .contain)
    }

    /// The Ask reading of "no model": it still shows the matching passages. Other causes keep their own advice.
    static func askUnavailableParts(_ status: LLMService.Status) -> (title: String, detail: String?) {
        if status.issue == nil || status.issue == .serverNotConfigured {
            return (String(localized: "Answers need a model", comment: "Ask: title of the notice when no model is set up"),
                    String(localized: "Without one, Ask shows the passages that match your question.",
                           comment: "Ask: no model is set up; the passages found by local search are shown instead"))
        }
        return unavailableParts(status)
    }

    /// Why no model can answer: the problem, then what to do about it.
    static func unavailableParts(_ status: LLMService.Status) -> (title: String, detail: String?) {
        guard let issue = status.issue else {
            return (String(localized: "Choose a model in Settings\u{00A0}→\u{00A0}Models to get answers.", comment: "Ask: no model available"), nil)
        }
        return (issue.localizedDescription, issue.recoverySuggestion)
    }

    /// Return in the field and the Ask button: "this meeting" is always the
    /// meeting selected now (the sidebar can change while in Ask).
    private func submit() {
        model.meetingID = meetings.selectedID
        if meetings.selectedID == nil { model.thisMeeting = false }
        meetings.noteActivity()
        model.ask()
    }

    /// A long title keeps its start and end, so the scope control never takes the room of the Ask button.
    static func middleTruncated(_ title: String, to limit: Int) -> String {
        guard title.count > limit else { return title }
        let head = (limit - 1) / 2 + (limit - 1) % 2
        let tail = (limit - 1) / 2
        return String(title.prefix(head)).trimmingCharacters(in: .whitespaces) + "…" + String(title.suffix(tail)).trimmingCharacters(in: .whitespaces)
    }

    /// The scope control and the Ask button. A long translation or a long meeting title must not widen the pane (that pushes the whole
    /// window sideways): the row falls back to the button on its own line, then to a menu. The title keeps up to 40 characters while the
    /// segments fit, and the width available decides, not a short fixed count (a localized title of 29 characters must not be cut when there is room).
    private var scopeRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack { scopeChoice(.segmented, titleLimit: 40); Spacer(); askButton }
            VStack(alignment: .leading, spacing: 8) {
                scopeChoice(.segmented, titleLimit: 40)
                HStack { Spacer(); askButton }
            }
            VStack(alignment: .leading, spacing: 8) {
                // A menu has the room: the title keeps up to 48 characters (a whole title in nearly every case).
                scopeChoice(.menu, titleLimit: 48)
                HStack { Spacer(); askButton }
            }
        }
        .frame(minHeight: 22)
    }

    private var askButton: some View {
        Button("Ask Question", action: submit)
            .fixedSize()
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canAsk)
    }

    enum ScopeStyle { case segmented, menu }

    @ViewBuilder private func scopeChoice(_ style: ScopeStyle, titleLimit: Int) -> some View {
        if hasDocumentSources && model.scope == .documents {
            // Only the documents are searched, whatever meeting is selected: no meeting picker, and the scope control
            // takes its place right under the question.
            scopePicker
        } else if meetings.selected != nil {
            let picker = Picker("Search in", selection: $model.thisMeeting) {
                Text("All meetings").tag(false)
                Text(scopeTitle(limit: titleLimit)).tag(true).accessibilityLabel(Text(scopeTitle(limit: .max)))
            }
            .labelsHidden()
            .accessibilityLabel(Text("Search in"))
            switch style {
            case .segmented: picker.pickerStyle(.segmented).fixedSize()
            case .menu: picker.pickerStyle(.menu).fixedSize()
            }
        } else {
            Text("Select a meeting in the sidebar to ask about only that one.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func scopeTitle(limit: Int) -> String {
        guard let selected = meetings.selected else {
            return String(localized: "Only the selected meeting", comment: "Ask scope when no meeting is selected")
        }
        return String(localized: "Only “\(Self.middleTruncated(selected.displayTitle, to: limit))”", comment: "Ask scope: only this meeting")
    }

    private var progressText: String { Self.progressText(status: recorder.llmStatus, progressTokens: model.progressTokens) }

    /// What the progress line says: the stage the integrated model reports for this question (reading a long meeting, checking the
    /// answer), else writing, else the generic wait.
    static func progressText(status: LLMService.Status, progressTokens: Int) -> String {
        if status.activityIsAsk, let stage = MinutesActivity.stageText(status) {
            switch status.stage {
            case .readingTranscript?:
                return String(localized: "Reading the meeting · \((MinutesActivity.fraction(status) ?? 0).formatted(.percent.precision(.fractionLength(0))))",
                              comment: "Ask progress while the integrated model reads a long meeting; the argument is a percentage")
            default:
                return stage
            }
        }
        return progressTokens > 0
            ? String(localized: "Writing the answer…", comment: "Ask progress")
            : String(localized: "The model is reading your meetings. The first question about a meeting takes longer.", comment: "Ask progress")
    }

    private var progress: some View {
        HStack {
            ThinkingOrb().accessibilityHidden(true)
            Text(progressText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Stop") { model.cancel() }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// "Each quote is checked against …" says what the question can be answered from: the transcript, the document, or either.
    private var footerWithChecks: Text {
        guard hasDocumentSources else { return Text("Questions aren’t saved. Each quote is checked against the transcript before it’s shown as verified.") }
        switch shownScope {
        case .meetings: return Text("Questions aren’t saved. Each quote is checked against the transcript before it’s shown as verified.")
        case .documents: return Text("Questions aren’t saved. Each quote is checked against the document before it’s shown as verified.")
        case .everywhere: return Text("Questions aren’t saved. Each quote is checked against the transcript or the document before it’s shown as verified.")
        }
    }

    var hasDocumentSources: Bool { model.documents?.snapshot.hasSources == true }

    /// The person has not added a source yet: Ask says it can answer from documents too.
    private var showsDocumentsHint: Bool {
        model.documents != nil && !hasDocumentSources && !model.busy && model.answer == nil && model.documentPassages.isEmpty
    }

    private var documentsHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.doc").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Ask can also answer from your documents.", comment: "Ask: shown when no document was added yet").foregroundStyle(.secondary)
            Button(SettingsModel.Pane.documents.openTitle, action: onOpenDocuments).controlSize(.small)
        }
        .font(.callout)
    }

    private var scopePicker: some View {
        Picker("Look in", selection: $model.scope) {
            Text("Everywhere", comment: "Ask scope: meetings and documents").tag(KnowledgeScope.everywhere)
            Text("Meetings", comment: "Ask scope: only meetings").tag(KnowledgeScope.meetings)
            Text("Documents", comment: "Ask scope: only documents").tag(KnowledgeScope.documents)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityLabel(Text("Look in", comment: "VoiceOver: the control that chooses where Ask looks"))
    }

    /// The passages of documents that matched: file and place, then the words that matched.
    private var documentPassages: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Passages from your documents", comment: "Ask: header of the passages found in the person's documents").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(model.documentPassages) { passage in
                let citation = DocumentCitation(passage)
                VStack(alignment: .leading, spacing: 4) {
                    Button { meetings.openDocument(citation) } label: {
                        Label { Text(verbatim: citation.label) } icon: { Image(systemName: citation.format.symbol) }
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .accessibilityLabel(Text(verbatim: citation.spokenLabel))
                    ProtectedText(Text(documentText(passage)).font(.callout))
                        .lineLimit(3)
                }
            }
        }
    }

    private func documentText(_ passage: DocumentPassage) -> AttributedString {
        let body = VautaPrompts.body(of: passage)
        var out = AttributedString(body)
        for range in MeetingStore.matchedRanges(of: model.answeredQuestion, in: body) {
            if let lower = AttributedString.Index(range.lowerBound, within: out), let upper = AttributedString.Index(range.upperBound, within: out) {
                out.markMatch(lower..<upper, dark: colorScheme == .dark)
            }
        }
        return out
    }

    private var passages: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.answer == nil ? "Matching passages" : "Passages consulted").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(model.passages) { p in
                VStack(alignment: .leading, spacing: 4) {
                    // The same "title · time" as the citations above; the date follows as secondary text.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button("\(p.meeting.displayTitle) · \(ElapsedTime.stamp(p.segments.first?.start ?? p.start))") {
                            if let first = p.segments.first { model.open(citation: first.id) }
                        }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        Text(p.meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(p.segments.prefix(3)), id: \.id) { segment in
                        ProtectedText(Text(line(of: segment)).font(.callout))
                            .font(.callout)
                            .lineLimit(2)
                            .accessibilityValue(Text(verbatim: segment.speaker?.isLowConfidence == true ? String(localized: "Not sure who said this", comment: "Tooltip and VoiceOver: the app is not sure which speaker said this transcript line") : ""))
                    }
                }
            }
        }
    }

    /// "Ana: text" with the speaker in bold and its color, as in the transcript.
    private func line(of segment: CitableSegment) -> AttributedString {
        let who = segment.channel.quotePrefix(for: segment.speaker, tint: segment.channel.tint(ordinal: segment.speaker?.ordinal ?? 1))
        // The words the search matched (whole words, no function words) are marked like the sidebar search.
        var body = AttributedString(segment.text)
        for range in MeetingStore.matchedRanges(of: model.answeredQuestion, in: segment.text) {
            if let lower = AttributedString.Index(range.lowerBound, within: body), let upper = AttributedString.Index(range.upperBound, within: body) {
                body.markMatch(lower..<upper, dark: colorScheme == .dark)
            }
        }
        return who + body
    }
}

/// An example question: a capsule with a hairline edge in Vauta's colours and a sparkle, like a suggestion from Vauta.
private struct AskExampleStyle: ButtonStyle {
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(Brand.sparkle).accessibilityHidden(true)
            configuration.label
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.quinary, in: Capsule())
        .overlay {
            Capsule().strokeBorder(contrast == .increased
                                   ? AnyShapeStyle(Color.primary.opacity(0.5))
                                   : AnyShapeStyle(LinearGradient(colors: [Brand.indigo, Brand.teal], startPoint: .leading, endPoint: .trailing).opacity(0.55)),
                                   lineWidth: 1)
        }
        .opacity(configuration.isPressed ? 0.7 : 1)
        .contentShape(Capsule())
    }
}
