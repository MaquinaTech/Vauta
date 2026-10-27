// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import VautaCore

/// Puts meeting text on a pasteboard so that it does not linger: the item carries the nspasteboard.org "concealed" and "transient"
/// marks (clipboard managers and history skip such items) and is asked to stay on this Mac, so Universal Clipboard does not carry it.
/// The email draft's Copy and Copy Minutes both use it.
enum ProtectedPasteboard {
    /// Replaces the pasteboard's contents with `text`, marked. The general pasteboard by default; tests pass a private one.
    @discardableResult
    static func copy(_ text: String, to board: NSPasteboard = .general) -> Bool {
        board.prepareForNewContents(with: [.currentHostOnly])
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for type in PasteboardMarks.all { item.setData(Data(), forType: NSPasteboard.PasteboardType(type)) }
        return board.writeObjects([item])
    }
}
