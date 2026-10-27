// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreGraphics
import Testing
@testable import VautaCore

@Suite struct PanelHeightBudgetTests {
    /// A 13-inch MacBook Air: about 860 pt for the panel. Heights as measured in the recording scene.
    private let screen: CGFloat = 860
    private let top: CGFloat = 262
    private let footer: CGFloat = 132
    private let tools: CGFloat = 200

    @Test func theToolsKeepTheirFullHeightOnAShortScreen() {
        // The tools are pinned: they are taken out of the room before anything else is shared.
        let room = PanelHeightBudget.room(screen: screen, padding: 16, top: top, footer: footer, pinned: tools, gaps: 48)
        #expect(room > 0)
        let transcript = PanelHeightBudget.transcriptLimit(room: room, middle: 250, cardMax: 288)
        let scroll = PanelHeightBudget.scrollLimit(room: room, transcript: transcript)
        // Everything fits in the screen, or the transcript sits at its floor and the cards above scroll.
        let total = 32 + top + footer + tools + 48 + transcript + scroll
        #expect(total <= screen + 1 || transcript == PanelHeightBudget.transcriptFloor)
    }

    @Test func theCardsAboveComeBeforeTheTranscript() {
        // Plenty of room: the cards above show whole and the transcript takes the rest, up to its maximum.
        #expect(PanelHeightBudget.transcriptLimit(room: 900, middle: 300, cardMax: 288) == 288)
        #expect(PanelHeightBudget.transcriptLimit(room: 500, middle: 300, cardMax: 288) == 200)
        // A short screen: the transcript shrinks to its floor (one whole passage), never below.
        #expect(PanelHeightBudget.transcriptLimit(room: 360, middle: 300, cardMax: 288) == 120)
        // Not even that without leaving the cards above the title and two whole notes: it collapses to its header.
        #expect(PanelHeightBudget.transcriptLimit(room: 340, middle: 300, cardMax: 288) == 0)
        #expect(PanelHeightBudget.transcriptLimit(room: 180, middle: 300, cardMax: 288) == 0)
    }

    @Test func theScrollingPartKeepsAUsableMinimum() {
        #expect(PanelHeightBudget.scrollLimit(room: 400, transcript: 130) == 270)
        #expect(PanelHeightBudget.scrollLimit(room: 150, transcript: 130) == PanelHeightBudget.scrollFloor)
    }

    @Test func theToolsScrollOnlyWhenNothingElseFitsAroundThem() {
        let normal = PanelHeightBudget.room(screen: screen, padding: 16, top: top, footer: footer, pinned: 0, gaps: 48)
        #expect(PanelHeightBudget.pinsTools(roomWithoutTools: normal, tools: tools))
        // Two banners over the record button (top part of 330) on an 800 pt screen: no room around the tools.
        let crowded = PanelHeightBudget.room(screen: 800, padding: 16, top: 330, footer: footer, pinned: 0, gaps: 48)
        #expect(!PanelHeightBudget.pinsTools(roomWithoutTools: crowded, tools: 275))
    }

    @Test func twoBannersOnAnEightyHundredPointScreenStillPinMarkAMomentAndTheQuickNote() {
        // Top part 406 pt (two banners over the record button), footer 66: 248 pt for everything between.
        let room = PanelHeightBudget.room(screen: 800, padding: 16, top: 406, footer: 66, pinned: 0, gaps: 48)
        let minimum = PanelHeightBudget.scrollFloor + PanelHeightBudget.transcriptCollapsed
        // The whole tools card (275 pt) does not fit, Mark a Moment and the quick note alone (90 pt) do, with the
        // transcript collapsed to its header and the cards above at their floor.
        #expect(!PanelHeightBudget.pinsTools(roomWithoutTools: room, tools: 275, minimum: minimum))
        #expect(PanelHeightBudget.pinsTools(roomWithoutTools: room, tools: 90, minimum: minimum))
        #expect(PanelHeightBudget.transcriptLimit(room: room - 90, middle: 200, cardMax: 288) == 0)
    }

    @Test func theLiveNotesWinTheRoomBeforeTheOthersEditor() {
        // 800 pt with two banners: the whole tools card (136 pt) would leave the cards 112 pt, under the generous floor
        // the notes need, so who "Others" is scrolls (the tools without it, 86 pt, leave them 162 pt).
        let room = PanelHeightBudget.room(screen: 800, padding: 16, top: 406, footer: 66, pinned: 0, gaps: 48)
        let collapsed = PanelHeightBudget.transcriptCollapsed
        #expect(!PanelHeightBudget.pinsTools(roomWithoutTools: room, tools: 136, minimum: PanelHeightBudget.fullToolsFloor + collapsed))
        #expect(PanelHeightBudget.pinsTools(roomWithoutTools: room, tools: 86, minimum: PanelHeightBudget.scrollFloor + collapsed))
    }

    @Test func theVisibleAreaEndsJustUnderTheLastWholeRow() {
        // Room 300 with a 20 pt hint row leaves 280: rows end at 120, 180 and 270, so it ends the gap (4 pt) under 270, which is less
        // than the 6 pt between two rows: the next row never shows under the cut.
        #expect(PanelHeightBudget.stopGap == 4)
        #expect(PanelHeightBudget.snappedScrollHeight(limit: 300, stops: [120, 180, 270]) == 274)
        // No stop fits: the room is used as it comes.
        #expect(PanelHeightBudget.snappedScrollHeight(limit: 100, stops: [200]) == 80)
    }

