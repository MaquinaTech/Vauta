// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI
import VautaCore

/// In a source's row: a calm line that says how many of the skipped files are not on this Mac (Google Drive shortcuts, and files a cloud
/// service keeps online only), with a help button. It is a part of the "N skipped" link above it, so it names the group and not the
/// skipped count again. Nothing when there are none. Vauta never downloads a file or contacts an online service by itself.
struct CloudFilesLine: View {
    let counts: DocumentSourceCounts
    let help: () -> Void

    private var total: Int { counts.notOnThisMac }
    private var online: Int { counts.onlineOnly + counts.onlineOnlyFolders }

    var body: some View {
        if total > 0 {
            HStack(spacing: 6) {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary).accessibilityHidden(true)
                text
                Button(action: help) { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .help(Text("How to add these files", comment: "Documents pane: help button of the line that counts skipped Google Drive shortcuts and files not downloaded; it opens an explanation"))
                    .accessibilityLabel(Text("How to add these files", comment: "Documents pane: help button of the line that counts skipped Google Drive shortcuts and files not downloaded; it opens an explanation"))
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder private var text: some View {
        Group {
            if counts.googleShortcuts > 0 && online > 0 {
                Text("Not on this Mac: \(total) (Google Drive shortcuts or not downloaded)", comment: "Documents pane: under a source; how many of its skipped files are not on this Mac because they are Google Drive shortcuts (Docs, Sheets or Slides) or are kept online by a cloud service; the argument is the number, which is part of the skipped count")
            } else if counts.googleShortcuts > 0 {
                Text("Not on this Mac: \(total) (Google Drive shortcuts)", comment: "Documents pane: under a source; how many of its skipped files are not on this Mac because they are Google Drive shortcuts (Docs, Sheets or Slides); the argument is the number, which is part of the skipped count")
            } else {
                Text("Not on this Mac: \(total) (not downloaded)", comment: "Documents pane: under a source; how many of its skipped files are not on this Mac because a cloud service keeps them online and the Mac holds only a placeholder; the argument is the number, which is part of the skipped count")
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// What to do about files the Mac does not hold, in plain words. Only the parts that apply to the source are shown.
struct CloudFilesHelpSheet: View {
    let googleShortcuts: Int
    let onlineOnly: Int
    /// Whole folders that were skipped (nothing inside was read).
    var folders = 0
    let sourceName: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(Text("Files this Mac doesn’t hold", comment: "Documents: title of the sheet that explains skipped Google Drive shortcuts and files not downloaded"),
                        message: Text(verbatim: sourceName), symbol: "icloud.slash")
            if googleShortcuts > 0 {
                section(Text("Google Drive shortcuts skipped: \(googleShortcuts)", comment: "Documents pane: how many Google Docs, Sheets or Slides shortcut files were skipped; the argument is the number"),
                        Text("A Google Drive shortcut file (Docs, Sheets or Slides) only points to a document online, so Vauta can’t read it. Download the document from Google as PDF, Word, Markdown, Excel or PowerPoint, and keep the copies in a folder on this Mac that you add here.",
                             comment: "Documents pane: what to do about Google Drive shortcut files; the folder must be on this Mac, because a folder of streamed Google Drive files would hold placeholders again"))
            }
            if onlineOnly > 0 || folders > 0 {
                // One explanation for the files and the folders: it is the same fix.
                VStack(alignment: .leading, spacing: 4) {
                    if onlineOnly > 0 {
                        Text("Files kept online only, skipped: \(onlineOnly)", comment: "Documents pane: how many files were skipped because a cloud service keeps them online and this Mac holds only a placeholder; the argument is the number").fontWeight(.medium)
                    }
                    if folders > 0 {
                        Text("Folders kept online only, skipped: \(folders)", comment: "Documents pane: how many whole folders were skipped because a cloud service keeps them online and this Mac holds only a placeholder, so nothing inside them was read; the argument is the number").fontWeight(.medium)
                    }
                    onlineNote.font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var onlineNote: Text {
        Text("This Mac holds only a placeholder for files and folders kept online only. The skipped files list shows which ones. In Finder, Control-click one and choose Download Now, or set the folder to stay downloaded (in iCloud Drive: keep downloaded; in Google Drive or Dropbox: make available offline). Vauta adds each one on its own once it’s on this Mac. It never downloads files or connects to online services itself.",
             comment: "Documents pane: what to do about files that are not downloaded from iCloud or another cloud service; the options named in brackets are those of iCloud Drive, Google Drive and Dropbox, described and not quoted")
    }

    private func section(_ title: Text, _ note: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            title.fontWeight(.medium)
            note.font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
