// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// What the minutes tell the user about the model's proposals that the transcript does not back. Vauta checks every
/// decision and task against the passage it cites; what does not match is kept and marked, never hidden.
/// A mark is a glyph and words (help, VoiceOver, the editor's note), never a colour alone.
enum VerificationText {
    static var unconfirmed: String {
        String(localized: "Not confirmed in the transcript", comment: "VoiceOver value and short help of a decision or task the transcript does not back")
    }

    static var unconfirmedHelp: String {
        String(localized: "This isn’t confirmed in the transcript. Check it before relying on it.", comment: "Help of the mark on a decision or task the transcript does not back: a name, date or figure that does not match the passage the model cited, or an item less certain than the main ones of the meeting; also the note in the task editor")
    }

    /// The help of an unconfirmed item: why it is marked, when that is something other than a check of its words.
    static func help(reason: String?) -> String {
        reason == UnconfirmedReason.edited ? editedHelp : unconfirmedHelp
    }

    static var editedHelp: String {
        String(localized: "You corrected the transcript here after the minutes were written. Check that this still says what was said.",
               comment: "Help of the mark on a decision or task whose cited transcript line the user corrected after the minutes were written; also the note in the task editor")
    }

    static var ownerHelp: String {
        String(localized: "Nothing in the passage the model cited confirms this owner.", comment: "Help of the mark on a task owner; also the note in the task editor")
    }

    static func ownerSpoken(_ name: String) -> String {
        String(localized: "\(name), owner not confirmed", comment: "VoiceOver label of a task owner the cited passage does not confirm; the argument is the owner's name")
    }
}

/// The word "Unconfirmed" with its glyph, after the text of a decision.
struct UnconfirmedBadge: View {
    /// Why it is unconfirmed (`UnconfirmedReason`), for the help.
    var reason: String?
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
            Text("Unconfirmed", comment: "Small badge after a decision the transcript doesn’t back")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .help(VerificationText.help(reason: reason))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(VerificationText.unconfirmed))
    }
}

/// The owner of a task in both tables, with a glyph when nothing in the cited passage confirms them.
struct TaskOwnerCell: View {
    let task: TaskItem
    /// The name as shown ("—" without an owner).
    let name: String
    @Environment(\.backgroundProminence) private var prominence

    private var marked: Bool { task.ownerMarked }

    /// The name gives way to the glyph: a long name truncates, the mark stays.
    var body: some View {
        HStack(spacing: 3) {
            Text(name).lineLimit(1).truncationMode(.tail)
            if marked {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .help(marked ? Text(VerificationText.ownerHelp) : Text(verbatim: ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(marked ? VerificationText.ownerSpoken(name) : name))
    }
}

/// The glyph of an owner nothing in the cited passage confirms, for lists that show the task without the Owner column
/// (a person's card). Same help and VoiceOver words as `TaskOwnerCell`.
struct OwnerMarkGlyph: View {
    let name: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: "questionmark.circle")
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
            .fixedSize()
            .help(VerificationText.ownerHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(VerificationText.ownerSpoken(name)))
    }
}

/// The note in the task editor that says what is not confirmed, in words.
///
/// Each line has the height its text needs at the editor's width, measured like the table rows are: a wrapping
/// `Text` that sizes itself makes the window's minimum height depend on the narrowest width its text can wrap at,
/// and the whole Meetings window overflowed in languages whose note takes two lines.
struct VerificationNote: View {
    let task: TaskItem
    /// The width of the editor's card (the table's width).
    let width: CGFloat

    private static let margin: CGFloat = 20
    private static let cardPadding: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if task.unconfirmed { line(VerificationText.help(reason: task.unconfirmedReason)) }
            if task.ownerMarked { line(VerificationText.ownerHelp) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    static func height(of text: String, width: CGFloat) -> CGFloat {
        let room = max(120, width - cardPadding - margin)
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let box = (text as NSString).boundingRect(with: CGSize(width: room, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        // 4 pt of slack, only when the text takes more than one line, for the wrapping of the real text.
        return ceil(box.height) + (box.height > font.pointSize * 1.6 ? 4 : 0)
    }

    /// The glyph is decoration (the words say it): it sits over the leading margin.
    private func line(_ text: String) -> some View {
        Text(verbatim: text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: Self.height(of: text, width: width), alignment: .top)
            .padding(.leading, Self.margin)
            .overlay(alignment: .topLeading) {
                Image(systemName: "questionmark.circle").foregroundStyle(Color.orange).accessibilityHidden(true)
            }
    }
}
