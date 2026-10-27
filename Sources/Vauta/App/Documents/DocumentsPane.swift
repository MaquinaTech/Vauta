// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Settings → Documents: the folders and files Ask can answer from.
struct DocumentsPane: View {
    let recorder: RecorderModel

    var body: some View {
        if let model = recorder.documents {
            DocumentsPaneContent(model: model, meaning: recorder.searchModel.documentsBackfill)
        } else {
            EmptyStateView(Text("Documents Aren’t Available", comment: "Documents pane: shown when the encrypted store is not open"), symbol: "doc.on.doc",
                           message: String(localized: "Unlock Vauta’s data first. Documents need the encrypted store.", comment: "Documents pane: shown when the encrypted store is not open"))
        }
    }
}

struct DocumentsPaneContent: View {
    @Bindable var model: DocumentsModel
    /// How much of the documents the search model has indexed, while it still does (nil when it is done or not in use).
    var meaning: SemanticRanker.Coverage?

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Ask can answer from your files too. Vauta reads them on this Mac and keeps an encrypted index. Your files are never changed.",
                         comment: "Documents pane: what adding folders and files does")
                } icon: { PromiseGlyph("lock") }
                .labelStyle(PromiseLabelStyle())
                HStack {
                    Button("Add Folder…") { model.addFolders() }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                    Button("Add Files…") { model.addFiles() }
                        .keyboardShortcut("o", modifiers: .command)
                    Spacer()
                    if model.snapshot.hasSources {
                        let allPaused = model.snapshot.sources.allSatisfy { $0.source.paused }
                        Button(allPaused ? "Resume All" : "Pause All") { model.setAllPaused(!allPaused) }
                    }
                }
                ForEach(Array(model.notes.enumerated()), id: \.offset) { _, note in
                    NoticeLabel(Text(note.text), status: { if case .added = note { .ok } else { .warning } }())
                }
            }

            Section {
                if model.snapshot.sources.isEmpty {
                    dropHint
                } else {
                    ForEach(model.snapshot.sources) { status in
                        DocumentSourceRow(status: status, model: model)
                    }
                }
            } header: {
                Text("Sources", comment: "Documents pane: header of the list of folders and files that were added")
            }

            Section {
                if model.snapshot.hasSources {
                    indexSummary
                }
                Toggle(isOn: $model.ocrEnabled) {
                    Text("Read text in images and scanned pages")
                    Text(description: String(localized: "Uses text recognition on this Mac. Pictures never leave it, and it can take a while.",
                         comment: "Documents pane: explains the switch that reads text in images and scanned pages"))
                }
                if model.embeddingsOnNetwork {
                    Toggle(isOn: $model.networkEmbeddings) {
                        Text("Also use the model server to find passages by meaning")
                        Text(description: String(localized: "Sends every indexed passage to your model server once.",
                             comment: "Documents pane: explains the switch that lets the model server on the network embed every passage of the documents"))
                    }
                }
            } header: {
                Text("Index", comment: "Documents pane: header of the section with the size of the index and its switches")
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshEmbeddingRoute() }
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(6).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { model.dropTargeted = $0 }
        .alert(item: $model.removing) { status in
            Alert(title: Text(verbatim: DocumentsModel.removeTitle(status.source.displayName)),
                  message: Text(verbatim: DocumentsModel.removeMessage(status.source.kind)),
                  primaryButton: .destructive(Text(verbatim: DocumentsModel.removeLabel)) { model.remove(status) },
                  secondaryButton: .cancel())
        }
        .sheet(item: $model.skipped) { list in
            SkippedFilesSheet(list: list) { model.skipped = nil }
        }
        .sheet(item: $model.cloudHelp) { status in
            CloudFilesHelpSheet(googleShortcuts: status.counts.googleShortcuts, onlineOnly: status.counts.onlineOnly, folders: status.counts.onlineOnlyFolders, sourceName: status.source.displayName) { model.cloudHelp = nil }
        }
    }

    private var dropHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down.on.square").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Drop folders or files here to add them.", comment: "Documents pane: shown when there are no sources; folders and files can be dragged in")
                .foregroundStyle(.secondary)
            Text("PDF, Word, Excel, PowerPoint, Markdown, text, RTF, HTML and images", comment: "Documents pane: the kinds of file Vauta reads, under the drop hint when there are no sources")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var indexSummary: some View {
        let snapshot = model.snapshot
        return VStack(alignment: .leading, spacing: 4) {
            Text("Index: \(snapshot.totalFiles) files · about \(DocumentsModel.pages(characters: snapshot.totalCharacters)) pages of text",
                 comment: "Documents pane: how big the index is; the arguments are the number of files and the approximate number of pages of their text")
            if snapshot.characterCapacityUsed > 0.8 {
                Text("Vauta indexes up to about \(DocumentsModel.pages(characters: DocumentLimits.maxTotalCharacters)) pages", comment: "Documents pane: the limit of the index, shown when it is nearly full")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let meaning {
                Label {
                    Text("Search by meaning: \(meaning.covered.formatted()) of \(meaning.total.formatted()) passages",
                         comment: "Documents pane: how many passages the search model has indexed so far, while it indexes; the arguments are passages done and total")
                } icon: {
                    Image(systemName: "sparkle.magnifyingglass")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if snapshot.rebuilding {
                Label("Rebuilding the document index", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One source: icon, name and path, its state and counts, and its menu.
struct DocumentSourceRow: View {
    let status: DocumentSourceStatus
    @Bindable var model: DocumentsModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            iconView
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: status.source.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: abbreviatedPath)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                statusLine
                if case .indexing(let done, let total) = status.state, total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                        .progressViewStyle(.linear)
                        .accessibilityHidden(true)
                } else if case .readingImages = status.state {
                    // The number of pages that need text recognition is not known up front: the bar only says that it is working.
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityHidden(true)
                }
                counts
                CloudFilesLine(counts: status.counts) { model.cloudHelp = status }
                if status.source.kind == .folder { notesFlag }
            }
            Spacer(minLength: 4)
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Actions for “\(status.source.displayName)”", comment: "VoiceOver: the menu button of a document source; the argument is its name"))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: status.spokenSummary))
        .accessibilityValue(progressValue)
        .accessibilityAction(named: Text(status.source.paused ? "Resume Indexing" : "Pause Indexing")) { model.setPaused(status, !status.source.paused) }
        .accessibilityAction(named: Text("Index Again")) { model.reindex(status) }
        .accessibilityAction(named: Text(DocumentsModel.removeMenuLabel)) { model.removing = status }
        .accessibilityActions {
            if status.counts.notOnThisMac > 0 {
                Button(String(localized: "How to add these files", comment: "Documents pane: help button of the line that counts skipped Google Drive shortcuts and files not downloaded; it opens an explanation")) { model.cloudHelp = status }
            }
        }
        // Focusable, so Tab reaches the row and Delete (⌫) removes the focused source after the same confirmation as the menu.
        .focusable()
        .onDeleteCommand { model.removing = status }
    }

    /// A folder of notes the person exported from Notes: the brief labels its excerpts "Note". Vauta reads the files only.
    private var notesFlag: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { status.source.isNotesExport }, set: { model.setNotesExport(status, $0) })) {
                Text("This folder holds notes exported from Notes", comment: "Documents pane: a switch on a folder source; the brief labels its passages as notes")
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            // The menu item is Notes' own name for the Markdown export (File menu and folder list); Vauta never drives Notes.
            Text("In Notes, choose Export Archive… and save the Markdown files in this folder.",
                 comment: "Documents pane: under the switch of a folder of exported notes; how to get the notes there. “Export Archive…” is the name of Notes’ own menu item, so use the name Notes shows in the language")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status.source.isNotesExport {
                Text("Its files are labelled “Note” in the brief. Vauta reads the files only and never opens Notes.",
                     comment: "Documents pane: under the switch of a folder of exported notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.isProblem ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            Text(verbatim: status.statusText).foregroundStyle(.primary)
            if status.needsLocate {
                Button("Locate…") { model.locate(status) }.controlSize(.small)
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var counts: some View {
        let c = status.counts
        if c.files > 0 {
            HStack(spacing: 4) {
                Group {
                    Text("\(c.files) files")
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text("\(c.indexed) indexed")
                    if c.skipped > 0 { Text(verbatim: "·").accessibilityHidden(true) }
                }
                .foregroundStyle(.secondary)
                // The way into the Skipped Files sheet reads as a link (the accent colour), not as one more count.
                if c.skipped > 0 {
                    Button { model.showSkipped(status) } label: { Text("\(c.skipped) skipped") }
                        .buttonStyle(.link)
                        .accessibilityHint(Text("Shows the files that were skipped and why"))
                }
            }
            .font(.subheadline)
        }
    }

    private var menuItems: some View { DocumentSourceMenuItems(status: status, model: model) }

    private var abbreviatedPath: String { DocumentsModel.abbreviated(status.source.path, home: model.displayHome) }

    /// The file's own icon, or a plain folder or document symbol when the source can't be found (there is no icon to ask for).
    @ViewBuilder private var iconView: some View {
        if status.state == .notFound || status.state == .disconnected || !FileManager.default.fileExists(atPath: status.source.path) {
            Image(systemName: status.source.kind == .folder ? "folder" : "doc")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(3)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: status.source.path)).resizable()
        }
    }

    private var progressValue: Text {
        if case .indexing(let done, let total) = status.state { return Text("\(done) of \(total)") }
        return Text(verbatim: "")
    }
}

/// The items of a source's menu (the ellipsis button and the context menu).
struct DocumentSourceMenuItems: View {
    let status: DocumentSourceStatus
    let model: DocumentsModel

    var body: some View {
        // A source that can't be found has nothing to pause, read again or show: it can be located or removed.
        Button(status.source.paused ? "Resume Indexing" : "Pause Indexing") { model.setPaused(status, !status.source.paused) }
            .disabled(status.needsLocate)
        Button("Index Again") { model.reindex(status) }
            .disabled(status.needsLocate)
        Divider()
        Button("Show in Finder") { model.showInFinder(status) }
            .disabled(status.needsLocate)
        if status.counts.skipped > 0 { Button("Show Skipped Files…") { model.showSkipped(status) } }
        if status.needsLocate { Button("Locate…") { model.locate(status) } }
        Divider()
        Button(DocumentsModel.removeMenuLabel, role: .destructive) { model.removing = status }
    }
}

/// The files of a source that were not (fully) indexed, and why. No content.
struct SkippedFilesSheet: View {
    let list: DocumentsModel.SkippedList
    let close: () -> Void
    /// The list scrolls beyond this height. Only the snapshots raise it, to show every row.
    var listMaxHeight: CGFloat = SkippedFilesSheet.defaultListMaxHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(Text("Skipped Files", comment: "Documents: title of the sheet that lists files that were not indexed"),
                        message: Text(verbatim: list.source.source.displayName), symbol: "doc.badge.ellipsis")
            if list.files.isEmpty {
                Text("No files were skipped.", comment: "Documents: the Skipped Files sheet has nothing to list").foregroundStyle(.secondary)
            } else {
                // Rows of their own (not a Table): a reason runs to two lines in some languages and is never cut with an ellipsis.
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Name", comment: "Documents: column of the Skipped Files sheet").frame(width: Self.nameWidth, alignment: .leading)
                        Text("Reason", comment: "Documents: column of the Skipped Files sheet; why the file was skipped").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Size", comment: "Documents: column of the Skipped Files sheet").frame(width: Self.sizeWidth, alignment: .trailing)
                        Color.clear.frame(width: 22, height: 1)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(list.files) { entry in
                                row(entry)
                                Divider()
                            }
                        }
                    }
                    .frame(height: min(max(CGFloat(list.files.count) * Self.rowHeight, 120), listMaxHeight))
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760)
    }

    private static let nameWidth: CGFloat = 200
    private static let sizeWidth: CGFloat = 70
    private static let rowHeight: CGFloat = 52
    static let defaultListMaxHeight: CGFloat = 720

    private func row(_ entry: DocumentsModel.SkippedEntry) -> some View {
        let reason = entry.reason.sheetText(format: entry.format, isFolder: entry.isFolder)
        // Centered, so a file with no folder line does not leave an empty second line under its name.
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if entry.isFolder { Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true) }
                    Text(verbatim: entry.name).lineLimit(1).truncationMode(.middle)
                }
                if !entry.folder.isEmpty {
                    Text(verbatim: entry.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            .frame(width: Self.nameWidth, alignment: .leading)
            Text(verbatim: reason)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(reason)
            // A folder kept online holds no size Vauta knows: nothing is shown instead of "Zero KB".
            Text(verbatim: entry.isFolder ? "" : ByteSize.string(entry.size)).foregroundStyle(.secondary).frame(width: Self.sizeWidth, alignment: .trailing)
            Button { reveal(entry) } label: { Image(systemName: "magnifyingglass.circle") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel(Text("Show in Finder"))
                .frame(width: 22)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: Self.rowHeight - 1, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private func reveal(_ entry: DocumentsModel.SkippedEntry) {
        let base = URL(fileURLWithPath: list.source.source.path)
        var url = list.source.source.kind == .file ? base : base.appendingPathComponent(entry.folder).appendingPathComponent(entry.name)
        // A source folder that is itself a placeholder is stored as "<its name>/": there is no such folder inside it, the folder is the source.
        if entry.isFolder, !FileManager.default.fileExists(atPath: url.path) { url = base }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
