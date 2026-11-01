// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// Settings → Status: a live setup checklist with fixes and copyable diagnostics.
struct StatusPane: View {
    let recorder: RecorderModel
    let preferences: Preferences
    @Bindable var model: SettingsModel
    @ViewLocalState private var copied = false
    @ViewLocalState private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                ForEach(model.statusItems) { item in
                    StatusRow(item: item) { perform($0) }
                }
                if model.statusItems.isEmpty { ProgressView().controlSize(.small).accessibilityLabel(String(localized: "Checking…", comment: "Accessibility label of the spinner while the checklist is loading")) }
            } header: {
                SectionHeaderWithAction {
                    Text("Checklist")
                } action: {
                    if model.checking { ProgressView().controlSize(.small).accessibilityLabel(String(localized: "Checking…", comment: "Accessibility label of the spinner while the checklist is loading")) }
                    Button("Check Again") { refresh() }
                        .disabled(model.checking)
                }
            }
            Section {
                LabeledContent {
                    Button(copied ? String(localized: "Copied", comment: "Diagnostics button after copying")
                                  : String(localized: "Copy Diagnostics", comment: "Diagnostics button")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.diagnostics(), forType: .string)
                        copied = true
                    }
                    .disabled(model.statusItems.isEmpty)
                } label: {
                    Text("Support report", comment: "Settings → Status; title of the row that copies the diagnostics")
                    Text(description: String(localized: "Versions and the checklist above, for a support request. No meeting content, names or addresses."))
                }
                LabeledContent {
                    Button(String(localized: "Report a Problem…", comment: "Settings → Status; copies the diagnostics and opens a new bug report on GitHub")) {
                        let report = model.diagnosticsReport()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.text, forType: .string)
                        copied = true
                        NSWorkspace.shared.open(report.issueURL)
                    }
                    .disabled(model.statusItems.isEmpty)
                } label: {
                    Text("Bug report", comment: "Settings → Status; title of the row that opens a new bug report on GitHub")
                    Text(description: String(localized: "Copies the diagnostics and opens a new bug report on GitHub in your browser, with your Vauta and macOS versions filled in. Paste the diagnostics there; nothing else is in the address.",
                                             comment: "Settings → Status; explains Report a Problem…"))
                }
            } header: {
                Text("Diagnostics")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(String(localized: "Delete the old copies of your meetings?", comment: "Confirmation title"),
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Old Copies", role: .destructive) { deleteLeftovers() }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text(leftoversMessage)
        }
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    /// Says what Delete Old Copies removes: the copies in Vauta's folder, the folder from an earlier version, or both.
    private var leftoversMessage: String {
        let found = model.statusItems.first { $0.kind == .leftovers }?.leftovers
        return Self.leftoversMessage(bytes: found?.totalBytes ?? 0,
                                     hasOldFolder: found?.hasOldFolder ?? false,
                                     hasSetAside: (found?.setAsideCount ?? 0) > 0)
    }

    /// The confirmation text itself, shared with the snapshot scenes so they show exactly what the alert shows.
    static func leftoversMessage(bytes: Int64, hasOldFolder: Bool, hasSetAside: Bool) -> String {
        let size = ByteSize.string(bytes)
        if hasOldFolder && hasSetAside {
            return String(localized: "This permanently deletes the old copies in Vauta’s folder and the folder from an earlier version (\(size)). Your current meetings and your encryption key aren’t affected.",
                          comment: "Confirmation message when both exist; the argument is a file size")
        }
        if hasOldFolder {
            return String(localized: "This permanently deletes the folder from an earlier version (\(size)). Your current meetings and your encryption key aren’t affected.",
                          comment: "Confirmation message for the folder from an earlier version; the argument is a file size")
        }
        return String(localized: "This permanently deletes the old copies in Vauta’s folder (\(size)). Your current meetings and your encryption key aren’t affected.",
                      comment: "Confirmation message for the old copies in Vauta's folder; the argument is a file size")
    }

    private func deleteLeftovers() {
        Task {
            await recorder.deleteStoreLeftovers()
            await model.runChecks(recorder, preferences)
        }
    }

    private func refresh() {
        copied = false
        Task { await model.runChecks(recorder, preferences) }
    }

    private func perform(_ action: StatusItem.Action) {
        switch action {
        case .systemSettings(let pane): Permissions.open(pane)
        case .showPane(let pane), .setUp(let pane), .change(let pane): model.pane = pane
        case .setUpModel: model.pane = .models; model.models.guidePresented = true
        case .changeShortcut: model.pane = .general
        case .requestMicrophone: Task { _ = await Permissions.requestMicrophone(); refresh() }
        case .requestNotifications: Task { _ = await Permissions.requestNotifications(); refresh() }
        case .retryStore:
            recorder.openStore()
            refresh()
        case .showInFinder(let urls): NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .deleteLeftovers: confirmingDelete = true
        case .repairIntegratedModel: recorder.integratedModel.repair()
        case .downloadSpeechModel(let language):
            let task = model.speech.install(language, keeping: [language.id])
            refresh()
            if let task { Task { await task.value; refresh() } }
        }
    }
}

private struct StatusRow: View {
    let item: StatusItem
    let perform: (StatusItem.Action) -> Void