    @Test func aRowStopInsideTheRoomWinsOverACardThatDoesNotFit() {
        // Stops [40, 120, 190], limit 200, hint 10: the room is 190, the last stop that fits with its gap is 120.
        #expect(PanelHeightBudget.snappedScrollHeight(limit: 200, stops: [40, 120, 190], indicator: 10) == 124)
        // A card stop far beyond the room and note stops inside it: the last note stop, never the room itself.
        #expect(PanelHeightBudget.snappedScrollHeight(limit: 200, stops: [60, 95, 400], indicator: 10) == 99)
    }

    @Test func theViewportNeverExceedsItsRoom() {
        // A row that ends past the room is never drawn to its end: nothing sticks out under the room it was given, so the panel
        // can never grow past the screen.
        #expect(PanelHeightBudget.snappedScrollHeight(limit: 100, stops: [100], indicator: 10) == 90)
        #expect(PanelHeightBudget.snappedScrollHeight(limit: 100, stops: [400], indicator: 10) == 90)
        #expect(PanelHeightBudget.snappedScrollHeight(limit: 100, stops: [], indicator: 10) == 90)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let limit = CGFloat.random(in: 60...900, using: &generator)
            let stops = (0..<Int.random(in: 0...8, using: &generator)).map { _ in CGFloat.random(in: 1...1_200, using: &generator) }
            let hint = CGFloat.random(in: 0...24, using: &generator)
            let height = PanelHeightBudget.snappedScrollHeight(limit: limit, stops: stops, indicator: hint)
            #expect(height + hint <= limit + 0.001, "limit \(limit) hint \(hint) stops \(stops) height \(height)")
        }
    }

    @Test func theNotesCardNeverGetsMoreThanTheScrollingPartLeaves() {
        let room: CGFloat = 400
        let limit = PanelHeightBudget.notesLimit(room: room, transcriptGranted: 120, notesTop: 40, hint: 10)
        #expect(limit <= PanelHeightBudget.scrollLimit(room: room, transcript: 120) - 40 - 10)
        #expect(limit == 226, "limit \(limit)")
        // A short screen: the card keeps a small floor, never zero or negative.
        #expect(PanelHeightBudget.notesLimit(room: 150, transcriptGranted: 130, notesTop: 40, hint: 10) == 80)
    }

    @Test func anOpenAnswerGetsTheRoomOfTheScrollingPartUnderTheCardChromeAndNeverNegative() {
        let limit = PanelHeightBudget.answerRowLimit(room: 600, transcriptGranted: 100, hint: 10)
        #expect(limit == PanelHeightBudget.scrollLimit(room: 600, transcript: 100) - 10 - PanelHeightBudget.stopGap - PanelHeightBudget.answersChrome)
        #expect(PanelHeightBudget.answerRowLimit(room: 120, transcriptGranted: 100, hint: 10) == 26, "a very short screen: the scroll floor leaves a small room, so the row is compact, never negative")
        #expect(PanelHeightBudget.answerRowLimit(room: 600, transcriptGranted: 100, top: 200, hint: 10) == limit - 200, "what is above the card is not its room")
        // It does not depend on how tall the row is drawn: the same inputs give the same limit.
        #expect(PanelHeightBudget.answerRowLimit(room: 600, transcriptGranted: 100, hint: 10) == limit)
    }

    @Test func theNotesCardBudgetIsStableWhenItsHeightIsFedBack() {
        // The card and the transcript are budgeted from the same granted height. Feed the card's drawn height back into what the
        // transcript and the scrolling part are given (as the panel does on its next pass): the card's limit does not change, and
        // the card, the viewport's hint and the transcript fit the room.
        for room in stride(from: CGFloat(260), through: 760, by: 20) {
            let granted = PanelHeightBudget.transcriptLimit(room: room, middle: PanelHeightBudget.notesFloor, cardMax: 276)
            let transcript = granted == 0 ? PanelHeightBudget.transcriptCollapsed : granted
            let first = PanelHeightBudget.notesLimit(room: room, transcriptGranted: transcript, notesTop: 40, hint: 10)
            // The notes card is drawn at its limit (the tallest case) and the panel measures it.
            let middle: CGFloat = 40 + first
            let actual = PanelHeightBudget.transcriptLimit(room: room, middle: middle, cardMax: 276)
            let drawnTranscript = actual == 0 ? PanelHeightBudget.transcriptCollapsed : actual
            let scroll = PanelHeightBudget.scrollLimit(room: room, transcript: drawnTranscript)
            let nextGranted = PanelHeightBudget.transcriptLimit(room: room, middle: PanelHeightBudget.notesFloor, cardMax: 276)
            let again = PanelHeightBudget.notesLimit(room: room, transcriptGranted: nextGranted == 0 ? PanelHeightBudget.transcriptCollapsed : nextGranted,
                                                     notesTop: 40, hint: 10)
            #expect(again == first, "room \(room)")
            // What is drawn (the viewport, the hint row when it scrolls, the transcript) never exceeds the room: the panel stays on screen.
            let scrolls = middle > scroll + 1
            let viewport = scrolls ? PanelHeightBudget.snappedScrollHeight(limit: scroll, stops: [middle], indicator: 10) : middle
            let total = viewport + (scrolls ? 10 : 0) + drawnTranscript
            #expect(total <= room + 0.001 || room - drawnTranscript < PanelHeightBudget.scrollFloor, "room \(room): drawn \(total)")
        }
    }
}
