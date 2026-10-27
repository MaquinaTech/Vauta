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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
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

/// Warnings with the action that fixes them, when there is one. Each kind sits
/// next to what it is about: a problem that blocks recording above the record
/// button, audio warnings under the level meters, the rest at the end. Every
/// banner carries its own button, right under the words it fixes.
struct PanelWarnings: View {
    enum Scope {
        /// Recording can't start: above the record button.
        case problem
        /// Audio isn't arriving: under the level meters.
        case live
        /// Results of the last recording and other notices.
        case general
    }

    let model: RecorderModel
    let scope: Scope

    var isVisible: Bool { !banners.isEmpty }

    var body: some View {
        if isVisible {
            VStack(spacing: 8) {
                ForEach(banners) { banner in
                    bannerView(banner)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func bannerView(_ banner: Banner) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(banner.messages, id: \.self) { message in
                Label {
                    if let detail = message.detail {
                        // A title (a sentence from the system loses its full stop) and what it means, like every other
                        // notice in the panel.
                        PanelNoticeText(title: message.text.withoutTerminalPunctuation, detail: detail)
                    } else {
                        Text(paragraph: message.text.withTerminalPunctuation)
                    }
                } icon: {
                    banner.icon
                }
                .help(Text(verbatim: message.help ?? model.warningDetails[message.text] ?? ""))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !banner.fixes.isEmpty || banner.dismissible {
                // Three buttons that do not fit one row (the countdown with its way out): the two decisions stay together
                // and the sound settings, which never compete with them, go on a row of their own.
                ViewThatFits(in: .horizontal) {
                    fixRow(banner)
                    if banner.fixes.count == 3, banner.fixes.last == .openSoundSettings, !banner.dismissible {
                        VStack(alignment: .leading, spacing: 6) {
                            PanelActionRow { ForEach(banner.fixes.dropLast(), id: \.self) { fix in fixButton(fix.title, prominent: isProminent(fix, in: banner)) { perform(fix) } } }
                            fixButton(Fix.openSoundSettings.title, prominent: false) { perform(.openSoundSettings) }
                        }
                    }
                    fixRow(banner, stacked: true)
                }
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .controlSize(.small)
                .panelBannerActions()
            }
        }
        .panelBannerLabel(banner.style)
        .panelBanner(banner.style)
    }

    @ViewBuilder private func fixRow(_ banner: Banner, stacked: Bool = false) -> some View {
        let buttons = Group {
            ForEach(banner.fixes, id: \.self) { fix in
                if stacked {
                    FittingButton(title: fix.title, prominent: isProminent(fix, in: banner)) { perform(fix) }
                } else {
                    fixButton(fix.title, prominent: isProminent(fix, in: banner)) { perform(fix) }
                }
            }
            if banner.dismissible {
                Button("Dismiss") { dismiss(banner) }
            }
        }
        // Stacked is the last resort: a long title ("Open Login Items Settings" in German) takes two lines there.
        if stacked { VStack(alignment: .leading, spacing: 6) { buttons } } else { HStack(spacing: 8) { buttons } }
    }

    /// The button that fixes the problem is the prominent one; "Dismiss" stays quiet. A button that only opens System
    /// Settings gives way to the action of Vauta that comes with it (Try Again after freeing space), and the sound
    /// settings never compete with "Keep Recording" or "Stop and Save".
    private func isProminent(_ fix: Fix, in banner: Banner) -> Bool {
        switch fix {
        case .openSoundSettings: false
        // Next to "Keep Recording" (the countdown), saving now is the other choice, not a second main action.
        case .stopAndSave: !banner.fixes.contains(.keepRecording)
        // The record button is the panel's primary action below the problem banner (and the stop button while
        // recording): a banner under it never adds a second blue button. Above it, it is blocked and grey.
        case .openStorageSettings: scope == .problem && !banner.fixes.contains(.tryAgain)
        case .openPrivacySettings: !banner.fixes.contains(.tryAgain)
        default: true
        }
    }

    private func fixButton(_ title: Text, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { title }
            .prominentButton(prominent)
    }

    private func perform(_ fix: Fix) {
        switch fix {
        case .tryAgain: model.openStore()
        case .openPrivacySettings:
            if let pane = model.permissionProblem { NSWorkspace.shared.open(pane.url) }
        case .openSoundSettings:
            if let url = Self.soundSettings { NSWorkspace.shared.open(url) }
        case .openLoginItems: model.openLoginItemsSettings()
        case .openStorageSettings:
            if let url = Self.storageSettings { NSWorkspace.shared.open(url) }
        case .stopAndSave: model.stop()
        case .keepRecording: model.keepRecording()
        case .checkSpeakers: model.checkSpeakers()
        }
    }

    /// The automatic-stop countdown runs because no system audio arrives, and the warning about it is on screen: the two
    /// are one banner (the warning's, titled with the time left), so the panel does not show two orange cards for one cause.
    static func mergesCountdown(_ model: RecorderModel) -> Bool {
        guard model.isRecording, model.autoStopRemaining != nil, model.channelWarnings.count == 1,
              let warning = model.channelWarnings[.others] else { return false }
        return warning == CaptureError(.systemAudioLost).localizedDescription
    }

    private static let storageSettings = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")
    private static let soundSettings = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    /// The failed-phase banner can be dismissed once the store is open (there is nothing left to retry).
    private var canDismissProblem: Bool { !model.isRecording && isFailed && model.storeAvailable }

    /// "Dismiss" clears only the notice of the banner it sits in: a save failure, the last error or the stop notice.
    /// Only the failed-phase banner clears everything that blocked the last start.
    private func dismiss(_ banner: Banner) {
        switch banner.id {
        case "capture": model.captureAlert = nil
        case "save": model.saveError = nil
        case "error": model.lastError = nil
        case "stop": model.lastStopReason = nil
        case "empty": model.nothingRecorded = false
        case "speakers": model.speakersUpdated = false
        default: model.clearWarnings()
        }
    }

    /// One warning: a sentence, or a title with what it means under it.
    struct Message: Hashable {
        let text: String
        var detail: String?
        /// The detail when the banner is the stop countdown's too: the reason it is stopping comes first.
        var countdownDetail: String?
        /// The system's own text, shown as a tooltip.
        var help: String?
    }

    /// What a banner's button does.
    enum Fix: Hashable {
        case tryAgain, openPrivacySettings, openSoundSettings, openLoginItems, openStorageSettings, stopAndSave, keepRecording, checkSpeakers

        var title: Text {
            switch self {
            case .tryAgain: Text("Try Again")
            case .openPrivacySettings: Text("Open System Settings")
            case .openSoundSettings: Text("Open Sound Settings")
            case .openLoginItems: Text("Open Login Items Settings")
            case .openStorageSettings: Text("Open Storage Settings")
            case .stopAndSave: Text("Stop and Save")
            case .keepRecording: Text("Keep Recording")
            case .checkSpeakers: Text("Check Speakers", comment: "Button of the panel notice after a recording: opens the saved meeting’s transcript to check the speaker names")
            }
        }
    }

    /// Messages that belong together, the button that fixes them, and how serious they are. A button sits under
    /// the words it is about, so each banner holds one cause.
    struct Banner: Identifiable {
        let id: String
        var messages: [Message]
        var style: PanelBannerStyle = .warning
        var fixes: [Fix] = []
        var dismissible = false
        /// A symbol of its own instead of the style's (the countdown's timer).
        var symbolName: String?

        @ViewBuilder var icon: some View {
            if let symbolName {
                Image(systemName: symbolName)
            } else {
                styleIcon
            }
        }

        @ViewBuilder private var styleIcon: some View {
            switch style {
            case .error: StatusSymbol.error.image
            case .warning: StatusSymbol.warning.image
            // A notice, not a fault: the shared info symbol (the label style fills it, like the other banner symbols);
            // the blue card already marks it as a notice.
            case .info: StatusSymbol.info.image
            }
        }
    }

    private var banners: [Banner] {
        var out: [Banner] = []
        switch scope {
        case .problem:
            // A failure that blocks recording is an error, as in Settings → Status.
            if case .failed = model.phase {
                var fixes: [Fix] = []
                // A full disk is fixed in Storage; Try Again stays the prominent action once there is room.
                // The main action leads in every banner: Try Again first, then the place where the room is made.
                if !model.storeAvailable && model.phase != .opening { fixes.append(.tryAgain) }
                if !model.storeAvailable && model.storeOpenIsDiskFull { fixes.append(.openStorageSettings) }
                if model.permissionProblem != nil { fixes.append(.openPrivacySettings) }
                out.append(Banner(id: "problem", messages: messages, style: .error, fixes: fixes, dismissible: canDismissProblem))
            }
        case .live:
            // No system audio: say what to check, not only that it happened.
            let lostSystemAudio = CaptureError(.systemAudioLost).localizedDescription
            let appName = model.recordingApp?.shortName
            let channels = Channel.allCases.compactMap { model.channelWarnings[$0] }.map { warning -> Message in
                guard warning == lostSystemAudio else { return Message(text: warning, detail: nil) }
                // The title is the plain form the stop countdown uses; "system audio" stays in the technical error.
                let title = String(localized: "Vauta can’t hear the meeting.", comment: "Panel banner: why the recording is about to stop")
                // The status line above already names the app: the advice names it too. The same words as the capture alert.
                let detail = appName.map {
                    String(localized: "Check that \($0) isn’t muted and that its sound plays through this Mac.",
                           comment: "Panel warning: what to check when no system audio arrives, with the meeting app’s name (%@); under the title “Vauta can’t hear the meeting”")
                } ?? String(localized: "Check that the meeting app isn’t muted and that its sound plays through this Mac.",
                            comment: "Panel warning: what to check when no system audio arrives; under the title “Vauta can’t hear the meeting”")
                // The countdown banner keeps the reason in front of the advice (one string per language, never joined here).
                let reasonAndDetail = appName.map {
                    String(localized: "Vauta can’t hear the meeting. Check that \($0) isn’t muted and that its sound plays through this Mac.",
                           comment: "Panel banner while the recording is about to stop because no sound arrives, with the meeting app’s name (%@): why, then what to check; under the countdown title")
                } ?? String(localized: "Vauta can’t hear the meeting. Check that the meeting app isn’t muted and that its sound plays through this Mac.",
                            comment: "Panel banner while the recording is about to stop because no sound arrives: why, then what to check; under the countdown title")
                return Message(text: title, detail: detail, countdownDetail: reasonAndDetail)
            }
            // Nothing arriving on Others is one cause told twice when the capture already says so: one card, with the way out.
            let othersExplained = model.channelWarnings[.others] != nil
            if Self.mergesCountdown(model), let left = model.autoStopRemaining, let advice = channels.first?.countdownDetail ?? channels.first?.detail {
                // The countdown is the same silence the warning reports: one banner, with the time left as its title.
                out.append(Banner(id: "channels",
                                  messages: [Message(text: String(localized: "Stopping in \(StopBanner.countdown(left))",
                                                                  comment: "Panel banner title; the argument is a countdown like 1:30"),
                                                     detail: advice)],
                                  fixes: Self.soundSettings == nil ? [.keepRecording, .stopAndSave] : [.keepRecording, .stopAndSave, .openSoundSettings],
                                  symbolName: "timer.circle.fill"))
            } else if !channels.isEmpty {
                // Stop and Save leads (the main action); the sound settings, which never compete with it, follow.
                var fixes: [Fix] = othersExplained && model.silenceWarning != nil ? [.stopAndSave] : []
                if Self.soundSettings != nil { fixes.append(.openSoundSettings) }
                out.append(Banner(id: "channels", messages: channels, fixes: fixes))
            }
            // The same cause told with the meeting app and what to check, once per silent stretch; "Dismiss" closes it.
            // Not when the channels banner already names why Others is silent: that cause is known, the advice here is a guess.
            if let w = model.captureAlert, !othersExplained {
                var fixes: [Fix] = []
                if Self.soundSettings != nil { fixes.append(.openSoundSettings) }
                out.append(Banner(id: "capture", messages: [Message(text: w.title, detail: w.detail)], fixes: fixes, dismissible: true))
            }
            // The warning comes back while the silence lasts, so it is not dismissible; saving is the way out. It is also
            // what a call in an app that is not the recorded source gets: the alert only fires for the recorded source. The
            // meeting-app alert (shown, or dismissed during this silent stretch) already said it, in more words. Once sound
            // has really returned the alert is re-armed, and this banner is the warning until it fires again.
            if let w = model.silenceWarning, !othersExplained, !model.captureAlertCoversSilence {
                out.append(Banner(id: "silence", messages: [Message(text: w.title, detail: w.detail)], fixes: [.stopAndSave]))
            }
        case .general:
            if let w = model.saveError { out.append(failureBanner(id: "save", w)) }
            if let w = model.lastError { out.append(failureBanner(id: "error", w)) }
            if let reason = model.lastStopReason {
                // An automatic stop is an expected outcome, not a fault.
                out.append(Banner(id: "stop", messages: [Message(text: String(localized: "Recording stopped automatically", comment: "Panel warning title; the sentence under it says why"),
                                                                  detail: reason.explanation)], style: .info))
            }
            if model.nothingRecorded {
                // A short title and what to do (the full sentence is what VoiceOver already announced).
                out.append(Banner(id: "empty", messages: [Message(text: String(localized: "No meeting saved", comment: "Panel notice title after a recording with nothing in it; the sentence under it says what to check"),
                                                                  detail: String(localized: "Nothing was heard during the recording. Check the microphone and the meeting app’s sound.",
                                                                                 comment: "Panel notice under “No meeting saved”: what happened and what to check"))],
                                  style: .info,
                                  fixes: Self.soundSettings == nil ? [] : [.openSoundSettings]))
            }
            if model.speakersUpdated {
                // After a recording whose voices were told apart: the live labels were guesses.
                out.append(Banner(id: "speakers", messages: [Message(text: String(localized: "Speakers updated", comment: "Panel notice title after a recording: the speaker labels were final-checked when the meeting ended; the sentence under it says what that means"),
                                                                     detail: model.speakersUpdatedMeetingID == nil
                                                                         ? String(localized: "Names shown while recording may have changed now that the meeting has ended. Check them in Meetings.",
                                                                                  comment: "Panel notice under “Speakers updated” when the meeting can’t be opened from the notice: the live speaker labels were provisional")
                                                                         : String(localized: "Names shown while recording may have changed now that the meeting has ended.",
                                                                                  comment: "Panel notice under “Speakers updated”, next to the Check Speakers button: the live speaker labels were provisional"))],
                                  style: .info,
                                  fixes: model.speakersUpdatedMeetingID == nil ? [] : [.checkSpeakers]))
            }
            if model.launchAtLoginNeedsApproval {
                out.append(Banner(id: "login", messages: [Message(text: String(localized: "Approve Vauta in System Settings\u{00A0}→\u{00A0}General\u{00A0}→\u{00A0}Login Items & Extensions."))],
                                  fixes: [.openLoginItems]))
            }
            // Each notice has its own "Dismiss", which clears only that notice.
            for index in out.indices where ["save", "error", "stop", "empty", "speakers"].contains(out[index].id) { out[index].dismissible = true }
        }
        return out
    }

    /// A failed save: the title, what to do under it and, when the disk is full, the button that opens Storage.
    private func failureBanner(id: String, _ message: String) -> Banner {
        guard let parts = model.warningParts[message] else { return Banner(id: id, messages: [Message(text: message)]) }
        return Banner(id: id, messages: [Message(text: parts.title, detail: parts.detail, help: model.warningDetails[message])],
                      fixes: parts.isDiskFull ? [.openStorageSettings] : [])
    }

    private var messages: [Message] {
        var out: [Message] = []
        if case .failed(let message) = model.phase {
            // Only a store that did not open is about the encrypted store; a recording that could not start
            // (microphone not allowed, capture error) says what happened as it is.
            if model.storeAvailable {
                out.append(Message(text: String(localized: "Recording didn’t start", comment: "Notification title when a recording could not start"),
                                   detail: message))
            } else {
                // The cause and, after it, what to do.
                out.append(Message(text: String(localized: "Your data couldn’t be opened", comment: "Panel warning title when the store failed to open; the sentence under it is the cause"),
                                   detail: [message, model.storeOpenRecovery].compactMap { $0 }.joinedAsSentences()))
            }
        }
        return out
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
