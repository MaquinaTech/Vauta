// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The state of the meeting's minutes written by the model: queued, being
/// written (stage, elapsed time, Cancel), failed (what to do, Try Again),
/// no model (why, and how to set one up) or done, and a Write/Rewrite button
/// with a template menu.
struct MinutesStatusBar: View {
    let model: MeetingsModel
    let recorder: RecorderModel
    let meeting: MeetingStore.Meeting
    @AppStorage("basicQualityHintDismissed") private var hintDismissed = false
    @Environment(\.openModelsSettings) private var openModels
    @Environment(\.openModelGuide) private var openGuide

    /// The card under the row is on screen (it names the provider and quality itself).
    private var showsQualityCard: Bool { !hintDismissed && (openGuide ?? openModels) != nil }

    /// The fixed column of the leading glyph, so the text starts at the same x in every state.
    private func glyph<G: View>(@ViewBuilder _ content: () -> G) -> some View {
        content().frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
    }

    /// The row shows a problem (no model, or the minutes failed) rather than a status.
    private var isWarning: Bool {
        let status = recorder.llmStatus
        let running = status.activityMeeting == meeting.id && status.activity != nil
        let pending = model.jobs.contains { $0.kind == .minutes && ($0.state == .queued || $0.state == .running) }
        let failed = model.jobs.contains { $0.kind == .minutes && $0.state == .failed }
        if running || pending { return false }
        if model.activeMeetingID == meeting.id, status.configured { return false }
        return !status.configured || failed
    }

    var body: some View {
        let status = recorder.llmStatus
        let running = status.activityMeeting == meeting.id && status.activity != nil
        let pending = model.jobs.first { $0.kind == .minutes && ($0.state == .queued || $0.state == .running) }
        let failed = model.jobs.first { $0.kind == .minutes && $0.state == .failed }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if running {
                    // One kind of indicator: the spinner while the stage is unknown, the bar once the model reports how far it has read.
                    // The bar is the indicator once the model reports how far it has read: no empty slot before the text then.
                    if MinutesActivity.fraction(status) == nil { glyph { ThinkingOrb() } }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(runningText(status, now: AppClock.now)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let fraction = MinutesActivity.fraction(status) {
                        // Only the integrated model knows how far it has read; the others keep the indeterminate spinner.
                        ProgressView(value: fraction)
                            .frame(width: 90)
                            .accessibilityLabel(Text("Minutes progress", comment: "Accessibility label of the progress bar while the model reads the transcript"))
                            .accessibilityValue(Text(MinutesActivity.spoken(fraction: fraction)))
                    }
                    Spacer()
                    Button("Cancel") { Task { await model.cancelMinutes() } }
                        .controlSize(.small)
                        .help("Stop writing the minutes")
                } else if model.activeMeetingID == meeting.id, status.configured {
                    // Recording: the minutes come at the end, whatever was proposed before.
                    glyph { Image(systemName: "clock").foregroundStyle(.secondary) }
                    Text("Minutes are written when the recording ends").foregroundStyle(.secondary)
                    Spacer()
                } else if pending != nil {
                    glyph { Image(systemName: "clock").foregroundStyle(.secondary) }
                    Text(recorder.isRecording ? "Minutes queued: they’ll be written when the recording ends"
                                              : "Minutes queued: waiting for the model")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { Task { await model.cancelMinutes() } }
                        .controlSize(.small)
                } else if !status.configured {
                    glyph { StatusSymbol.warning.image }
                    let parts = AskView.unavailableParts(status)
                    // The same two buttons as Status: the guide, and the pane itself.
                    NoticeText(title: parts.title, detail: parts.detail) { ModelSetUpButtons() }
                } else if let failed {
                    failedRow(failed)
                } else if model.cardSource == "llm" {
                    llmStatusRow(status)
                } else {
                    if canWrite {
                        glyph { Image(systemName: "text.badge.plus").foregroundStyle(.secondary) }
                        Text(model.cardSource == "user" ? "You wrote these minutes. The model can add proposed decisions and tasks."
                                                        : "No minutes yet. The model can propose a summary, decisions and tasks.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if canWrite { writeButton(retry: false) }
                }
            }
            .font(.callout)
            // The height of a row with a small button, so the title doesn't move between states.
            .frame(minHeight: 22)
            // A warning is a tinted card, like the panel's; the plain rows have no inset on either side.
            .noticeCard(tint: .orange, enabled: isWarning)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Minutes status"))
            if model.cardSource == "llm", status.chatProvider == .onDevice, !running {
                BasicQualityHint(controlSize: .small)
                    .font(.callout)
            }
        }
    }

    /// The caveat on the model's minutes, worded the same for every model; the basic on-device model adds its badge
    /// before the text.
    private func llmStatusRow(_ status: LLMService.Status) -> some View {
        let onDevice = status.chatProvider == .onDevice
        // The basic on-device model is always named here: the setup card doesn't name it. Two whole sentences, since
        // the wording around the name differs between languages.
        let text = Text(onDevice ? "Minutes proposed by Apple Intelligence: review them and correct anything that’s wrong."
                                 : "Minutes proposed by the model: review them and correct anything that’s wrong.").foregroundStyle(.secondary)
        let glyphView = glyph { Image(systemName: "sparkles").foregroundStyle(Brand.sparkle) }
        let writer: AnyView = canWrite ? AnyView(writeButton(retry: false)) : AnyView(EmptyView())
        // A template the person wrote is not evaluated as Vauta's are: the minutes it wrote say so, with its name in the tooltip.
        let custom = model.cardFollowedCustomTemplate
        // One layout at every width and in every language: the badges sit on a line of their own and the sentence
        // under them takes the room up to the button.
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            glyphView
            VStack(alignment: .leading, spacing: 4) {
                if onDevice || custom.followed {
                    HStack(spacing: 6) {
                        if onDevice { BadgeCapsule(ModelQuality.badge).fixedSize() }
                        if custom.followed { BadgeCapsule(CustomMinutesTemplate.label).fixedSize().help(custom.name ?? "") }
                    }
                }
                text.fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            writer
        }
    }

    /// The same callout as Ask's failure: the glyph, the problem as the title with the buttons on its line, and what
    /// to do (or the reason) under it.
    private func failedRow(_ failed: LLMJob) -> some View {
        let tooLong = failed.errorCode == .contextLengthExceeded
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            glyph { StatusSymbol.warning.image }
            NoticeText(title: Self.failureTitle(failed),
                       detail: tooLong ? String(localized: "Set the context length to 32K in your model server app.") : failed.lastError.flatMap { $0.isEmpty ? nil : $0 }) {
                HStack(spacing: 6) {
                    // Try Again first, then where the cause is fixed, in the same order as Ask's failure. The server
                    // may be the problem: the Models pane is where it is checked.
                    if canWrite { writeButton(retry: true) }
                    if tooLong {
                        ModelSetUpButtons(onlyGuide: true)
                    } else if let models = openModels {
                        Button(SettingsModel.Pane.models.openTitle) { models() }.controlSize(.small)
                    }
                }
            }
        }
    }

