// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Settings → Models: who writes minutes and answers Ask, and how.
struct ModelsPane: View {
    @Bindable var recorder: RecorderModel
    @Bindable var preferences: Preferences
    @Bindable var models: ModelsSettingsModel
    /// The text column of the form's rows in the pane's coordinates (it widens with the window), so the Save bar
    /// ends on the same edges at every width. Nil until measured.
    @ViewLocalState private var rowColumn: CGRect?
    @ViewLocalState private var barWidth: CGFloat = 0

    var body: some View {
        Form {
            providerSection
            if recorder.integratedModel.showsCard(provider: models.provider) {
                IntegratedModelSection(model: recorder.integratedModel, models: models, recorder: recorder)
            }
            if recorder.searchModel.showsCard(choice: models.embeddings) {
                SearchModelSection(model: recorder.searchModel, models: models, recorder: recorder)
            }
            if models.usesServer {
                ServerSections(recorder: recorder, models: models)
            }
            MinutesSection(recorder: recorder, preferences: preferences)
            ActivitySection(recorder: recorder, usesServer: models.usesServer, provider: models.provider,
                            appleAvailable: models.appleAvailable)
        }
        .formStyle(.grouped)
        .coordinateSpace(name: Self.paneSpace)
        // The first field must not open with its text selected: a stray keystroke would replace the saved address.
        .background(ClearInitialFocus())
        .safeAreaInset(edge: .bottom, spacing: 0) { applyBar }
        .sheet(isPresented: $models.guidePresented) {
            ModelGuideSheet(recorder: recorder, settings: models, guide: ModelGuideModel(physicalMemory: models.physicalMemory),
                            close: { models.guidePresented = false },
                            useNetworkServer: { models.guidePresented = false; models.provider = .networkServer })
        }
        .onAppear { models.loadIfNeeded(recorder) }
        // Installing or deleting the search model changes the saved choice behind the pane's back: take it.
        .onChange(of: recorder.searchModel.status.isReady) { models.adoptSavedEmbeddings(recorder) }
        // Downloading, importing or "Use for Minutes" on the integrated model saves the chat choice behind the pane's back too.
        .onChange(of: recorder.integratedModel.chatChoiceRevision) { models.adoptSavedChat(recorder) }
        .onChange(of: recorder.serverConfigUnavailable) { _, locked in
            // The Keychain opened: show the configuration it was hiding.
            if !locked { models.revert(recorder) }
        }
    }

    /// The quality hint that guides the choice, said as in setup: Apple's quick start, and the same neutral badge on both
    /// model servers (they give the same better minutes), whatever the memory of this Mac.
    private var providerBadges: [ModelProviderChoice: (text: String, style: BadgeCapsule.Style)] {
        let better = String(localized: "Better minutes", comment: "Badge of the model server on this Mac option")
        // The integrated model is a 15 GB download: a neutral badge that says so, never "Better minutes" or "Recommended".
        var badges: [ModelProviderChoice: (text: String, style: BadgeCapsule.Style)] =
            [.onDevice: (ModelQuality.badge, .neutral), .localServer: (better, .neutral), .networkServer: (better, .neutral)]
        // Once the model is installed there is nothing left to download: the badge goes with it.
        if recorder.integratedModel.status.state != .ready { badges[.integrated] = (IntegratedModelText.badge, .neutral) }
        // On a Mac that cannot run Apple Intelligence the option stays in the list (the saved choice may be it) but is never offered as the quick start.
        if !models.appleAvailable {
            badges[.onDevice] = (String(localized: "Not available on this Mac", comment: "Badge of the Apple Intelligence option in Settings → Models when this Mac cannot run Apple Intelligence"), .neutral)
        }
        return badges
    }

    private static let paneSpace = "modelsPane"

