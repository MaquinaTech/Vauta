// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// First-run setup: welcome, languages, permissions, speech model, models, done.
/// Every page can be skipped; finishing or skipping marks the setup as done.
struct OnboardingView: View {
    let recorder: RecorderModel
    @Bindable var preferences: Preferences
    /// Opens Settings at Models from the last page; nil where Settings is not at hand.
    var settings: SettingsModel?
    @ViewLocalState private var model = OnboardingModel()
    /// The setup window itself, so only its own becoming key (not the panel's, Settings' or Meetings') re-reads the state.
    @ViewLocalState private var windowBox = SetupWindowBox()
    @ViewLocalState private var pageOverflows = false
    @ViewLocalState private var canScrollDown = false
    @ViewLocalState private var containerHeight: CGFloat = 0
    /// The Almost Ready and Minutes pages are as tall as their content needs (set when they overflowed), so no tip is left under the footer
    /// and the page is never left scrolled with its icon under the title bar (found servers, longer languages).
    @ViewLocalState private var doneFitHeight: CGFloat = 0
    /// Set when setup ended with "Start Using Vauta", which shows the menu bar itself.
    @ViewLocalState private var finishedThroughButton = false
    /// The system's microphone prompt is showing, asked for by Continue.
    @ViewLocalState private var askingMicrophone = false
    /// Whether this run is the first setup. Setup opened again from the Help menu does not point at the menu bar
    /// when it closes: the person already knows where Vauta lives.
    @ViewLocalState private var isFirstSetup = false
    /// For `Vauta render-ui`: the guide is drawn over the window by hand, which is then as tall as with the real sheet.
    @ViewLocalState private var guideDrawnOver = false
    /// The tallest the window can be on the screen it is on; follows display changes.
    @ViewLocalState private var screenLimit = OnboardingMetrics.screenLimit()
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The setup shares the app's speech downloads, so one it starts goes on (and is seen in the panel and Settings)
    /// after the window closes.
    init(recorder: RecorderModel, preferences: Preferences, settings: SettingsModel? = nil) {
        self.recorder = recorder
        self.preferences = preferences
        self.settings = settings
        _model = ViewLocalState(initialValue: OnboardingModel(speech: recorder.speechDownloads))
    }

    #if VAUTA_DIAGNOSTICS
    // For `Vauta render-ui`: opens on a given page.

    init(recorder: RecorderModel, preferences: Preferences, settings: SettingsModel? = nil, snapshotModel: OnboardingModel) {
        self.recorder = recorder
        self.preferences = preferences
        self.settings = settings
        _model = ViewLocalState(initialValue: snapshotModel)
        // Rendering never closes a real setup: no menu bar reveal when the snapshot window goes away.
        _finishedThroughButton = ViewLocalState(initialValue: true)
    }

    init(recorder: RecorderModel, preferences: Preferences, settings: SettingsModel? = nil, snapshotModel: OnboardingModel, guideDrawnOver: Bool) {
        self.init(recorder: recorder, preferences: preferences, settings: settings, snapshotModel: snapshotModel)
        _guideDrawnOver = ViewLocalState(initialValue: guideDrawnOver)
    }
    #endif

    /// The model guide sheet needs more room than the pages do: the window is as tall as the sheet reports (and the
    /// footer under it), up to `guideWindowHeight`, and never taller than the screen leaves room for.
    private var windowHeight: CGFloat {
        var wanted = OnboardingMetrics.windowSize.height
        if model.guidePresented || guideDrawnOver {
            let sheet = model.guideSheetHeight ?? OnboardingMetrics.guideSheetHeight
            wanted = max(wanted, min(sheet + OnboardingMetrics.guideFooterBand, OnboardingMetrics.guideWindowHeight))
        }
        if growsToContent, doneFitHeight > 0 { wanted = max(wanted, doneFitHeight) }
        return OnboardingMetrics.windowHeight(wanted: wanted, screenLimit: screenLimit)
    }

