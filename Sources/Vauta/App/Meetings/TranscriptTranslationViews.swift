// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Transcript → Translate: the languages the transcript can be read in. Choosing one shows it and translates the lines that
/// don't have it yet; Translate Again translates every line of the language shown once more (after turning on the model
/// server, say). A language marked with the download symbol is downloaded first, through Apple's own sheet.
struct TranscriptTranslateMenu: View {
    let model: MeetingsModel
    let meeting: MeetingStore.Meeting

    static let title = String(localized: "Translate", comment: "Transcript tab: the menu of languages to read the transcript in")

    private var translation: TranscriptTranslationModel { model.translation }
    private var shows: Bool { model.preferences?.showTranslationsInTranscript ?? true }

    var body: some View {
        Menu {
            ForEach(translation.targets) { target in
                Toggle(isOn: Binding(get: { shows && model.translationLanguage == target.id },
                                     set: { _ in model.translateTranscript(into: target.language) })) {
                    if target.needsDownload { Label(target.name, systemImage: "arrow.down.circle") } else { Text(target.name) }
                }
            }
            if let shown = model.translationLanguage, translation.targets.contains(where: { $0.id == shown }) {
                Divider()
                Button(String(localized: "Translate Again", comment: "Transcript tab, Translate menu: translates every line again into the language shown")) {
                    model.translateTranscript(into: Locale.Language(identifier: shown), again: true)
                }
            }
        } label: {
            Label(Self.title, systemImage: "translate")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .disabled(translation.targets.isEmpty)
        .help(String(localized: "Read the transcript in another language. The lines keep their words, with the translation under each one.",
                     comment: "Transcript tab: tooltip of the Translate menu"))
        .task(id: "\(meeting.transcriptionLocale.identifier)|\(translation.usesServer)") {
            await translation.refreshTargets(source: meeting.transcriptionLocale.language)
        }
    }
}

/// Under the transcript's controls: how the translation of the meeting shown is going, with Stop, or how it ended when there
/// is something to say.
struct TranscriptTranslationStatus: View {
    let model: MeetingsModel
    let meetingID: Int64

    var body: some View {
        let translation = model.translation
        if let stage = translation.stages[meetingID] {
            HStack(alignment: .center, spacing: 8) {
                if case .translating(_, let done, let total, _) = stage, total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                        .frame(width: 90)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(Self.text(of: stage))
                Button(String(localized: "Stop", comment: "Transcript tab: stops translating the transcript; what was translated stays")) {
                    translation.stop(meetingID)
                }
                .buttonStyle(.link)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .contain)
        } else if let notice = translation.notices[meetingID] {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                (notice == .downloadFailed || isMissing(notice) ? StatusSymbol.info : StatusSymbol.warning).image
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.text(of: notice)).fixedSize(horizontal: false, vertical: true)
                    if let detail = Self.detail(of: notice) { Text(verbatim: detail).font(.caption).fixedSize(horizontal: false, vertical: true) }
                }
                if let shown = model.translationLanguage {
                    Button(String(localized: "Try Again", comment: "Transcript tab: translates the lines without a translation again")) {
                        model.translateTranscript(into: Locale.Language(identifier: shown))
                    }
                    .buttonStyle(.link)
                }
                Button { translation.dismissNotice(meetingID) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel(Text("Dismiss"))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .contain)
        }
    }

    private func isMissing(_ notice: TranscriptTranslationModel.Notice) -> Bool {
        if case .missing = notice { return true }
        return false
    }

    static func text(of stage: TranscriptTranslationModel.Stage) -> String {
        switch stage {
        case .waiting(let language):
            let name = TranslationPair.name(of: language)
            return String(localized: "Waiting to translate into \(name)…",
                          comment: "Transcript tab: another meeting is being translated first; the argument is a language name in running text")
        case .downloading(let language):
            let name = TranslationPair.name(of: language)
            return String(localized: "Downloading \(name) for translation on this Mac…",
                          comment: "Transcript tab: Apple's translation languages are downloading; the argument is a language name in running text")
        case .waitingForRecording(let language):
            let name = TranslationPair.name(of: language)
            return String(localized: "The translation into \(name) goes on when the recording ends.",
                          comment: "Transcript tab: nothing is translated while a meeting is being recorded; the argument is a language name in running text")
        case .translating(let language, let done, let total, let server):
            let name = TranslationPair.name(of: language)
            guard total > 0 else {
                return server
                    ? String(localized: "Translating into \(name) with your model server…", comment: "Transcript tab: the argument is a language name in running text")
                    : String(localized: "Translating into \(name) on this Mac…", comment: "Transcript tab: Apple's translation on this Mac; the argument is a language name in running text")
            }
            let percent = done * 100 / total
            return server
                ? String(localized: "Translating into \(name) with your model server (\(percent)%)",
                         comment: "Transcript tab: the arguments are a language name in running text and how much is done, in percent")
                : String(localized: "Translating into \(name) on this Mac (\(percent)%)",
                         comment: "Transcript tab: Apple's translation on this Mac; the arguments are a language name in running text and how much is done, in percent")
        }
    }

    static func text(of notice: TranscriptTranslationModel.Notice) -> String {
        switch notice {
        case .missing(let count):
            String(localized: "\(count) lines couldn’t be translated.", comment: "Transcript tab: after translating, some lines have no translation; the argument is how many")
        case .serverStopped(_, onDevice: true):
            String(localized: "Your model server stopped answering, so Apple’s translation on this Mac did the rest.",
                   comment: "Transcript tab: after translating with the model server")
        case .serverStopped(_, onDevice: false):
            String(localized: "Your model server stopped answering. The rest of the lines have no translation.",
                   comment: "Transcript tab: after translating with the model server, when Apple’s translation can’t do the rest")
        case .failed:
            String(localized: "Couldn’t translate the transcript.", comment: "Transcript tab: translating the transcript failed; the reason follows")
        case .downloadFailed:
            String(localized: "The language download didn’t finish.", comment: "Transcript tab: Apple’s download of the translation languages didn’t finish")
        }
    }

    /// What the server or the system said, when it says more than the sentence.
    static func detail(of notice: TranscriptTranslationModel.Notice) -> String? {
        switch notice {
        case .serverStopped(let message, _), .failed(let message): message.isEmpty ? nil : message
        case .missing, .downloadFailed: nil
        }
    }
}
