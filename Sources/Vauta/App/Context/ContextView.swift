// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Settings → Context: people, projects and clients, glossary and recurring
/// meetings. With this context Vauta recognizes names in transcripts and
/// gives the model server the background of each meeting.
struct ContextView: View {
    @Bindable var model: ContextModel

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                // A narrower list in a narrow Settings window, so the editor keeps its room.
                ContextSidebar(model: model)
                    .frame(width: proxy.size.width < 760 ? 250 : 300)
                Divider()
                ContextDetail(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await model.reload() }
        .alert(unsavedTitle, isPresented: isPresent(\.pendingNavigation), presenting: model.pendingNavigation) { navigation in
            Button("Save") { Task { await model.resolve(navigation, save: true) } }
            Button("Don’t Save", role: .destructive) { Task { await model.resolve(navigation, save: false) } }
            Button("Cancel", role: .cancel) { model.pendingNavigation = nil }
        } message: { _ in
            Text("Your changes will be lost if you don’t save them.")
        }
        .sheet(item: $model.mergeRequest) { request in
            MergeSheet(model: model, request: request)
        }
        .sheet(item: $model.deleteRequest) { request in
            DeleteEntitySheet(model: model, request: request)
        }
        .confirmationDialog(termDeleteTitle, isPresented: isPresent(\.termToDelete), presenting: model.termToDelete) { term in
            Button("Delete Term", role: .destructive) { Task { await model.delete(term) } }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { _ in
            Text(SheetFootnote.keepingLastWordsTogether(String(localized: "The term is removed from the glossary. Transcripts don’t change. You can’t undo this.")))
        }
        .confirmationDialog(seriesDeleteTitle, isPresented: isPresent(\.seriesToDelete), presenting: model.seriesToDelete) { series in
            Button("Delete Recurring Meeting", role: .destructive) { Task { await model.delete(series) } }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { _ in
            Text(SheetFootnote.keepingLastWordsTogether(seriesDeleteMessage))
        }
        .alert(model.failure?.title ?? "", isPresented: isPresent(\.failure), presenting: model.failure) { failure in
            if let action = failure.action, let title = failure.actionTitle {
                Button(title) { Task { await model.performFailureAction(action) } }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { failure in
            Text(SheetFootnote.keepingLastWordsTogether([failure.message, failure.recovery].compactMap { $0 }.joined(separator: "\n\n")))
        }
        .alert(reportTitle, isPresented: isPresent(\.reanalysisReport), presenting: model.reanalysisReport) { _ in
            Button("OK", role: .cancel) {}
        } message: { report in
            Text(ReanalysisReportText.message(for: report))
        }
    }

    /// Presents while the optional property is set; dismissing clears it.
    private func isPresent<T>(_ keyPath: ReferenceWritableKeyPath<ContextModel, T?>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] != nil }, set: { if !$0 { model[keyPath: keyPath] = nil } })
    }

    private var unsavedTitle: String {
        let name = model.editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? String(localized: "Do you want to save your changes?", comment: "Prompt before leaving an edited item without a name")
            : String(localized: "Do you want to save the changes to “\(name)”?", comment: "Prompt before leaving an edited item; the argument is its name")
    }

    private var termDeleteTitle: String {
        String(localized: "Delete “\(model.termToDelete?.term ?? "")”?", comment: "Confirmation title; the argument is a glossary term")
    }

    private var seriesDeleteTitle: String {
        String(localized: "Delete “\(model.seriesToDelete?.titlePattern ?? "")”?",
               comment: "Confirmation title; the argument is the title of a recurring meeting")
    }

    private var seriesDeleteMessage: String {
        guard let s = model.seriesToDelete else { return "" }
        let meetings = s.id.flatMap { model.seriesMeetingCounts[$0] } ?? 0
        var parts: [String] = []
        if meetings > 0 {
            parts.append(String(localized: "\(meetings) meetings stay, but are no longer grouped under this recurring meeting.",
                                comment: "Delete confirmation for a recurring meeting; the argument is a count (needs plural forms)"))
        }
        if s.calendarKey != nil {
            parts.append(String(localized: "It comes from your calendar, so Vauta creates it again the next time you record this event.",
                                comment: "Delete confirmation for a recurring meeting created from a calendar event"))
        }
        parts.append(String(localized: "You can’t undo this.", comment: "Last sentence of a delete confirmation"))
        return parts.joinedAsSentences()
    }

    private var reportTitle: String {
        model.reanalysisReport?.state == .cancelled
            ? String(localized: "Finding names stopped", comment: "Alert title after the user cancelled finding the names again in all meetings")
            : String(localized: "Finished finding names", comment: "Alert title after finding the names again in all meetings")
    }
}

/// Text of the alert shown when a re-analysis ends.
enum ReanalysisReportText {
    static func message(for report: ReanalysisProgress) -> String {
        guard report.total > 0 else {
            return String(localized: "There are no meetings with a transcript to search.",
                          comment: "Reanalysis result when no meeting has a transcript")
        }
        var parts: [String] = []
        if report.state == .cancelled {
            parts.append(String(localized: "Stopped after \(report.processed) of \(report.total) meetings.",
                                comment: "Reanalysis result after cancelling; arguments are counts (needs plural forms)"))
        }
        let found = report.found
        // Only what was found: a list of zeros reads like a malfunction.
        var counts: [String] = []
        if found.mentions > 0 {
            counts.append(String(localized: "\(found.mentions) mentions", comment: "Reanalysis result: a count of mentions of known people and projects (needs plural forms)"))
        }
        if found.ambiguous > 0 {
            counts.append(String(localized: "\(found.ambiguous) ambiguous names", comment: "Reanalysis result: a count of names that could be more than one person (needs plural forms)"))
        }
        if found.corrections > 0 {
            counts.append(String(localized: "\(found.corrections) possible recognition errors", comment: "Reanalysis result: a count of words that may have been recognized wrongly (needs plural forms)"))
        }
        if counts.isEmpty {
            parts.append(String(localized: "No new names were found in \(report.analyzed) meetings.",
                                comment: "Reanalysis result when nothing was found; the argument is a count of meetings (needs plural forms)"))
        } else {
            parts.append(String(localized: "Found \(ListFormatter.localizedString(byJoining: counts)) in \(report.analyzed) meetings.",
                                comment: "Reanalysis result; the first argument is a list of counts, e.g. “3 mentions and 1 ambiguous name”; the second is a count of meetings (needs plural forms)"))
        }
        if report.failed > 0 {
            parts.append(String(localized: "Vauta couldn’t search \(report.failed) meetings; they were left as they were.",
                                comment: "Reanalysis result; the argument is a count (needs plural forms)"))
        }
        if found.ambiguous + found.corrections > 0 {
            parts.append(String(localized: "Review them in the “To Review” tab of each meeting.",
                                comment: "Reanalysis result: where to review ambiguous names and recognition errors"))
        }
        return parts.joinedAsSentences()
    }
}
