// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI
import VautaCore

/// The follow-up email: a preview of the fixed template filled from the minutes, who it goes to (nobody ticked), and how it leaves
/// Vauta: the person's mail app, the share menu or the clipboard. Vauta never sends it. With copy protection on, the buttons are off, as
/// Export is, and the preview stays readable.
struct EmailDraftView: View {
    @Bindable var actions: ActionsModel
    let state: EmailState
    /// Copy protection is on.
    let locked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Email draft", comment: "Heading of the email section of the Follow-up sheet").font(.headline).accessibilityAddTraits(.isHeader)
            options
            if let draft = state.current, draft.hasContent {
                if state.drafts.count > 1 { ownerPicker }
                preview(draft)
                recipients(draft)
                buttons(draft)
            } else {
                Text("There are no decisions or next steps to send yet.", comment: "Follow-up sheet: the minutes have nothing for the email").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Side by side when they fit; stacked when a long translation would push them past the sheet's width.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { modePicker; languagePicker }
                VStack(alignment: .leading, spacing: 8) { modePicker; languagePicker }
            }
            if state.summaryOffered {
                Toggle("Include the summary", isOn: Binding(get: { state.options.includeSummary }, set: { on in Task { await actions.setEmailSummary(on) } }))
                    .toggleStyle(.checkbox)
            }
            // A per-owner draft holds only that person's next steps, so there is nothing for this switch to do there.
            if state.options.mode == .one {
                Toggle("Include open questions", isOn: Binding(get: { state.options.includeOpenQuestions }, set: { on in Task { await actions.setEmailOpenQuestions(on) } }))
                    .toggleStyle(.checkbox)
            }
            Toggle("Include unconfirmed items", isOn: Binding(get: { state.options.includeUnconfirmed }, set: { on in Task { await actions.setEmailUnconfirmed(on) } }))
                .toggleStyle(.checkbox)
        }
    }

    private var modePicker: some View {
        Picker("Email", selection: Binding(get: { state.options.mode }, set: { mode in Task { await actions.setEmailMode(mode) } })) {
            Text("One email").tag(FollowUpEmailOptions.Mode.one)
            Text("One per owner").tag(FollowUpEmailOptions.Mode.perOwner)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var languagePicker: some View {
        Picker("Language", selection: Binding(get: { state.languageID }, set: { id in Task { await actions.setEmailLocale(id) } })) {
            ForEach(ActionsModel.emailLanguages, id: \.self) { id in
                Text(verbatim: Locale.current.localizedString(forIdentifier: id)?.localizedCapitalized ?? id).tag(id)
            }
        }
        .fixedSize()
    }

    private var ownerPicker: some View {
        Picker("Draft", selection: Binding(get: { state.current?.id ?? "" }, set: { actions.selectDraft($0) })) {
            ForEach(state.drafts) { draft in Text(verbatim: draft.ownerName ?? draft.subject).tag(draft.id) }
        }
        .fixedSize()
    }

    // MARK: Preview

    private func preview(_ draft: FollowUpEmailDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Subject", comment: "Follow-up sheet: label of the email's subject line").foregroundStyle(.secondary)
                ProtectedText(draft.subject).fontWeight(.medium).lineLimit(2)
            }
            Divider()
            ProtectedText(draft.plainText)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Email preview", comment: "VoiceOver: the preview of the follow-up email"))
    }

    // MARK: Recipients

    @ViewBuilder private func recipients(_ draft: FollowUpEmailDraft) -> some View {
        let list = state.candidates(for: draft)
        VStack(alignment: .leading, spacing: 6) {
            Text("To", comment: "Follow-up sheet: label of the email's recipients").font(.subheadline.weight(.semibold))
            if list.isEmpty {
                Text("No addresses known for the attendees. Add them in your mail app.", comment: "Follow-up sheet: no attendee has a stored address").foregroundStyle(.secondary)
            } else {
                ForEach(list) { recipient in
                    Toggle(isOn: Binding(get: { state.ticked[draft.id]?.contains(recipient.entityID) == true },
                                         set: { _ in actions.toggleRecipient(recipient, draft: draft) })) {
                        HStack(spacing: 6) {
                            Text(verbatim: recipient.name).lineLimit(1).truncationMode(.middle)
                            Text(verbatim: recipient.email).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if recipient.isExternal {
                                Label { Text("External", comment: "Follow-up sheet: the address is outside the person's own organization") } icon: { Image(systemName: "person.badge.shield.exclamationmark") }
                                    .font(.callout).foregroundStyle(.orange).fixedSize()
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(locked)
                }
                if !state.recipients.selfDomainKnown {
                    Text("Vauta can’t tell which addresses are outside your organization: your own address isn’t saved in Context.", comment: "Follow-up sheet: External can't be marked because the person's own address is unknown")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Buttons

    @ViewBuilder private func buttons(_ draft: FollowUpEmailDraft) -> some View {
        let chosen = state.chosen(for: draft)
        let copyAndOpen = actions.needsCopyAndOpen(draft)
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { mailButton(draft, copyAndOpen: copyAndOpen, chosen: chosen.count); ShareLink(item: draft.plainText, subject: Text(verbatim: draft.subject)) { Text("Share…") }; copyButton(draft) }
                VStack(alignment: .leading, spacing: 8) {
                    mailButton(draft, copyAndOpen: copyAndOpen, chosen: chosen.count)
                    HStack(spacing: 10) { ShareLink(item: draft.plainText, subject: Text(verbatim: draft.subject)) { Text("Share…") }; copyButton(draft) }
                }
            }
            .disabled(locked)
            if locked {
                NoticeLabel(Text(MeetingsAlert.copyProtected.message), status: .info, secondary: true)
            } else if copyAndOpen {
                Text("This email is too long for a link, so Vauta copies it and opens Mail.", comment: "Follow-up sheet: why the button says Copy and Open Mail")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Your mail app may save the draft to your mail server before you send it.", comment: "Follow-up sheet: a mail app may keep a draft on its server")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mailButton(_ draft: FollowUpEmailDraft, copyAndOpen: Bool, chosen: Int) -> some View {
        let button = Button { actions.openInMail(draft) } label: {
            if copyAndOpen { Text("Copy and Open Mail") }
            else if chosen == 0 { Text("Open in Mail · no recipients") }
            else { Text("Open in Mail · \(chosen) recipients", comment: "Follow-up sheet button; the argument is how many addresses are ticked") }
        }
        // With copy protection on, nothing here can act: the default button loses its accent too, so all three read as unavailable.
        return Group {
            if locked { button.buttonStyle(.bordered) } else { button.buttonStyle(.borderedProminent) }
        }
    }

    private func copyButton(_ draft: FollowUpEmailDraft) -> some View {
        Button("Copy") { actions.copyEmail(draft, markdown: NSEvent.modifierFlags.contains(.shift)) }
            .help(Text("Copy as plain text. Hold Shift to copy as Markdown.", comment: "Help of the Copy button of the email draft"))
    }
}
