// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

extension AskView {
    /// The state of an answer that is not simply verified: the first element of the card, so VoiceOver reads it first ("Answer, not verified").
    @ViewBuilder
    private func stateBadge(_ answer: VerifiedAnswer) -> some View {
        switch answer.kind {
        case .unverified, .cutShort:
            // A tinted capsule at body size, so an unchecked answer is not skimmed past as if it were a verified one.
            Label {
                Text("Not verified", comment: "Ask: badge at the top of an answer none of whose claims could be checked").font(.callout.bold())
            } icon: {
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.16)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Answer, not verified", comment: "VoiceOver: the first thing read of an answer none of whose claims could be checked"))
        case .notYet:
            Label {
                Text("Not yet", comment: "Ask: badge at the top of the answer to a question about something that has not happened yet in the meeting").font(.caption.bold())
            } icon: {
                Image(systemName: "clock").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Answer: it hasn’t come up yet", comment: "VoiceOver: the first thing read of the answer to a question about something that has not happened yet"))
        case .partlyVerified:
            Label {
                Text("Partly verified", comment: "Ask: badge at the top of an answer some of whose claims could be checked and some could not").font(.caption.bold())
            } icon: {
                Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Answer, partly verified", comment: "VoiceOver: the first thing read of an answer some of whose claims could not be checked"))
        case .related:
            // Like Not verified, at body size and tinted: the quotes are in the transcript, but the card may not answer the question.
            Label {
                Text("Only related", comment: "Ask: badge at the top of an answer whose quoted moments are in the transcript but only touch the topic").font(.callout.bold())
            } icon: {
                Image(systemName: "link").foregroundStyle(.orange)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.16)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Answer, only related", comment: "VoiceOver: the first thing read of an answer whose quoted moments may not answer the question"))
        case .verified, .notFound:
            EmptyView()
        }
    }

    func answerView(_ answer: VerifiedAnswer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            stateBadge(answer)
            HStack(alignment: .firstTextBaseline) {
                ProtectedText(answer.kind == .notYet ? AskModel.notYetText : answer.answer).font(.body)
                    // What could not be checked reads quieter than what was.
                    .foregroundStyle(answer.isUnverified || answer.kind == .related ? .secondary : .primary)
                Spacer()
                // Like "Rewrite Minutes": a bordered menu whose button copies as Markdown; the arrow offers plain text. Nothing to copy
                // when the answer only says that nothing was found.
                if answer.found, answer.kind != .notYet {
                Menu {
                    Button("Copy Answer as Plain Text") { copy(markdown: false) }
                } label: {
                    Text("Copy Answer")
                } primaryAction: {
                    copy(markdown: true)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help("Copy the answer with its sources")
                }
            }
            if answer.kind == .notYet, !answer.claims.isEmpty {
                Text("Related so far", comment: "Ask: heading over the moments already said that are related to a question about something that has not happened yet")
                    .font(.caption.bold()).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            } else if answer.isUnverified, answer.claims.contains(where: { !$0.citations.isEmpty }) {
                Text("Moments the model pointed to", comment: "Ask: heading over the moments an unverified answer cites")
                    .font(.caption.bold()).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            }
            if answer.kind == .notYet {
                // Only the moments, as links: the withheld answer's claims are not shown, so nothing here reads as a verified fact.
                notYetMoments(answer)
            }
            ForEach(Array((answer.kind == .notYet ? [] : answer.claims).enumerated()), id: \.offset) { _, claim in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Only related: the quote is in the transcript but may not answer the question, so no green seal.
                    Image(systemName: answer.kind == .related && claim.verified ? "text.quote" : claim.verified ? "checkmark.seal.fill" : "questionmark.circle")
                        .foregroundStyle(answer.kind == .related && claim.verified ? Color.secondary : claim.verified ? .green : .orange)
                        .help(claim.isFromDocumentsOnly
                              ? (claim.verified ? Text("Verified: the quote appears word for word in your document") : Text("Not verified: the quote doesn’t appear as such"))
                              : (claim.verified ? Text("Verified: the quote appears word for word in the transcript") : Text("Not verified: the quote doesn’t appear as such")))
                        .accessibilityLabel(answer.kind == .related && claim.verified
                                            ? Text("Quote found", comment: "VoiceOver: a quote of an answer that is in the transcript while the answer may not answer the question")
                                            : claim.verified ? Text("Verified") : Text("Not verified"))
                    VStack(alignment: .leading, spacing: 4) {
                        ProtectedText(claim.text).foregroundStyle(claim.verified && answer.kind != .related ? .primary : .secondary)
                        if claim.isFromDocumentsOnly && claim.verified {
                            Text("From your documents").font(.caption).foregroundStyle(.secondary)
                        }
                        // Wraps to new lines: a claim can cite several passages with long meeting titles.
                        let labels = model.citationLabels(claim.citations)
                        TokenFlowLayout(spacing: 10) {
                            ForEach(Array(claim.citations.enumerated()), id: \.offset) { index, segment in
                                Button(labels[index]) { model.open(citation: segment) }
                                    .buttonStyle(.link)
                                    .lineLimit(1)
                                    .accessibilityHint(Text("Opens the transcript at this moment"))
                            }
                            ForEach(claim.documents) { citation in
                                Button { meetings.openDocument(citation) } label: {
                                    Label { Text(verbatim: citation.label) } icon: { Image(systemName: citation.format.symbol) }
                                }
                                .buttonStyle(.link)
                                .lineLimit(1)
                                .accessibilityLabel(Text(verbatim: citation.spokenLabel))
                                .accessibilityHint(Text("Opens the document at this passage"))
                            }
                        }
                    }
                }
            }
            // About the whole answer, not one more claim: set apart by a rule, no glyph, on the card's text edge.
            if answer.kind == .partlyVerified || answer.kind == .related {
                Divider().padding(.top, 2)
                Text(answer.kind == .related ? AskModel.relatedNote : AskModel.partlyVerifiedNote)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if answer.endsIncomplete {
                Divider().padding(.top, 2)
                Text(AskModel.endsIncompleteNote)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if answer.isUnverified {
                Divider().padding(.top, 2)
                Text(answer.cutShort && answer.claims.isEmpty ? AskModel.cutShortNote : AskModel.unverifiedNote(for: hasDocumentSources ? model.answeredScope : .meetings))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .vautaCardBackground()
    }

    /// The moments a "not yet" answer relates to: one link each, in the order they were said, without the model's sentences.
    private func notYetMoments(_ answer: VerifiedAnswer) -> some View {
        let segments = model.momentsInSpokenOrder(answer.claims)
        let labels = model.citationLabels(segments)
        return TokenFlowLayout(spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                Button(labels[index]) { model.open(citation: segment) }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .accessibilityHint(Text("Opens the transcript at this moment"))
            }
        }
    }

    private func copy(markdown: Bool) {
        guard !meetings.copyProtected else { meetings.alert = .copyProtected; return }
        guard let export = model.copyableAnswer() else { return }
        MeetingExporter.copy(markdown ? export.markdown() : export.plainText())
        meetings.show(.copied)
    }
}
