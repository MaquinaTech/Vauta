// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// Apple's model can't be used (yet): the reason in one line and what to do, not a card that looks like an offer.
struct AppleUnavailableRow: View {
    let availability: AppleChatModel.Availability
    /// A Mac with little memory has no model server to set up on it: the way out is a server on another computer.
    let enoughMemory: Bool

    private var reason: String {
        switch availability {
        case .deviceNotEligible: String(localized: "This Mac can’t run Apple Intelligence.", comment: "Setup: why Apple Intelligence can't write minutes")
        case .appleIntelligenceNotEnabled: String(localized: "Apple Intelligence is turned off.", comment: "Setup: why Apple Intelligence can't write minutes")
        case .modelNotReady: String(localized: "Apple Intelligence is still downloading.", comment: "Setup: why Apple Intelligence can't write minutes")
        default: String(localized: "Apple Intelligence isn’t available right now.", comment: "Setup: why Apple Intelligence can't write minutes")
        }
    }

    /// What to do: every unavailable state ends with a next step. A Mac with little memory is sent to a server, not to a
    /// model server on this Mac.
    private var hint: String {
        switch (availability, enoughMemory) {
        case (.appleIntelligenceNotEnabled, true):
            String(localized: "Turn it on, or set up a model below.", comment: "Setup: what to do when Apple Intelligence is off")
        case (.appleIntelligenceNotEnabled, false):
            String(localized: "Turn it on, or use a model server below.", comment: "Setup: what to do when Apple Intelligence is off, on a Mac with little memory")
        case (.modelNotReady, true):
            String(localized: "It will appear here when the download finishes. Or set up a model below.", comment: "Setup: what to do while Apple Intelligence downloads")
        case (.modelNotReady, false):
            String(localized: "It will appear here when the download finishes. Or use a model server below.", comment: "Setup: what to do while Apple Intelligence downloads, on a Mac with little memory")
        case (_, true):
            String(localized: "For minutes, set up a model below.", comment: "Setup: what to do when Apple Intelligence can't be used")
        case (_, false):
            String(localized: "For minutes, use a model server below.", comment: "Setup: what to do when Apple Intelligence can't be used, on a Mac with little memory")
        }
    }

    private var canOpenSettings: Bool { availability == .appleIntelligenceNotEnabled || availability == .modelNotReady }

