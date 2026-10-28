// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// Page 5: who writes the minutes. Two clear choices: Apple's model now, or a guided model server.
struct ModelsPage: View {
    let recorder: RecorderModel
    @Bindable var model: OnboardingModel

    private var enoughMemory: Bool { ModelRecommendation(physicalMemory: model.models.physicalMemory).hasRecommendation }

    private var provider: ModelProviderSettings.Chat { model.chatProvider(hasServerConfig: recorder.serverConfig != nil) }

    /// What is chosen now: the choice made on this page, or else what Vauta would use if the user just continued.
    private var serverChosen: Bool {
        switch model.modelSetup {
        case .server?: true
        case .onDevice?: false
        case nil: provider == .server
        }
    }

    private var appleSelected: Bool {
        switch model.modelSetup {
        case .onDevice?: true
        case .server?: false
        case nil: provider == .onDevice && model.appleAvailability == .available
        }
    }

    /// The warning about a server is shown under its own row while the list is shown.
    private func messageBelongsToRow(_ found: [DiscoveredServer]?) -> Bool {
        guard !serverChosen, let url = model.messageServer else { return false }
        return found?.contains { $0.baseURL == url } == true
    }

    var body: some View {
        VStack(spacing: OnboardingMetrics.cardSpacing) {
            OnboardingHeader(symbol: "doc.text",
                             title: String(localized: "Minutes", comment: "Setup page title"),
                             subtitle: String(localized: "Choose the model that writes minutes and answers your questions. Transcription works either way.",
                                              comment: "Setup page subtitle"))
            // One rhythm for every card (and the message between them), the same as on the other pages.
            VStack(spacing: OnboardingMetrics.cardSpacing) {
                quickStartChoice
                localModelChoice
                if let message = model.modelMessage, !messageBelongsToRow(model.discovered) {
                    SetupStatusLabel(text: message, onBulletGrid: false)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !serverChosen { findServersCard }
            }
        }
        .onDisappear { model.guidePresented = false }
        // Apple Intelligence can be turned on in System Settings while this page is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAppleAvailability()
        }
        .task {
            // Apple Intelligence may still be downloading: look again until it is ready.
            while !Task.isCancelled, model.appleAvailability == .modelNotReady || model.appleAvailability == .appleIntelligenceNotEnabled {
                try? await Task.sleep(for: .seconds(3))
                model.refreshAppleAvailability()
            }
        }
    }

    @ViewBuilder
    private var quickStartChoice: some View {
        let availability = model.appleAvailability
        if availability == .available {
            ChoiceCard(symbol: "apple.intelligence", title: String(localized: "Apple Intelligence on this Mac", comment: "Setup model choice title"),
                       badge: .neutral(ModelQuality.badge),
                       details: [String(localized: "No setup and private, but minutes are shorter and less reliable.",
                                        comment: "Setup model choice detail")],
                       selected: appleSelected, hasAction: !appleSelected) {
                if !appleSelected {
                    // The short label always fits on the title line; VoiceOver gets the full name.
                    Button("Use") { Task { await model.useOnDevice(recorder) } }
                        .accessibilityLabel(Text("Use Apple Intelligence"))
                }
            }
            integratedLine(IntegratedModelText.onboardingLine)
        } else {
            AppleUnavailableRow(availability: availability, enoughMemory: enoughMemory)
            // Where Apple Intelligence is off or unsupported the integrated model helps most; nothing came before it, so no "also".
            integratedLine(IntegratedModelText.onboardingLineWithoutApple)
        }
    }

