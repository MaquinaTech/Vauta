// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Writing exports to a file the user picks, and copying minutes or answers.
/// Files are written only where the user chose in the save panel (the
/// sandbox grants nothing else).
@MainActor
enum MeetingExporter {
    /// Shows the save panel and writes the file. Returns the URL written, or
    /// nil if the user cancelled.
    static func save(_ export: MeetingExport, format: MeetingExportFormat, options: MeetingExportOptions,
                     onRendering: () -> Void = {}) async throws -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Meeting", comment: "Save panel title")
        panel.nameFieldStringValue = fileName(for: export.title) + "." + format.fileExtension
        panel.allowedContentTypes = [contentType(format)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response: NSApplication.ModalResponse
        // The Export sheet may still be animating out (its button dismisses it and starts the export at once):
        // wait for it to detach, so the panel is a sheet of the Meetings window and not a free-floating modal.
        let window = (NSApp.keyWindow ?? NSApp.mainWindow).map { $0.sheetParent ?? $0 }
        for _ in 0..<30 where window?.attachedSheet != nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let window, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        try await write(export, format: format, options: options, to: url, onRendering: onRendering)
        return url
    }

    /// The text formats are rendered and written off the main actor. The PDF text system is main-actor bound, so
    /// `onRendering` lets the window say "Exporting…" and a short pause lets that paint before the main actor is busy.
    static func write(_ export: MeetingExport, format: MeetingExportFormat, options: MeetingExportOptions, to url: URL,
                      onRendering: () -> Void = {}) async throws {
        if format == .pdf {
            onRendering()
            try? await Task.sleep(for: .milliseconds(80))
            try MinutesPDFRenderer.write(export, options: options, to: url)
        } else {
            try await Task.detached(priority: .userInitiated) {
                if let text = format.render(export, options: options) {
                    try Data(text.utf8).write(to: url, options: .atomic)
                }
            }.value
        }
    }

    /// Puts text on the general pasteboard, marked concealed and transient and kept on this Mac (`ProtectedPasteboard`).
    static func copy(_ text: String) {
        ProtectedPasteboard.copy(text)
    }

    static func contentType(_ format: MeetingExportFormat) -> UTType {
        switch format {
        case .pdf: .pdf
        case .json: .json
        case .plainText: .plainText
        default: UTType(filenameExtension: format.fileExtension, conformingTo: .plainText) ?? .plainText
        }
    }

    /// A file name from the meeting title: no path separators or characters
    /// Finder would refuse, at most 100 characters.
    static func fileName(for title: String) -> String {
        let cleaned = SingleLineText.flatten(title)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        let name = String(cleaned.prefix(100))
        return name.isEmpty ? String(localized: "Meeting", comment: "Default export file name") : name
    }
}

extension MeetingsModel {
    /// The meeting on screen as an export (drafts are saved first). A meeting hidden by a search or filter with no
    /// results is not on screen, so it is never exported or copied.
    func loadExport() async -> MeetingExport? {
        guard let id = shownMeeting?.id else { return nil }
        await saveDraft()
        do {
            // The translation the transcript shows is the one exported.
            return try await store.meetingExport(id, translationLanguage: preferences?.translationTarget,
                                                 shownTranslation: id == selectedID ? translationLanguage : nil)
        } catch {
            present(String(localized: "Couldn’t read the meeting", comment: "Alert title"), error)
            return nil
        }
    }

    /// Export… (menu, toolbar): the export sheet, unless copy protection is on.
    func requestExport() {
        guard shownMeeting != nil else { return }
        guard !copyProtected else { alert = .copyProtected; return }
        showingExport = true
    }

    func export(format: MeetingExportFormat, options: MeetingExportOptions) async {
        guard !copyProtected else { alert = .copyProtected; return }
        guard let export = await loadExport() else { return }
        noteActivity()
        do {
            if let url = try await MeetingExporter.save(export, format: format, options: options, onRendering: { [weak self] in
                self?.show(MeetingsNotice(text: String(localized: "Exporting…", comment: "Shown while a meeting is written to a PDF file"), inProgress: true))
            }) {
                show(MeetingsNotice(text: String(localized: "Exported “\(url.lastPathComponent)”", comment: "Confirmation after exporting a meeting; the argument is the file name"),
                                    symbol: StatusSymbol.ok.name, reveal: url))
            } else if notice?.inProgress == true {
                dismissNotice()
            }
        } catch {
            dismissNotice()
            alert = .exportFailure(error) { [weak self] in await self?.export(format: format, options: options) }
        }
    }

    /// Copies the minutes (without the transcript) as Markdown or plain text.
    func copyMinutes(asMarkdown: Bool) async {
        guard !copyProtected else { alert = .copyProtected; return }
        guard let export = await loadExport() else { return }
        let options = MeetingExportOptions(includeTranscript: false)
        MeetingExporter.copy(asMarkdown ? MeetingExportRenderer.markdown(export, options: options)
                                        : MeetingExportRenderer.plainText(export, options: options))
        show(.copied)
    }

    /// Shows a confirmation and announces it to VoiceOver. A plain confirmation goes after a few seconds; a notice
    /// with an action (Show in Finder) stays until it is dismissed or another meeting is selected, so keyboard and
    /// VoiceOver users always have time to reach its button.
    func show(_ notice: MeetingsNotice) {
        self.notice = notice
        AccessibilityNotification.Announcement(notice.text).post()
        noticeTask?.cancel()
        guard notice.reveal == nil, !notice.inProgress else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }
}

/// A confirmation shown over the Meetings window.
struct MeetingsNotice: Equatable {
    let text: String
    var symbol = StatusSymbol.ok.name
    /// A file to show in Finder.
    var reveal: URL?
    /// Work that is still running: a spinner instead of the success mark, and it stays until the result replaces it.
    var inProgress = false

    /// Notices that stay until replaced or dismissed live in the bottom bar; only a passing one floats.
    var inBar: Bool { reveal != nil || inProgress }

    static var copied: MeetingsNotice {
        MeetingsNotice(text: String(localized: "Copied", comment: "Confirmation after copying minutes or an answer"))
    }
}

/// The height of the bars under the sidebar list and under the detail pane (the retention note and the
/// persistent notice), so their dividers line up across the window.
enum MeetingsBottomBar {
    static let height: CGFloat = 34
}

struct MeetingsNoticeBanner: View {
    let notice: MeetingsNotice
    let dismiss: () -> Void
    /// In the bottom bar the notice is a plain row; a passing notice floats as a capsule.
    var inBar = false

    var body: some View {
        HStack(spacing: 8) {
            if notice.inProgress {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            } else {
                Image(systemName: notice.symbol).foregroundStyle(StatusSymbol.ok.color).accessibilityHidden(true)
            }
            Text(notice.text).lineLimit(1).truncationMode(.middle)
            if inBar { Spacer(minLength: 8) }
            if let url = notice.reveal {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .controlSize(.small)
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Dismiss")
                    .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, inBar ? 0 : 14)
        .padding(.vertical, inBar ? 0 : 8)
        .background {
            // The shadow belongs to the capsule alone: on the whole row it would draw a box around the text.
            if !inBar { Capsule().fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.2), radius: 8, y: 2) }
        }
        .overlay { if !inBar { Capsule().strokeBorder(.separator) } }
        .accessibilityElement(children: .contain)
        .modifier(RevealAction(url: notice.reveal))
    }
}

/// VoiceOver's "Show in Finder" action, only when the notice has a file.
private struct RevealAction: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.accessibilityAction(named: Text("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } else {
            content
        }
    }
}