    /// The model can write now: one is set up, there is a transcript and the meeting is over.
    private var canWrite: Bool {
        let status = recorder.llmStatus
        let running = status.activityMeeting == meeting.id && status.activity != nil
        let pending = model.jobs.contains { $0.kind == .minutes && ($0.state == .queued || $0.state == .running) }
        return status.configured && !running && !pending && !model.transcript.isEmpty && model.activeMeetingID != meeting.id
    }

    private static func failureTitle(_ job: LLMJob) -> String {
        if job.errorCode == .contextLengthExceeded {
            return String(localized: "This meeting is too long for the model’s current settings.",
                          comment: "Minutes failed: the transcript doesn't fit the model's context length")
        }
        return String(localized: "The minutes couldn’t be written", comment: "Minutes failed: title of the notice; the reason is its detail")
    }

    /// "Rewrite Minutes" (or "Try Again" after a failure) with the meeting's template; the menu picks another.
    private func writeButton(retry: Bool) -> some View {
        Menu {
            // Minutes written with the general template, of a meeting whose title points to another one: that one first.
            if let suggested = suggestedTemplate {
                Section(String(localized: "Suggested by the Title", comment: "Minutes menu: the section with the template the meeting's title suggests")) {
                    Button(suggested.displayName) { Task { await model.regenerateMinutes(template: .builtIn(suggested)) } }
                }
            }
            Section("Template") {
                ForEach(MinutesTemplate.allCases) { template in
                    Button(template.displayName) { Task { await model.regenerateMinutes(template: .builtIn(template)) } }
                }
            }
            if !model.customTemplates.isEmpty {
                Section(CustomMinutesTemplate.label) {
                    ForEach(model.customTemplates) { template in
                        Button(template.name) { Task { await model.regenerateMinutes(template: .custom(template.id)) } }
                    }
                }
            }
            if let models = openModels {
                Divider()
                Button(String(localized: "Edit Templates…", comment: "Minutes menu: opens Settings → Models, where the person writes their own minutes templates")) { models() }
            }
        } label: {
            if retry { Text("Try Again") }
            else if model.cardSource == "user" { Text("Propose Decisions and Tasks") }
            else { Text(model.cardSource == "llm" ? "Rewrite Minutes" : "Write Minutes") }
        } primaryAction: {
            Task { await model.regenerateMinutes() }
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help(model.cardSource == "user"
              ? "Your summary is kept; proposed decisions and tasks are added"
              : "The model writes the summary, decisions and tasks, citing the transcript. Choose a template from the menu.")
    }

    /// The template the meeting's title suggests, when its minutes use the general one.
    private var suggestedTemplate: MinutesTemplate? {
        guard (model.minutesTemplate ?? .general) == .general, let title = meeting.title,
              let suggested = MinutesTemplate.suggested(forTitle: title), suggested != .general else { return nil }
        return suggested
    }

    private func runningText(_ s: LLMService.Status, now: Date) -> String {
        MinutesActivity.text(s, now: now)
    }
}

/// "Set Up…" opens the guide sheet; "Show Models Pane" goes to the pane. Each label has one destination.
/// `onlyGuide` leaves out "Show Models Pane" (the guide already leads there) unless there is no guide.
struct ModelSetUpButtons: View {
    var onlyGuide = false
    /// Opens the Models pane when the window gave no environment actions.
    var fallback: (() -> Void)?
    @Environment(\.openModelGuide) private var openGuide
    @Environment(\.openModelsSettings) private var openModels

    var body: some View {
        HStack(spacing: 6) {
            if let guide = openGuide { Button("Set Up…") { guide() }.controlSize(.small) }
            if let models = openModels ?? fallback, !(onlyGuide && openGuide != nil) {
                Button(SettingsModel.Pane.models.openTitle) { models() }.controlSize(.small)
            }
        }
    }
}

extension View {
    /// A notice as a tinted card (the same for the minutes' problems and for Ask's missing model).
    /// Disabled, the content keeps its place and only loses the card.
    func noticeCard(tint: Color, enabled: Bool = true) -> some View {
        self
            .padding(.horizontal, enabled ? 12 : 0)
            .padding(.vertical, enabled ? 10 : 0)
            .background(enabled ? tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: CardStyle.radius))
    }
}