    /// On a Mac with 16 GB or more: one secondary line about the optional integrated model (no card: it stays opt-in).
    @ViewBuilder private func integratedLine(_ line: String) -> some View {
        if recorder.integratedModel.isOffered, model.models.physicalMemory >= LanguageModelGate.minimumMemory {
            Text(description: line)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, OnboardingMetrics.choicePadding)
        }
    }

    /// The chosen server runs on this Mac: the guide and the found servers always do; a saved one by its mode.
    private var serverIsOnThisMac: Bool {
        if case .server? = model.modelSetup { return true }
        return recorder.serverConfig?.mode != .remote
    }

    /// Nouns, not actions: the verb is on the button.
    private var localModelTitle: String {
        // Once a server is chosen the card names what was chosen (where it runs), not the guided offer.
        if serverChosen {
            return serverIsOnThisMac
                ? String(localized: "A model server on this Mac", comment: "Setup model choice title once a server running on this Mac is chosen")
                : String(localized: "A model server on your network", comment: "Setup model choice title: a server on another computer; also the name of this option in Settings → Models")
        }
        // A Mac with little memory is offered a server on the network, under the name Settings → Models gives the option.
        if !enoughMemory { return String(localized: "A model server on your network", comment: "Setup model choice title: a server on another computer; also the name of this option in Settings → Models") }
        // The card keeps its name once chosen: the check and "Minutes will use…" say that it is.
        return String(localized: "A new model server on this Mac", comment: "Setup model choice title: the guided set-up of a new model server, as opposed to the card that looks for one already running")
    }

    private var localModelDetails: [String] {
        if serverChosen {
            let summary = model.serverSummary ?? recorder.serverConfig?.deepModel ?? ""
            return [String(localized: "Minutes will use \(summary).",
                           comment: "Setup model step after a server was chosen; the argument is the model and app that write minutes, like “Qwen3.5-9B in LM Studio”")]
        }
        if enoughMemory {
            return [ModelQuality.recommendationReason]
        }
        return [ModelQuality.serverRecommendationReason]
    }

    private var localModelChoice: some View {
        // A model on this Mac, or a server on another computer: the icon says which.
        ChoiceCard(symbol: enoughMemory ? ModelGuideSheet.localModelSymbol : ModelGuideSheet.serverSymbol,
                   title: localModelTitle,
                   // "Better" compares with Apple's model: with no Apple option above, the badge would compare with nothing.
                   badge: enoughMemory && !serverChosen && model.appleAvailability == .available
                       ? .neutral(String(localized: "Better minutes", comment: "Badge of the model server on this Mac option")) : nil,
                   details: localModelDetails,
                   selected: serverChosen) {
            let label = serverChosen ? String(localized: "Change…", comment: "Button that opens the model server guide again")
                : enoughMemory ? String(localized: "Set Up…", comment: "Button that opens the model server guide")
                : String(localized: "See Options…", comment: "Button that opens the model guide on a Mac with little memory")
            // "Continue" is the one default button of the page: this one is a regular button, and the badge says it is the advice.
            Button(label) { model.guidePresented = true }
        }
        .localModelGuide(recorder: recorder, model: model)
    }

    /// People who already run a server can still let Vauta look for it; what it finds is listed in the same card.
    private var findServersCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The same structure and insets as the cards above: icon column, title with the button on its line, description.
            HStack(alignment: .top, spacing: OnboardingMetrics.choiceIconGap) {
                Image(systemName: "magnifyingglass")
                    .symbolRenderingMode(.monochrome)
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundStyle(.tint)
                    .frame(width: OnboardingMetrics.choiceIconWidth)
                    .accessibilityHidden(true)
                ChoiceCardLayout {
                    // The card that looks for servers that are already running on this Mac.
                    Text("A model server already running", comment: "Setup model step: title of the card that looks for model servers already running on this Mac (loopback only)")
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)
                    // Only this Mac is searched, on a small Mac too: the sentence says so in both.
                    SentenceLines(text: String(localized: "Vauta looks for LM Studio, Ollama and others on this Mac.",
                                               comment: "Setup model step: what searching for servers does"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        // The button already says “Searching…”: VoiceOver reads that once.
                        if model.scanning { ProgressView().controlSize(.small).accessibilityHidden(true) }
                        Button(model.scanning ? String(localized: "Searching…")
                               : model.discovered == nil ? String(localized: "Find Model Servers")
                               : String(localized: "Search Again", comment: "Button that looks for model servers again"))
                        { Task { await model.detect() } }
                            .disabled(model.scanning)
                    }
                    .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(OnboardingMetrics.choicePadding)
            foundServers
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// What was found, one hairline-separated row each under the header, with the card's horizontal inset.
    @ViewBuilder
    private var foundServers: some View {
        if let found = model.discovered {
            if found.isEmpty {
                Divider().padding(.horizontal, OnboardingMetrics.cardInset)
                // The same structure as a found row: the mark in the icon column, the sentence in the text column.
                HStack(alignment: .firstTextBaseline, spacing: OnboardingMetrics.choiceIconGap) {
                    StatusSymbol.info.image
                        .font(.title3)
                        .frame(width: OnboardingMetrics.choiceIconWidth)
                        .accessibilityHidden(true)
                    noServerText
                }
                .padding(.vertical, 10)
                .padding(.horizontal, OnboardingMetrics.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                ForEach(found, id: \.baseURL) { server in
                    Divider().padding(.horizontal, OnboardingMetrics.cardInset)
                    FoundServerRow(server: server, model: model, recorder: recorder,
                                   message: model.messageServer == server.baseURL ? model.modelMessage : nil, enoughMemory: enoughMemory)
                        .padding(.horizontal, OnboardingMetrics.cardInset)
                        // The name's line is taller than its text (the button is laid over it): 3 pt less on top, so the
                        // space above the name looks the same as the space below the detail.
                        .padding(.top, 7)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// What is said when nothing was found: secondary text in the text column.
    private var noServerText: some View {
        SentenceLines(text: (enoughMemory
             ? String(localized: "No server found. Set one up above, or start yours and search again.",
                      comment: "Setup model step: nothing was found")
             : String(localized: "No server found. See the options above, or start yours and search again.",
                      comment: "Setup model step on a Mac with little memory: nothing was found")))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One server that "Find Model Servers" found, with the button that uses it.
private struct FoundServerRow: View {
    let server: DiscoveredServer
    let model: OnboardingModel
    let recorder: RecorderModel
    /// What went wrong with this server, if the last try failed.
    let message: String?
    /// The guide has steps for this Mac (not a Mac with little memory).
    let enoughMemory: Bool

    var body: some View {
        let name = server.kind.displayName
        let modelName = OnboardingModel.modelName(of: server)
        // The app of this server, whose guide the row offers while it has no model; none on a Mac with little memory.
        let guideApp = enoughMemory ? LocalModelApp.allCases.first { $0.serverKind == server.kind } : nil
        HStack(alignment: .top, spacing: 0) {
            // A result, not a card: nested under the card's title (its text column), with a small status mark, the
            // check for a server that can be used and the warning for one that can't yet. The glyph of the cards
            // above ("this Mac") is not reused: it would read as a sibling card.
            Color.clear
                .frame(width: OnboardingMetrics.choiceIconWidth + OnboardingMetrics.choiceIconGap, height: 1)
            (modelName == nil ? StatusSymbol.warning : StatusSymbol.ok).image
                .font(.callout)
                .frame(width: 16)
                .padding(.trailing, 6)
                // On the name's line, whose button is taller than the text.
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                // The name line is as tall as the button whether or not the row has one (the button is laid over its
                // trailing end), so the line below starts the same distance under the name in every row.
                Text(name)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if model.usingServer == server.baseURL {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(String(localized: "Saving…", comment: "Progress"))
                        } else if modelName != nil {
                            Button("Use") { Task { await model.use(server, recorder) } }
                                .disabled(model.usingServer != nil)
                                .accessibilityLabel(Text("Use \(name)", comment: "VoiceOver: button that uses a found server; the argument is a server name"))
                        } else if let guideApp {
                            // Without a model there is nothing to use: the guide, on this server's app, is the way on.
                            Button(String(localized: "Set Up…", comment: "Button that opens the model server guide")) {
                                model.guideApp = guideApp
                                model.guidePresented = true
                            }
                            .disabled(model.usingServer != nil)
                            .accessibilityLabel(Text("Set Up \(name)", comment: "VoiceOver: button that opens the model guide on a found server that has no model; the argument is a server name"))
                        }
                    }
                Group {
                    if let modelName {
                        Text("\(modelName) on this Mac", comment: "Setup: a server that was found; the argument is a model name")
                    } else if guideApp != nil {
                        // The row's button is Set Up…: the sentence points to it, not to a second action.
                        Text(wrapping: String(localized: "No model downloaded yet. Set Up shows which one to get.",
                                    comment: "Setup: a server that was found but has no model; the row's Set Up… button opens the guide").avoidingWidow)
                    } else {
                        Text(wrapping: String(localized: "No model loaded. Load one in \(name), then search again.",
                                    comment: "Setup: a server that was found but has no model loaded; the argument is a server name").avoidingWidow)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let message {
                    SetupStatusLabel(text: message, onBulletGrid: false).font(.callout).padding(.top, 2)
                }
            }
        }
    }
}

@MainActor
private func guide(for model: OnboardingModel) -> ModelGuideModel {
    let guide = ModelGuideModel(physicalMemory: model.models.physicalMemory)
    if let app = model.guideApp { guide.app = app }
    return guide
}

extension View {
    /// The "Set up a model server" guide as a sheet of the setup window, on the Minutes page and on the last page.
    func localModelGuide(recorder: RecorderModel, model: OnboardingModel) -> some View {
        sheet(isPresented: Bindable(model).guidePresented) {
            // A Mac too small for a model server on it: "Connect a Model Server…" opens Settings → Models over setup, which
            // stays open behind it, so the person who chose a server on another computer is taken to where it is connected.
            ModelGuideSheet(recorder: recorder, settings: model.models, guide: guide(for: model),
                            close: { model.guidePresented = false },
                            useNetworkServer: { model.guidePresented = false; recorder.showSettings(.models) },
                            keepApple: { Task { await model.useOnDevice(recorder) } },
                            finished: { model.guideFinished($0) },
                            maxHeight: OnboardingMetrics.guideSheetMaxHeight(),
                            onHeightChange: { model.guideSheetHeight = $0 })
        }
    }
}
