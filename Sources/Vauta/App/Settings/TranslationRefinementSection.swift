// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Settings → Translation → "Better translations": the model server improves
/// finished sentences. Apple's caption always shows first and stays when the
/// server can't help.
struct TranslationRefinementSection: View {
    let recorder: RecorderModel
    @Bindable var preferences: Preferences
    let live: LiveTranslationModel
    /// The language the next meeting is spoken in, for the test sentence.
    let source: Locale.Language?
    /// Opens the guided model setup.
    let setUp: () -> Void
    /// Goes to Settings → Models.
    let showModels: () -> Void

    private var serverConfigured: Bool { recorder.llmStatus.serverConfigured }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { serverConfigured && preferences.translationRefinementEnabled },
                                 set: { preferences.translationRefinementEnabled = $0 })) {
                Text("Improve finished sentences with your model server")
                // Without a server there is no "server version" to describe: the notice below says what is used instead.
                if serverConfigured {
                    Text(description: String(localized: "Apple’s translation shows at once. Your server’s version replaces it on screen if it answers within a few seconds, and it’s always the one saved with the transcript."))
                }
            }
            .disabled(!serverConfigured)

            if !serverConfigured {
                // The same row as the other "not available yet" rows with an action (General → Notifications).
                HStack {
                    NoticeLabel(Text("Connect a model server to improve translations. Until then, Apple’s translation is used.",
                                     comment: "Settings → Translation: shown when no model server is set up"),
                                status: .info)
                    Spacer()
                    Button("Set Up…", action: setUp)
                }
            } else if preferences.translationRefinementEnabled {
                Picker(String(localized: "Translation model", comment: "Settings → Translation: which server model translates"),
                       selection: modelChoice) {
                    Text(fastModelLabel).tag("")
                    let others = modelNames
                    if !others.isEmpty {
                        Divider()
                        ForEach(others, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                }
                testRow
                statusRow
            }
        } header: {
            Text("Better translations")
        } footer: {
            // Nothing is sent without a server, or while the feature is off: the note appears when it applies.
            if serverConfigured && preferences.translationRefinementEnabled {
                SettingsNote(String(localized: "During a meeting, only the other participants’ finished sentences go to your model server, with the three previous sentences and their translations as context. When you translate a transcript in Meetings, its lines go the same way. Nothing is sent anywhere else.",
                                    comment: "Settings → Translation: privacy note about the model server"))
            }
        }
    }

    // MARK: Models

    private var fastModel: String { recorder.serverConfig?.model(for: .fast) ?? "" }

    /// The fast model is the "" choice: stored as its own name it would be listed twice, once as a bare id.
    private var modelChoice: Binding<String> {
        Binding(get: { preferences.translationModel == fastModel ? "" : preferences.translationModel },
                set: { preferences.translationModel = $0 == fastModel ? "" : $0 })
    }

    private var fastModelLabel: String {
        fastModel.isEmpty
            ? String(localized: "Fast model", comment: "Settings → Translation: the server's fast model is used")
            : String(localized: "Fast model (\(fastModel))", comment: "Settings → Translation: the server's fast model is used; the argument is its name")
    }

    /// The server's chat models other than the fast one (already the first option), plus the chosen one
    /// even when the server doesn't list it (so the picker never lies). Embedding models can't translate.
    private var modelNames: [String] {
        let embedding = recorder.serverConfig?.embeddingModel ?? ""
        var names = recorder.llmStatus.models.filter {
            $0 != fastModel && $0 != embedding && ServerDiscovery.kindFromName($0) != .embedding
        }
        let chosen = preferences.translationModel
        if !chosen.isEmpty, chosen != fastModel, !names.contains(chosen) { names.insert(chosen, at: 0) }
        return names
    }

    // MARK: Status and test

    @ViewBuilder private var statusRow: some View {
        if let indicator = RefinementIndicator.Content(live.refinementStatus) {
            // A short value beside the title; the reason is the row's own description, a full sentence that wraps
            // on the leading side in every language.
            LabeledContent {
                // The filled status symbols every other row of Settings uses.
                // The panel says the server didn't answer; here the row's description explains the late version, so the
                // value says what it means for the captions.
                TrailingStatus(text: live.refinementStatus == .unavailable
                               ? Text("Too slow for captions", comment: "Settings → Translation: value of the last sentence when the model server’s version came too late for the captions")
                               : Text(indicator.text)) {
                    (live.refinementStatus == .improved ? StatusSymbol.ok : StatusSymbol.warning).image
                }
            } label: {
                Text("Last finished sentence", comment: "Settings → Translation: how the latest sentence was translated")
                Text(description: statusDescription(indicator))
            }
        }
    }

    /// The consequence, not a repeat of the value beside it (which already says it was too slow).
    private func statusDescription(_ indicator: RefinementIndicator.Content) -> String {
        if live.refinementStatus == .improved {
            return String(localized: "The captions show the server’s version, and it’s the one saved with the transcript.",
                          comment: "Settings → Translation: description of the last sentence the model server improved")
        }
        guard live.refinementStatus == .unavailable else { return indicator.help }
        return String(localized: "Apple’s translation stays on screen. If the server’s version arrives later, it’s still saved with the transcript.",
                      comment: "Settings → Translation: description of the last sentence the model server did not answer in time")
    }

    @ViewBuilder private var testRow: some View {
        let running = live.refinementTest == .running
        LabeledContent {
            Button("Test") { live.runRefinementTest(source: source) }.disabled(running)
        } label: {
            Text("Test the translation model")
            Text(description: String(localized: "Translates a sample sentence and shows how long it takes."))
        }
        switch live.refinementTest {
        case .idle:
            EmptyView()
        case .running:
            // The same icon column as the results, so the text starts at the same place.
            Label {
                Text("Translating…").foregroundStyle(.secondary)
            } icon: {
                ProgressView().controlSize(.small)
            }
            .labelStyle(AlignedIconLabelStyle(width: 20))
            .font(.callout)
        case .finished(let test):
            TranslationTestResult(test: test, showModels: showModels)
        }
    }
}

