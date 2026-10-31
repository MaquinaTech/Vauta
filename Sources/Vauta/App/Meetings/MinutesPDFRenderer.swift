// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit

/// Renders an export as a paginated PDF with AppKit's text system and a Core
/// Graphics PDF context (no third-party code, no print system). Right-to-left
/// and CJK text lay out as in any Mac text view.
@MainActor
enum MinutesPDFRenderer {
    static let margin: CGFloat = 54

    static func write(_ e: MeetingExport, options: MeetingExportOptions, to url: URL) throws {
        // US Letter where the US measurement system is used, else A4.
        let page = options.locale.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
        let textSize = CGSize(width: page.width - 2 * margin, height: page.height - 2 * margin)

        let storage = NSTextStorage(attributedString: attributed(e, options: options))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if range.length == 0 || NSMaxRange(range) >= layout.numberOfGlyphs { break }
        } while containers.count < 5_000

        var box = CGRect(origin: .zero, size: page)
        let info = [kCGPDFContextTitle: e.title, kCGPDFContextCreator: "Vauta"] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &box, info) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            // AppKit text draws top-down: flip the page.
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let range = layout.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func attributed(_ e: MeetingExport, options: MeetingExportOptions) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func paragraph(spacingBefore: CGFloat, after: CGFloat = 4, indent: CGFloat = 0, firstLineIndent: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = firstLineIndent
            p.paragraphSpacingBefore = spacingBefore
            p.paragraphSpacing = after
            p.baseWritingDirection = .natural
            p.headIndent = indent
            return p
        }
        func add(_ text: String, font: NSFont, color: NSColor = .black, style: NSParagraphStyle) {
            out.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        let listStyle: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.tabStops = [NSTextTab(textAlignment: .natural, location: 14)]
            p.headIndent = 14
            p.paragraphSpacing = 3
            p.baseWritingDirection = .natural
            return p
        }()
        let body = NSFont.systemFont(ofSize: 11)
        let secondary = NSColor.darkGray
        func heading(_ text: String) { add(text, font: .boldSystemFont(ofSize: 14), style: paragraph(spacingBefore: 14, after: 6)) }
        func bullets(_ items: [String]) {
            for item in items { add("•\t" + item, font: body, style: listStyle) }
        }
        let time = { (t: Double?) in t.map { " (\(ExportTimestamp.clock($0)))" } ?? "" }

        add(e.title, font: .boldSystemFont(ofSize: 20), style: paragraph(spacingBefore: 0, after: 6))
        add(MeetingExportRenderer.dateLine(e, options: options), font: body, color: secondary, style: paragraph(spacingBefore: 0))
        if !e.attendees.isEmpty {
            add(String(localized: "Attendees: \(e.attendees.joined(separator: ", "))", comment: "PDF export: attendee list"),
                font: body, color: secondary, style: paragraph(spacingBefore: 0))
        }
        if let informed = MeetingExportRenderer.informedTime(e, options: options) {
            add(String(localized: "Participants informed: \(informed)",
                       comment: "PDF export: the time the user marked that the participants were told the meeting was being recorded"),
                font: body, color: secondary, style: paragraph(spacingBefore: 0))
        }
        if !e.notes.isEmpty {
            // The user's own document comes first: their words in bold, what the transcript says under each, in gray.
            heading(String(localized: "Your notes", comment: "Exported minutes: section title for the notes the user typed themselves; it comes first"))
            if e.notes.contains(where: { !$0.expansion.isEmpty && !$0.editedByUser }) {
                add(String(localized: "Expanded from the transcript", comment: "Exported minutes: line under “Your notes” saying that the indented sentences under each note were written by the model from the transcript, while the note itself is the user’s own words"),
                    font: .systemFont(ofSize: 10), color: secondary, style: paragraph(spacingBefore: 0))
            }
            for n in e.notes {
                add("•\t" + (n.time.map { "(\(ExportTimestamp.clock($0))) " } ?? "") + n.text, font: .boldSystemFont(ofSize: 11), style: listStyle)
                for s in n.expansion {
                    let line = MeetingExportRenderer.sentenceText(s) + (s.unconfirmed ? " — " + MeetingExportRenderer.unconfirmedLabel : "")
                    add(line, font: body, color: secondary, style: paragraph(spacingBefore: 0, after: 3, indent: 28, firstLineIndent: 28))
                }
                if n.editedByUser && !n.expansion.isEmpty {
                    add(MeetingExportRenderer.editedByYouLabel, font: .systemFont(ofSize: 10), color: secondary,
                        style: paragraph(spacingBefore: 0, after: 3, indent: 28, firstLineIndent: 28))
                }
            }
        }
        if !e.summary.isEmpty {
            heading(String(localized: "Summary", comment: "Exported minutes: section title"))
            for line in e.summary.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                add(String(line), font: body, style: paragraph(spacingBefore: 0, after: 6))
            }
        }
        if !e.topics.isEmpty {
            heading(String(localized: "Topics", comment: "Exported minutes: section title"))
            bullets(e.topics)
        }
        if !e.decisions.isEmpty {
            heading(String(localized: "Decisions", comment: "Exported minutes: section title"))
            bullets(e.decisions.map { $0.text + MeetingExportRenderer.decisionNote($0) + time($0.time) })
        }
        if !e.tasks.isEmpty {
            heading(String(localized: "Tasks", comment: "Exported minutes: section title"))
            for t in e.tasks {
                let box = t.status == .done ? "☑︎" : "☐"
                var parts = [t.text]
                if t.status == .dropped { parts.append(TaskItem.Status.dropped.label) }
                parts += MeetingExportRenderer.taskDetails(t, options: options)
                add(box + "\t" + parts.joined(separator: " · ") + time(t.time), font: body, style: listStyle)
            }
        }
        if !e.openQuestions.isEmpty {
            heading(String(localized: "Open questions", comment: "Exported minutes: section title"))
            bullets(e.openQuestions)
        }
        if options.includeTranscript && !e.transcript.isEmpty {
            heading(String(localized: "Transcript", comment: "Exported minutes: section title"))
            let small = NSFont.systemFont(ofSize: 10)
            let bold = NSFont.boldSystemFont(ofSize: 10)
            let paused = MeetingPause.places(of: e.pauses, among: e.transcript.map(\.start))
            // Where the recording was paused: nothing was captured, so the gap in the times is not a silence.
            func pauses(at i: Int) {
                for pause in paused[i] ?? [] {
                    let p = NSMutableAttributedString(string: "— " + pause.text(clock: ExportTimestamp.clock) + " —\n",
                                                      attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: secondary])
                    p.addAttribute(.paragraphStyle, value: paragraph(spacingBefore: 0, after: 4), range: NSRange(location: 0, length: p.length))
                    out.append(p)
                }
            }
            for (i, line) in e.transcript.enumerated() {
                pauses(at: i)
                let p = NSMutableAttributedString(string: "[\(ExportTimestamp.clock(line.start))] ",
                                                  attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                               .foregroundColor: secondary])
                p.append(NSAttributedString(string: SingleLineText.flatten(options.speaker(of: line)) + ": ", attributes: [.font: bold, .foregroundColor: NSColor.black]))
                p.append(NSAttributedString(string: line.text + "\n", attributes: [.font: small, .foregroundColor: NSColor.black]))
                if let translation = line.translation(options) {
                    p.append(NSAttributedString(string: translation + "\n", attributes: [.font: small, .foregroundColor: secondary]))
                }
                p.addAttribute(.paragraphStyle, value: paragraph(spacingBefore: 0, after: 4), range: NSRange(location: 0, length: p.length))
                out.append(p)
            }
            pauses(at: e.transcript.count)
        }
        return out
    }
}
