// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// The one card that recommends setting up a model server, in Meetings, Settings → Models and the
/// last setup page: a tinted icon, the title on the first line, the
/// reason under it, an optional documentation link, and the action trailing on the title's line.
/// A dismissible card puts its ✕ at the end of the title's line, after the action, so both share the title's baseline.
/// The reason, badge and link are 8 pt apart.
struct RecommendationCard: View {
    /// Inset and icon column. The setup pages use their own (the rows and bullets of the cards around it), so text lines up.
    struct Metrics {
        let inset: CGFloat
        let iconWidth: CGFloat
        let iconGap: CGFloat
        /// Title to reason: the gap of every notice, except in setup, where the choice cards around it set it.
        var titleSpacing: CGFloat = NoticeMetrics.gap
        /// Top and bottom inset when it differs from `inset`.
        var verticalInset: CGFloat?
        /// A row of a Settings card, not a banner: no tinted background and no inset, so its icon sits in the icon column of
        /// the status rows above it and its title on their text edge; the action is centred on the two lines.
        var isRow = false
        /// The action does not set the title row's height (it overhangs, on the title's baseline), as in the choice cards of
        /// setup, so the title and the reason are as far apart as in the card above.
        var actionOverhangs = false

        /// Inside a Settings card: a row like the status row above it (the icon column and text edge of its notice).
        static let settings = Metrics(inset: 0, iconWidth: 16, iconGap: 8, titleSpacing: NoticeMetrics.gap, verticalInset: 0, isRow: true)
        /// As the notices of Meetings (`noticeCard`): 12 pt sides, 10 pt top and bottom, the 20 pt icon column and its 8 pt gap.
        static let standard = Metrics(inset: 12, iconWidth: SourceBadge.columnWidth, iconGap: 8, verticalInset: 10)
        /// As `OnboardingCard` rows: the inset of a card, and the 22 pt bullet column with a 10 pt gap.
        /// The same top and bottom inset as those rows (10 pt), not the 14 pt of the large choice cards.
        static let setup = Metrics(inset: OnboardingMetrics.cardInset, iconWidth: 22, iconGap: 10, titleSpacing: 6, verticalInset: 10,
                                   actionOverhangs: true)
    }

    let title: String
    let reason: String
    var symbol = ModelGuideSheet.localModelSymbol
    /// What the badge qualifies is the model in use now, not the recommendation: it goes under the reason.
    var badge: String?
    /// The size of the action: regular in Settings and setup; small next to the other banners of the Meetings page.
    var controlSize: ControlSize = .regular
    /// The reason's font: the callout of a notice, or the Settings rows' subtitle size inside a form.
    var reasonFont: Font = .callout
    var metrics = Metrics.standard
    let actionTitle: String
    var actionHelp: String?
    var onDismiss: (() -> Void)?
    let action: () -> Void

    var body: some View {
        if metrics.isRow { row } else { banner }
    }

    /// A Settings row: the icon and the two lines, with the action centred on them (it doesn't set the title's height).
    private var row: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.iconGap) {
                // The status rows' size and fill variant (the green check above it is filled, at the body size).
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .symbolVariant(.fill)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: metrics.iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: metrics.titleSpacing) {
                    // The same weight as the status row above it in the card: the invitation doesn't outrank the active choice.
                    Text(title).font(.body).fixedSize(horizontal: false, vertical: true)
                    Text(description: reason).font(reasonFont).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let badge { BadgeCapsule(badge).padding(.top, 6) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionButton
            if let onDismiss { dismissButton(onDismiss) }
        }
        .accessibilityElement(children: .contain)
    }

    private var banner: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.iconGap) {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: metrics.iconWidth)
                // Centred on the title's x-height, not on the (taller) row of title and action.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                .accessibilityHidden(true)
            bannerText
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, metrics.inset)
        .padding(.vertical, metrics.verticalInset ?? metrics.inset)
        .bannerBackground(.accentColor)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var bannerText: some View {
        if metrics.actionOverhangs {
            // The title row is as tall as its text (a bordered button is taller): the button joins it when it fits and
            // goes under the reason otherwise, as in the choice cards.
            ChoiceCardLayout(spacing: metrics.titleSpacing, minimumRow: 20) {
                Text(title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    SentenceLines(text: reason).font(reasonFont).foregroundStyle(.primary.opacity(0.78))
                    if let badge { BadgeCapsule(badge).padding(.top, 6) }
                }
                HStack(spacing: 8) {
                    actionButton
                    if let onDismiss { dismissButton(onDismiss) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: metrics.titleSpacing) {
                // The action takes only the title's line: the reason, badge and link have the whole text width below it.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    actionButton
                    if let onDismiss { dismissButton(onDismiss) }
                }
                // Secondary grey on the tinted banner is under 4.5:1 in light mode: the primary colour, softened.
                SentenceLines(text: reason).font(reasonFont).foregroundStyle(.primary.opacity(0.78))
                if let badge { BadgeCapsule(badge).padding(.top, 6) }
            }
        }
    }

    private var actionButton: some View {
        Button(actionTitle, action: action)
            .controlSize(controlSize)
            .help(actionHelp ?? "")
    }

    private func dismissButton(_ dismiss: @escaping () -> Void) -> some View {
        Button(action: dismiss) {
            Image(systemName: "xmark").imageScale(.small)
        }
        .buttonStyle(.borderless)
        .help("Don’t show this again")
        .accessibilityLabel(Text("Dismiss Recommendation"))
    }
}