    var body: some View {
        // The action goes under the text in every row: beside it, long details (translations are long)
        // would be squeezed into a narrow column, and rows would differ in layout.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 8) {
                texts
                button
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: item.level.symbol)
            .foregroundStyle(color)
            .frame(width: 20)
            .accessibilityLabel(item.level.accessibilityLabel)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
            detailText
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Korean breaks at its spaces (never inside 개인정보); the other languages keep SwiftUI's own wrapping.
    private var detailText: Text {
        // The Korean strings tie every space of a path with no-break spaces: the whole path would be one chunk wider
        // than the line and break inside a word. Spaces break between words; each arrow stays with the step before it.
        item.detail.containsHangulSyllables
            ? Text(paragraph: item.detail.replacingOccurrences(of: "\u{00A0}", with: " "))
            : Text(item.detail.avoidingWidow)
    }

    @ViewBuilder
    private var button: some View {
        if item.action != nil || item.secondaryAction != nil {
            HStack(spacing: 8) {
                ForEach([item.action, item.secondaryAction].compactMap { $0 }, id: \.title) { action in
                    Button(action.title) { perform(action) }
                }
            }
        }
    }

    private var color: Color {
        switch item.level {
        case .ok: .green
        case .attention: .orange
        case .problem: .red
        case .info, .pending: .secondary
        }
    }
}

/// Settings → About.
struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return String(localized: "Version \(short) (\(build))", comment: "About; arguments are the version and build numbers")
    }

    private static let appIcon = AppIconImage.image(points: 96)

    private static let repository = URL(string: "https://github.com/MaquinaTech/Vauta")!

    /// A label column (trailing, secondary) and a value column (leading), so every row lines up.
    private func aboutRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value().gridColumnAlignment(.leading)
        }
    }

    /// One width for the dividers, the information rows and the paragraph, so the centred column has a single edge.
    private static let columnWidth: CGFloat = 460

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(nsImage: Self.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text(verbatim: "Vauta").font(.largeTitle.bold())
                // The promise right under the name; the version is a detail below it.
                Text("Your meetings, locked in your Mac.").font(.title3)
                Text(version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Divider().frame(maxWidth: Self.columnWidth)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    aboutRow(String(localized: "License", comment: "About")) {
                        Link(destination: Self.repository.appendingPathComponent("blob/main/LICENSE")) { Text(verbatim: "Apache License 2.0") }
                    }
                    aboutRow(String(localized: "Copyright", comment: "About")) { Text(verbatim: "© 2026 Nicolás López de Lerma López") }
                    aboutRow(String(localized: "Source code", comment: "About")) {
                        Link(destination: Self.repository) { Text(verbatim: "github.com/MaquinaTech/Vauta") }
                    }
                    aboutRow(String(localized: "Policies", comment: "About; the row with the links to the privacy and security policies")) {
                        HStack(spacing: 8) {
                            Link(destination: Self.repository.appendingPathComponent("blob/main/PRIVACY.md")) { Text("Privacy", comment: "About") }
                            Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true)
                            Link(destination: Self.repository.appendingPathComponent("blob/main/SECURITY.md")) { Text("Security", comment: "About") }
                        }
                    }
                }
                .textSelection(.enabled)
                Divider().frame(maxWidth: Self.columnWidth)
                Text("Third-party software", comment: "About: heading of the dependency statement").font(.headline)
                Text(wrapping: String(localized: "Vauta uses Apple frameworks, the SQLite library that comes with macOS, and MLX (mlx\u{2011}swift, MIT) with its swift\u{2011}numerics library (Apache 2.0). MLX runs the optional search and integrated models on this Mac; the models are downloaded only when you ask. Credits and Licenses lists everything.", comment: "About: the dependency statement; MLX (mlx-swift, MIT) is the one third-party package, with swift-numerics (Apache 2.0), the library it needs; MLX runs the optional models Vauta downloads only on request. The button below it is “Credits and Licenses”").avoidingWidow)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.columnWidth)
                Text(wrapping: String(localized: "Speaker separation uses the pyannote community\u{2011}1 segmentation model and the WeSpeaker ResNet34\u{2011}LM voice-embedding model (CC\u{00A0}BY\u{00A0}4.0), converted to Core ML.",
                                      comment: "About: attribution of the bundled speaker models").avoidingWidow)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.columnWidth)
                Button {
                    // The NOTICE shipped in the app is the one that matches this version; the repository is the fallback.
                    if let notice = Bundle.main.url(forResource: "NOTICE", withExtension: nil) {
                        // A file without an extension has no default app: it is plain text, so TextEdit shows it.
                        if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
                            NSWorkspace.shared.open([notice], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
                        } else {
                            NSWorkspace.shared.open(notice)
                        }
                    } else {
                        NSWorkspace.shared.open(Self.repository.appendingPathComponent("blob/main/NOTICE"))
                    }
                } label: {
                    Text("Credits and Licenses", comment: "About; link to the NOTICE file with the authors and licenses of the bundled models")
                }
                .buttonStyle(.link)
            }
            // Less above the icon, so the last link fits at the minimum window height in every language.
            .padding(.horizontal, 30)
            .padding(.top, 22)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity)
        }
    }
}