    var body: some View {
        // The same padding, text column and button place (on the reason's line when it fits, otherwise under the hint,
        // trailing) as the choice card below.
        HStack(alignment: .top, spacing: OnboardingMetrics.choiceIconGap) {
            StatusSymbol.info.image
                .font(.title3)
                .frame(width: OnboardingMetrics.choiceIconWidth)
                .accessibilityHidden(true)
            // A semibold title without its full stop and the next step under it, with the metrics of the choice cards
            // below (same title row, same gap), with or without the button.
            ChoiceCardLayout {
                Text(wrapping: reason.droppingFinalStop.keepingLastWordsTogether).noticeTitle().fixedSize(horizontal: false, vertical: true)
                Text(wrapping: hint.keepingLastWordsTogether).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if canOpenSettings { settingsButton }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(OnboardingMetrics.choicePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var settingsButton: some View {
        if canOpenSettings {
            Button("Open System Settings") { Permissions.open(.appleIntelligence) }.fixedSize()
        }
    }
}

/// A large option with an icon, a title (and a badge) with its button trailing on the same line, and a short explanation below.
struct ChoiceCard<Action: View>: View {
    enum Badge {
        /// A fact (the quality of Apple's model): neutral.
        case neutral(String)
        /// The advice (best minutes): in the accent colour.
        case recommended(String)

        var text: String {
            switch self {
            case .neutral(let text), .recommended(let text): text
            }
        }

        var isRecommended: Bool {
            if case .recommended = self { true } else { false }
        }
    }

    let symbol: String
    let title: String
    var badge: Badge?
    let details: [String]
    let selected: Bool
    /// Whether the card has a button; the selected Apple option has none.
    var hasAction = true
    @ViewBuilder var action: Action

    private var titleRow: some View {
        // The badge follows the title on its line, and drops under it when the line is too short (long names): the
        // button then still fits on the title line.
        TitleBadgeLayout {
            Text(title)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            if let badge { BadgeCapsule(badge.text, style: badge.isRecommended ? .recommended : .neutral).fixedSize() }
        }
    }

    private var detailTexts: some View {
        ForEach(details, id: \.self) { detail in
            SentenceLines(text: detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: OnboardingMetrics.choiceIconGap) {
            // The selection mark has one place in every card, whether or not the card has a button: the icon column,
            // where it takes the card's icon (the title says what the card is). VoiceOver gets the selected trait of the card.
            Image(systemName: selected ? "checkmark.circle.fill" : symbol)
                .symbolRenderingMode(.monochrome)
                .font(.title2)
                // One weight for every choice icon: apple.intelligence is a hairline next to the display and the magnifier otherwise.
                .fontWeight(.medium)
                .foregroundStyle(.tint)
                .frame(width: OnboardingMetrics.choiceIconWidth)
                .accessibilityHidden(true)
            // The button is on the title line when title, badge and button fit on one line (the details do not count);
            // otherwise the title (with its badge) keeps its line and the button goes under the details, trailing.
            ChoiceCardLayout(headerWraps: badge != nil) {
                titleRow
                VStack(alignment: .leading, spacing: 6) { detailTexts }
                if hasAction { action.fixedSize() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(OnboardingMetrics.choicePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(selected: selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lays out a choice card's content: the header row, the details, and the optional button. The button joins the
/// header row when the row's natural width plus the button fits the width offered, and goes under the details,
/// trailing, otherwise. Unlike a ViewThatFits, the length of the details plays no part in that decision.
struct ChoiceCardLayout: Layout {
    /// The space above a button that goes under the details.
    private static let buttonSpacing: CGFloat = 6
    /// The space between the header row and the details.
    var spacing: CGFloat = 6
    /// The height of a title row with a badge (a capsule is taller than the text): a title without one reserves it,
    /// so the description starts the same distance below the title in every card.
    var minimumRow: CGFloat = 20
    /// The least space between an inline button's bottom edge and the details when the button overhangs the row
    /// (nil: the button may overhang by `spacing`, as the cards do). The row grows to keep it.
    var actionClearance: CGFloat?
    /// The least space between the header row and an inline button.
    var gap: CGFloat = 8
    /// The header can give way (its badge drops under the title): the button stays on the title line when the header,
    /// so reduced, is no taller than a title with its badge under it.
    var headerWraps = false

    private struct Plan {
        var inline: Bool
        var header: CGSize
        var action: CGSize
        var details: CGSize
        var headerY: CGFloat
        var actionY: CGFloat
        var rowHeight: CGFloat
        var size: CGSize
    }

    private func plan(width proposed: CGFloat?, subviews: Subviews) -> Plan {
        let header = subviews[0], details = subviews[1]
        let action = subviews.count > 2 ? subviews[2] : nil
        let width = proposed ?? header.sizeThatFits(.unspecified).width
        let actionSize = action?.sizeThatFits(.unspecified) ?? .zero
        let natural = header.sizeThatFits(.unspecified).width
        var inline = action != nil && natural + gap + actionSize.width <= width
        if !inline, headerWraps, action != nil {
            let reduced = header.sizeThatFits(ProposedViewSize(width: max(0, width - actionSize.width - gap), height: nil))
            inline = reduced.height <= minimumRow * 2 + 8
        }
        let headerWidth = inline ? width - actionSize.width - gap : width
        let headerSize = header.sizeThatFits(ProposedViewSize(width: headerWidth, height: nil))
        var headerY: CGFloat = 0, actionY: CGFloat = 0, row = max(headerSize.height, minimumRow)
        if inline, let action {
            let hb = header.dimensions(in: ProposedViewSize(width: headerWidth, height: nil))[.firstTextBaseline]
            let ab = action.dimensions(in: .unspecified)[.firstTextBaseline]
            // The title keeps its place (every card has the same top inset); a taller button overhangs it, into
            // the card's padding and the gap below, so the two share a baseline and the details start the same
            // distance below the title in every card, with or without a button.
            actionY = hb - ab
            if let clearance = actionClearance {
                row = max(row, actionY + actionSize.height + clearance - spacing)
            }
        }
        let detailSize = details.sizeThatFits(ProposedViewSize(width: width, height: nil))
        var height = row + (detailSize.height > 0 ? spacing + detailSize.height : 0)
        if !inline, action != nil { height += Self.buttonSpacing + actionSize.height }
        return Plan(inline: inline, header: headerSize, action: actionSize, details: detailSize, headerY: headerY,
                    actionY: actionY, rowHeight: row, size: CGSize(width: width, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(width: proposal.width, subviews: subviews).size
    }

    /// The first baseline is the header's, so an icon beside the layout can line up with the title's text.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let header = subviews.first else { return nil }
        let p = plan(width: bounds.width, subviews: subviews)
        let width = p.inline ? bounds.width - p.action.width - gap : bounds.width
        return bounds.minY + p.headerY + header.dimensions(in: ProposedViewSize(width: width, height: nil))[.firstTextBaseline]
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(width: bounds.width, subviews: subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + p.headerY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: p.inline ? bounds.width - p.action.width - gap : bounds.width, height: nil))
        var y = bounds.minY + p.rowHeight + spacing
        subviews[1].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        y += p.details.height + Self.buttonSpacing
        if subviews.count > 2 {
            if p.inline {
                subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + p.actionY), anchor: .topTrailing, proposal: .unspecified)
            } else {
                subviews[2].place(at: CGPoint(x: bounds.maxX, y: y), anchor: .topTrailing, proposal: .unspecified)
            }
        }
    }
}

/// A title and its badge: on one row, first baselines together, when they fit the width offered; otherwise the badge
/// goes under the title, leading. Its first baseline is the title's.
struct TitleBadgeLayout: Layout {
    private let gap: CGFloat = 8
    private let stackedGap: CGFloat = 4

    private func rowFits(_ width: CGFloat?, _ subviews: Subviews) -> Bool {
        guard subviews.count > 1 else { return true }
        guard let width else { return true }
        return subviews[0].sizeThatFits(.unspecified).width + gap + subviews[1].sizeThatFits(.unspecified).width <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let title = subviews[0].sizeThatFits(proposal)
        guard subviews.count > 1 else { return title }
        let badge = subviews[1].sizeThatFits(.unspecified)
        if rowFits(proposal.width, subviews) {
            let tb = subviews[0].dimensions(in: proposal)[.firstTextBaseline], bb = subviews[1].dimensions(in: .unspecified)[.firstTextBaseline]
            let top = max(tb, bb)
            let bottom = max(title.height - tb, badge.height - bb)
            return CGSize(width: title.width + gap + badge.width, height: top + bottom)
        }
        return CGSize(width: max(title.width, badge.width), height: title.height + stackedGap + badge.height)
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline else { return nil }
        let title = subviews[0].dimensions(in: ProposedViewSize(width: bounds.width, height: nil))[.firstTextBaseline]
        guard subviews.count > 1, rowFits(bounds.width, subviews) else { return bounds.minY + title }
        let badge = subviews[1].dimensions(in: .unspecified)[.firstTextBaseline]
        return bounds.minY + max(title, badge)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let titleProposal = ProposedViewSize(width: bounds.width, height: nil)
        guard subviews.count > 1 else {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: titleProposal)
            return
        }
        let title = subviews[0].sizeThatFits(titleProposal)
        if rowFits(bounds.width, subviews) {
            let tb = subviews[0].dimensions(in: titleProposal)[.firstTextBaseline], bb = subviews[1].dimensions(in: .unspecified)[.firstTextBaseline]
            let top = max(tb, bb)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top - tb), anchor: .topLeading, proposal: titleProposal)
            subviews[1].place(at: CGPoint(x: bounds.minX + title.width + gap, y: bounds.minY + top - bb), anchor: .topLeading, proposal: .unspecified)
        } else {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: titleProposal)
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + title.height + stackedGap), anchor: .topLeading, proposal: .unspecified)
        }
    }
}
