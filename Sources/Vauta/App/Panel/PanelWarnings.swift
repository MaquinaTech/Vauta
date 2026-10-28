// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Warnings with the action that fixes them, when there is one. Each kind sits
/// next to what it is about: a problem that blocks recording above the record
/// button, audio warnings under the level meters, the rest at the end. Every
/// banner carries its own button, right under the words it fixes.
struct PanelWarnings: View {
    enum Scope {
        /// Recording can't start: above the record button.
        case problem
        /// Audio isn't arriving: under the level meters.
        case live
        /// Results of the last recording and other notices.
        case general
    }

    let model: RecorderModel
    let scope: Scope

    var isVisible: Bool { !banners.isEmpty }

    var body: some View {
        if isVisible {
            VStack(spacing: 8) {
                ForEach(banners) { banner in
                    bannerView(banner)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func bannerView(_ banner: Banner) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(banner.messages, id: \.self) { message in
                Label {
                    if let detail = message.detail {
                        // A title (a sentence from the system loses its full stop) and what it means, like every other
                        // notice in the panel.
                        PanelNoticeText(title: message.text.withoutTerminalPunctuation, detail: detail)
                    } else {
                        Text(paragraph: message.text.withTerminalPunctuation)
                    }
                } icon: {
                    banner.icon
                }
                .help(Text(verbatim: message.help ?? model.warningDetails[message.text] ?? ""))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !banner.fixes.isEmpty || banner.dismissible {
                // Three buttons that do not fit one row (the countdown with its way out): the two decisions stay together
                // and the sound settings, which never compete with them, go on a row of their own.
                ViewThatFits(in: .horizontal) {
                    fixRow(banner)
                    if banner.fixes.count == 3, banner.fixes.last == .openSoundSettings, !banner.dismissible {
                        VStack(alignment: .leading, spacing: 6) {
                            PanelActionRow { ForEach(banner.fixes.dropLast(), id: \.self) { fix in fixButton(fix.title, prominent: isProminent(fix, in: banner)) { perform(fix) } } }
                            fixButton(Fix.openSoundSettings.title, prominent: false) { perform(.openSoundSettings) }
                        }
                    }
                    fixRow(banner, stacked: true)
                }
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .controlSize(.small)
                .panelBannerActions()
            }
        }
        .panelBannerLabel(banner.style)
        .panelBanner(banner.style)
    }

    @ViewBuilder private func fixRow(_ banner: Banner, stacked: Bool = false) -> some View {
        let buttons = Group {
            ForEach(banner.fixes, id: \.self) { fix in
                if stacked {
                    FittingButton(title: fix.title, prominent: isProminent(fix, in: banner)) { perform(fix) }
                } else {
                    fixButton(fix.title, prominent: isProminent(fix, in: banner)) { perform(fix) }
                }
            }
            if banner.dismissible {
                Button("Dismiss") { dismiss(banner) }
            }
        }
        // Stacked is the last resort: a long title ("Open Login Items Settings" in German) takes two lines there.
        if stacked { VStack(alignment: .leading, spacing: 6) { buttons } } else { HStack(spacing: 8) { buttons } }
    }

    /// The button that fixes the problem is the prominent one; "Dismiss" stays quiet. A button that only opens System
    /// Settings gives way to the action of Vauta that comes with it (Try Again after freeing space), and the sound
    /// settings never compete with "Keep Recording" or "Stop and Save".
    private func isProminent(_ fix: Fix, in banner: Banner) -> Bool {
        switch fix {
        case .openSoundSettings: false
        // Next to "Keep Recording" (the countdown), saving now is the other choice, not a second main action.
        case .stopAndSave: !banner.fixes.contains(.keepRecording)
        // The record button is the panel's primary action below the problem banner (and the stop button while
        // recording): a banner under it never adds a second blue button. Above it, it is blocked and grey.
        case .openStorageSettings: scope == .problem && !banner.fixes.contains(.tryAgain)
        case .openPrivacySettings: !banner.fixes.contains(.tryAgain)
        default: true
        }
    }

    private func fixButton(_ title: Text, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { title }
            .prominentButton(prominent)
    }

    private func perform(_ fix: Fix) {
        switch fix {
        case .tryAgain: model.openStore()
        case .openPrivacySettings:
            if let pane = model.permissionProblem { NSWorkspace.shared.open(pane.url) }
        case .openSoundSettings:
            if let url = Self.soundSettings { NSWorkspace.shared.open(url) }
        case .openLoginItems: model.openLoginItemsSettings()
        case .openStorageSettings:
            if let url = Self.storageSettings { NSWorkspace.shared.open(url) }
        case .stopAndSave: model.stop()
        case .keepRecording: model.keepRecording()
        case .checkSpeakers: model.checkSpeakers()
        }
    }

    /// The automatic-stop countdown runs because no system audio arrives, and the warning about it is on screen: the two
    /// are one banner (the warning's, titled with the time left), so the panel does not show two orange cards for one cause.
    static func mergesCountdown(_ model: RecorderModel) -> Bool {
        guard model.isRecording, model.autoStopRemaining != nil, model.channelWarnings.count == 1,
              let warning = model.channelWarnings[.others] else { return false }
        return warning == CaptureError(.systemAudioLost).localizedDescription
    }

    private static let storageSettings = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")
    private static let soundSettings = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    /// The failed-phase banner can be dismissed once the store is open (there is nothing left to retry).
    private var canDismissProblem: Bool { !model.isRecording && isFailed && model.storeAvailable }

    /// "Dismiss" clears only the notice of the banner it sits in: a save failure, the last error or the stop notice.
    /// Only the failed-phase banner clears everything that blocked the last start.
    private func dismiss(_ banner: Banner) {
        switch banner.id {
        case "capture": model.captureAlert = nil
        case "save": model.saveError = nil
        case "error": model.lastError = nil
        case "stop": model.lastStopReason = nil
        case "empty": model.nothingRecorded = false
        case "speakers": model.speakersUpdated = false
        default: model.clearWarnings()
        }
    }

    /// One warning: a sentence, or a title with what it means under it.
    struct Message: Hashable {
        let text: String
        var detail: String?
        /// The detail when the banner is the stop countdown's too: the reason it is stopping comes first.
        var countdownDetail: String?
        /// The system's own text, shown as a tooltip.
        var help: String?
    }

    /// What a banner's button does.
    enum Fix: Hashable {
        case tryAgain, openPrivacySettings, openSoundSettings, openLoginItems, openStorageSettings, stopAndSave, keepRecording, checkSpeakers

        var title: Text {
            switch self {
            case .tryAgain: Text("Try Again")
            case .openPrivacySettings: Text("Open System Settings")
            case .openSoundSettings: Text("Open Sound Settings")
            case .openLoginItems: Text("Open Login Items Settings")
            case .openStorageSettings: Text("Open Storage Settings")
            case .stopAndSave: Text("Stop and Save")
            case .keepRecording: Text("Keep Recording")
            case .checkSpeakers: Text("Check Speakers", comment: "Button of the panel notice after a recording: opens the saved meeting’s transcript to check the speaker names")
            }
        }
    }

    /// Messages that belong together, the button that fixes them, and how serious they are. A button sits under
    /// the words it is about, so each banner holds one cause.
    struct Banner: Identifiable {
        let id: String
        var messages: [Message]
        var style: PanelBannerStyle = .warning
        var fixes: [Fix] = []
        var dismissible = false
        /// A symbol of its own instead of the style's (the countdown's timer).
        var symbolName: String?

        @ViewBuilder var icon: some View {
            if let symbolName {
                Image(systemName: symbolName)
            } else {
                styleIcon
            }
        }

        @ViewBuilder private var styleIcon: some View {
            switch style {
            case .error: StatusSymbol.error.image
            case .warning: StatusSymbol.warning.image
            // A notice, not a fault: the shared info symbol (the label style fills it, like the other banner symbols);
            // the blue card already marks it as a notice.
            case .info: StatusSymbol.info.image
            }
        }
    }

    private var banners: [Banner] {
        var out: [Banner] = []
        switch scope {
        case .problem:
            // A failure that blocks recording is an error, as in Settings → Status.
            if case .failed = model.phase {
                var fixes: [Fix] = []
                // A full disk is fixed in Storage; Try Again stays the prominent action once there is room.
                // The main action leads in every banner: Try Again first, then the place where the room is made.
                if !model.storeAvailable && model.phase != .opening { fixes.append(.tryAgain) }
                if !model.storeAvailable && model.storeOpenIsDiskFull { fixes.append(.openStorageSettings) }
                if model.permissionProblem != nil { fixes.append(.openPrivacySettings) }
                out.append(Banner(id: "problem", messages: messages, style: .error, fixes: fixes, dismissible: canDismissProblem))
            }
        case .live:
            // No system audio: say what to check, not only that it happened.
            let lostSystemAudio = CaptureError(.systemAudioLost).localizedDescription
            let appName = model.recordingApp?.shortName
            let channels = Channel.allCases.compactMap { model.channelWarnings[$0] }.map { warning -> Message in
                guard warning == lostSystemAudio else { return Message(text: warning, detail: nil) }
                // The title is the plain form the stop countdown uses; "system audio" stays in the technical error.
                let title = String(localized: "Vauta can’t hear the meeting.", comment: "Panel banner: why the recording is about to stop")
                // The status line above already names the app: the advice names it too. The same words as the capture alert.
                let detail = appName.map {
                    String(localized: "Check that \($0) isn’t muted and that its sound plays through this Mac.",
                           comment: "Panel warning: what to check when no system audio arrives, with the meeting app’s name (%@); under the title “Vauta can’t hear the meeting”")
                } ?? String(localized: "Check that the meeting app isn’t muted and that its sound plays through this Mac.",
                            comment: "Panel warning: what to check when no system audio arrives; under the title “Vauta can’t hear the meeting”")
                // The countdown banner keeps the reason in front of the advice (one string per language, never joined here).
                let reasonAndDetail = appName.map {
                    String(localized: "Vauta can’t hear the meeting. Check that \($0) isn’t muted and that its sound plays through this Mac.",
                           comment: "Panel banner while the recording is about to stop because no sound arrives, with the meeting app’s name (%@): why, then what to check; under the countdown title")
                } ?? String(localized: "Vauta can’t hear the meeting. Check that the meeting app isn’t muted and that its sound plays through this Mac.",
                            comment: "Panel banner while the recording is about to stop because no sound arrives: why, then what to check; under the countdown title")
                return Message(text: title, detail: detail, countdownDetail: reasonAndDetail)
            }
            // Nothing arriving on Others is one cause told twice when the capture already says so: one card, with the way out.
            let othersExplained = model.channelWarnings[.others] != nil
            if Self.mergesCountdown(model), let left = model.autoStopRemaining, let advice = channels.first?.countdownDetail ?? channels.first?.detail {
                // The countdown is the same silence the warning reports: one banner, with the time left as its title.
                out.append(Banner(id: "channels",
                                  messages: [Message(text: String(localized: "Stopping in \(StopBanner.countdown(left))",
                                                                  comment: "Panel banner title; the argument is a countdown like 1:30"),
                                                     detail: advice)],
                                  fixes: Self.soundSettings == nil ? [.keepRecording, .stopAndSave] : [.keepRecording, .stopAndSave, .openSoundSettings],
                                  symbolName: "timer.circle.fill"))
            } else if !channels.isEmpty {
                // Stop and Save leads (the main action); the sound settings, which never compete with it, follow.
                var fixes: [Fix] = othersExplained && model.silenceWarning != nil ? [.stopAndSave] : []
                if Self.soundSettings != nil { fixes.append(.openSoundSettings) }
                out.append(Banner(id: "channels", messages: channels, fixes: fixes))
            }
            // The same cause told with the meeting app and what to check, once per silent stretch; "Dismiss" closes it.
            // Not when the channels banner already names why Others is silent: that cause is known, the advice here is a guess.
            if let w = model.captureAlert, !othersExplained {
                var fixes: [Fix] = []
                if Self.soundSettings != nil { fixes.append(.openSoundSettings) }
                out.append(Banner(id: "capture", messages: [Message(text: w.title, detail: w.detail)], fixes: fixes, dismissible: true))
            }
            // The warning comes back while the silence lasts, so it is not dismissible; saving is the way out. It is also
            // what a call in an app that is not the recorded source gets: the alert only fires for the recorded source. The
            // meeting-app alert (shown, or dismissed during this silent stretch) already said it, in more words. Once sound
            // has really returned the alert is re-armed, and this banner is the warning until it fires again.
            if let w = model.silenceWarning, !othersExplained, !model.captureAlertCoversSilence {
                out.append(Banner(id: "silence", messages: [Message(text: w.title, detail: w.detail)], fixes: [.stopAndSave]))
            }
        case .general:
            if let w = model.saveError { out.append(failureBanner(id: "save", w)) }
            if let w = model.lastError { out.append(failureBanner(id: "error", w)) }
            if let reason = model.lastStopReason {
                // An automatic stop is an expected outcome, not a fault.
                out.append(Banner(id: "stop", messages: [Message(text: String(localized: "Recording stopped automatically", comment: "Panel warning title; the sentence under it says why"),
                                                                  detail: reason.explanation)], style: .info))
            }
            if model.nothingRecorded {
                // A short title and what to do (the full sentence is what VoiceOver already announced).
                out.append(Banner(id: "empty", messages: [Message(text: String(localized: "No meeting saved", comment: "Panel notice title after a recording with nothing in it; the sentence under it says what to check"),
                                                                  detail: String(localized: "Nothing was heard during the recording. Check the microphone and the meeting app’s sound.",
                                                                                 comment: "Panel notice under “No meeting saved”: what happened and what to check"))],
                                  style: .info,
                                  fixes: Self.soundSettings == nil ? [] : [.openSoundSettings]))
            }
            if model.speakersUpdated {
                // After a recording whose voices were told apart: the live labels were guesses.
                out.append(Banner(id: "speakers", messages: [Message(text: String(localized: "Speakers updated", comment: "Panel notice title after a recording: the speaker labels were final-checked when the meeting ended; the sentence under it says what that means"),
                                                                     detail: model.speakersUpdatedMeetingID == nil
                                                                         ? String(localized: "Names shown while recording may have changed now that the meeting has ended. Check them in Meetings.",
                                                                                  comment: "Panel notice under “Speakers updated” when the meeting can’t be opened from the notice: the live speaker labels were provisional")
                                                                         : String(localized: "Names shown while recording may have changed now that the meeting has ended.",
                                                                                  comment: "Panel notice under “Speakers updated”, next to the Check Speakers button: the live speaker labels were provisional"))],
                                  style: .info,
                                  fixes: model.speakersUpdatedMeetingID == nil ? [] : [.checkSpeakers]))
            }
            if model.launchAtLoginNeedsApproval {
                out.append(Banner(id: "login", messages: [Message(text: String(localized: "Approve Vauta in System Settings\u{00A0}→\u{00A0}General\u{00A0}→\u{00A0}Login Items & Extensions."))],
                                  fixes: [.openLoginItems]))
            }
            // Each notice has its own "Dismiss", which clears only that notice.
            for index in out.indices where ["save", "error", "stop", "empty", "speakers"].contains(out[index].id) { out[index].dismissible = true }
        }
        return out
    }

    /// A failed save: the title, what to do under it and, when the disk is full, the button that opens Storage.
    private func failureBanner(id: String, _ message: String) -> Banner {
        guard let parts = model.warningParts[message] else { return Banner(id: id, messages: [Message(text: message)]) }
        return Banner(id: id, messages: [Message(text: parts.title, detail: parts.detail, help: model.warningDetails[message])],
                      fixes: parts.isDiskFull ? [.openStorageSettings] : [])
    }

    private var messages: [Message] {
        var out: [Message] = []
        if case .failed(let message) = model.phase {
            // Only a store that did not open is about the encrypted store; a recording that could not start
            // (microphone not allowed, capture error) says what happened as it is.
            if model.storeAvailable {
                out.append(Message(text: String(localized: "Recording didn’t start", comment: "Notification title when a recording could not start"),
                                   detail: message))
            } else {
                // The cause and, after it, what to do.
                out.append(Message(text: String(localized: "Your data couldn’t be opened", comment: "Panel warning title when the store failed to open; the sentence under it is the cause"),
                                   detail: [message, model.storeOpenRecovery].compactMap { $0 }.joinedAsSentences()))
            }
        }
        return out
    }
}