    /// The pages whose content (a result, a problem, a tip, a long translation) differs by language and by what was found.
    private var growsToContent: Bool { model.flow.step == .done || model.flow.step == .models }

    var body: some View {
        VStack(spacing: 0) {
            // Pages start at the same height, so the icon and title stay put from one step to the next;
            // long ones (other languages, found servers) scroll, with a fade at the bottom to say so.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        page
                            .padding(.horizontal, OnboardingMetrics.pageMargin)
                            // A classic scroller takes width from the right: give the same to the left.
                            .padding(.leading, pageOverflows ? ScrollerMetrics.reservedWidth : 0)
                            .padding(.top, isWelcome ? 24 : OnboardingMetrics.pageTopInset)
                            .padding(.bottom, 20)
                            // The welcome page has no header to align with: it sits in the middle of the window.
                            .frame(maxWidth: .infinity, minHeight: containerHeight, alignment: isWelcome ? .center : .top)
                        // After the page's bottom padding: scrolling here shows the last card with its whole inset.
                        Color.clear.frame(height: 0).id(OnboardingAnchor.pageEnd)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // Vauta's colours glow softly behind the top of every page, as in the menu-bar panel.
                .background(alignment: .top) { PanelGlow(isRecording: false).frame(height: isWelcome ? 520 : 300) }
                .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height > $0.containerSize.height + 1 } action: { _, overflows in
                    pageOverflows = overflows
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                    containerHeight = height
                }
                // The last page (its problems and tips differ by language) grows the window to its content instead of scrolling.
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height > $0.containerSize.height + 1 ? $0.contentSize.height : 0 } action: { _, needed in
                    if needed > 0, growsToContent { doneFitHeight = max(doneFitHeight, needed + OnboardingMetrics.guideFooterBand - 7) }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 4
                } action: { _, scrollable in
                    canScrollDown = scrollable
                }
                .overlay(alignment: .bottom) {
                    if canScrollDown {
                        LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(0), Color(nsColor: .windowBackgroundColor)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 32)
                            .allowsHitTesting(false)
                    }
                }
                .scrollIndicatorsFlash(onAppear: true)
                .scrollIndicatorsFlash(trigger: model.discovered?.count)
                // Coming back to a page that already has results: show them, not the top of the page.
                .onAppear {
                    guard model.flow.step == .models, model.discovered?.isEmpty == false else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        proxy.scrollTo(OnboardingAnchor.pageEnd, anchor: .bottom)
                    }
                }
                .id(model.flow.step)
                // The result of "Find Model Servers" appears below the fold: bring it into view.
                .onChange(of: model.scanning) { _, scanning in
                    guard !scanning, model.discovered != nil else { return }
                    animated { proxy.scrollTo(OnboardingAnchor.pageEnd, anchor: .bottom) }
                }
            }
            SetupProgressLine(fraction: isWelcome ? 0 : Double(model.flow.position.index) / Double(max(1, model.flow.position.count)))
            footer
        }
        .frame(width: OnboardingMetrics.windowSize.width, height: windowHeight)
        .background(SetupWindowReader(box: windowBox))
        .onAppear { isFirstSetup = preferences.needsOnboarding }
        .task { await model.load(preferences) }
        // Settings may have been used meanwhile (a server saved there): the pages show what is saved now.
        // The permissions too, on every page: the person may have allowed the microphone in System Settings and come
        // back to the last page, which shows what is still missing.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.settingsMayHaveChanged()
            Task { await model.refreshPermissions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            // Another Vauta window coming forward changes nothing here (the sheet's closing returns the key to this one).
            guard let window = windowBox.window, notification.object as? NSWindow === window else { return }
            model.settingsMayHaveChanged()
            Task { await model.refreshPermissions() }
            screenLimit = OnboardingMetrics.screenLimit()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screenLimit = OnboardingMetrics.screenLimit()
        }
        // The number of pages depends on the language: settle it as soon as the choice changes.
        .onChange(of: preferences.transcriptionLanguage) { model.updateSkips(preferences) }
        .onChange(of: model.flow.step) { pageOverflows = false; doneFitHeight = 0; announcePage() }
        .onDisappear {
            // Closing the window counts as skipping: it never comes back on its own.
            model.micTest.stop()
            markCompleted()
            // Closed without "Start Using Vauta": the Dock icon goes away, so show where Vauta lives all the same.
            if !finishedThroughButton, isFirstSetup { MenuBarReveal.showOnce(recorder: recorder) }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.flow.step {
        case .welcome: WelcomePage()
        case .language: LanguagePage(preferences: preferences, speech: model.speech)
        case .permissions: PermissionsPage(recorder: recorder, model: model)
        case .speechModel: SpeechModelPage(preferences: preferences, speech: model.speech)
        case .models: ModelsPage(recorder: recorder, model: model)
        case .done: DonePage(preferences: preferences, recorder: recorder, model: model)
        }
    }

    private var pageTitle: String {
        switch model.flow.step {
        case .welcome: String(localized: "Welcome to Vauta", comment: "Setup first page title")
        case .language: String(localized: "Languages", comment: "Setup page title")
        case .permissions: String(localized: "Permissions", comment: "Setup page title")
        case .speechModel: String(localized: "Speech Model", comment: "Setup page title")
        case .models: String(localized: "Minutes", comment: "Setup page title")
        case .done: model.finishedTitle(recorder, preferences)
        }
    }

    private var isWelcome: Bool { model.flow.step == .welcome }

    /// Runs `body` with an animation, or at once when the person asked for less motion.
    private func animated(_ body: () -> Void) {
        if reduceMotion { body() } else { withAnimation { body() } }
    }

    /// VoiceOver keeps its focus on the Continue button when the page changes: say where we are.
    private func announcePage() {
        let position = model.flow.position
        let text = model.flow.isLast
            ? pageTitle
            : String(localized: "\(pageTitle), step \(position.index) of \(position.count)",
                     comment: "VoiceOver announcement after a setup page change; arguments are the page title and two numbers")
        AccessibilityNotification.Announcement(text).post()
    }

    private var footer: some View {
        // The counter is always in the same place, right after "Skip Setup" (it is left out only when the buttons
        // leave it no room). The welcome page has no counter: a lone "Step 1" would look unfinished.
        SetupFooterLayout {
            HStack(spacing: 10) {
                if !model.flow.isLast {
                    Button("Skip Setup") {
                        model.micTest.stop()
                        animated { model.flow.finish() }
                    }
                    .help(String(localized: "Skip the rest of setup and change anything later in Settings", comment: "Setup skip button help"))
                    // The system prompt is up: setup waits for the answer instead of moving under it.
                    .disabled(askingMicrophone)
                }
            }
            ZStack {
                if !model.flow.isLast && !isWelcome {
                    let position = model.flow.position
                    // On the Languages page the total follows the language picked there (an installed language
                    // skips the speech model page): the change is the person's own.
                    // Shown only when it fits the room the footer leaves it.
                    ViewThatFits(in: .horizontal) {
                        Text("Step \(position.index) of \(position.count)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .allowsHitTesting(false)
                        Color.clear.frame(width: 0, height: 0)
                    }
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            HStack(spacing: 10) {
                if model.flow.canGoBack {
                    Button("Back") {
                        model.micTest.stop()
                        animated { model.flow.goBack() }
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(askingMicrophone)
                }
                Button(continueTitle) {
                    next()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(askingMicrophone)
            }
        }
        // The same margin as the cards above, so the buttons line up with them.
        .padding(.horizontal, OnboardingMetrics.pageMargin)
        .padding(.vertical, 14)
    }

    /// The speech model of the chosen language, when it hasn't been asked for yet: Continue asks for it.
    private var continueDownloadsSpeechModel: Bool {
        guard model.flow.step == .speechModel, model.speech.errorMessage == nil,
              let language = model.speech.effectiveLanguage(preferences.transcriptionLanguage) else { return false }
        return model.speech.state(language) == .notInstalled
    }

    /// The Permissions page while the microphone has not been asked for: Continue asks for it.
    private var continueAsksMicrophone: Bool {
        model.flow.step == .permissions && model.microphone == .notDetermined
    }

    private var continueTitle: String {
        if model.flow.isLast { return String(localized: "Start Using Vauta", comment: "Setup final button") }
        // The button says what Return will do: this page's download starts with it.
        if continueDownloadsSpeechModel { return String(localized: "Download and Continue", comment: "Setup next button on the speech model page; it also starts the download") }
        // Likewise: Return must not skip the microphone, or the system prompt would appear in the middle of the first meeting.
        if continueAsksMicrophone { return String(localized: "Allow Microphone and Continue", comment: "Setup next button on the permissions page while the microphone has not been asked for; it also shows the system prompt") }
        return String(localized: "Continue", comment: "Setup next button")
    }

    private func next() {
        if model.flow.isLast {
            finishedThroughButton = true
            markCompleted()
            dismissWindow(id: "onboarding")
            // Vauta goes back to the menu bar: show where it lives.
            if isFirstSetup { MenuBarReveal.showOnce(recorder: recorder) }
            return
        }
        if continueDownloadsSpeechModel, let language = model.speech.effectiveLanguage(preferences.transcriptionLanguage) {
            // Return must not skip the one thing this page is for: the download goes on while setup does.
            model.speech.install(language)
        }
        if continueAsksMicrophone {
            // The system prompt comes first, here; setup goes on whatever the answer is.
            guard !askingMicrophone else { return }
            askingMicrophone = true
            Task {
                await model.requestMicrophone()
                askingMicrophone = false
                if model.flow.step == .permissions { advance() }
            }
            return
        }
        advance()
    }

    private func advance() {
        if model.flow.step == .language { model.updateSkips(preferences) }
        if model.flow.step == .permissions { model.micTest.stop() }
        animated { model.flow.advance() }
    }

    private func markCompleted() {
        if preferences.onboardingCompletedVersion < Preferences.currentOnboardingVersion {
            preferences.onboardingCompletedVersion = Preferences.currentOnboardingVersion
        }
    }
}

/// Title, subtitle and an icon at the top of a page.
struct OnboardingHeader: View {
    let symbol: String
    /// Shows this glyph on Vauta's sphere instead of the symbol (the last page, when everything is set up).
    var orbGlyph: String?
    /// The sphere is lit, with its orbit (everything is set up); otherwise the quiet one.
    var orbLit = false
    /// The icon's colour; the accent colour unless the page has a state to show.
    var tint: Color = .accentColor
    let title: String
    let subtitle: String

    private var subtitleText: some View {
        SentenceLines(text: subtitle, alignment: .center)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let orbGlyph {
                BrandSymbol(symbol: orbGlyph, diameter: 56, showsOrbit: orbLit)
                    .padding(.vertical, 6)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    // The accent becomes Vauta's gradient; a state (a problem, a success) keeps its own colour.
                    .foregroundStyle(tint == .accentColor ? AnyShapeStyle(Brand.symbolGradient) : AnyShapeStyle(tint))
                    // Symbols differ in height: a fixed frame keeps the title at the same place on every page.
                    .frame(height: OnboardingMetrics.headerIconHeight)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            subtitleText
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // Two balanced lines instead of one very long one.
                .frame(maxWidth: OnboardingMetrics.readableWidth)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }
}

/// A text of several sentences: on one line when it fits; otherwise each sentence on its own line when every sentence
/// fits one line (a line never ends with the first words of the next sentence); otherwise plain wrapping.
struct SentenceLines: View {
    let text: String
    var alignment: HorizontalAlignment = .leading
    /// Each sentence starts its own line even when the whole text would fit one (footnotes read the same in every language).
    var alwaysSplit = false
    /// Command names inside the text, drawn in the monospaced font of commands.
    var code: [String] = []

    var body: some View {
        let sentences = text.sentences
        if sentences.count > 1 {
            ViewThatFits(in: .horizontal) {
                if !alwaysSplit {
                    line(text).fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: alignment, spacing: 0) {
                    ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                        line(sentence).fixedSize(horizontal: true, vertical: false)
                    }
                }
                // A sentence too long for a line still starts its own line.
                VStack(alignment: alignment, spacing: 0) {
                    ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                        line(sentence)
                    }
                }
            }
            // One paragraph for VoiceOver, not one element per sentence.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(text))
        } else {
            line(text)
        }
    }

    private func line(_ sentence: String) -> Text {
        let safe = sentence.avoidingWidow
        guard !code.isEmpty else { return Text(wrapping: safe) }
        var attributed = safe.containsHangulSyllables ? AttributedString.hangulWordPriority(safe) : AttributedString(safe)
        for name in code {
            var from = attributed.startIndex
            while from < attributed.endIndex, let range = attributed[from...].range(of: name) {
                attributed[range].swiftUI.font = .system(.subheadline, design: .monospaced)
                from = range.upperBound
            }
        }
        return Text(attributed)
    }
}

/// A message whose sentences each start their own line, never hyphenated ("System Settings" stays whole): a sentence
/// that fits `width` is one line, and one that doesn't breaks as a panel message does (no widow, the path of System
/// Settings kept whole).
struct SentenceParagraphs: View {
    let text: String
    var width: CGFloat = OnboardingMetrics.permissionTextWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.sentences.enumerated()), id: \.offset) { _, sentence in
                ViewThatFits(in: .horizontal) {
                    Text(oneLine(sentence)).fixedSize(horizontal: true, vertical: false)
                    Text(paragraph: sentence, font: .callout, width: width).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }

    private func oneLine(_ sentence: String) -> AttributedString {
        var attributed = sentence.containsHangulSyllables ? AttributedString.hangulWordPriority(sentence.avoidingWidow) : AttributedString(sentence.avoidingWidow)
        attributed.disableHyphenation(of: sentence)
        return attributed
    }
}

extension String {
    /// The text after its first sentence ("" when it has one): the detail under a title made of the first sentence.
    var afterFirstSentence: String {
        guard let first = sentences.first else { return "" }
        return String(dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text without its final full stop (Latin or CJK): a sentence used as a title.
    var droppingFinalStop: String {
        guard let last = last, ".。".contains(last) else { return self }
        return String(dropLast())
    }

    /// The sentences of a short text, split after a full stop, question or exclamation mark that is followed by a
    /// space, or after the full-width marks of Japanese and Chinese.
    var sentences: [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(self)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let wide = "。！？".contains(character)
            let narrow = ".!?".contains(character) && index + 1 < characters.count && characters[index + 1] == " "
            if (wide && index + 1 < characters.count) || narrow {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        return result
    }
}


/// A reference to the window that shows the setup.
@MainActor
final class SetupWindowBox {
    weak var window: NSWindow?
}

/// Fills a `SetupWindowBox` with the window its view lives in.
private struct SetupWindowReader: NSViewRepresentable {
    let box: SetupWindowBox

    final class Reader: NSView {
        var box: SetupWindowBox?
        override func viewDidMoveToWindow() { box?.window = window }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.box = box
        return view
    }

    func updateNSView(_ view: Reader, context: Context) { view.box = box; box.window = view.window }
}

/// The line above the footer: a divider that fills with Vauta's colours as the steps go by.
private struct SetupProgressLine: View {
    let fraction: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Divider()
            GeometryReader { geo in
                Capsule()
                    .fill(LinearGradient(colors: [Brand.indigo, Brand.blue, Brand.teal], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * fraction, height: 2)
                    .shadow(color: Brand.blue.opacity(0.6), radius: 4)
            }
            .frame(height: 2)
        }
        .frame(height: 2)
        .animation(.smooth(duration: 0.5), value: fraction)
        .accessibilityHidden(true)
    }
}
