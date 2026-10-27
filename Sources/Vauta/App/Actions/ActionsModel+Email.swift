// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import VautaCore

/// The follow-up email draft: a fixed template filled from the stored minutes (no model writes any of it), built on demand and kept in
/// memory. Vauta never sends: it hands the text to the person's mail app, the share menu or the clipboard.
extension ActionsModel {
    static let emailLanguages = ["en", "es", "fr", "de", "it", "pt-BR", "ja", "ko", "zh-Hans"]

    /// The language the email starts in: the minutes' language, else the transcription's, else the app's.
    static func defaultEmailLocale(minutes: String?, transcription: String?) -> Locale {
        FollowUpEmail.language(minutes: minutes, transcription: transcription)
    }

    /// The picker's choice for a locale: one of the nine languages, English for any other.
    static func languageID(for locale: Locale) -> String {
        switch locale.language.languageCode?.identifier ?? "en" {
        case "pt": "pt-BR"
        case "zh": "zh-Hans"
        case let code: emailLanguages.contains(code) ? code : "en"
        }
    }

    func loadEmailInput() async {
        guard emailDraftAvailable, let current = sheet else { return }
        let id = current.meeting.id
        let stored = try? await store.meeting(id)
        let locale = Self.defaultEmailLocale(minutes: stored?.outputLocale, transcription: stored?.transcriptionLocale.identifier)
        var email = EmailState()
        email.languageID = Self.languageID(for: locale)
        email.options = FollowUpEmailOptions(locale: locale, mode: preferences.emailMode, includeSummary: preferences.emailSummary,
                                             includeOpenQuestions: preferences.emailOpenQuestions, includeUnconfirmed: preferences.emailUnconfirmed)
        email.recipients = (try? await store.followUpRecipients(id)) ?? EmailRecipients(recipients: [], selfDomainKnown: false)
        email.summaryOffered = FollowUpEmailSummary.isOffered(backend: backend())
        if !email.summaryOffered { email.options.includeSummary = false }
        sheet?.email = email
        await rebuildEmail()
    }

    /// The drafts again, from the stored fields and the options. "Next meeting" appears only for a follow-up the person added.
    func rebuildEmail() async {
        guard var current = sheet else { return }
        let next = current.followUps.first { $0.state == .done && $0.day != nil }
        let nextMeeting = next.flatMap { f in f.day.map { FollowUpEmailInput.NextMeeting(day: $0, minuteOfDay: f.minuteOfDay) } }
        guard let input = try? await store.followUpEmailInput(current.meeting.id, nextMeeting: nextMeeting) else { return }
        current.email.input = input
        current.email.drafts = FollowUpEmail.drafts(input, options: current.email.options)
        if current.email.selectedDraft == nil || !current.email.drafts.contains(where: { $0.id == current.email.selectedDraft }) {
            current.email.selectedDraft = current.email.drafts.first?.id
        }
        // Addresses ticked for a draft that no longer exists are dropped.
        let ids = Set(current.email.drafts.map(\.id))
        current.email.ticked = current.email.ticked.filter { ids.contains($0.key) }
        sheet?.email = current.email
    }

    func setEmailMode(_ mode: FollowUpEmailOptions.Mode) async {
        preferences.emailMode = mode
        sheet?.email.options.mode = mode
        sheet?.email.selectedDraft = nil
        await rebuildEmail()
    }

    func setEmailLocale(_ identifier: String) async {
        sheet?.email.languageID = identifier
        sheet?.email.options.locale = Locale(identifier: identifier)
        await rebuildEmail()
    }

    func setEmailSummary(_ on: Bool) async {
        preferences.emailSummary = on
        sheet?.email.options.includeSummary = on && (sheet?.email.summaryOffered ?? false)
        await rebuildEmail()
    }

    func setEmailOpenQuestions(_ on: Bool) async {
        preferences.emailOpenQuestions = on
        sheet?.email.options.includeOpenQuestions = on
        await rebuildEmail()
    }

    func setEmailUnconfirmed(_ on: Bool) async {
        preferences.emailUnconfirmed = on
        sheet?.email.options.includeUnconfirmed = on
        await rebuildEmail()
    }

    func selectDraft(_ id: String) { sheet?.email.selectedDraft = id }

    func toggleRecipient(_ recipient: EmailRecipient, draft: FollowUpEmailDraft) {
        guard sheet != nil else { return }
        var picked = sheet?.email.ticked[draft.id] ?? []
        if picked.contains(recipient.entityID) { picked.remove(recipient.entityID) } else { picked.insert(recipient.entityID) }
        sheet?.email.ticked[draft.id] = picked
    }

    // MARK: Handing the draft over (blocked by copy protection, as Export is)

    /// "Open in Mail": the person's mail app composes it. Nothing is sent by Vauta.
    func openInMail(_ draft: FollowUpEmailDraft) {
        guard ActionCopyPolicy.emailAllowed(copyProtection: copyProtected), let email = sheet?.email else { return }
        let addresses = email.chosen(for: draft).map(\.email)
        MailHandoffOpener.open(subject: draft.subject, body: draft.plainText, recipients: addresses)
    }

    /// "Copy" (Shift: Markdown): marked concealed and transient and kept on this Mac.
    func copyEmail(_ draft: FollowUpEmailDraft, markdown: Bool) {
        guard ActionCopyPolicy.emailAllowed(copyProtection: copyProtected) else { return }
        ProtectedPasteboard.copy(markdown ? draft.markdown : draft.plainText)
        host?.show(.copied)
    }

    /// The email is too long for a `mailto:` link: Open in Mail copies it and says so.
    func needsCopyAndOpen(_ draft: FollowUpEmailDraft) -> Bool {
        guard let email = sheet?.email else { return false }
        if case .copyAndOpen = MailHandoff.plan(to: email.chosen(for: draft).map(\.email), subject: draft.subject, body: draft.plainText) { return true }
        return false
    }
}
