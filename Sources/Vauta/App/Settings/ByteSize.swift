// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// File sizes as the system writes them ("6.6 MB"), with a no-break space between the number and the unit so a size
/// never splits over two lines ("20" / "KB").
enum ByteSize {
    static func string(_ bytes: Int64, style: ByteCountFormatter.CountStyle = .file) -> String {
        glued(ByteCountFormatter.string(fromByteCount: bytes, countStyle: style))
    }

    /// The formatter's own output with its ordinary spaces (and narrow ones) made non-breaking.
    static func glued(_ formatted: String) -> String {
        formatted.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "\u{202F}", with: "\u{00A0}")
    }
}