/// What the test sentence became, and how long the server took.
struct TranslationTestResult: View {
    let test: RefinementTest
    var showModels: (() -> Void)?

    private var time: String {
        Measurement(value: test.seconds, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(test.seconds < 10 ? 1 : 0))))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            result
                .textSelection(.enabled)
                // The verdict and the sample are one thing for VoiceOver; the button stays its own control.
                .accessibilityElement(children: .combine)
            if case .failed = test.outcome, let showModels {
                Button(SettingsModel.Pane.models.openTitle, action: showModels)
                    .padding(.leading, 28)
            }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch test.outcome {
            case .translated(let text):
                // The verdict first, then the sample on the same text edge as the verdict.
                if test.withinBudget {
                    FeedbackLabel(feedback: .init(kind: .success, text: String(localized: "Translated in \(time)."), isTitle: true))
                } else {
                    FeedbackLabel(feedback: .init(kind: .warning, text: String(localized: "Translated in \(time)."),
                                                  note: String(localized: "That’s too slow for the captions: they keep Apple’s translation, and the transcript saves the server’s version. Try a smaller or faster model.",
                                                               comment: "Settings → Translation test: the model server took longer than the time allowed for replacing a caption")))
                }
                Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        Text("Original", comment: "Settings → Translation test: label of the sample sentence").foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(verbatim: test.sample.text).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Translation", comment: "Settings → Translation test: label of the sentence the model server translated").foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(verbatim: text)
                    }
                }
                .font(.callout)
                .padding(.leading, 28)
            case .timedOut:
                // Apple's translation stays and a late refinement is still saved: a warning, not a failure.
                FeedbackLabel(feedback: .init(kind: .warning, text: String(localized: "The model server didn’t answer in time."),
                                              note: String(localized: "The captions keep Apple’s translation on screen. If the server answers later, its version is still saved with the transcript. Try a smaller or faster model, or check that the server isn’t busy.",
                                                           comment: "Settings → Translation test: the model server did not answer in time")))
            case .failed(let message):
                FeedbackLabel(feedback: .init(kind: .error, text: String(localized: "The test sentence couldn’t be translated."),
                                              note: message.isEmpty ? nil : message))
            }
        }
    }
}
