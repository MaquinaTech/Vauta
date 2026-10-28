// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// Page 1: what Vauta does, shown as four short cards under Vauta's sphere. The privacy promise is the last card;
/// Settings → Privacy & Security says it in full.
struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 18) {
            // Vauta's core, as on the website: the sphere with its orbit, turning slowly.
            VautaOrb(mode: .idle, diameter: 92, carriesGlyph: false)
                .padding(.vertical, 16)
            Text("Welcome to Vauta")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(wrapping: String(localized: "Vauta transcribes your meetings on this Mac and turns them into minutes, decisions and tasks you can search and ask about.").keepingLastWordsTogether)
                // The intro under every page's title is secondary text (as the subtitle of the other pages).
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: OnboardingMetrics.readableWidth)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    WelcomeFeature(symbol: "waveform", index: 0,
                                   title: String(localized: "Transcription on this Mac", comment: "Welcome card title"),
                                   detail: String(localized: "Any call app. No bot joins the call.", comment: "Welcome card text under “Transcription on this Mac”"))
                    WelcomeFeature(symbol: "checklist", index: 1,
                                   title: String(localized: "Minutes and tasks", comment: "Welcome card title"),
                                   detail: String(localized: "Decisions, tasks with owner and date, and open questions.", comment: "Welcome card text under “Minutes and tasks”"))
                }
                GridRow {
                    WelcomeFeature(symbol: "sparkle.magnifyingglass", index: 2,
                                   title: String(localized: "Ask", comment: "Welcome card title: the Ask feature (one question across meetings, notes and files)"),
                                   detail: String(localized: "One question across your meetings, notes and files.", comment: "Welcome card text under “Ask”"))
                    WelcomeFeature(symbol: "lock", index: 3,
                                   title: String(localized: "Private", comment: "Welcome card title: Vauta keeps meetings private"),
                                   detail: String(localized: "Audio is never saved. No account, no analytics.", comment: "Welcome card text under “Private”"))
                }
            }
            // As tall as the cards' text: the two cards of a row share the taller one's height, nothing more.
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One thing Vauta does: a symbol in Vauta's colours, a name and one line. The four cards come in one after another.
private struct WelcomeFeature: View {
    let symbol: String
    let index: Int
    let title: String
    let detail: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewLocalState private var shown = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Brand.symbolGradient)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(wrapping: detail.keepingLastWordsTogether)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
        .accessibilityElement(children: .combine)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 8)
        .onAppear {
            guard !shown else { return }
            if reduceMotion || Brand.freezesMotion { shown = true; return }
            withAnimation(.smooth(duration: 0.6).delay(0.15 + 0.09 * Double(index))) { shown = true }
        }
    }
}

/// Page 2: the language spoken in meetings and the language of the minutes.
struct LanguagePage: View {
    @Bindable var preferences: Preferences
    let speech: SpeechSettingsModel
    /// Both pickers have the same width, so their edges line up.
    private static let pickerWidth: CGFloat = 270

