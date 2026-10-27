// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Settings → Recording → Live answers: whether Vauta answers the questions it hears, where it looks, and how many sentences it checks.
struct LiveAnswersSection: View {
    @Bindable var recorder: RecorderModel
    @Bindable var preferences: Preferences
    /// Goes to Settings → Models, where the model that works while recording is chosen.
    var showModels: () -> Void = {}

    var body: some View {
        if preferences.liveAnswersOffered { offered } else { notOffered }
    }

    /// With Apple’s on-device model live answers are not offered (decision D16): no switches, one calm line and the way to the Models
    /// pane. What the person chose stays stored and comes back with the integrated model or a model server.
    private var notOffered: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Live answers need the integrated model or a model server.", comment: "Settings → Recording → Live answers, shown instead of the switches while the model that works during a recording is Apple’s on-device model")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(SettingsModel.Pane.models.openTitle, action: showModels)
            }
        } header: {
            Text("Live answers", comment: "Settings → Recording: section header")
        }
    }

    @ViewBuilder
    private var offered: some View {
        Section {
            Toggle(isOn: $preferences.liveAnswersEnabled) {
                Text("Answer questions asked in the meeting", comment: "Settings → Recording → Live answers: the switch")
                Text(description: recorder.llmStatus.chatProvider == .server
                     ? String(localized: "When someone asks a question that your meetings or documents can answer, a short answer with its sources appears in the panel. Nothing is spoken. The meeting so far, the questions and the passages they need are sent to your model server, as with Ask.",
                              comment: "Settings → Recording → Live answers, description when the model is a server")
                     : String(localized: "When someone asks a question that your meetings or documents can answer, a short answer with its sources appears in the panel. Nothing is spoken and nothing leaves your Mac.",
                              comment: "Settings → Recording → Live answers, description when the model runs on this Mac"))
            }

            Group {
                LabeledContent {
                    VStack(alignment: .leading, spacing: 4) {
                        sourceToggle(.thisMeeting, title: String(localized: "This meeting", comment: "Settings → Live answers: source the answers may use"))
                        sourceToggle(.pastMeetings, title: lowPowerMode
                                        ? String(localized: "Your past meetings (off in Low Power Mode)", comment: "Settings → Live answers: the past meetings are left out while the Mac is in Low Power Mode")
                                        : String(localized: "Your past meetings", comment: "Settings → Live answers: source the answers may use"),
                                    inactive: lowPowerMode)
                        sourceToggle(.documents, title: String(localized: "Your documents", comment: "Settings → Live answers: source the answers may use"))
                    }
                } label: {
                    Text("Look in", comment: "Settings → Live answers: label of the sources the answers may use (this meeting, past meetings, documents)")
                }
                // In Low Power Mode the recording uses the lowest level whatever was chosen (`LiveAnswerSettings.effective`): the picker says so.
                Picker(selection: lowPowerMode ? .constant(QuestionSensitivity.low) : $preferences.liveAnswersSensitivity) {
                    Text(lowPowerMode
                         ? String(localized: "Fewer answers (Low Power Mode)", comment: "Settings → Live answers → Sensitivity: shown instead of the chosen level while the Mac is in Low Power Mode, which uses the lowest level")
                         : String(localized: "Fewer answers", comment: "Settings → Live answers → Sensitivity: the lowest level, fewer sentences are checked")).tag(QuestionSensitivity.low)
                    Text("Standard", comment: "Settings → Live answers → Sensitivity: the middle level").tag(QuestionSensitivity.standard)
                    Text("More answers", comment: "Settings → Live answers → Sensitivity: the highest level, more sentences are checked").tag(QuestionSensitivity.high)
                } label: {
                    Text("Sensitivity", comment: "Settings → Live answers: how many of the sentences heard are checked for a question")
                    Text(description: String(localized: "“More answers” checks more of what is said, which uses more energy.", comment: "Settings → Live answers, under Sensitivity"))
                }
                // The choice is not lost: it applies again when the Mac leaves Low Power Mode.
                .disabled(lowPowerMode)
                Picker(selection: $preferences.liveAnswersSpeakers) {
                    Text("Everyone", comment: "Settings → Live answers → Questions from: questions asked by you and by the others in the call").tag(LiveAnswerSpeakers.everyone)
                    Text("Others only", comment: "Settings → Live answers → Questions from: only questions asked by the others in the call, not by you").tag(LiveAnswerSpeakers.othersOnly)
                } label: {
                    Text("Questions from", comment: "Settings → Live answers: whose questions are answered")
                }
                Toggle(isOn: $preferences.liveAnswersHideAnsweredAloud) {
                    Text("Hide answers when someone answers aloud", comment: "Settings → Live answers: the switch that hides an answer card when the people in the meeting already answered the question")
                    Text(description: String(localized: "No card is shown when the lines right after a question already answer it.",
                                             comment: "Settings → Live answers, under Hide answers when someone answers aloud"))
                }
                Toggle(isOn: $preferences.liveAnswersKeepQuestions) {
                    Text("Keep detected questions with the meeting", comment: "Settings → Live answers: the switch that keeps the questions heard with the meeting")
                    Text(description: preferences.liveAnswersKeepQuestions
                         ? String(localized: "They are stored encrypted with the meeting and listed on its page. Only the ones you keep are exported or searched.",
                                  comment: "Settings → Live answers, under Keep detected questions with the meeting when it is on")
                         : String(localized: "Questions you don’t keep are removed when the recording ends.",
                                  comment: "Settings → Live answers, under Keep detected questions with the meeting when it is off"))
                }
            }
            .disabled(!preferences.liveAnswersEnabled)
        } header: {
            Text("Live answers", comment: "Settings → Recording: section header")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if recorder.isRecording {
                    SettingsNote(String(localized: "The switch and “Keep detected questions” apply at once; the other settings apply to the next recording.",
                                        comment: "Settings → Live answers, while recording: the switch applies immediately, the other settings wait for the next recording"))
                }
                if lowPowerMode {
                    SettingsNote(String(localized: "In Low Power Mode Vauta checks fewer sentences and leaves your past meetings out.", comment: "Settings → Live answers: note while the Mac is in Low Power Mode"))
                }
                SettingsNote(LiveAnswersText.canBeWrong)
                SettingsNote(String(localized: "Answers can show text from other meetings and documents. Vauta asks macOS to keep the panel out of screen sharing, but that is not guaranteed.",
                                    comment: "Settings → Live answers: privacy note"))
            }
        }
    }

    #if VAUTA_DIAGNOSTICS
    /// The snapshot renderer shows the note whatever the render Mac is doing.
    nonisolated(unsafe) static var lowPowerOverride: Bool?
    private var lowPowerMode: Bool { Self.lowPowerOverride ?? ProcessInfo.processInfo.isLowPowerModeEnabled }
    #else
    private var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    #endif

    private func sourceToggle(_ source: LiveAnswerSources, title: String, inactive: Bool = false) -> some View {
        Toggle(title, isOn: Binding(get: { preferences.liveAnswersSources.contains(source) && !inactive }, set: { on in
            if on { preferences.liveAnswersSources.insert(source) } else { preferences.liveAnswersSources.remove(source) }
        }))
        .disabled(inactive)
    }
}
