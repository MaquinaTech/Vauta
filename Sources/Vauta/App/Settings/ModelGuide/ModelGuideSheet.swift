// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// "Set up a model server": install an app, download the model that fits this Mac, start the
/// server, and let Vauta use it. Vauta downloads nothing itself and runs no engine; it opens the
/// app's website, shows the exact commands and watches (on this Mac only) for the server.
struct ModelGuideSheet: View {
    let recorder: RecorderModel
    @Bindable var settings: ModelsSettingsModel
    @ViewLocalState var guide: ModelGuideModel
    /// Closes the sheet.
    let close: () -> Void
    /// Offered on a Mac too small for a model server on it: takes the person to where a server on another computer is
    /// connected (Settings → Models, over the setup window in first-run setup).
    var useNetworkServer: (() -> Void)?
    /// First-run setup: "Keep Apple Intelligence" also records that choice before closing; nil in Settings.
    var keepApple: (() -> Void)?
    /// Called after the server was saved.
    var finished: ((ModelGuideModel.Summary) -> Void)?
    /// For snapshots: whether Apple Intelligence can write minutes (nil asks the system).
    var appleAvailableOverride: Bool?
    /// The tallest the sheet gets: the room of the window it comes from (setup grows its window for it).
    var maxHeight: CGFloat = ModelGuideSheet.defaultMaxHeight
    static let defaultMaxHeight: CGFloat = 700
    /// Told the sheet's height whenever it changes (first-run setup sizes its window from it).
    var onHeightChange: ((CGFloat) -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    /// VoiceOver lands on "Done" when the result replaces the steps.
    @AccessibilityFocusState var doneFocused: Bool

    init(recorder: RecorderModel, settings: ModelsSettingsModel, guide: ModelGuideModel = ModelGuideModel(),
         close: @escaping () -> Void, useNetworkServer: (() -> Void)? = nil, keepApple: (() -> Void)? = nil,
         finished: ((ModelGuideModel.Summary) -> Void)? = nil, appleAvailableOverride: Bool? = nil,
         maxHeight: CGFloat = ModelGuideSheet.defaultMaxHeight, onHeightChange: ((CGFloat) -> Void)? = nil) {
        self.recorder = recorder
        self.settings = settings
        _guide = ViewLocalState(initialValue: guide)
        self.close = close
        self.useNetworkServer = useNetworkServer
        self.keepApple = keepApple
        self.finished = finished
        self.appleAvailableOverride = appleAvailableOverride
        self.maxHeight = maxHeight
        self.onHeightChange = onHeightChange
    }

    var appleAvailable: Bool { appleAvailableOverride ?? (settings.appleModel.availability == .available) }

    @ViewLocalState var canScrollDown = false
    @ViewLocalState var canScrollUp = false
    @ViewLocalState var overflows = false
    /// Finished steps are collapsed to their title; the ones the person opened.
    @ViewLocalState var expandedSteps: Set<Int> = []
    /// "Show Fix" in the status strip asks the scroll area to bring a step into view.
    @ViewLocalState var scrollRequest: ScrollRequest?
    /// Where each step (and the context fix) sits in the scrolled content, and which part is on screen: the
    /// strip offers "Show Step 2" only when that step is not already in view.
    @ViewLocalState var blockFrames: [Int: CGRect] = [:]
    @ViewLocalState var visibleRect: CGRect = .zero
    /// The height of the scrolled content and of everything around it (header, status strip, footer, rules): when the
    /// steps are shorter than the sheet's ideal height, the sheet is as tall as they are instead of leaving a blank band.
    @ViewLocalState var contentHeight: CGFloat = 0
    @ViewLocalState var chromeHeights: [String: CGFloat] = [:]
    /// The tallest the steps have needed so far: the sheet keeps that height while its steps change.
    @ViewLocalState var tallestSteps: CGFloat = 0
    /// Step 3's context length part, closed until that step is the current one; the person can open it before.
    @ViewLocalState var contextOpen = false

    struct ScrollRequest: Equatable {
        let step: Int
        let id = UUID()
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header.trackChrome("header", into: $chromeHeights)
            // Rules only where content scrolls under them: the finished and low-memory pages have none in their layout,
            // so they look (and are spaced) like the other sheets. On the steps pages they stay in it (invisible).
            if showsSteps { Divider().opacity(canScrollUp ? 1 : 0) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) { content }
                        // With the header's 4 pt this is the 16 pt between a sheet's title and its body.
                        .padding(.top, 12)
                        .padding(.bottom, isDone ? 4 : 20)
                        .padding(.leading, 20)
                        // The status strip below ends 20 pt from the edge: a classic scroller must not move the
                        // content's right edge away from it.
                        .padding(.trailing, max(0, 20 - (overflows ? ScrollerMetrics.reservedWidth : 0)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .coordinateSpace(.named(Self.contentSpace))
                }
                .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
                    visibleRect = rect
                }
                .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height > $0.containerSize.height + 1 } action: { _, value in
                    overflows = value
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                    contentHeight = height
                }
                // The steps are taller than the sheet: say so with a fade, and follow the current step.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 4
                } action: { _, scrollable in
                    canScrollDown = scrollable
                }
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 4 } action: { _, scrolled in
                    canScrollUp = scrolled
                }
                // Overlay scrollers are invisible: show them when the sheet opens and when the next step takes over.
                .scrollIndicatorsFlash(onAppear: true)
                .scrollIndicatorsFlash(trigger: currentStep)
                .overlay(alignment: .bottom) {
                    if canScrollDown { moreBelow }
                }
                .onChange(of: currentStep) { _, step in
                    guard let step else { return }
                    if reduceMotion { proxy.scrollTo(step, anchor: .top) } else { withAnimation { proxy.scrollTo(step, anchor: .top) } }
                }
                .onChange(of: scrollRequest) { _, request in
                    guard let step = request?.step else { return }
                    if reduceMotion { proxy.scrollTo(step, anchor: .top) } else { withAnimation { proxy.scrollTo(step, anchor: .top) } }
                }
            }
            if showsSteps {
                Divider()
                statusStrip.trackChrome("strip", into: $chromeHeights)
            }
            // The one footer of the sheet: the rule, then the link leading and the buttons trailing. The status strip is
            // a band between two rules, so its content has the same space above and below it; the finished page has no
            // link and no rule.
            // The low-memory page has the same rule above its footer (only the finished page has none).
            if !isDone { Divider() }
            footer.trackChrome("footer", into: $chromeHeights)
        }
        // Flexible, so the sheet fits the window it comes from (the setup window and Settings are both shorter
        // than a fixed 700 pt); only the scroll area grows or shrinks.
        .frame(minWidth: 500, idealWidth: lowMemory ? Self.lowMemoryWidth : Self.idealWidth, maxWidth: 640,
               minHeight: fittedHeight.map { min($0, 440) } ?? Self.minHeight(showsSteps: showsSteps),
               idealHeight: fittedHeight,
               maxHeight: maxHeight)
        // Escape closes the finished sheet too ("Done" is its default button).
        .onExitCommand {
            if guide.phase == .applying { guide.cancelUse() } else if isDone || !guide.recommendation.hasRecommendation { close() }
        }
        .onChange(of: reportedHeight, initial: true) { _, height in
            if let height { onHeightChange?(height) }
        }
        .onChange(of: measuredHeight) { _, height in
            if let height, height > tallestSteps { tallestSteps = height }
        }
        .task {
            guide.start(existing: recorder.serverConfig)
        }
        .onDisappear { guide.stop() }
        // The window was hidden or closed: stop looking, and look again when it is back. (Meetings relocking
        // does not concern this sheet: it shows no meeting content, and losing progress here would cost minutes.)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { guide.stop() } else if guide.isLookingForServer { guide.start(existing: recorder.serverConfig) }
        }
        .onChange(of: guide.phase) { _, phase in
            if case .done(let summary) = phase {
                finished?(summary)
            }
        }
        // VoiceOver keeps its focus elsewhere: say what the guide found or what went wrong, once per change
        // (the 3 s polling does not repeat an unchanged status).
        // The finished page moves focus to "Done" first and announces the result with high priority afterwards:
        // an announcement made at the same moment as the focus move would be cut short.
        .onChange(of: statusAnnouncement) { _, text in
            guard let text else { return }
            if isDone {
                BackupAnnouncement.announceResult(text) { doneFocused = true }
            } else {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    /// The edge of the scroll area while more content is below: a soft shadow and, on the steps, a 30 pt cue naming what
    /// is next. The band is only as tall as the cue; whatever it covers scrolls under it, so no empty strip is left
    /// between the cue and the status strip.
    var moreBelow: some View {
        let cueHeight: CGFloat = 30
        // The first step that starts in the band or below it is the one the cue names; when every step has started,
        // the cue only says there is more.
        let next: Int? = guide.stepOrder.first { (blockFrames[$0]?.minY ?? 0) >= visibleRect.maxY - cueHeight }
        return ZStack(alignment: .bottom) {
            if showsSteps {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor)).frame(height: cueHeight)
                    .overlay { moreBelowCue(next: next) }
                    .overlay(alignment: .top) { shadow.offset(y: -10) }
            } else {
                shadow
            }
        }
        .allowsHitTesting(showsSteps && next != nil)
    }

    private var shadow: some View {
        LinearGradient(colors: [.black.opacity(0), .black.opacity(colorScheme == .dark ? 0.32 : 0.10)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func moreBelowCue(next: Int?) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            if let next { Text("Step \(guide.number(of: next)) below", comment: "Model guide: cue at the bottom of the scrolled steps; the argument is a step number") }
            else { Text("More below", comment: "Model guide: cue at the bottom of the scrolled steps when no step follows") }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        // VoiceOver reads the steps themselves.
        .accessibilityHidden(true)
        if let next {
            Button { scrollRequest = ScrollRequest(step: next) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .focusable(false)
        } else {
            label
        }
    }

    /// The sheet's size: the steps need room and scroll; the finished page and the low-memory page are exactly as
    /// tall as their text (nil: the scroll view reports its content), and scroll only in a window shorter than that.
    static func minHeight(showsSteps: Bool) -> CGFloat? { showsSteps ? 440 : nil }

    /// Every page of the guide, the low-memory one too, is as wide as the setup window leaves room for.
    static let idealWidth: CGFloat = 560
    /// The low-memory page has no steps and a footer with two buttons: it takes the whole width the setup window leaves (the
    /// sheet's maximum), so its sentences and its footer keep one row in the longer languages.
    static let lowMemoryWidth: CGFloat = 640

    /// The steps get the room of the sheet's maximum in Settings too (the Settings window is about as tall as the
    /// sheet), so step 3 is in view when the sheet opens; setup grows its window for it (see
    /// `OnboardingMetrics.guideWindowHeight`). Short content is fitted below.
    static func idealHeight(showsSteps: Bool, maxHeight: CGFloat = defaultMaxHeight) -> CGFloat? {
        showsSteps ? maxHeight : nil
    }

    /// The ideal height, cut down to the content when the steps are shorter than it, but never below the tallest the
    /// steps have been in this sheet: finishing a step must not move the footer under the pointer while the person
    /// waits. Nil where the sheet is as tall as its text anyway (the finished and low-memory pages).
    var fittedHeight: CGFloat? {
        guard let ideal = Self.idealHeight(showsSteps: showsSteps, maxHeight: maxHeight) else { return nil }
        // From step 2 on (the steps above are done and collapsed) the sheet fits its content: the floor of the taller
        // layout of step 1 would leave a blank band between the last step and the status line.
        if guide.number(of: currentStep ?? 4) >= 2, let measured = measuredHeight { return measured }
        return max(measuredHeight ?? ideal, min(tallestSteps, ideal))
    }

    /// The sheet's height now: what `fittedHeight` asks for, or the page's own height where the sheet is as tall as its text.
    var reportedHeight: CGFloat? {
        if let fitted = fittedHeight { return fitted }
        guard contentHeight > 0, let header = chromeHeights["header"], let footer = chromeHeights["footer"] else { return nil }
        return min(maxHeight, ceil(header + footer + contentHeight))
    }

    /// The height the steps need now, once measured.
    var measuredHeight: CGFloat? {
        guard let ideal = Self.idealHeight(showsSteps: showsSteps, maxHeight: maxHeight) else { return nil }
        guard contentHeight > 0, let header = chromeHeights["header"], let strip = chromeHeights["strip"],
              let footer = chromeHeights["footer"] else { return nil }
        // The three rules between the pieces are 1 pt each.
        return min(ideal, ceil(header + strip + footer + 3 + contentHeight))
    }

    static let contentSpace = "guide-content"
    /// The key of the context fix among the tracked frames (the steps use their number).
    static let fixKey = 13

    /// The first step that is not done, if any: the one to scroll to.
    var currentStep: Int? {
        showsSteps ? guide.stepOrder.first { guide.stepState($0) == .current } : nil
    }

    // MARK: Header and footer

    var header: some View {
        Group {
            if isDone {
                // The title says the result, with the success mark as the icon; the body starts with what changed.
                SheetHeader(Text("Model Server Ready"), symbol: StatusSymbol.ok.name, tint: StatusSymbol.ok.color)
            } else if guide.recommendation.hasRecommendation {
                SheetHeader(Text("Set Up a Model Server"),
                            message: Text("Better minutes, still private: the model runs on this Mac."),
                            symbol: Self.localModelSymbol)
            } else {
                // Too little memory: nothing is set up here, so the title says what the page is for: the choice.
                SheetHeader(Text("Choose How to Write Minutes"),
                            message: Text("This Mac has \(ByteCountFormatter.string(fromByteCount: Int64(guide.physicalMemory), countStyle: .memory)) of memory."),
                            symbol: "doc.text")
            }
        }
        .symbolRenderingMode(.monochrome)
        .padding(.horizontal, 20)
        // The 20 pt inset of every sheet above; the content adds the rest of the 16 pt under the title.
        .padding(.top, 20)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The icon of "a model that runs on this Mac", the same in the setup, this guide and Settings.
    static let localModelSymbol = StatusSymbol.thisMac
    /// The icon of "a model server on another computer", the option of a Mac too small for a model server on it.
    static let serverSymbol = "network"

    /// The link to the model server documentation is in the footer, leading, on every page but the finished one. When
    /// the link and the buttons do not fit one row (the longer languages), the footer stacks them.
    var footerHasGuideLink: Bool { !isDone }

    /// The buttons on one line; when a language is too long for that, the link goes above them, then Close goes
    /// on a row of its own, and in the last resort the buttons stack. Always on the trailing edge; a button never truncates.
    var footer: some View {
        ViewThatFits(in: .horizontal) {
            FooterRow(gap: 20) {
                if footerHasGuideLink { ModelServerGuideLink().fixedSize() }
                HStack(spacing: 10) { footerButtons }.fixedSize()
            }
            VStack(alignment: .trailing, spacing: 10) {
                if footerHasGuideLink { ModelServerGuideLink().fixedSize().frame(maxWidth: .infinity, alignment: .leading) }
                HStack(spacing: 10) { footerButtons }.fixedSize()
            }
            VStack(alignment: .trailing, spacing: 10) {
                if footerHasGuideLink { ModelServerGuideLink().fixedSize().frame(maxWidth: .infinity, alignment: .leading) }
                HStack(spacing: 10) { footerActionButtons }.fixedSize()
                HStack(spacing: 10) { footerCancelButton }.fixedSize()
            }
            VStack(alignment: .trailing, spacing: 8) {
                if footerHasGuideLink { ModelServerGuideLink().fixedSize().frame(maxWidth: .infinity, alignment: .leading) }
                VStack(alignment: .trailing, spacing: 8) { footerButtons }.fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        // The same distance from the sheet's bottom edge as the buttons of the other sheets.
        .padding(.bottom, 20)
    }

    /// Every button of the footer, in the order they appear: the way out first, the default action last.
    @ViewBuilder
    var footerButtons: some View {
        footerCancelButton
        footerActionButtons
    }

    /// The way out. Absent on the finished page, where "Done" is the only button.
    @ViewBuilder
    var footerCancelButton: some View {
        if isDone {
            EmptyView()
        } else if !guide.recommendation.hasRecommendation {
            // "Keep Apple Intelligence" is the way out, in Settings and in setup alike (it also records the choice in setup),
            // and Escape leaves too: a Close that does the same would only be a third button. Without Apple Intelligence,
            // Close is the way out, and the default button when it is the only one.
            if appleAvailable {
                EmptyView()
            } else if useNetworkServer == nil {
                Button("Close") { close() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
            }
        } else if guide.phase == .applying {
            // The test can take long when the model is still loading: the way out stops it and keeps the previous setup.
            Button("Cancel") { guide.cancelUse() }.keyboardShortcut(.cancelAction)
        } else {
            Button("Close") { close() }.keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    var footerActionButtons: some View {
        if isDone {
            // Its own key: "Done" is also a task status, translated as an adjective in several languages.
            Button(String(localized: "button.done", defaultValue: "Done",
                          comment: "Button that closes a finished setup sheet (not the task status)")) { close() }
                .keyboardShortcut(.defaultAction)
                .accessibilityFocused($doneFocused)
        } else if !guide.recommendation.hasRecommendation {
            // The ways out of the low-memory page, as the sheet's buttons (one place for actions): the default action last.
            if let useNetworkServer {
                Button("Connect a Model Server…") { useNetworkServer() }
                    .keyboardShortcut(appleAvailable ? nil : .defaultAction)
            }
            if appleAvailable {
                Button("Keep Apple Intelligence") { keepApple?(); close() }.keyboardShortcut(.defaultAction)
            }
        } else if showsSteps {
            Button(useTitle) {
                guide.startUse(recorder: recorder, settings: settings)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(guide.candidate == nil || guide.phase == .applying)
        }
    }

    /// Whether two models will be saved. Before a server is found the plan decides, so the button doesn't change
    /// its name when the server appears.
    var savesTwoModels: Bool {
        if let candidate = guide.candidate { return candidate.fastModel != candidate.mainModel }
        return guide.models.count > 1
    }

    /// "Use These Models" when two models will be saved.
    var useTitle: String {
        if isFailed { return String(localized: "Try Again", comment: "Retry button") }
        if savesTwoModels {
            return String(localized: "Use These Models", comment: "Model guide: saves the server found, with two models")
        }
        return String(localized: "Use This Model", comment: "Model guide: saves the server found")
    }

    var lowMemory: Bool { !isDone && !guide.recommendation.hasRecommendation }

    var isDone: Bool { if case .done = guide.phase { true } else { false } }
    var isFailed: Bool { if case .failed = guide.phase { true } else { false } }

    // MARK: Content

    /// The steps are shown while there is a model to recommend and nothing was saved yet.
    var showsSteps: Bool {
        if case .done = guide.phase { return false }
        return guide.recommendation.hasRecommendation
    }

    @ViewBuilder
    var content: some View {
        switch guide.phase {
        case .done(let summary):
            DoneView(summary: summary)
        default:
            if guide.recommendation.hasRecommendation {
                steps
            } else {
                LowMemoryView(appleAvailable: appleAvailable)
            }
        }
    }

    /// A finished step opens and closes on a click; the others are always open.
    func toggle(_ step: Int) -> (() -> Void) {
        { if expandedSteps.contains(step) { expandedSteps.remove(step) } else { expandedSteps.insert(step) } }
    }

    func isExpanded(_ step: Int) -> Bool { guide.stepState(step) != .done || expandedSteps.contains(step) }

    @ViewBuilder
    func stepView(_ step: Int) -> some View {
        switch step {
        case 1: installStep
        case 2: modelStep
        case 3: serverStep
        default: useStep
        }
    }

    var steps: some View {
        VStack(alignment: .leading, spacing: 22) {
            appPicker.disabled(guide.phase == .applying)
            ForEach(guide.stepOrder, id: \.self) { step in
                stepView(step).id(step).trackFrame(step, in: Self.contentSpace, into: $blockFrames)
            }
        }
        // While the choice is being checked and saved, the app and options it was built from stay as they are.
        // (Not .disabled: that would dim the finished steps but not their badges.)
        .allowsHitTesting(guide.phase != .applying)
        .environment(\.guideStepsLocked, guide.phase == .applying)
    }

    // MARK: Live status and "Use it"

    /// Always visible: what Vauta sees on this Mac right now, and what to fix. "Use This Model" in
    /// the footer is the last step. Short: one or two lines and, when the fix is in a step, a button to it.
    var statusStrip: some View {
        Group {
            if case .failed(let message) = guide.phase {
                // What happened and what to do, instead of a success row with an error under it.
                // In Settings the guide opens over the Models pane itself: only setup points to it.
                GuideStatusRow(kind: .error, inStepColumn: true, title: Self.withoutFinalPeriod(message),
                               detail: keepApple != nil
                                ? String(localized: "Make sure the server is still running, then try again. Or check it in Settings\u{00A0}→\u{00A0}Models.",
                                         comment: "Model guide in first-run setup: what to do after the server settings couldn’t be saved")
                                : String(localized: "Make sure the server is still running, then try again. Or close this guide and check the server in the Models pane.",
                                         comment: "Model guide in Settings: what to do after the server settings couldn’t be saved"))
            } else if guide.phase == .applying {
                // The footer keeps its link and buttons; the wait is explained where the status is.
                GuideStatusRow(kind: .waiting, inStepColumn: true, title: String(localized: "Checking and saving…", comment: "Model guide progress"))
            } else {
                let status = statusDescription
                HStack(alignment: .center, spacing: 12) {
                    GuideStatusRow(kind: status.kind, inStepColumn: true, title: status.title, detail: status.detail)
                    if let action = status.action, !isInView(action) {
                        Button(action.title) {
                            switch action.target {
                            case .step(let step): scrollRequest = ScrollRequest(step: step)
                            case .openApp: guide.openApp()
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        // As tall as its content, with the same space above and below it: a single line is not left floating in a
        // two-line band, and the buttons below are not further from it than the rule above.
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    enum ActionTarget { case step(Int), openApp }
    typealias StatusAction = (title: String, target: ActionTarget)
    typealias StatusDescription = (kind: GuideStatusRow.Kind, title: String, detail: String?, action: StatusAction?)

    /// The button that scrolls to a step (or opens the app of step 3) is pointless while that step is on screen.
    func isInView(_ action: StatusAction) -> Bool {
        guard visibleRect != .zero else { return false }
        // "Open Ollama" is the button of step 3: it is not repeated while that step shows its own.
        let step: Int
        switch action.target {
        case .step(let number): step = number
        case .openApp: step = 3
        }
        var contextTooSmall = false
        if case .contextTooSmall = guide.status { contextTooSmall = true }
        guard let frame = blockFrames[step == 3 && contextTooSmall ? Self.fixKey : step] else { return false }
        let shown = frame.intersection(visibleRect)
        return !shown.isNull && shown.height >= min(frame.height, 100)
    }

    /// A message used as a title has no final period (the sentence form stays for alerts).
    static func withoutFinalPeriod(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, last == "." || last == "。" { trimmed.removeLast() }
        return trimmed
    }

    /// What the strip says now. Titles have no final period; details are sentences.
    var statusDescription: StatusDescription {
        let appName = guide.app.displayName
        let lookingForServer: Bool = switch guide.status {
        case .searching, .serverNotRunning: true
        default: false
        }
        if lookingForServer, !guide.isInstalled {
            // Nothing to wait for before the app exists.
            return (.info, String(localized: "Install \(appName) to continue.", comment: "Model guide status while the app is not installed; the argument is an app name"), nil, nil)
        }
        switch guide.status {
        case .searching:
            return (.waiting, lookingTitle(appName), lookingDetail, nil)
        case .serverNotRunning:
            // The same wording as while the first look is running: it is the same wait.
            return (.waiting, lookingTitle(appName), lookingDetail,
                    // Ollama serves as soon as its app is open; LM Studio's server is a switch inside the app.
                    guide.app == .ollama && guide.isInstalled
                        ? (String(localized: "Open \(appName)", comment: "Model guide button; the argument is an app name"), .openApp) : nil)
        case .noSuitableModel:
            let name = guide.recommendation.main?.displayName ?? ""
            // The expected next step, not a problem: the waiting style, as while the server is looked for.
            return (.waiting,
                    String(localized: "\(appName) is running, but \(name) isn’t downloaded yet",
                           comment: "Model guide status; arguments are an app name and a model name"),
                    String(localized: "Download it in step \(guide.number(of: 2)). Vauta notices when it’s ready.", comment: "Model guide status detail; the argument is the number of the download step"),
                    (String(localized: "Show Step \(guide.number(of: 2))", comment: "Model guide: scrolls to the download step; the argument is its number"), .step(2)))
        case .contextTooSmall(let shortfall):
            let model = guide.displayName(of: shortfall.modelID)
            return (.warning,
                    ModelGuideModel.contextTitle(shortfall, name: model),
                    [ModelGuideModel.contextDetail(shortfall),
                     String(localized: "The fix is in step \(guide.number(of: 3)).", comment: "Model guide status detail when a model has too little context; the button beside it scrolls to the step; the argument is its number")].joinedAsSentences(),
                    (String(localized: "Show Fix", comment: "Model guide: scrolls to the step with the fix for the context length"), .step(3)))
        case .ready(let candidate):
            return readyDescription(candidate)
        }
    }

    private func lookingTitle(_ appName: String) -> String {
        String(localized: "Looking for the \(appName) server…", comment: "Model guide status while Vauta looks for the app’s server; the argument is an app name")
    }

    private var lookingDetail: String {
        String(localized: "Vauta checks this Mac every few seconds while this guide is open.", comment: "Model guide status detail")
    }

    /// The same words for VoiceOver when the strip changes; nil while nothing is worth saying.
    var statusAnnouncement: String? {
        if case .failed(let message) = guide.phase { return message }
        if guide.phase == .applying { return String(localized: "Checking and saving…", comment: "Model guide progress") }
        if case .done(let summary) = guide.phase {
            // The sheet swaps to the result: say that it worked and what changed, as the backup sheets do.
            let title = String(localized: "Model Server Ready")
            let result = String(localized: "Minutes are now written with \(summary.mainModel) in \(summary.serverName). The model runs on this Mac, so meeting text sent to it stays here.",
                                comment: "Model guide result; arguments are a model name and an app name")
            return [title, result].joined(separator: " ")
        }
        guard showsSteps else { return nil }
        let status = statusDescription
        return [status.title, status.detail].compactMap { $0 }.joined(separator: " ")
    }

    func readyDescription(_ candidate: SetupCandidate) -> StatusDescription {
        let appName = candidate.serverKind.displayName
        let main = guide.displayName(of: candidate.mainModel)
        let title: String
        if candidate.fastModel == candidate.mainModel {
            title = String(localized: "Found \(main) in \(appName)", comment: "Model guide status; arguments are a model name and an app name")
        } else {
            let fast = guide.displayName(of: candidate.fastModel)
            title = String(localized: "Found \(main) and \(fast) in \(appName)",
                           comment: "Model guide status; arguments are two model names and an app name")
        }
        // The server didn't say which context the model loads with (it isn't loaded yet): Vauta looks once it is,
        // when the setup is saved, instead of leaving a warning the person can do nothing about.
        guard candidate.contextVerified else {
            return (.info, title, String(localized: "Context length is checked when you save.",
                                         comment: "Model guide status detail"), nil)
        }
        return (.success, title, String(localized: "Context length: \(ModelGuideModel.tokens(candidate.config.contextTokens)), enough for long meetings.",
                                        comment: "Model guide status detail; the argument is a token count"), nil)
    }

    // MARK: Formatting

    /// An approximate size in whole gigabytes ("About 16 GB"): a decimal adds nothing to an estimate.
    static func gigabytes(_ gb: Double) -> String {
        Measurement(value: gb.rounded(), unit: UnitInformationStorage.gigabytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
            .replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// Free space the way download sizes are written: whole gigabytes, one decimal below 10 GB, the same in every language.
    static func freeSpace(_ count: Int64) -> String {
        let gb = Double(count) / 1_000_000_000
        let decimals = gb < 10 ? 1 : 0
        return Measurement(value: gb, unit: UnitInformationStorage.gigabytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(decimals))))
            .replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}

extension View {
    /// Records the height this piece of the sheet has, under `key`.
    func trackChrome(_ key: String, into heights: Binding<[String: CGFloat]>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.wrappedValue[key] = $0 }
    }
}

/// The footer's first choice: the link leading and the buttons trailing on one row. Its ideal width is the two
/// pieces and the gap between them, so `ViewThatFits` takes the row exactly when they fit the width offered (and
/// stacks them otherwise); with one child (no link) the child sits on the trailing edge.
private struct FooterRow: Layout {
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = sizes.map(\.width).reduce(0, +) + gap * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: max(width, proposal.width ?? 0), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard let first = subviews.first, let firstSize = sizes.first else { return }
        if subviews.count == 1 {
            first.place(at: CGPoint(x: bounds.maxX - firstSize.width, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            return
        }
        first.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        let last = subviews[subviews.count - 1], lastSize = sizes[sizes.count - 1]
        last.place(at: CGPoint(x: bounds.maxX - lastSize.width, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }
}
