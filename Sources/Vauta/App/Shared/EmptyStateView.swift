// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// The one empty, locked or "nothing selected" state: a "No …" title in title case, a
/// sentence that says what to do next, at most one button, centred in the space it has.
/// In two-pane windows only the detail pane shows this (with the button); an empty list pane
/// stays empty (no caption), so the explanation is never said twice.
struct EmptyStateView<Actions: View>: View {
    let title: Text
    let symbol: String
    let message: String?
    /// nil = the system's grey; a failure passes the error colour, as the panel and Status do.
    let symbolColor: Color?
    /// The widest the message grows before it wraps (Latin text); nil = the standard narrow measure.
    var messageWidth: CGFloat?
    @ViewBuilder var actions: () -> Actions

    init(_ title: Text, symbol: String, symbolColor: Color? = nil, message: String? = nil, messageWidth: CGFloat? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.messageWidth = messageWidth
        self.title = title
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.message = message
        self.actions = actions
    }

    @Environment(\.locale) private var locale

    private var usesCJK: Bool {
        let interface = Bundle.main.preferredLocalizations.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        let codes = [interface, locale.language.languageCode?.identifier]
        return codes.contains { ["zh", "ja", "ko"].contains($0 ?? "") }
    }

    var body: some View {
        ContentUnavailableView {
            Label { title } icon: {
                // A problem keeps the system's symbol in its colour; every other state sits on Vauta's sphere.
                if let symbolColor { Image(systemName: symbol).foregroundStyle(symbolColor) } else { BrandSymbol(symbol: symbol) }
            }
        } description: {
            // A narrow measure keeps Latin lines balanced (no one-word last line). CJK text has no
            // spaces to break at, so a narrow measure splits words: it gets a wider one.
            if let message {
                if usesCJK && !message.hasHangul {
                    // No word spaces to protect: the system's line breaking (no line starts with a particle or a closing
                    // mark) decides, and the measure is asked for in full so the container cannot narrow it.
                    Text(verbatim: message)
                        .frame(idealWidth: 360, maxWidth: 360)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(wrapping: message.keepingLastWordsTogether).frame(maxWidth: usesCJK ? 360 : (messageWidth ?? 280))
                }
            }
        } actions: {
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(_ title: Text, symbol: String, message: String? = nil, messageWidth: CGFloat? = nil) {
        self.init(title, symbol: symbol, message: message, messageWidth: messageWidth) { EmptyView() }
    }
}

/// The one "nothing matches" state of every search: the system search wording, with a "Clear Search"
/// (or "Clear Filters") button that gets the list back.
struct SearchEmptyStateView: View {
    let query: String
    /// A filter also narrows the list: the sentence mentions it.
    var filtered = false
    /// Replaces the spelling advice when nothing was typed and the filters alone matched nothing.
    var message: String?
    let clearTitle: LocalizedStringKey
    let clear: () -> Void

    init(query: String, filtered: Bool = false, message: String? = nil, clearTitle: LocalizedStringKey = "Clear Search", clear: @escaping () -> Void) {
        self.query = query
        self.filtered = filtered
        self.message = message
        self.clearTitle = clearTitle
        self.clear = clear
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ContentUnavailableView {
            Label {
                if trimmed.isEmpty { Text("No Results") } else { Text("No Results for “\(trimmed)”") }
            } icon: { Image(systemName: "magnifyingglass") }
        } description: {
            // Same line-break rule as the other empty states: the last words (and short articles) stay together.
            if let message { Text(wrapping: message.keepingLastWordsTogether) }
            else if filtered { Text(wrapping: String(localized: "Check the spelling or try a different search or filter.").keepingLastWordsTogether) }
            else { Text(wrapping: String(localized: "Check the spelling or try a new search.").keepingLastWordsTogether) }
        } actions: {
            Button(clearTitle, action: clear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A locked window or pane: the same state everywhere, with one bordered "Unlock…" button
/// (the ellipsis is right: a system prompt follows). While the store is still opening it shows
/// a spinner; when it failed to open it says why and offers "Try Again".
struct LockedStateView: View {
    let title: Text
    let message: String
    let recorder: RecorderModel
    let unlock: () -> Void

    var body: some View {
        if recorder.storeAvailable {
            EmptyStateView(title, symbol: "lock.fill", message: message) {
                Button("Unlock…", action: unlock)
                    .keyboardShortcut(.defaultAction)
            }
        } else if case .failed(let reason) = recorder.phase {
            EmptyStateView(Text("Your Data Couldn’t Be Opened", comment: "Empty-state title when the store failed to open; the sentence under it is the cause"), symbol: StatusSymbol.error.name, symbolColor: StatusSymbol.error.color,
                           message: [reason, recorder.storeOpenRecovery].compactMap { $0 }.joinedAsSentences()) {
                Button("Try Again") { recorder.openStore() }
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            // The store isn't open yet: say so instead of showing a button that does nothing.
            EmptyStateView(title, symbol: "lock.fill", message: message) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Vauta is still opening your data…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A state's symbol in white on a small Vauta sphere: quiet (no orbit, no glow) unless `showsOrbit`.
struct BrandSymbol: View {
    let symbol: String
    var diameter: CGFloat = 54
    /// The lit sphere with its orbit (a success), instead of the quiet one.
    var showsOrbit = false

    var body: some View {
        ZStack {
            VautaOrb(mode: showsOrbit ? .idle : .muted, diameter: diameter, showsOrbit: showsOrbit)
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.bottom, 4)
    }
}