    var body: some View {
        VStack(spacing: 12) {
            OnboardingHeader(symbol: "character.bubble",
                             title: String(localized: "Languages", comment: "Setup page title"),
                             subtitle: String(localized: "Choose the language of your meetings and of your minutes.",
                                              comment: "Setup page subtitle"))
            OnboardingCard {
                if let catalog = speech.catalog {
                    SetupFieldRow(title: String(localized: "Meetings are in", comment: "Setup transcription language picker")) {
                        Picker(String(localized: "Meetings are in", comment: "Setup transcription language picker"),
                               selection: $preferences.transcriptionLanguage) {
                            if let automatic = catalog.defaultLanguage()?.displayName.standaloneCapitalized {
                                // A dash, not parentheses: language names already contain some ("English (United States)").
                                Text("Automatic – \(automatic)", comment: "Language picker: the default, followed by the language it uses; the argument is a language name").tag(String?.none)
                            } else {
                                Text("Automatic").tag(String?.none)
                            }
                            Divider()
                            ForEach(catalog.languages.sorted { LanguageNameSort.precedes($0.displayName, $1.displayName) }) { language in
                                Text(language.displayName.standaloneCapitalized).tag(Optional(language.id))
                            }
                        }
                        .labelsHidden()
                        .buttonSizing(.flexible)
                        .frame(width: Self.pickerWidth)
                    }
                } else {
                    SetupFieldRow(title: String(localized: "Meetings are in", comment: "Setup transcription language picker")) {
                        ProgressView().controlSize(.small).frame(width: Self.pickerWidth, alignment: .trailing)
                            .accessibilityLabel(String(localized: "Loading languages…", comment: "VoiceOver: progress while the list of languages loads"))
                    }
                }
                SetupFieldRow(title: String(localized: "Write minutes in", comment: "Setup output language picker")) {
                    Picker(String(localized: "Write minutes in", comment: "Setup output language picker"), selection: $preferences.outputLanguage) {
                        Text("The meeting’s language").tag(Preferences.OutputLanguage.sameAsMeeting)
                        Divider()
                        ForEach(OutputLanguageOptions.identifiers(), id: \.self) { id in
                            Text(OutputLanguageOptions.displayName(id).standaloneCapitalized).tag(Preferences.OutputLanguage.fixed(id))
                        }
                    }
                    .labelsHidden()
                    .buttonSizing(.flexible)
                    .frame(width: Self.pickerWidth)
                }
            }
            Text(wrapping: String(localized: "You can change both later in Settings.").keepingLastWordsTogether)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Last page: what was set up, where to find Vauta and how to start recording.
struct DonePage: View {
    let preferences: Preferences
    let recorder: RecorderModel
    let model: OnboardingModel

    private var enoughMemory: Bool { ModelRecommendation(physicalMemory: model.models.physicalMemory).hasRecommendation }

    private var allSet: Bool { model.isAllSet(recorder, preferences) }

    /// Where the buttons of the problem card go, decided once for all its rows.
    @ViewLocalState private var tipButtons = TipButtonGroup()

    /// Something to fix before the first recording, or a download that is still on its way: said first, in a card of its own.
    private var hasProblems: Bool {
        model.microphoneBlocksRecording || model.missingSpeechLanguage(preferences) != nil
            || model.downloadingSpeech(preferences) != nil || !recorder.hotKeyAvailable
    }

    var body: some View {
        VStack(spacing: OnboardingMetrics.cardSpacing) {
            // The success mark only when Vauta can record and something writes minutes; otherwise the same outline as the other pages.
            // With the microphone or the speech model missing, the page does not announce a success: a warning mark and
            // the instruction to fix them.
            let blocked = model.hasBlockingProblem(preferences)
            OnboardingHeader(symbol: allSet ? StatusSymbol.ok.name : (blocked ? StatusSymbol.warning.name : "checkmark.circle"),
                             // Vauta's sphere on every variant, so the title never moves: lit with a check when all is set,
                             // quiet with a check or an exclamation mark otherwise (the title and the cards say what is missing).
                             orbGlyph: blocked ? "exclamationmark" : "checkmark", orbLit: allSet,
                             tint: allSet ? StatusSymbol.ok.color : (blocked ? StatusSymbol.warning.color : .accentColor),
                             title: model.finishedTitle(recorder, preferences),
                             subtitle: blocked
                                ? String(localized: "Fix the items below before your first recording.", comment: "Setup last page subtitle when the microphone or the speech model stops recording")
                                : String(localized: "Vauta lives in the menu bar. Look for the waveform icon at the top of the screen.",
                                         comment: "Setup last page subtitle"))
            // What would make the first recording fail comes before everything else, tinted like the warning about
            // minutes: the microphone, the speech model and the shortcut, each with its fix.
            if hasProblems {
                // A download that is on its way is no warning: the tint is for what needs the person.
                OnboardingCard(warning: model.microphoneBlocksRecording || model.missingSpeechLanguage(preferences) != nil || !recorder.hotKeyAvailable) {
                    recordingProblems
                    recordingShortcutProblem
                }
                .sharingTipButtonPlacement(tipButtons)
            }
            minutesSummary
            OnboardingCard {
                VStack(alignment: .leading, spacing: SetupBulletStyle.spacing) {
                    // Pressing the shortcut records nothing until the microphone and the speech model are there.
                    if model.canRecord(preferences) { recordingBullet }
                    Label("When a call starts, Vauta suggests recording. It never records on its own.", systemImage: "phone")
                    Label("Tell the other participants that you’re transcribing.", systemImage: "person.2")
                    Label("To change anything later, choose “Settings…” from the waveform icon.", systemImage: "gearshape")
                }
                .labelStyle(SetupBulletStyle())
                .symbolRenderingMode(.monochrome)
            }
        }
        // VoiceOver keeps its focus on the button: say what changed when the person comes back from System Settings
        // or the download ends.
        .onChange(of: model.microphoneBlocksRecording) { was, blocks in
            if was, !blocks { AccessibilityNotification.Announcement(String(localized: "Microphone allowed", comment: "VoiceOver: the microphone was allowed while the last setup page is open")).post() }
        }
        .onChange(of: model.downloadingSpeech(preferences) != nil) { was, downloading in
            guard was, !downloading else { return }
            if let language = model.missingSpeechLanguage(preferences), let failure = model.speechFailure(language) {
                AccessibilityNotification.Announcement(failure).post()
            } else if allSet {
                AccessibilityNotification.Announcement(model.finishedTitle(recorder, preferences)).post()
            } else if model.missingSpeechLanguage(preferences) == nil {
                // Installed, but something else is still open: the person still hears the download ended well.
                AccessibilityNotification.Announcement(String(localized: "Speech model installed", comment: "VoiceOver: the speech model download ended on the last setup page")).post()
            }
        }
    }

    /// The microphone and the speech model, each with the button that fixes it (or its progress while it downloads).
    @ViewBuilder
    private var recordingProblems: some View {
        if model.microphoneBlocksRecording {
            TipWithAction(symbol: .error, text: String(localized: "The microphone isn’t allowed, so Vauta can’t record yet.", comment: "Setup last page: the microphone is not allowed"),
                          actions: [(model.microphone == .notDetermined ? String(localized: "Allow…") : String(localized: "Open System Settings"), {
                if model.microphone == .notDetermined { Task { await model.requestMicrophone() } } else { Permissions.open(.microphone) }
            })])
        }
        if let download = model.downloadingSpeech(preferences) {
            // The row of the speech model page (language, bar, percent, Cancel), with the download's mark in the bullet column.
            Label {
                SpeechDownloadingRow(language: download.language, speech: model.speech, titled: true)
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
            .labelStyle(SetupBulletStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        } else if let language = model.missingSpeechLanguage(preferences) {
            let failure = model.speechFailure(language)
            // A failure says what failed first (the row has no header of its own), then the cause.
            TipWithAction(symbol: .error,
                          title: failure == nil ? nil : String(localized: "The speech model couldn’t download.", comment: "Setup last page: title of the problem when the speech model download failed; the cause is under it"),
                          text: failure ?? String(localized: "The speech model isn’t installed yet, so Vauta can’t transcribe.", comment: "Setup last page: the speech model of the meeting language is not on this Mac"),
                          actions: [(failure == nil ? String(localized: "Download") : String(localized: "Try Again"), { model.speech.install(language) })]
                            // Out of space: the pane where it is freed is one click away.
                            + (model.speech.failureNeedsSpace(language) ? [(String(localized: "Open Storage Settings"), { Permissions.open(.storage) })] : []))
        }
    }

    /// Another app holds the recording shortcut: a problem with its fix, in the card above.
    @ViewBuilder
    private var recordingShortcutProblem: some View {
        if !recorder.hotKeyAvailable {
            let shortcut = HotKeyFormatter.display(preferences.recordHotKey)
            // It says what to do instead (the subtitle already explains the waveform icon) and offers to change the shortcut.
            TipWithAction(text: String(localized: "\(shortcut) is used by another app. Record from the waveform icon in the menu bar, or change the shortcut.",
                                       comment: "Setup last page: the recording shortcut is taken; the argument is the shortcut"),
                          actions: [(String(localized: "Change Shortcut"), { recorder.showSettings(.general) })])
        }
    }

    /// How to start recording with the shortcut (when another app holds it, the problem above says so instead).
    @ViewBuilder
    private var recordingBullet: some View {
        if recorder.hotKeyAvailable {
            let shortcut = HotKeyFormatter.display(preferences.recordHotKey)
            Label {
                Text("Press \(shortcut) in any app to start or stop recording.")
            } icon: {
                Image(systemName: "record.circle")
            }
        }
    }

    /// A server that runs on this Mac only works while its app is open (the guide says the same).
    private var keepOpenSentence: String? {
        guard case .server(let app)? = model.modelSetup else { return nil }
        return String(localized: "Keep \(app) open while you record and until the minutes are ready.", comment: "Model guide and setup last page; the argument is an app name like LM Studio")
    }

    /// Who writes the minutes now, or the plain fact that nobody does yet. When the recommendation
    /// is still open, the card that acts on it sits right under it (the page's spacing applies to both).
    @ViewBuilder
    private var minutesSummary: some View {
        let noModel = model.chatProvider(hasServerConfig: recorder.serverConfig != nil) != .server && model.appleAvailability != .available
        OnboardingCard(warning: noModel) {
            VStack(alignment: .leading, spacing: 6) {
                if model.chatProvider(hasServerConfig: recorder.serverConfig != nil) == .server {
                    let name = model.serverSummary ?? recorder.serverConfig?.deepModel ?? ""
                    SetupStatusLabel(text: String(localized: "Minutes: \(name)", comment: "Setup last page; the argument is the model and app that write minutes"),
                                     kind: .success, detail: keepOpenSentence)
                } else if model.appleAvailability == .available {
                    let apple = String(localized: "Apple Intelligence on this Mac", comment: "Setup model choice title")
                    // The same row as a server's: a semibold title with its detail under it (the one the Minutes card says).
                    // A ready choice, so the same mark; the quality badge and the card below carry the recommendation.
                    SetupStatusLabel(text: String(localized: "Minutes: \(apple)", comment: "Setup last page; the argument is the model that writes minutes"),
                                     kind: .success, badge: ModelQuality.badge,
                                     detail: String(localized: "No setup and private, but minutes are shorter and less reliable.",
                                                    comment: "Setup model choice detail"))
                } else {
                    setUpRow
                }
            }
        }
        .localModelGuide(recorder: recorder, model: model)
        // Not while something stops the first recording: that comes first, and the card stays in Settings.
        if model.chatProvider(hasServerConfig: recorder.serverConfig != nil) != .server,
           model.appleAvailability == .available, model.canRecord(preferences) {
            // The same card as Settings and Meetings: on a Mac with little memory it points to a server, not to a model server on this Mac.
            LocalModelCard(physicalMemory: model.models.physicalMemory, metrics: .setup, controlSize: .regular, setUp: { model.guidePresented = true })
        }
    }

    /// The warning with the button that opens the same guide as the Minutes step: the button on the first line,
    /// and the warning wrapping in the space left of it.
    private var setUpRow: some View {
        // The first sentence is the title and the rest its detail, as in the row of a chosen server above.
        let message = String(localized: "No model chosen. Vauta still records and transcribes, but writes no minutes.",
                             comment: "Status detail")
        let warning = SetupStatusLabel(text: (message.sentences.first ?? message).droppingFinalStop, detail: message.afterFirstSentence.isEmpty ? nil : message.afterFirstSentence)
        let button = Button(enoughMemory ? String(localized: "Set Up…", comment: "Button that opens the model server guide")
                                         : String(localized: "See Options…", comment: "Button that opens the model guide on a Mac with little memory")) {
            model.guidePresented = true
        }
        // The warning wraps in the space left of the button, which stays on its first line in every language.
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            warning.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            button.fixedSize()
        }
    }
}

/// The rows of one problem card agree on where their buttons go: each row reports whether its button fits beside
/// the text, and when any does not, every row of the card puts its buttons under the text. One alignment line per card.
@MainActor @Observable
final class TipButtonGroup {
    private var needsBelow: [UUID: Bool] = [:]
    var below: Bool { needsBelow.values.contains(true) }

    func report(_ id: UUID, needsBelow value: Bool?) {
        guard needsBelow[id] != value else { return }
        needsBelow[id] = value
    }
}

private struct TipButtonGroupKey: EnvironmentKey {
    static let defaultValue: TipButtonGroup? = nil
}

private extension EnvironmentValues {
    var tipButtonGroup: TipButtonGroup? {
        get { self[TipButtonGroupKey.self] }
        set { self[TipButtonGroupKey.self] = newValue }
    }
}

extension View {
    /// The problem rows inside agree on one button placement.
    func sharingTipButtonPlacement(_ group: TipButtonGroup) -> some View { environment(\.tipButtonGroup, group) }
}

/// A problem of the last page: its mark in the bullet column, the sentence, and its button(s). A single button sits on
/// the sentence's first line, trailing; with a title, two buttons, or a language written without spaces (Japanese,
/// Chinese: the button would narrow the column and break words) the buttons go under the text, leading, so the text
/// uses the card's full width. The row is as tall as its content needs, so consecutive rows keep their distance.
struct TipWithAction: View {
    var symbol: StatusSymbol = .warning
    /// What failed, said first and in semibold, when the text alone would not say it.
    var title: String?
    let text: String
    let actions: [(title: String, perform: () -> Void)]

    @Environment(\.tipButtonGroup) private var group
    @ViewLocalState private var id = UUID()

    /// This row alone needs its buttons under the text (always so with a title, two buttons or unspaced scripts).
    private var rowNeedsBelow: Bool { title != nil || actions.count > 1 || text.containsCJKText }

    var body: some View {
        // Rows whose button would fit beside the text still follow a sibling that cannot.
        let buttonsBelow = rowNeedsBelow || (group?.below ?? false)
        Label {
            if buttonsBelow {
                VStack(alignment: .leading, spacing: 6) {
                    if let title {
                        Text(wrapping: title.avoidingWidow).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(wrapping: text.avoidingWidow)
                        .foregroundStyle(title == nil ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ForEach(actions.indices, id: \.self) { index in
                            Button(actions[index].title, action: actions[index].perform).lineLimit(1).fixedSize()
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // The button trails the first line while the text takes two lines at most; with a longer button (or
                // text) it goes under the text instead of leaving three ragged lines.
                TrailingOrBelowLayout(gap: 12, below: 6, report: { fits in group?.report(id, needsBelow: !fits) }) {
                    Text(wrapping: text.avoidingWidow).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ForEach(actions.indices, id: \.self) { index in
                            Button(actions[index].title, action: actions[index].perform).lineLimit(1).fixedSize()
                        }
                    }
                }
            }
        } icon: {
            symbol.image
        }
        .labelStyle(SetupBulletStyle(keepsIconColor: true))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onAppear { if rowNeedsBelow { group?.report(id, needsBelow: true) } }
        .onDisappear { group?.report(id, needsBelow: nil) }
    }
}

/// Two subviews, the text and its buttons: the buttons trail the text's first line when the text then takes two lines
/// at most, and sit under it, leading, otherwise.
private struct TrailingOrBelowLayout: Layout {
    let gap: CGFloat
    let below: CGFloat
    /// Told, after each placement, whether the button fits beside the text.
    var report: @MainActor (Bool) -> Void = { _ in }

    private func isTrailing(_ width: CGFloat, _ subviews: Subviews) -> Bool {
        let button = subviews[1].sizeThatFits(.unspecified)
        let oneLine = subviews[0].sizeThatFits(.unspecified)
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: max(0, width - button.width - gap), height: nil))
        return oneLine.width > 0 && text.height <= oneLine.height * 2.3
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
        let button = subviews[1].sizeThatFits(.unspecified)
        if isTrailing(width, subviews) {
            let text = subviews[0].sizeThatFits(ProposedViewSize(width: max(0, width - button.width - gap), height: nil))
            return CGSize(width: width, height: max(text.height, button.height))
        }
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: text.height + below + button.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let button = subviews[1].sizeThatFits(.unspecified)
        let trailing = isTrailing(bounds.width, subviews)
        // Outside the layout pass: the answer changes the state of the view that owns this row.
        let report = report
        Task { @MainActor in report(trailing) }
        if trailing {
            let textWidth = max(0, bounds.width - button.width - gap)
            let text = subviews[0].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
            // On the first baseline of the text, as a button beside a sentence.
            let textBase = subviews[0].dimensions(in: ProposedViewSize(width: textWidth, height: nil))[.firstTextBaseline]
            let buttonBase = subviews[1].dimensions(in: .unspecified)[.firstTextBaseline]
            let shift = textBase - buttonBase
            let textY = max(0, -shift), buttonY = max(0, shift)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + textY), anchor: .topLeading, proposal: ProposedViewSize(width: textWidth, height: text.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX - button.width, y: bounds.minY + buttonY), anchor: .topLeading, proposal: ProposedViewSize(button))
        } else {
            let text = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: text.height))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + text.height + below), anchor: .topLeading, proposal: ProposedViewSize(button))
        }
    }
}

private extension String {
    /// Kana or ideographs: written without spaces, so SwiftUI may break inside a word.
    var containsCJKText: Bool {
        unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }
}