    private var providerSection: some View {
        Section {
            RadioGroupRow(title: String(localized: "Write minutes with", comment: "Settings → Models provider picker"), selection: $models.provider,
                          options: [(.onDevice, String(localized: "Apple Intelligence on this Mac"))]
                              + (recorder.integratedModel.isOffered || models.provider == .integrated ? [(.integrated, IntegratedModelText.optionTitle)] : [])
                              + [(.localServer, String(localized: "A model server on this Mac")),
                                 (.networkServer, String(localized: "A model server on your network"))],
                          badges: providerBadges)
            // Said next to the options it is about, not after the search picker.
            if let reason = recorder.integratedModel.unsupportedReason {
                NoticeLabel(Text(description: IntegratedModelText.unsupportedNote(reason)), status: .info, iconWidth: 16)
            }
            switch models.provider {
            case .onDevice:
                let availability = models.appleModel.availability
                // What the Apple option means is the status row's own second line, in the status text column.
                NoticeLabel(Text(availability.explanation), status: availability == .available ? .ok : .warning, iconWidth: 16,
                            note: Text(description: String(localized: "No setup needed. Runs entirely on this Mac. It reads only a short part of a meeting at a time, so long meetings are summarized in parts, and minutes are shorter and less reliable than with a large model.",
                                                           comment: "Settings → Models on-device explanation")))
                if let action = availability.action, case .systemSettings(let pane) = action {
                    Button("Open System Settings") { Permissions.open(pane) }
                }
                LocalModelCard(physicalMemory: models.physicalMemory, metrics: .settings, reasonFont: .subheadline) { models.guidePresented = true }
            case .integrated:
                let ready = recorder.integratedModel.status.state == .ready
                // Without Apple Intelligence to stand in, "Vauta can’t write minutes" is a warning, not information.
                NoticeLabel(Text(description: IntegratedModelText.optionExplanation(appleAvailable: models.appleAvailable, installed: ready)),
                            status: ready || models.appleAvailable ? .info : .warning, iconWidth: 16)
                // Chosen but not ready: who writes the minutes meanwhile is said here, where the choice is, not only in the apply bar.
                if models.savedSettings.chat == .integrated, !ready, models.appleAvailable, recorder.integratedModel.unsupportedReason == nil {
                    NoticeLabel(Text(description: IntegratedModelText.activityFallback(appleAvailable: true)), status: .info, iconWidth: 16)
                }
            case .localServer, .networkServer:
                EmptyView()
            }
            embeddingsRow
        } header: {
            Text("Provider")
        } footer: {
            // The explanation of the chosen option sits under the card, like every section's explanation.
            VStack(alignment: .leading, spacing: 6) {
            switch models.provider {
            case .onDevice, .integrated:
                EmptyView()
            case .localServer:
                SettingsNote(String(localized: "A model server is an app such as LM Studio or Ollama that runs larger models. A server on this Mac keeps meeting text on this Mac.",
                                    comment: "Settings → Models local server explanation"))
            case .networkServer:
                SettingsNote(String(localized: "Vauta uses a model server on another computer on your local network, over HTTPS only. It never sends meetings to the internet.",
                                    comment: "Settings → Models network server explanation"))
            }
            }
        }
    }

