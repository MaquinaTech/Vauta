// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What Tasks mode shows.
enum TasksPane: String, CaseIterable, Identifiable {
    case open, week
    var id: String { rawValue }
    var label: String {
        switch self {
        case .open: String(localized: "Open Tasks", comment: "Tasks mode: the segment that shows the open tasks")
        case .week: String(localized: "This Week", comment: "Tasks mode: the segment that shows what a week held (meetings, decisions, tasks)")
        }
    }
}

/// This Week, in Tasks mode (`MeetingStore.weekDigest`): what a week of the person's calendar held, read from the store with no
/// model, one week back or forward at a time, and exported as Markdown unless copy protection is on.
extension MeetingsModel {
    func loadWeek() async {
        weekDigest = try? await store.weekDigest(containing: weekShown)
    }

    /// The week before (-1) or after (1) the one shown; never past the current week.
    func moveWeek(by weeks: Int) {
        guard let day = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: weekShown) else { return }
        weekShown = min(day, .now)
        Task { await loadWeek() }
    }

    func showThisWeek() {
        weekShown = .now
        Task { await loadWeek() }
    }

    var showsThisWeek: Bool { Calendar.current.isDate(weekShown, equalTo: .now, toGranularity: .weekOfYear) }

    /// Saves the week as Markdown where the person picks. Refused with copy protection on, like every export.
    func exportWeek() async {
        guard !copyProtected, let digest = weekDigest else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Week", comment: "Save panel title for the This Week export")
        panel.nameFieldStringValue = MeetingExporter.fileName(for: digest.title()) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        do {
            try Data(digest.markdown().utf8).write(to: url, options: .atomic)
        } catch {
            present(String(localized: "Couldn’t export the week", comment: "Alert title: saving the This Week export failed"), error)
        }
    }
}
