// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Aliases as removable tokens plus a field for new ones. A list separator
/// (comma, semicolon, 、, ،…) or Return turns the typed text into tokens.
struct AliasTokenField: View {
    @Binding var aliases: [String]
    @Binding var input: String
    /// The entry's name: never repeated as an alias.
    let name: String
    let origins: [String: AliasOrigin]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !aliases.isEmpty {
                TokenFlowLayout(spacing: 6) {
                    ForEach(aliases, id: \.self) { alias in
                        AliasToken(text: alias, origin: origins[alias]) {
                            aliases.removeAll { $0 == alias }
                        }
                    }
                }
            }
            NoCopyField(title: String(localized: "Add an alias", comment: "Placeholder of the field for new aliases"),
                        text: $input, lineBreakReplacement: ", ", onCommit: commit)
                .accessibilityLabel(Text("New alias"))
                .onChange(of: input) { tokenizeTypedText() }
        }
    }

    private func commit() {
        aliases = AliasList.adding(input, to: aliases, name: name)
        input = ""
    }

    /// Everything up to the last separator becomes tokens; the rest stays typed.
    private func tokenizeTypedText() {
        guard let last = input.lastIndex(where: AliasList.isSeparator) else { return }
        let done = String(input[..<last])
        let rest = String(input[input.index(after: last)...])
        aliases = AliasList.adding(done, to: aliases, name: name)
        input = rest.trimmingCharacters(in: .whitespaces)
    }
}

private struct AliasToken: View {
    let text: String
    let origin: AliasOrigin?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .overlay(Capsule().strokeBorder(.tertiary))
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove this alias")
            .accessibilityLabel(Text("Remove Alias “\(text)”"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(badge.map { String(localized: "\(text), \($0)", comment: "Alias token for VoiceOver: the alias and where it came from") } ?? text))
    }

    /// Where the alias came from, when it was not typed by the user.
    private var badge: String? {
        switch origin {
        case .learned?: String(localized: "Learned", comment: "Badge of an alias learned from a correction the user accepted in a meeting")
        case .calendar?: String(localized: "Calendar", comment: "Badge of an alias taken from a calendar attendee")
        case .llm?: String(localized: "Suggested", comment: "Badge of an alias proposed by the model")
        case .user?, nil: nil
        }
    }
}

/// Lays out its children left to right, wrapping to new lines.
struct TokenFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