    /// "Ask finds passages with": the label and the closed picker on one line when they fit; when the window is
    /// narrow or the language long, the picker goes under the label at full width instead of cutting its value.
    private var embeddingsRow: some View {
        let title = String(localized: "Ask finds passages with", comment: "Settings → Models embeddings picker; the options say how: keyword search, a server model or this Mac")
        let picker = Picker(title, selection: $models.embeddings) {
            ForEach(models.provider.embeddingOptions, id: \.self) { option in
                Text(option.displayName).tag(option)
            }
        }
        .labelsHidden()
        return ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).lineLimit(1).fixedSize()
                Spacer(minLength: 12)
                picker.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                picker.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.paneSpace)) } action: { rowColumn = $0 }
    }

    /// The commit bar: a footer with its own edge and an opaque background, so the form scrolls behind it without showing through.
    private var applyBar: some View {
        let dirty = models.hasChanges(recorder)
        let locked = models.usesServer && models.serverLocked(recorder)
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let feedback = models.applyBarFeedback {
                    FeedbackLabel(feedback: feedback).lineLimit(3)
                } else if dirty {
                    Text("You have unsaved changes.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if models.applying { ProgressView().controlSize(.small).accessibilityLabel(String(localized: "Saving…", comment: "Accessibility label of the spinner while the model settings are saved")) }
                Button("Revert") { models.revert(recorder) }
                    .disabled(!dirty || models.applying)
                Button("Save") { Task { await models.apply(recorder) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dirty || locked || models.applying)
            }
            // The text column of the form's cards (measured from a row), so the bar lines up with the rows above.
            .padding(.leading, rowColumn?.minX ?? 51)
            .padding(.trailing, rowColumn.map { max(0, barWidth - $0.maxX) } ?? 51)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
    }
}

/// Language and template of the minutes, and catching up on missing ones.
private struct MinutesSection: View {
    let recorder: RecorderModel
    @Bindable var preferences: Preferences

    /// A model can write them now, or the on-device model will once it is
    /// ready (downloading, or Apple Intelligence turned off for now).
    private var canQueueMinutes: Bool {
        let s = recorder.llmStatus
        return s.configured || (s.chatProvider == .onDevice && s.issue != .onDeviceModel(.deviceNotEligible))
    }

    private var canWriteMinutes: Bool { recorder.llm != nil && canQueueMinutes }

    /// Why the button is disabled, in place of its usual explanation.
    private var disabledReason: String {
        if recorder.llmStatus.issue == .onDeviceModel(.deviceNotEligible) {
            return String(localized: "Apple Intelligence isn’t available on this Mac.", comment: "Settings → Models; why Write Missing Minutes is disabled")
        }
        // A model is set up but the meetings aren't open yet (locked, or still opening): the service doesn't exist until then.
        if recorder.llm == nil && canQueueMinutes {
            return String(localized: "Unlock Meetings to write the missing minutes.", comment: "Settings → Models; why Write Missing Minutes is disabled while Meetings are locked")
        }
        return String(localized: "Choose a model first.", comment: "Settings → Models; why Write Missing Minutes is disabled")
    }

    var body: some View {
        Section {
            Picker(selection: $preferences.outputLanguage) {
                Text("Same as the meeting").tag(Preferences.OutputLanguage.sameAsMeeting)
                Divider()
                ForEach(OutputLanguageOptions.identifiers(including: currentFixed), id: \.self) { id in
                    Text(OutputLanguageOptions.displayName(id).standaloneCapitalized).tag(Preferences.OutputLanguage.fixed(id))
                }
            } label: {
                Text("Minutes language", comment: "Settings → Models; the language the minutes are written in")
                Text(description: String(localized: "The language minutes are written in. Ask always answers in the language of your question.", comment: "Settings → Models note under the minutes language"))
            }
            Picker(selection: $preferences.minutesTemplate) {
                ForEach(MinutesTemplate.allCases) { template in
                    Text(template.displayName).tag(template)
                }
            } label: {
                Text("Default template", comment: "Settings → Models minutes template")
                Text(description: String(localized: "The template decides the sections of the minutes. It applies to minutes written from now on.", comment: "Settings → Models"))
            }
            LabeledContent {
                // The on-device model may still be downloading or be turned
                // off for now: the queue waits for it (not on a Mac that can't run it).
                Button("Write Missing Minutes") { Task { await recorder.generatePendingMinutes() } }
                    .disabled(!canWriteMinutes)
            } label: {
                Text("Meetings without minutes")
                Text(description: canWriteMinutes ? String(localized: "Queues minutes for every meeting that doesn’t have them yet.", comment: "Settings → Models")
                                                  : disabledReason)
            }
        } header: {
            Text("Minutes")
        }
    }

    private var currentFixed: [String] {
        if case .fixed(let id) = preferences.outputLanguage { return [id] }
        return []
    }
}

/// What the model service is doing (no meeting content).
private struct ActivitySection: View {
    let recorder: RecorderModel
    /// With a model server the note names its fast and main models; Apple Intelligence has no such roles to name.
    let usesServer: Bool
    let provider: ModelProviderChoice
    /// Apple Intelligence can write minutes while the integrated model is not ready.
    let appleAvailable: Bool

    var body: some View {
        let s = recorder.llmStatus
        Section {
            if let issue = s.issue {
                IssueLabel(title: String(localized: "Minutes and Ask", comment: "Settings → Models activity"), issue: issue)
            }
            if let issue = s.searchIssue {
                IssueLabel(title: String(localized: "Search by meaning", comment: "Settings → Models activity"), issue: issue)
            }
            LabeledContent(String(localized: "Now", comment: "Settings → Models activity"),
                           value: s.activity ?? (s.readingMeeting ? String(localized: "Reading the meeting as it goes", comment: "Settings → Models activity; the integrated model reads the meeting while it is recorded")
                                                                  : String(localized: "Idle", comment: "Settings → Models activity")))
            LabeledContent(String(localized: "Waiting", comment: "Settings → Models activity"),
                           value: s.queued == 0 ? String(localized: "None", comment: "Number of queued model jobs when there are none")
                                                : String(localized: "\(s.queued) jobs", comment: "Number of queued model jobs"))
            if let cached = s.lastCacheHit {
                LabeledContent(String(localized: "Reused from the server cache", comment: "Settings → Models activity"),
                               value: String(localized: "\(cached) tokens", comment: "Token count"))
            }
            if let fallback = s.integratedFallback {
                // The model that is still downloading is the expected state after opting in: an info glyph, not a warning.
                IssueLabel(title: String(localized: "Minutes and Ask", comment: "Settings → Models activity"), text: IntegratedModelText.activityFallback(appleAvailable: appleAvailable),
                           symbol: fallback == .notReady ? .info : .warning)
            }
            if provider == .integrated {
                // The meeting is read as it goes only when the integrated model is the one that will write the minutes.
                if recorder.integratedModel.status.state == .ready, s.integratedFallback == nil {
                    SettingsNote(IntegratedModelText.activityWhileRecording(liveOnApple: recorder.integratedModel.liveTasks == .apple && appleAvailable))
                }
            } else if usesServer {
                SettingsNote(String(localized: "While recording, only the fast model runs (live notes). Minutes are written with the main model when the meeting ends; on a modest Mac that can take from a few minutes to more than half an hour per hour of meeting.",
                                    comment: "Settings → Models activity"))
            } else {
                SettingsNote(String(localized: "While recording, Apple Intelligence writes live notes. Minutes are written when the meeting ends.",
                                    comment: "Settings → Models activity, with Apple Intelligence as the provider"))
            }
        } header: {
            Text("Activity", comment: "Settings → Models: section showing what the model is doing now and how many jobs wait")
        }
    }
}

/// Why a model provider can't be used right now, and what to do about it.
private struct IssueLabel: View {
    let title: String
    var issue: ProviderIssue?
    /// A plain note instead of an issue (the integrated model is not ready and Apple's stands in).
    var text: String?
    var symbol: StatusSymbol = .warning

    init(title: String, issue: ProviderIssue) {
        self.title = title
        self.issue = issue
    }

    init(title: String, text: String, symbol: StatusSymbol = .warning) {
        self.title = title
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(text ?? issue?.localizedDescription ?? "")", comment: "A problem: what it affects, then the error")
                if let suggestion = issue?.recoverySuggestion {
                    Text(suggestion).font(.callout).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            symbol.image
        }
        .labelStyle(AlignedIconLabelStyle(width: 20))
    }
}

extension ModelProviderSettings.Embeddings {
    var displayName: String {
        switch self {
        case .server: String(localized: "Search by meaning (model server)", comment: "Embeddings option: the model server’s embedding model builds the search index")
        case .onDeviceModel: String(localized: "Search by meaning on this Mac", comment: "Embeddings option: the downloaded search model (EmbeddingGemma 2) builds the search index on this Mac")
        case .none: String(localized: "Keyword search", comment: "Embeddings option")
        }
    }
}
