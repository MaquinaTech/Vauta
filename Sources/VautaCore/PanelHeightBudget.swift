// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreGraphics

/// How the menu-bar panel shares the height the screen leaves it. Room is given up in this order: the transcript
/// first (down to its header alone), then the scrolling cards (down to a floor), and the tools last: what the person
/// uses while recording (Mark a Moment, the quick note) is never cut.
public enum PanelHeightBudget {
    /// The least the scrolling cards are given on a short screen: the Live Translation card and the title with the
    /// first lines of the live notes.
    public static let scrollFloor: CGFloat = 96
    /// The room the cards keep before the transcript is given any: the Live Translation card and the live notes with
    /// their title and at least two whole notes, plus the empty room the fade and the scroll hint use. Under it the
    /// transcript collapses to its header.
    public static let notesFloor: CGFloat = 232
    /// The least the scrolling cards keep for the whole tools card (with who "Others" is) to stay pinned: the live
    /// notes win the room before the "Others" editor does, so on a short screen that editor scrolls instead.
    public static let fullToolsFloor: CGFloat = 160
    /// The transcript card with room for one whole passage (its speaker line and two lines of text) under the header.
    public static let transcriptFloor: CGFloat = 120
    /// The transcript card with only its header, when even one passage does not fit.
    public static let transcriptCollapsed: CGFloat = 48

    /// The room between the fixed top part and the footer, once the pinned tools and the gaps are taken out.
    public static func room(screen: CGFloat, padding: CGFloat, top: CGFloat, footer: CGFloat, pinned: CGFloat,
                            gaps: CGFloat) -> CGFloat {
        screen - padding * 2 - top - footer - pinned - gaps
    }

    /// Whether the tools stay pinned under the scrolling cards: while the screen leaves the cards at least
    /// `minimum` after them (the scroll floor, plus the transcript's header when it is on screen: the transcript
    /// collapses before the tools give way). With two banners on a short screen there is no such room, and the tools
    /// scroll with the cards (the footer and the buttons that fix the problem always stay reachable).
    public static func pinsTools(roomWithoutTools: CGFloat, tools: CGFloat, minimum: CGFloat = scrollFloor) -> Bool {
        roomWithoutTools - tools >= minimum
    }

    /// The tallest the transcript card may be: the cards above keep their natural height first; the transcript
    /// gets what is left, never less than `floor` and never more than `cardMax`. When even `floor` would push the
    /// cards above under their own floor, it is 0: the card collapses to its header.
    public static func transcriptLimit(room: CGFloat, middle: CGFloat, cardMax: CGFloat, floor: CGFloat = transcriptFloor,
                                       scrollFloor: CGFloat = notesFloor) -> CGFloat {
        let wanted = min(cardMax, room - middle)
        if wanted >= floor { return wanted }
        return room - floor >= scrollFloor ? floor : 0
    }

    /// The height of the scrolling part: its natural height, or what the transcript leaves.
    public static func scrollLimit(room: CGFloat, transcript: CGFloat, floor: CGFloat = scrollFloor) -> CGFloat {
        max(floor, room - transcript)
    }

    /// The empty room kept under the last whole row of the viewport. It is smaller than the 6 pt between two rows, so the next row
    /// never shows through under the cut.
    public static let stopGap: CGFloat = 4

    /// The height of the scrolling viewport, cut so the visible area ends on empty room, never through a row.
    /// `stops` are the bottoms (from the top of the content) of rows that may be the last one visible: whole cards and
    /// the notes inside the live notes card, never a heading. The viewport ends `gap` below the last stop that fits
    /// beside the `indicator` row (the scroll hint under the viewport). It is never taller than the room: with no stop that
    /// fits (a row taller than the whole viewport, which `notesLimit` and the floors are there to prevent), the room is used as it comes.
    public static func snappedScrollHeight(limit: CGFloat, stops: [CGFloat], gap: CGFloat = stopGap,
                                           indicator: CGFloat = 20) -> CGFloat {
        let budget = limit - indicator
        guard let stop = stops.filter({ $0 + gap <= budget }).max(), stop > 0 else { return budget }
        return stop + gap
    }

    /// The tallest the live notes card may be: the room the scrolling part leaves once the transcript has what it is
    /// granted, under what is above the card (`notesTop`) and the scroll hint. `transcriptGranted` is the transcript
    /// card's height with the notes at their floor (`notesFloor`), not as drawn now, so the card and the transcript never
    /// chase each other: the result does not depend on the notes' own height. Never less than `minimum`.
    public static func notesLimit(room: CGFloat, transcriptGranted: CGFloat, notesTop: CGFloat, hint: CGFloat,
                                  minimum: CGFloat = 80) -> CGFloat {
        max(minimum, scrollLimit(room: room, transcript: transcriptGranted) - notesTop - hint - stopGap)
    }

    /// The Answers card's own title, gaps and padding around its rows.
    public static let answersChrome: CGFloat = 56
    /// The tallest an open answer may be so that the viewport shows it whole: the room the scrolling part has once the transcript has
    /// what it is granted, under what is above the card, the card's own chrome and the scroll hint. Past it the row uses its compact layout. Never less than
    /// `minimum`.
    /// `top` is what sits above the card in the scrolling part (the tools, where they scroll).
    public static func answerRowLimit(room: CGFloat, transcriptGranted: CGFloat, top: CGFloat = 0, hint: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        max(minimum, scrollLimit(room: room, transcript: transcriptGranted) - top - hint - stopGap - answersChrome)
    }
}
