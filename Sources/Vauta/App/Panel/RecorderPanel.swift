// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The menu-bar panel. The header, the record button with what is urgent under it (audio warnings, the
/// automatic-stop countdown), the tools used while recording (Mark a Moment, quick note, who "Others" is) and
/// the footer stay put; the cards between them scroll when the panel would be taller than the screen, so the
/// tools, Settings and Quit are always reachable. The transcript has its own room under the cards (a sibling,
/// not nested in the scroll), so one scroll gesture moves one thing, and it is the first to give room up.
struct RecorderPanel: View {
    @Bindable var model: RecorderModel
    @Environment(\.panelMaxHeight) private var maxHeightOverride
    @ViewLocalState private var topHeight: CGFloat = 0
    @ViewLocalState private var footerHeight: CGFloat = 0
    @ViewLocalState private var contentHeight: CGFloat = 0
    /// The pinned (or scrolling) tools block as drawn now, and the "Others" part of it, wherever it is drawn.
    @ViewLocalState private var toolsHeight: CGFloat = 0
    @ViewLocalState private var othersHeight: CGFloat = 0
    @ViewLocalState private var toolsIncludeOthers = true
    @ViewLocalState private var transcriptHeight: CGFloat = 0
    @ViewLocalState private var canScrollUp = false
    @ViewLocalState private var canScrollDown = false
    /// Where the rows that may end the visible area end, in the scrolling content (see `PanelRowStop`).
    @ViewLocalState private var rowStops: [CGFloat] = []
    /// Where the live notes card starts in the scrolling content: what is above it is not the notes' room.
    @ViewLocalState private var notesTop: CGFloat = 0
    /// Where the Answers card starts in the scrolling content: what is above it is not the answer's room.
    @ViewLocalState private var answersTop: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let width: CGFloat = 360
    private static let padding: CGFloat = 16
    private static let spacing: CGFloat = 12

