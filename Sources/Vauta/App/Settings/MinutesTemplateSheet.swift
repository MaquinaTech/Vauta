// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Settings → Models → Minutes: the templates the person wrote, each with Edit…, and Add Template…. Locked, the names wait for
/// Touch ID, as the saved voices' do.
struct CustomTemplateRows: View {
    let recorder: RecorderModel
    @Bindable var templates: MinutesTemplatesModel

    var body: some View {
        if recorder.historyUnlocked {
            LabeledContent {
                Button(String(localized: "Add Template…", comment: "Settings → Models; button that opens the editor for a new minutes template the person writes")) { templates.add() }
            } label: {
                Self.title
                Text(description: String(localized: "Say in your own words what the minutes should cover and stress. Unlike Vauta’s own templates, these aren’t evaluated.",
                                         comment: "Settings → Models; under Your templates"))
            }
            .sheet(item: $templates.editing) { _ in MinutesTemplateSheet(recorder: recorder, templates: templates) }
            ForEach(templates.templates) { template in
                LabeledContent {
                    Button("Edit…") { templates.edit(template) }
                        .accessibilityLabel(Text("Edit the template \(template.name)", comment: "VoiceOver: opens the editor of a minutes template the person wrote; the argument is its name"))
                } label: {
                    Text(verbatim: template.name)
                    Text(description: Self.firstLine(template.instructions))
                }
            }
            if let failure = templates.failure { NoticeLabel(Text(verbatim: failure), status: .warning) }
        } else {
            LabeledContent {
                Button("Unlock…") { Task { _ = await recorder.authorizeHistory() } }
            } label: {
                Self.title
                Text(description: String(localized: "Unlock with Touch ID or your password to see and edit the templates you wrote.",
                                         comment: "Settings → Models, under Your templates while Meetings are locked"))
            }
        }
    }

    private static var title: Text {
        Text("Your templates", comment: "Settings → Models; the row of the minutes templates the person wrote")
    }

    /// The start of the instructions, on one line, under the template's name.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }
}

/// The editor of a template the person writes: its name, what the minutes should cover, and what a template can't change.
struct MinutesTemplateSheet: View {
    let recorder: RecorderModel
    @Bindable var templates: MinutesTemplatesModel
    @FocusState private var focus: Field?

    private enum Field { case name, instructions }

    var body: some View {
        if let draft = Binding($templates.editing) { content(draft) }
    }

    private func content(_ draft: Binding<MinutesTemplateDraft>) -> some View {
        let isNew = draft.wrappedValue.templateID == nil
        return VStack(alignment: .leading, spacing: 16) {
            SheetHeader(isNew ? Text("New Template", comment: "Title of the sheet for a new minutes template the person writes")
                              : Text("Edit Template", comment: "Title of the sheet that edits a minutes template the person wrote"),
                        symbol: "doc.text")
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Name")
                        TextField(text: draft.name, prompt: Text("Product review", comment: "Placeholder of the name of a minutes template the person writes")) { Text("Name") }
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .name)
                    }
                }
                Text("What the minutes should cover", comment: "Label above the instructions of a minutes template the person writes")
                instructions(draft)
                HStack(alignment: .firstTextBaseline) {
                    BadgeCapsule(CustomMinutesTemplate.label).fixedSize()
                    Spacer()
                    let count = draft.wrappedValue.instructions.count
                    Text(verbatim: "\(count.formatted()) / \(CustomMinutesTemplate.instructionsLimit.formatted())")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("\(count) of \(CustomMinutesTemplate.instructionsLimit) characters",
                                                 comment: "VoiceOver: how long the instructions of a minutes template are, of the most they can be"))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            VStack(alignment: .leading, spacing: 6) {
                SettingsNote(String(localized: "The minutes keep their sections, and every decision and task is still checked against the transcript: a template says what to cover and stress, not what to conclude.",
                                    comment: "Minutes template editor: what a template the person writes can and can't change"))
                SettingsNote(String(localized: "Apple Intelligence and other models with a small context read only the first 600 characters or so.",
                                    comment: "Minutes template editor: small models read only the start of a long template"))
            }
            if let failure = draft.wrappedValue.failure { NoticeLabel(Text(verbatim: failure), status: .warning) }
            HStack {
                if let id = draft.wrappedValue.templateID, let template = templates.templates.first(where: { $0.id == id }) {
                    Button(String(localized: "Delete Template…", comment: "Minutes template editor; button that opens the confirmation to delete the template"),
                           role: .destructive) { templates.pendingDelete = template }
                }
                Spacer()
                Button("Cancel", role: .cancel) { templates.editing = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await templates.save(recorder) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.wrappedValue.canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { focus = isNew ? .name : .instructions }
        // Typing here is activity, as in Meetings: it postpones the automatic lock.
        .onChange(of: draft.wrappedValue.name) { _, name in
            recorder.touchHistory()
            if name.count > CustomMinutesTemplate.nameLimit { draft.wrappedValue.name = String(name.prefix(CustomMinutesTemplate.nameLimit)) }
        }
        .onChange(of: draft.wrappedValue.instructions) { _, text in
            recorder.touchHistory()
            if text.count > CustomMinutesTemplate.instructionsLimit {
                draft.wrappedValue.instructions = String(text.prefix(CustomMinutesTemplate.instructionsLimit))
            }
        }
        .confirmationDialog(templates.pendingDelete.map { String(localized: "Delete the template “\($0.name)”?", comment: "Confirmation title; the argument is the name of a minutes template the person wrote") } ?? "",
                            isPresented: Binding(get: { templates.pendingDelete != nil }, set: { if !$0 { templates.pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: templates.pendingDelete) { template in
            Button(String(localized: "Delete Template", comment: "Confirm button: delete a minutes template the person wrote"), role: .destructive) {
                Task { await templates.delete(template, recorder) }
            }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("Minutes already written stay as they are. Recurring meetings that use it go back to the default template, and if it’s the default, “General meeting” becomes the default.",
                 comment: "Confirmation message when deleting a minutes template the person wrote")
        }
    }

    private func instructions(_ draft: Binding<MinutesTemplateDraft>) -> some View {
        TextEditor(text: draft.instructions)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: 180)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .overlay(alignment: .topLeading) {
                if draft.wrappedValue.instructions.isEmpty {
                    Text("For example: the feature requests, who asked for each and why; the bugs, with how serious they are; and what the team will look at next.",
                         comment: "Placeholder of the instructions of a minutes template the person writes")
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused($focus, equals: .instructions)
            .accessibilityLabel(Text("What the minutes should cover", comment: "Label above the instructions of a minutes template the person writes"))
    }
}
