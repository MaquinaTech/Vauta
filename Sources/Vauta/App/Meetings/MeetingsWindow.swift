// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The Meetings window: a sidebar with search and four modes (Meetings, Ask,
/// Tasks, People; ⌘1–⌘4, ⌘F to search) and the selected item on the right.
/// Meeting text is selectable and copyable only when copy protection is off.
struct MeetingsWindow: View {
    /// Shared with the locked view, so the window doesn't resize when it unlocks.
    static let minimumSize = CGSize(width: 900, height: 540)

    @Bindable var model: MeetingsModel
    let recorder: RecorderModel
    let preferences: Preferences
    /// The Settings window's state (to open it at Context).
    let settings: SettingsModel
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The window's: speaker edits register with it, so Edit ▸ Undo takes them back.
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            MeetingsSidebar(model: model, onImport: importRecording)
                .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 420)
        } detail: {
            detail
        }
        .searchable(text: $model.query, tokens: $model.tokens, suggestedTokens: $model.suggestedTokens,
                    placement: .sidebar, prompt: Text(searchPrompt)) { token in
            Label(token.label, systemImage: token.symbol)
        }
        .searchFocused($searchFocused)
        .toolbar { toolbar }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .environment(\.copyProtection, preferences.copyProtection)
        .environment(\.openModelsSettings, openModelsSettings)
        .environment(\.openModelGuide, { settings.pane = .models; settings.models.guidePresented = true; openSettings() })
        .focusedSceneValue(\.meetingsModel, model)
        .onChange(of: undoManager.map(ObjectIdentifier.init), initial: true) { model.undoManager = undoManager }
        .task {
            model.isShowing = true
            model.llm = recorder.llm
            model.documentsModel = recorder.documents
            model.preferences = preferences
            model.actions.backend = { "\(recorder.llmStatus.chatProvider)" }
            await model.reload()
            // Like Mail or Notes: open on the latest meeting instead of an empty pane.
            if model.mode == .meetings, model.selectedID == nil, !model.showingUpcoming, let latest = model.visibleMeetings.first {
                model.selectedID = latest.id
            }
            await model.consumePendingFollowUpReview()
        }
        .onChange(of: recorder.llmStatus.activityMeeting) { old, new in
            // A model job on the open meeting finished: reload its minutes.
            if new == nil, old != nil, old == model.selectedID { Task { await model.refreshAfterMinutes() } }
        }
        .onChange(of: recorder.llmStatus.queued) {
            // The queue changed (a job finished, failed or was postponed).
            if model.selectedID != nil { Task { await model.refreshDetail() } }
        }
        .onDisappear { model.purgeVisible() }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { alert in
            switch alert.recovery {
            case .openSettings(let pane):
                Button(pane.openTitle) {
                    settings.pane = pane
                    openSettings()
                }
            case .retry(let action):
                Button("Try Again") { Task { await action() } }
            case nil:
                EmptyView()
            }
            Button(alert.recovery == nil ? "OK" : "Cancel", role: .cancel) {}
        } message: { alert in
            Text(SheetFootnote.keepingLastWordsTogether(alert.message))
        }
        .confirmationDialog(model.pendingDeletion?.title ?? "",
                            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
                            titleVisibility: .visible, presenting: model.pendingDeletion) { deletion in
            Button(deletion.confirmLabel, role: .destructive) { Task { await model.performDeletion(deletion) } }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { deletion in
            Text(SheetFootnote.keepingLastWordsTogether(deletion.message))
        }
        .sheet(isPresented: Binding(get: { model.importer.isPresented }, set: { if !$0 { model.importer.cancel() } })) {
            ImportRecordingSheet(model: model.importer)
        }
        .sheet(isPresented: $model.showingExport) {
            ExportSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.actions.page != nil }, set: { if !$0 { model.actions.dismissedExternally() } })) {
            ActionsSheetHost(actions: model.actions, showInTranscript: { model.showInTranscript($0) })
        }
        .removalDialog(model.actions)
        .sheet(item: $model.passageViewer) { viewer in
            PassageViewer(model: viewer) { model.passageViewer = nil }
        }
        .onChange(of: recorder.documents.map(ObjectIdentifier.init)) { model.documentsModel = recorder.documents }
        .sheet(item: $model.voiceConsent) { request in
            VoiceConsentSheet(name: request.name, remember: { Task { await model.rememberVoice(request) } }, cancel: { model.voiceConsent = nil })
        }
        .sheet(isPresented: $model.reviewingPastVoices) {
            if case .found(let person, let rows)? = model.voiceHistory {
                PastVoiceReviewSheet(person: person, rows: rows,
                                     answer: { row, accept in Task { await model.answerPastVoice(speakerID: row.id, accept: accept) } },
                                     undo: { row in Task { await model.undoPastVoiceAnswer(speakerID: row.id) } },
                                     done: { model.reviewingPastVoices = false })
            }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }

    /// The detail pane with the confirmation over its bottom edge (centred on the pane, not on the window).
    private var detail: some View {
        VStack(spacing: 0) {
            detailContent
            // The notice that stays until dismissed (the exported file) is a real bar under the pane,
            // so the content ends above it and nothing reads through.
            if let notice = model.notice, notice.inBar {
                Divider()
                MeetingsNoticeBanner(notice: notice, dismiss: { model.dismissNotice() }, inBar: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: MeetingsBottomBar.height)
                    .padding(.horizontal, PaneLayout.pane)
                    .background(.bar)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            // The bar after an Add: where it went, Open, Undo. It never takes the focus.
            if let bar = model.actions.undoBar {
                Divider()
                ActionUndoBar(bar: bar, open: { model.actions.openAddedItem(bar) }, undo: { Task { await model.actions.undo(bar) } },
                              dismiss: { model.actions.dismissUndoBar() })
                    .frame(maxWidth: .infinity)
                    .frame(height: MeetingsBottomBar.height)
                    .padding(.horizontal, PaneLayout.pane)
                    .background(.bar)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            // A passing confirmation (Copied) floats over the bottom edge.
            if let notice = model.notice, !notice.inBar {
                MeetingsNoticeBanner(notice: notice, dismiss: { model.dismissNotice() })
                    .padding(.bottom, 20)
                    .padding(.horizontal, 20)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .default, value: model.notice)
        .animation(reduceMotion ? nil : .default, value: model.actions.undoBar)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.mode {
        case .meetings:
            if model.showingUpcoming {
                UpcomingBriefView(model: model, brief: recorder.brief, openSettings: { settings.pane = $0; openSettings() },
                                  openSystemSettings: { Permissions.open(.calendars) })
            } else if let meeting = model.shownMeeting {
                // A fresh view per meeting: the text views' undo history and
                // scroll position never carry over to another meeting.
                MeetingDetailView(model: model, recorder: recorder, meeting: meeting)
                    .id(meeting.id)
            } else if model.searchHasNoResults || model.filterHasNoResults {
                // The sidebar already explains the empty result and offers to clear it; the detail shows only the
                // pane's icon, with no prompt to choose a meeting that isn't there.
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            } else {
                MeetingsEmptyDetail(model: model, hotKeyText: recorder.hotKeyAvailable ? recorder.recordHotKeyText : nil,
                                    onImport: importRecording)
            }
        case .ask: AskView(model: model.ask, meetings: model, recorder: recorder, onOpenSettings: openModelsSettings, onOpenDocuments: openDocumentsSettings)
        case .tasks: TasksModeView(model: model)
        case .people: EntityCardView(model: model, onOpenSettings: openContextSettings, onEdit: editInContext)
        }
    }

    private var searchPrompt: String {
        switch model.mode {
        case .meetings, .ask: String(localized: "Search, or filter by person or project", comment: "Meetings search field prompt")
        case .tasks: String(localized: "Filter tasks", comment: "Search field prompt in Tasks")
        case .people: String(localized: "Filter people, projects and clients", comment: "Search field prompt in People")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Three groups: Import, Ask, and the two output actions (Copy, Export) together.
        ToolbarItem(placement: .primaryAction) {
            Button(action: importRecording) {
                Label("Import Recording…", systemImage: "square.and.arrow.down")
            }
            .help("Transcribe an audio or video recording into a new meeting")
        }
        // In Ask the sidebar's Ask segment is selected already, and with no meetings there is nothing to ask about.
        if model.mode != .ask {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { model.askAboutSelection() } label: {
                    Label("Ask", systemImage: "text.bubble")
                }
                .disabled(model.meetings.isEmpty)
                .help("Ask a question about your meetings")
            }
        }
        if model.mode == .meetings, model.shownMeeting != nil {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { model.openFollowUp() } label: {
                    Label("Follow Up…", systemImage: "checklist.checked")
                }
                .disabled(!model.canOpenFollowUp)
                .help(ActionsRelease.emailDraft ? Text("Add tasks to Reminders, follow-up meetings to Calendar, and write the follow-up email")
                                                 : Text("Add tasks to Reminders and follow-up meetings to Calendar"))
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            // Copy and Export share one glass capsule: no spacer between them.
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Copy as Markdown") { Task { await model.copyMinutes(asMarkdown: true) } }
                    Button("Copy as Plain Text") { Task { await model.copyMinutes(asMarkdown: false) } }
                } label: {
                    Label("Copy Minutes", systemImage: "doc.on.doc")
                }
                .help("Copy the summary, decisions and tasks")
                Button { model.requestExport() } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .help("Save this meeting as Markdown, text, PDF, subtitles or JSON")
            }
        }
        // Delete stands alone at the trailing edge, away from Export.
        if model.mode == .meetings, model.shownMeeting != nil {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { model.confirmDeleteSelected() } label: {
                    Label("Delete Meeting…", systemImage: "trash")
                }
                .disabled(model.isActive)
                .help(model.isActive ? "Stop the recording before deleting this meeting"
                                     : "Delete this meeting, its transcript, notes and tasks for good")
            }
        }
    }

    private func importRecording() {
        Task { await model.importer.chooseFile() }
    }

    private func openModelsSettings() {
        settings.pane = .models
        openSettings()
    }

    private func openDocumentsSettings() {
        settings.pane = .documents
        openSettings()
    }

    private func openContextSettings() {
        settings.pane = .context
        openSettings()
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate()
    }

    /// Opens the person or project in Settings → Context.
    private func editInContext(_ entityID: Int64) {
        settings.pane = .context
        openSettings()
        guard let context = recorder.context else { return }
        Task {
            if !context.hasLoaded { await context.reload() }
            context.show(entityID: entityID)
        }
    }
}

/// Nothing selected in Meetings: what to do next. The sidebar stays quiet, so
/// each situation has one explanation, here.
private struct MeetingsEmptyDetail: View {
    let model: MeetingsModel
    /// The record shortcut as the keyboard layout types it (nil = not available).
    let hotKeyText: String?
    let onImport: () -> Void

    var body: some View {
        if model.meetings.isEmpty {
            EmptyStateView(Text("No Meetings Yet"), symbol: "waveform",
                           message: hotKeyText.map { String(localized: "Press \($0) in a meeting to record it, or import a recording.") }
                               ?? String(localized: "Use the record button in the menu bar during a meeting to record it, or import a recording.")) {
                Button("Import Recording…", action: onImport)
            }
        } else {
            EmptyStateView(Text("Select a Meeting"), symbol: "list.bullet.rectangle",
                           message: String(localized: "Select a meeting in the sidebar to review its minutes, tasks and transcript.")) {
                Button("Ask About Your Meetings") { model.askAboutSelection() }
            }
        }
    }
}
