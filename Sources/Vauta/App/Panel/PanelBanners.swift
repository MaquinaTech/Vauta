// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// "Record this meeting?" when a meeting app starts a call.
struct SuggestionBanner: View {
    let model: RecorderModel
    let suggestion: RecordingSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if suggestion.title.isEmpty {
                        Text("Record this meeting?").font(.callout.weight(.semibold))
                    } else {
                        Text("Record “\(suggestion.title)”?").font(.callout.weight(.semibold))
                    }
                    Text(paragraph: suggestion.scheduled ? RecordingSuggestion.scheduledSentence : suggestion.call.sentence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: suggestion.event != nil ? "calendar.badge.clock" : "phone.bubble.fill")
            }
            PanelActionRow {
                // The big button under the banner is muted while this is shown, so the banner's own answer is the one
                // call to action (accent), like every other banner of the panel.
                Button("Record") { model.acceptSuggestion() }
                    .prominentButton(true)
                Button("Not Now") { model.dismissSuggestion() }
                    .prominentButton(false)
            }
            .controlSize(.small)
            .panelBannerActions()
        }
        .panelBannerLabel(.info)
        .panelBanner(.info)
        .accessibilityElement(children: .contain)
    }
}

/// Before the automatic stop, or when the meeting app released the microphone.
struct StopBanner: View {
    let model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let left = model.autoStopRemaining {
                Label {
                    PanelNoticeText(title: String(localized: "Stopping in \(Self.countdown(left))",
                                                  comment: "Panel banner title; the argument is a countdown like 1:30"),
                                    detail: String(localized: "Vauta can’t hear the meeting.", comment: "Panel banner: why the recording is about to stop"))
                } icon: {
                    Image(systemName: "timer.circle.fill")
                }
                .accessibilityValue(Text(verbatim: ElapsedTime.spoken(left)))
            } else if let app = model.recordingApp?.shortName {
                Label {
                    PanelNoticeText(title: String(localized: "Has the meeting ended?", comment: "Panel banner title"),
                                    detail: String(localized: "\(app) stopped using the microphone.",
                                                   comment: "Panel banner; the argument is the meeting app"))
                } icon: {
                    Image(systemName: "phone.down.circle.fill")
                }
            } else {
                Label {
                    PanelNoticeText(title: String(localized: "Has the meeting ended?", comment: "Panel banner title"),
                                    detail: String(localized: "The meeting app stopped using the microphone.", comment: "Panel banner"))
                } icon: {
                    Image(systemName: "phone.down.circle.fill")
                }
            }
            PanelActionRow {
                // The main action leads, like every banner of the panel: when the meeting app let go of the
                // microphone, most likely the meeting is over, so saving is first; in the automatic-stop
                // countdown, staying is the one that needs a decision.
                if model.autoStopRemaining == nil {
                    Button("Stop and Save") { model.stop() }
                        .prominentButton(true)
                    Button("Keep Recording") { model.keepRecording() }
                        .prominentButton(false)
                } else {
                    Button("Keep Recording") { model.keepRecording() }
                        .prominentButton(true)
                    Button("Stop and Save") { model.stop() }
                        .prominentButton(false)
                }
            }
            .controlSize(.small)
            .panelBannerActions()
        }
        .panelBannerLabel(.warning)
        .panelBanner(.warning)
    }

    /// "1:30": the same form as the elapsed timer and the times of notes and passages.
    static func countdown(_ seconds: Int) -> String { ElapsedTime.stamp(seconds) }
}

/// The speech model of the chosen language must be downloaded first.
struct SpeechModelBanner: View {
    let model: RecorderModel

    var body: some View {
        if let missing = model.missingModel {
            let progress = model.speechDownloadProgress
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    PanelNoticeText(
                        title: progress != nil
                            ? String(localized: "Downloading the \(model.shortLanguageName(missing.language, inSentence: true)) speech model…")
                            : String(localized: "The speech model for \(model.shortLanguageName(missing.language, inSentence: true)) isn’t installed.", comment: "Capture error; the argument is a language name"),
                        detail: String(localized: "It downloads once from Apple. After that, transcription runs on this Mac."))
                } icon: {
                    Image(systemName: "arrow.down.circle.fill")
                }
                if let progress {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .accessibilityLabel(Text("Download progress"))
                        Text(verbatim: progress.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Button("Cancel") { model.cancelModelInstall() }
                            .controlSize(.small)
                    }
                    .panelBannerActions()
                } else {
                    PanelActionRow {
                        Button("Download") { model.installMissingModel() }
                            .buttonStyle(.borderedProminent)
                        Button("Not Now") { model.missingModel = nil }
                    }
                    .controlSize(.small)
                    .panelBannerActions()
                }
            }
            .panelBannerLabel(.info)
            .panelBanner(.info)
        }
    }
}

/// Vauta's windows are hidden for presenting (Hide Vauta Windows): the panel says so until they come back, and brings them back.
struct WindowsHiddenBanner: View {
    let model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                PanelNoticeText(
                    title: String(localized: "Vauta’s windows are hidden", comment: "Panel notice while Vauta’s windows, the notepad and the captions are hidden for sharing the screen"),
                    detail: String(localized: "Nothing of Vauta comes on screen by itself until you show them again.", comment: "Detail of the panel notice while Vauta’s windows are hidden for sharing the screen; a window the user opens on purpose still shows"))
            } icon: {
                Image(systemName: "eye.slash")
            }
            PanelActionRow {
                Button("Show Windows") { model.showHiddenWindows() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .panelBannerActions()
        }
        .panelBannerLabel(.info)
        .panelBanner(.info)
    }
}
