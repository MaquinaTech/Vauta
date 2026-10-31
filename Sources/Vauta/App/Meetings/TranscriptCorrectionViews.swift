// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The words of a transcript line, corrected in place: Return saves, Esc cancels, and the field grows with the text. With copy
/// protection on, words can be typed and pasted but not copied out (`NoCopyText`).
struct TranscriptLineEditor: View {
    @Bindable var model: MeetingsModel
    @ViewLocalState private var width: CGFloat = 400

    private static let font = NSFont.preferredFont(forTextStyle: .body)
    private static let line = ceil(NSLayoutManager().defaultLineHeight(for: font))

    private var text: Binding<String> {
        Binding(get: { model.lineDraft?.text ?? "" }, set: { model.lineDraft?.text = $0 })
    }

    private var isEmpty: Bool { (model.lineDraft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Every line of the text, up to eight (a longer one scrolls inside the field). The text view's own inset (2 pt) and line
    /// padding (5 pt) are on each side of the text.
    private var height: CGFloat {
        let measured = ((model.lineDraft?.text ?? "") as NSString).boundingRect(
            with: NSSize(width: max(60, width - 14), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: Self.font]).height
        return min(8 * Self.line, max(Self.line, ceil(measured))) + 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NoCopyText(text: text,
                       accessibilityLabel: String(localized: "Corrected words", comment: "Accessibility label of the field where the user corrects a transcript line"),
                       singleLine: true, wraps: true, font: Self.font, takesInitialFocus: true,
                       onCommit: { model.saveLineDraft() }, onCancel: { model.cancelCorrecting() })
                .frame(height: height)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            HStack(spacing: 8) {
                Button("Cancel") { model.cancelCorrecting() }
                Button("Save") { model.saveLineDraft() }
                    .disabled(isEmpty)
                Text("Return saves, Esc cancels", comment: "Transcript: hint under the field where the user corrects a line")
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .font(.caption)
        }
    }
}

/// Under a line the user corrected: that it was corrected, what the transcriber wrote (on hover), and the way back.
struct CorrectedNote: View {
    let original: String
    let restore: () -> Void

    static let title = String(localized: "Corrected", comment: "Transcript: under a line whose words the user corrected")
    static let restoreTitle = String(localized: "Restore Original",
                                     comment: "Transcript: button under a corrected line that puts back the words the transcriber wrote; also the action Edit ▸ Undo takes back")

    static func transcribed(_ original: String) -> String {
        String(localized: "Transcribed as: “\(original)”", comment: "Transcript: tooltip and VoiceOver value of a corrected line; the argument is the words the transcriber wrote")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "pencil").accessibilityHidden(true)
            Text(Self.title)
                .help(Self.transcribed(original))
            Button(Self.restoreTitle, action: restore)
                .buttonStyle(.link)
                .help(String(localized: "Put back the words as they were transcribed",
                             comment: "Transcript: tooltip of the button under a corrected line"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The pencil at the end of the highlighted line: corrects its words (Return does the same).
struct CorrectLineButton: View {
    let action: () -> Void

    static let title = String(localized: "Correct Line", comment: "Transcript: button, context menu item and VoiceOver action that corrects the words of a line; also the action Edit ▸ Undo takes back")

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil").accessibilityLabel(Text(Self.title))
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Correct the words of this line (Return)", comment: "Transcript: tooltip of the pencil at the end of the highlighted line"))
    }
}

/// Under a line just corrected, when the words it replaced are elsewhere in the meeting (other lines, the minutes): the offer
/// to correct them there too; and when it put in a name or term Vauta doesn't know, the offer to add it to the glossary. Nothing
/// changes until the person accepts, and Edit ▸ Undo takes it back.
struct CorrectEverywhereNote: View {
    let offer: MeetingStore.CorrectEverywhereOffer
    let accept: () -> Void
    let add: (String) -> Void
    let dismiss: () -> Void

    static let title = String(localized: "Correct Everywhere",
                              comment: "Transcript: button under a corrected line that also corrects the same words in the other lines and in the minutes; also the action Edit ▸ Undo takes back")

    /// "Also elsewhere in this meeting: Ana → Anna".
    static func text(_ offer: MeetingStore.CorrectEverywhereOffer) -> String {
        let words = offer.replacements.map { "\($0.from) → \($0.to)" }.joined(separator: ", ")
        return String(localized: "Also elsewhere in this meeting: \(words)",
                      comment: "Transcript: under a corrected line whose replaced words are in other lines or in the minutes; the argument lists them, such as “Ana → Anna”")
    }

    static func addTitle(_ term: String) -> String {
        String(localized: "Add “\(term)” to Glossary",
               comment: "Transcript: button under a corrected line that adds the name or term the user wrote to the glossary in Context; also the action Edit ▸ Undo takes back")
    }

    /// What VoiceOver hears when the offer appears.
    static func announcement(_ offer: MeetingStore.CorrectEverywhereOffer) -> String {
        ((offer.isElsewhere ? [text(offer)] : []) + offer.newTerms.map(addTitle)).joined(separator: ". ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: offer.isElsewhere ? "text.magnifyingglass" : "character.book.closed").accessibilityHidden(true)
            if offer.isElsewhere {
                Text(verbatim: Self.text(offer))
                Button(Self.title, action: accept)
                    .buttonStyle(.link)
                    .help(String(localized: "Correct these words in the other lines of the transcript and in the minutes too. Undo takes it back.",
                                 comment: "Transcript: tooltip of the Correct Everywhere button"))
            }
            ForEach(offer.newTerms, id: \.self) { term in
                Button(Self.addTitle(term)) { add(term) }
                    .buttonStyle(.link)
                    .help(String(localized: "Pinned in the glossary, it goes in the custom vocabulary for dictation, and a later meeting that seems to mishear it gets a suggestion.",
                                 comment: "Transcript: tooltip of the button that adds a corrected name or term to the glossary"))
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel(Text("Dismiss"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
    }
}
