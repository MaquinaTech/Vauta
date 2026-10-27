// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// The header of every sheet: an icon, a title (title case for a task: "Export Meeting";
/// a confirmation asks a question in sentence case, like the alerts: "Erase all meetings and context?") and an optional one-line explanation. Sheets add their own
/// 20 pt outer padding and 16 pt spacing between sections. A finished task keeps its title; the result is a
/// success row (FeedbackLabel) under it, never a header that turns into the result.
struct SheetHeader: View {
    let title: Text
    let message: Text?
    let symbol: String?
    let tint: Color

    init(_ title: Text, message: Text? = nil, symbol: String? = nil, tint: Color = .accentColor) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        // Top-aligned with an icon column as tall as the title's line: a tall symbol (arrow up, arrow down) never
        // pushes the title down, and the 20 pt column + 8 pt gap puts the text where AlignedIconLabelStyle does.
        HStack(alignment: .top, spacing: 8) {
            if let symbol {
                Text(verbatim: " ")
                    .font(.headline)
                    .frame(width: 20)
                    .overlay(alignment: .leading) {
                        Image(systemName: symbol)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(tint)
                            .fixedSize()
                    }
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    message
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
