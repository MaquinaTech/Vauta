// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// A Mac with less than 16 GB: the honest answer instead of steps that would end in a slow model.
struct LowMemoryView: View {
    /// Apple Intelligence can write minutes on this Mac; otherwise it is not offered as the way out.
    let appleAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The memory is in the header; this is the why. avoidingWidow also joins the last characters of
            // Japanese and Chinese, which have no spaces to hold together.
            SentenceLines(text: String(localized: "The models Vauta recommends need at least 16 GB of memory to run well. On this Mac they would be slow or fail, so Vauta doesn’t suggest one."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let network = String(localized: "Use a model server on another computer with more memory.",
                                   comment: "Model guide: what to do on a small Mac without Apple Intelligence")
            if appleAvailable {
                VStack(alignment: .leading, spacing: SetupBulletStyle.spacing) {
                    Text("What you can do").fontWeight(.semibold)
                    // The options are the actionable part: normal text, one row each; a second sentence starts its own line.
                    // The second sentence is the setup page's card detail, word for word.
                    Label {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(wrapping: String(localized: "Keep Apple Intelligence on this Mac."))
                            SentenceLines(text: String(localized: "No setup and private, but minutes are shorter and less reliable."))
                        }
                    }
                        icon: { Image(systemName: "apple.intelligence") }
                    Label { SentenceLines(text: network) } icon: { Image(systemName: "network") }
                }
                .labelStyle(SetupBulletStyle())
            } else {
                // One way out is not a list: a sentence under the explanation.
                SentenceLines(text: network)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The result: what changed and what happens next.
struct DoneView: View {
    let summary: ModelGuideModel.Summary

    /// What happens to Ask, from the search that is really in use.
    private var searchSentence: String {
        if summary.embeddingsOff {
            String(localized: "Ask now searches by keyword. This server can’t search by meaning.",
                   comment: "Model guide result")
        } else if summary.keywordSearch {
            String(localized: "Ask keeps using keyword search, which did as well as search by meaning in our tests.", comment: "Model guide result")
        } else {
            String(localized: "Ask keeps searching by meaning.", comment: "Model guide result")
        }
    }

    /// What changed, then the one thing to remember, then the details. Everything starts at the sheet's leading margin
    /// (under the header's icon), as the body of every other sheet does.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The header says it is done (check mark and title); the result follows it.
            SentenceLines(text: String(localized: "Minutes are now written with \(summary.mainModel) in \(summary.serverName). The model runs on this Mac, so meeting text sent to it stays here.",
                                       comment: "Model guide result; arguments are a model name and an app name"))
                .fixedSize(horizontal: false, vertical: true)
            if let warning = summary.warning {
                FeedbackLabel(feedback: .init(kind: .warning, text: warning.avoidingWidow))
            }
            // The same level of emphasis as the setup's last page, where it is the detail of the Minutes row: secondary
            // callout text, like the notes under it, not a bold paragraph of its own.
            VStack(alignment: .leading, spacing: 4) {
                SentenceLines(text: String(localized: "Keep \(summary.serverName) open while you record and until the minutes are ready.",
                                           comment: "Model guide and setup last page; the argument is an app name like LM Studio"))
                    .font(.callout)
                    .foregroundStyle(Self.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fast = summary.fastModel {
                    footnote(String(localized: "\(fast) writes the live notes during a meeting.", comment: "Model guide result; the argument is a model name"))
                }
                // One note is one paragraph, so the gaps between notes are the only breaks: two sentences wrap, they do not
                // split into lines of their own with a tighter gap.
                footnote(searchSentence, paragraph: true)
                footnote(String(localized: "You can change this any time in Settings\u{00A0}→\u{00A0}Models.", comment: "Model guide result"))
            }
        }
    }

    /// The system's secondary label colour itself: the hierarchical `.secondary` of a view draws lighter on the white sheet.
    private static let secondary = Color(nsColor: .secondaryLabelColor)

    @ViewBuilder
    private func footnote(_ text: String, paragraph: Bool = false) -> some View {
        Group {
            if paragraph {
                Text(wrapping: text.avoidingWidow)
            } else {
                SentenceLines(text: text, alwaysSplit: true)
            }
        }
            .font(.callout)
            .foregroundStyle(Self.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Opens the model server documentation in the browser; the arrow says so.
struct ModelServerGuideLink: View {
    var body: some View {
        Link(destination: ModelQuality.guideURL) {
            HStack(spacing: 4) {
                Text("More About Model Servers")
                Image(systemName: "arrow.up.right").imageScale(.small).accessibilityHidden(true)
            }
        }
        .font(.callout)
    }
}

extension View {
    /// Records where this view sits in a named coordinate space, under `key`.
    func trackFrame(_ key: Int, in space: String, into frames: Binding<[Int: CGRect]>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frames.wrappedValue[key] = $0 }
    }
}
