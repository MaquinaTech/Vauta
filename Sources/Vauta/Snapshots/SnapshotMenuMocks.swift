// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import AppKit
import SwiftUI

// Menus, notifications and file panels are drawn by macOS, which an offscreen render cannot capture. These stand-ins draw the
// words Vauta gives them (titles, shortcuts, checkmarks, greyed items, notes) on a plain card, so the text can be reviewed in
// every language; the system's own chrome (shadow, material, blur, the file browser) is not reproduced.

/// One row of a menu.
enum MockMenuEntry {
    case item(String, shortcut: String? = nil, checked: Bool = false, disabled: Bool = false, symbol: String? = nil,
              destructive: Bool = false, submenu: Bool = false)
    case separator
    /// A section title.
    case header(String)
    /// A line of text inside the menu (not a command).
    case note(String)
}

/// A menu as a card.
struct MenuMock: View {
    let entries: [MockMenuEntry]
    var minWidth: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in row(entry) }
        }
        .padding(.vertical, 6)
        .frame(minWidth: minWidth, alignment: .leading)
        .fixedSize()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    @ViewBuilder private func row(_ entry: MockMenuEntry) -> some View {
        switch entry {
        case let .item(title, shortcut, checked, disabled, symbol, destructive, submenu):
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(checked ? 1 : 0).frame(width: 14)
                if let symbol { Image(systemName: symbol).frame(width: 18) }
                Text(verbatim: title)
                Spacer(minLength: 24)
                if let shortcut { Text(verbatim: shortcut).foregroundStyle(.secondary) }
                if submenu { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            }
            .font(.system(size: 13))
            .foregroundStyle(disabled ? Color.secondary.opacity(0.7) : (destructive ? Color.red : Color.primary))
            .padding(.horizontal, 10).padding(.vertical, 3)
        case .separator:
            Divider().padding(.vertical, 4).padding(.horizontal, 6)
        case .header(let title):
            Text(verbatim: title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2).padding(.leading, 20)
        case .note(let text):
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 290, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 3).padding(.leading, 20)
        }
    }
}

/// A button with a menu behind it (the small bordered menu buttons of the Meetings window), with its menu open under it.
struct MenuButtonMock: View {
    let title: String
    let entries: [MockMenuEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                Divider().frame(height: 12)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            MenuMock(entries: entries)
        }
    }
}

/// A notification banner with its action buttons.
struct NotificationMock: View {
    let notification: AppNotification

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: notification.title).font(.system(size: 13, weight: .semibold))
                    Text(verbatim: notification.body).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            let actions = notification.kind.actions.map { Notifier.action($0).title }
            if !actions.isEmpty {
                // The buttons size to their words; when they do not fit side by side they stand one under the other (never a wrapped pill).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { ForEach(actions, id: \.self) { actionPill($0) } }
                    VStack(alignment: .leading, spacing: 6) { ForEach(actions, id: \.self) { actionPill($0) } }
                }
                .padding(.leading, 46)
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

extension NotificationMock {
    fileprivate func actionPill(_ title: String) -> some View {
        Text(verbatim: title).font(.system(size: 12, weight: .medium))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color.primary.opacity(0.12), in: Capsule())
    }
}

/// An open or save panel with the words Vauta sets on it.
struct FilePanelMock: View {
    var title: String?
    var message: String?
    var saveName: String?
    /// The button label Vauta sets (nil: the system's own wording, which isn't Vauta's to review).
    var prompt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(verbatim: title).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity) }
            if let saveName {
                HStack {
                    Text(verbatim: saveName).padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                }
            }
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)).frame(height: 90)
                .overlay { Image(systemName: "folder").font(.system(size: 28)).foregroundStyle(.tertiary) }
            if let message {
                Text(verbatim: message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if let prompt {
                HStack {
                    Spacer()
                    Text(verbatim: prompt).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                }
                .font(.system(size: 13))
            }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}
#endif
