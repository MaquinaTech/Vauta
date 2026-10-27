// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// The popover of "Add Language…" (speech models and translation languages): one plain row per language,
/// choosing one starts its download.
struct LanguageChoiceList: View {
    struct Choice: Identifiable {
        let id: String
        let name: String
    }

    let choices: [Choice]
    let choose: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(choices) { choice in
                    Button {
                        choose(choice.id)
                    } label: {
                        Text(choice.name.standaloneCapitalized)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        // Every row has the same fixed height, so the list is exactly as tall as its rows (up to a scrolling 320 pt).
        .frame(width: 280, height: min(320, CGFloat(choices.count) * Self.rowHeight + 12))
    }

    private static let rowHeight: CGFloat = 26
}