    var body: some View {
        VStack(spacing: Self.spacing) {
            VStack(spacing: Self.spacing) {
                PanelHeader(model: model)
                if hasProblem {
                    PanelWarnings(model: model, scope: .problem)
                }
                if let suggestion = model.suggestion, !model.isRecording {
                    SuggestionBanner(model: model, suggestion: suggestion)
                }
                if model.missingModel != nil {
                    SpeechModelBanner(model: model)
                }
                // The brief of the meeting about to start: above the record button, under the banners (it replaces nothing).
                BriefCardView(model: model)
                // After a meeting: review its tasks and follow-up meetings (gone after 2 hours, hidden while recording).
                FollowUpCardView(model: model)
                // One call to action at a time: while a banner asks for something first (record this call, download the speech model), the button steps back.
                RecordButton(model: model, isMuted: (model.suggestion != nil || model.missingModel != nil) && !model.isRecording)
                // What the recording needs now never scrolls away: levels, audio warnings, the countdown.
                if showsStatus {
                    RecordingStatus(model: model)
                }
                if showsLiveWarnings {
                    PanelWarnings(model: model, scope: .live)
                }
                if model.isRecording, model.autoStopRemaining != nil || model.hangupNotice, !PanelWarnings.mergesCountdown(model) {
                    StopBanner(model: model)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { topHeight = $0 }

            // The tools used during the meeting never sit behind a scroll (unless the screen is so short that
            // nothing else would fit around them). The user's own notes are among them, above the live notes: what
            // the user typed comes first.
            if pinsTools {
                tools(showsOthers: toolsMode == .full)
            }

            // While the transcript is being saved there is nothing to scroll: no empty room above the footer.
            if hasMiddle {
                scrollingMiddle
            }

            if hasTranscript {
                TranscriptSection(model: model, maxBoxHeight: transcriptBoxLimit, isCollapsed: transcriptIsCollapsed)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { transcriptHeight = $0 }
            }

            PanelFooter(model: model)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { footerHeight = $0 }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        // Vauta's colours glow softly behind the header and the record button, as on the website.
        .background(alignment: .top) {
            PanelGlow(isRecording: model.isRecording).frame(height: topHeight + Self.padding * 2)
        }
        .environment(\.copyProtection, model.preferences.copyProtection)
        .background(WindowHardening())
        .writingToolsBehavior(.disabled)
        .task {
            model.refreshLaunchAtLogin()
            model.brief.refreshNext()
            await model.refreshLanguages()
        }
    }

    /// The scrolling part, as tall as its content up to the room the screen leaves. While it scrolls, the visible area
    /// ends just under a whole card or note (never through a row or on a heading), and the scroll hint has its own row
    /// under it, so nothing is faded or covered.
    private var scrollingMiddle: some View {
        VStack(spacing: 0) {
            ScrollView {
                middle
                    .coordinateSpace(name: PanelRowStop.space)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                    .onPreferenceChange(PanelRowStop.Key.self) { rowStops = $0 }
            }
            // A new answer never moves the scroll: the person may be reading the notes or typing in the quick note. It arrives at the top of
            // the scrolling part, where it is seen at once unless the person has scrolled down; VoiceOver hears "Answer available".
            .scrollIndicators(.automatic)
            .scrollIndicatorsFlash(onAppear: true)
            .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                let top = geometry.contentOffset.y + geometry.contentInsets.top
                let bottom = geometry.contentSize.height - geometry.containerSize.height - top
                return ScrollEdges(up: top > 1, down: bottom > 1)
            } action: { _, edges in
                canScrollUp = edges.up
                canScrollDown = edges.down
            }
            // More content above or below: the edge fades out, so a cut card never reads as the end. The bottom fades only
            // once the content has moved (at the top the cut is already on a row boundary).
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(canScrollUp ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(canScrollDown ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: canScrollUp ? 10 : 0)
                }
            }
            .frame(height: viewportHeight)
            .panelProbe(.panelViewport)
            // Under the cards, in a row of its own, a chevron says there is more: a cut card alone can read as a broken
            // panel, and a Mac without an always-visible scroller shows nothing else. The row stays when there is no more
            // (at the end), so the panel never changes height while it is scrolled.
            if scrolls {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(canScrollDown ? 1 : 0)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.hintHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .panelProbeCollects()
        // The hint sits in the gap under the cards, so the next card is not pushed far away from the last one.
        .padding(.bottom, scrolls ? -4 : 0)
    }

    private static let hintHeight: CGFloat = 10

    /// The viewport: all of the content, or (when it scrolls) the content up to the last whole row that fits.
    private var viewportHeight: CGFloat? {
        guard contentHeight > 0 else { return nil }
        guard scrolls else { return contentHeight }
        return min(contentHeight, PanelHeightBudget.snappedScrollHeight(limit: scrollLimit, stops: rowStops, indicator: Self.hintHeight))
    }

    /// The cards are taller than the room the screen leaves them.
    private var scrolls: Bool { contentHeight > scrollLimit + 1 }

    /// What scrolls: the consent helper, notices, Live Translation, live notes and tools.
    @ViewBuilder private var middle: some View {
        VStack(spacing: Self.spacing) {
            if model.isRecording, let prompt = model.consentPrompt {
                ConsentRow(model: model, prompt: prompt).panelRowStop()
            }
            // The brief the meeting started with: one collapsed row that never opens by itself.
            if model.isRecording, model.brief.recordingRow != nil {
                BriefRecordingRow(model: model).panelRowStop()
            }
            // What the meeting answers by itself is the first thing in the scrolling part: on a short screen a card below the live notes
            // is out of sight, and nothing tells the person it arrived. It takes room from the notes, never from the pinned tools, and
            // it does not move the scroll (the pinned tools and the quick note stay where they are; where the tools scroll, they stay first); each of its rows is a place where
            // the scrolling part may end.
            // Where nothing can be pinned, the tools are the first thing in the scroll, not buried under the notes or the card.
            if model.isRecording, toolsMode == .scrolling {
                tools(showsOthers: true).panelRowStop()
            }
            if model.isRecording, model.answers.isVisible {
                AnswersCard(model: model.answers, rowLimit: answerRowLimit, onTop: { answersTop = $0 }) { model.showSettings(.recording) }
            }
            // What the last recording left behind (why it stopped, a save error) comes first when nothing is recording.
            if !model.isRecording, showsGeneralWarnings {
                PanelWarnings(model: model, scope: .general).panelRowStop()
            }
            // On a short screen the live notes come first: they are what the meeting produces, and the switch
            // of Live Translation (set before the meeting, or from its shortcut) can sit under them.
            if model.isRecording, toolsMode != .full {
                LiveNotesView(model: model, maxHeight: notesLimit) { notesTop = $0 }.panelRowStop()
            }
            // Always there: the switch and the language can be set before the meeting starts. While the
            // transcript is being saved nothing can be captioned any more, so the card steps aside.
            if model.phase != .stopping {
                LiveTranslationRow(model: model).panelRowStop()
            }
            if model.isRecording, toolsMode == .full {
                LiveNotesView(model: model, maxHeight: notesLimit) { notesTop = $0 }.panelRowStop()
            }
            // Pinned Mark a Moment and quick note, with no room for who "Others" is beside them: it scrolls.
            if model.isRecording, toolsMode == .essential {
                OthersCard(model: model) { othersHeight = $0 }.panelRowStop()
            }
        }
    }

    /// Mark a Moment, the quick note, who "Others" is (when `showsOthers`), and the notices that follow them.
    private func tools(showsOthers: Bool) -> some View {
        VStack(spacing: Self.spacing) {
            LiveTools(model: model, showsOthers: showsOthers) { othersHeight = $0 }
            if showsGeneralWarnings {
                PanelWarnings(model: model, scope: .general)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { toolsHeight = $0; toolsIncludeOthers = showsOthers }
    }

    /// How much of the tools stays pinned under the scrolling cards.
    enum ToolsMode { case full, essential, scrolling }

    /// The room is given up in this order: the transcript (down to its header), who "Others" is (it scrolls before the
    /// live notes lose their room), the scrolling cards (down to their floor), the tools last. The whole tools card is
    /// pinned while the cards keep a generous room; on a shorter screen Mark a Moment and the quick note stay pinned
    /// and who "Others" is scrolls with the cards; only when even those do not fit does
    /// everything scroll (tools first).
    private var toolsMode: ToolsMode {
        guard model.isRecording else { return .scrolling }
        let room = PanelHeightBudget.room(screen: maxHeightOverride ?? PanelMetrics.screenLimit, padding: Self.padding,
                                          top: topHeight, footer: footerHeight, pinned: 0, gaps: gaps(pinned: true))
        // The cards above keep a usable room, and the transcript at least its header when it is on screen.
        let collapsed = hasTranscript ? PanelHeightBudget.transcriptCollapsed : 0
        let minimum = PanelHeightBudget.scrollFloor + collapsed
        let fullMinimum = PanelHeightBudget.fullToolsFloor + collapsed
        // The Others part and the gap before it are what the essential tools do without.
        let others = toolsIncludeOthers ? othersHeight + 10 : 0
        let full = toolsIncludeOthers ? toolsHeight : toolsHeight + others
        let essential = toolsIncludeOthers ? toolsHeight - others : toolsHeight
        if PanelHeightBudget.pinsTools(roomWithoutTools: room, tools: full, minimum: fullMinimum) { return .full }
        if PanelHeightBudget.pinsTools(roomWithoutTools: room, tools: essential, minimum: minimum) { return .essential }
        return .scrolling
    }


    /// Mark a Moment and the quick note are pinned (with or without who "Others" is).
    private var pinsTools: Bool { toolsMode != .scrolling }

    /// There is something to scroll unless the transcript is being saved with nothing else to say.
    private var hasMiddle: Bool { model.phase != .stopping || showsGeneralWarnings }

    private var showsStatus: Bool { model.isRecording || model.phase == .stopping }
    private var showsGeneralWarnings: Bool { PanelWarnings(model: model, scope: .general).isVisible }
    private var showsLiveWarnings: Bool { PanelWarnings(model: model, scope: .live).isVisible }
    private var hasTranscript: Bool { !model.segments.isEmpty || !model.volatileSegments.isEmpty }
    private var hasProblem: Bool { PanelWarnings(model: model, scope: .problem).isVisible }

    /// The gaps between the parts of the panel that are on screen.
    private func gaps(pinned: Bool) -> CGFloat {
        let parts = 2 + (hasMiddle ? 1 : 0) + (pinned ? 1 : 0) + (hasTranscript ? 1 : 0)
        return Self.spacing * CGFloat(parts - 1)
    }

    /// The room between the fixed top part and the footer on this screen, once the pinned tools are taken out.
    private var available: CGFloat {
        let pinned = pinsTools
        return PanelHeightBudget.room(screen: maxHeightOverride ?? PanelMetrics.screenLimit, padding: Self.padding,
                                      top: topHeight, footer: footerHeight, pinned: pinned ? toolsHeight : 0, gaps: gaps(pinned: pinned))
    }

    /// The tallest the live notes card may be: the room the scrolling cards have once the transcript has what it is
    /// granted, under what is above the card (`PanelHeightBudget.notesLimit`). The transcript is taken at the room it gets
    /// with the notes at their floor, not at the notes' height now, so the two never chase each other. A whole note,
    /// never a slice of one, ends the visible area.
    private var notesLimit: CGFloat {
        PanelHeightBudget.notesLimit(room: available, transcriptGranted: grantedTranscript, notesTop: notesTop, hint: Self.hintHeight)
    }

    /// The tallest an open answer may be for the viewport to show it whole (a taller one uses its compact layout). Like `notesLimit`, it
    /// does not depend on the height drawn now.
    private var answerRowLimit: CGFloat {
        PanelHeightBudget.answerRowLimit(room: available, transcriptGranted: grantedTranscript, top: answersTop, hint: Self.hintHeight)
    }

    /// The transcript card's height when the cards above it are at their floor: what `transcriptLimit` gives it, or its header alone.
    private var grantedTranscript: CGFloat {
        guard hasTranscript else { return 0 }
        let limit = PanelHeightBudget.transcriptLimit(room: available, middle: PanelHeightBudget.notesFloor, cardMax: Self.transcriptCardMax)
        // Not the height drawn now: that depends on the notes' height, and the two would chase each other.
        return limit == 0 ? PanelHeightBudget.transcriptCollapsed : limit
    }

    /// The tallest the whole transcript card may be: the cards above keep their natural height first.
    private var transcriptLimit: CGFloat {
        PanelHeightBudget.transcriptLimit(room: available, middle: contentHeight, cardMax: Self.transcriptCardMax)
    }

    /// What the passages inside the transcript card may use (the header and padding are the rest).
    private var transcriptBoxLimit: CGFloat { max(PanelHeightBudget.transcriptFloor - Self.transcriptChrome, transcriptLimit - Self.transcriptChrome) }

    /// The screen has no room for even one passage: the card keeps its header (the switch) and nothing else.
    private var transcriptIsCollapsed: Bool { transcriptLimit == 0 }

    /// The room left for the scrolling part on this screen.
    private var scrollLimit: CGFloat {
        PanelHeightBudget.scrollLimit(room: available, transcript: hasTranscript
                                      ? (transcriptIsCollapsed ? transcriptHeight : min(transcriptHeight, transcriptLimit)) : 0)
    }

    /// The transcript card's own height around its passages: header, the gap and the card padding.
    private static let transcriptChrome: CGFloat = 56
    private static let transcriptCardMax: CGFloat = TranscriptView.defaultMaxHeight + transcriptChrome
}

/// Whether there is more to scroll to above or below.
private struct ScrollEdges: Equatable {
    var up: Bool
    var down: Bool
}

/// App name, state and the privacy promise.
struct PanelHeader: View {
    let model: RecorderModel
    private static let icon = AppIconImage.image(points: 20)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(nsImage: Self.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(verbatim: "Vauta").font(.headline)
                Spacer()
                // The colour is on the glyph only: red or orange text on the light panel has too little contrast.
                HStack(spacing: 4) {
                    if let glyph = stateGlyph {
                        Image(systemName: glyph.name).foregroundStyle(glyph.color).accessibilityHidden(true)
                    }
                    if !stateText.isEmpty {
                        Text(verbatim: stateText).foregroundStyle(stateIsUrgent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    }
                }
                .font(.caption.weight(.medium))
            }
            Label("Encrypted on this Mac · Audio is never saved", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Audio is never saved to disk. Meetings and context are encrypted (AES-256) on this Mac. Meeting text leaves this Mac only through a model server on another computer, or in what you choose to add to Reminders, Calendar or an email.")
        }
        .accessibilityElement(children: .combine)
    }

    /// Recording is a red dot, a problem the error symbol; the words always carry the meaning too.
    private var stateGlyph: (name: String, color: Color)? {
        switch model.phase {
        case .recording: ("record.circle.fill", .red)
        case .failed: (StatusSymbol.error.name, StatusSymbol.error.color)
        default: nil
        }
    }

    private var stateIsUrgent: Bool { stateGlyph != nil }

    private var stateText: String {
        switch model.phase {
        case .opening: String(localized: "Opening…", comment: "Panel state")
        // While a backup replaces the meetings the panel is not "Ready": the header always has a state, as in every busy phase.
        case .idle:
            model.isErasing ? String(localized: "Erasing…", comment: "Panel state while Erase Everything runs")
                : model.isRestoring ? String(localized: "Restoring…", comment: "Panel state while a backup is restored")
                // Recording cannot work until the speech model of the chosen language is there: the header says so.
                : model.missingModel != nil ? (model.speechDownloadProgress != nil
                    ? String(localized: "Downloading…", comment: "Menu-bar panel, Live Translation: a language is downloading")
                    : String(localized: "Needs a download", comment: "Menu-bar panel, Live Translation: the language pair needs a one-time download"))
                : String(localized: "Ready", comment: "Panel state")
        case .starting: String(localized: "Starting…", comment: "Panel state")
        case .recording: String(localized: "state.recording", defaultValue: "Recording",
                                comment: "State: a meeting is being recorded right now (not the Settings pane)")
        case .stopping: String(localized: "Saving…", comment: "Panel state")
        case .failed: String(localized: "Needs attention", comment: "Panel state")
        }
    }
}

/// The bottom of a card or a note in the scrolling part, in the content's coordinates: where the visible area may end.
enum PanelRowStop {
    static let space = "panelMiddle"

    struct Key: PreferenceKey {
        static let defaultValue: [CGFloat] = []
        static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { value += nextValue() }
    }
}

extension View {
    /// `panelRowStop()` when `condition` holds.
    @ViewBuilder func panelRowStop(if condition: Bool) -> some View {
        if condition { panelRowStop() } else { self }
    }

    /// Marks the bottom of this view as a place where the scrolling part of the panel may end.
    func panelRowStop() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: PanelRowStop.Key.self, value: [proxy.frame(in: .named(PanelRowStop.space)).maxY])
        })
    }
}
