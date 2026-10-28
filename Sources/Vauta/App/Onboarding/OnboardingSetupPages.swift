// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// Page 3: microphone, system audio and notifications.
struct PermissionsPage: View {
    let recorder: RecorderModel
    let model: OnboardingModel

    /// The button's words and the permission it is about, so two buttons with the same title are told apart by VoiceOver
    /// ("Open System Settings, Microphone").
    private static func named(_ action: String, _ permission: String) -> String {
        SpokenLabel.join([action.replacingOccurrences(of: "…", with: ""), permission])
    }

    var body: some View {
        VStack(spacing: 12) {
            OnboardingHeader(symbol: "hand.raised",
                             title: String(localized: "Permissions", comment: "Setup page title"),
                             subtitle: String(localized: "Vauta needs to hear you and the other participants. Nothing is recorded until you start.",
                                              comment: "Setup page subtitle"))
            OnboardingCard {
                PermissionRow(title: String(localized: "Microphone", comment: "Permission name"), state: model.microphone, warns: micTestFoundProblem, stateLabel: micStateLabel) {
                    // The same height whatever the test shows, so the row doesn't move when it starts.
                    micDetail.frame(minHeight: 16, alignment: .topLeading)
                } actions: {
                    if model.microphone == .notDetermined {
                        Button("Allow…") { Task { await model.requestMicrophone() } }
                            .accessibilityLabel(Text(verbatim: Self.named(String(localized: "Allow…"), String(localized: "Microphone", comment: "Permission name"))))
                    } else if model.microphone == .denied {
                        Button("Open System Settings") { Permissions.open(.microphone) }
                            .accessibilityLabel(Text(verbatim: Self.named(String(localized: "Open System Settings"), String(localized: "Microphone", comment: "Permission name"))))
                    } else {
                        micTestButton
                    }
                }
                // macOS shows no state for system audio and lists Vauta only after the first recording:
                // there is nothing to do here, so no button.
                PermissionRow(title: String(localized: "System audio recording", comment: "Permission name; also the Status row"), state: .unknown, hasActions: false) {
                    Text(wrapping: String(localized: "Hears the other participants, shown as “\(Channel.others.displayName)”.",
                                comment: "Permission detail; argument is the other participants' channel name").avoidingWidow)
                } actions: {}
                // Optional: not allowing them is no error, so no red cross.
                PermissionRow(title: String(localized: "Notifications", comment: "Permission name"), state: model.notifications, isOptional: true,
                              hasActions: model.notifications == .notDetermined || model.notifications == .denied) {
                    if model.notifications == .denied {
                        // As the denied microphone: the consequence, then what to turn on and where, in the text colour.
                        testResult(String(localized: "You won’t know when minutes are ready. Turn on Vauta in System Settings\u{00A0}→\u{00A0}Notifications.",
                                          comment: "Permission detail when notifications are not allowed: the consequence, then the path in System Settings"))
                    } else {
                        Text(wrapping: String(localized: "Optional: minutes ready, a recording about to stop.", comment: "Permission detail").avoidingWidow)
                    }
                } actions: {
                    if model.notifications == .notDetermined {
                        Button("Allow…") { Task { await model.requestNotifications() } }
                            .accessibilityLabel(Text(verbatim: Self.named(String(localized: "Allow…"), String(localized: "Notifications", comment: "Permission name"))))
                    } else if model.notifications == .denied {
                        Button("Open System Settings") { Permissions.open(.notifications) }
                            .accessibilityLabel(Text(verbatim: Self.named(String(localized: "Open System Settings"), String(localized: "Notifications", comment: "Permission name"))))
                    }
                }
            }
            if model.microphone == .denied {
                // Continue stays available: say what happens if the person goes on without the microphone.
                Text(wrapping: String(localized: "You can continue, but Vauta can’t record until the microphone is allowed.", comment: "Setup permissions footnote while the microphone is not allowed").keepingLastWordsTogether)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // The card's content width (its edges less the row inset), not the subtitle's: one line where it fits, otherwise
                    // two balanced lines that never run past the card above.
                    .padding(.horizontal, OnboardingMetrics.cardInset)
                    .frame(maxWidth: .infinity)
            }
        }
        // (OnboardingView re-reads the permissions whenever the app becomes active, on every page.)
        // VoiceOver keeps its focus on the test button: say what the test found.
        .onChange(of: model.micTest.heardSound) { _, heard in
            if heard { AccessibilityNotification.Announcement(Self.heardText).post() }
        }
        .onChange(of: model.micTest.failure) { _, failure in
            if let failure { AccessibilityNotification.Announcement(failure).post() }
        }
        .onChange(of: model.micTest.finished) { _, finished in
            if finished, !model.micTest.heardSound { AccessibilityNotification.Announcement(Self.silentText).post() }
        }
    }

    private static var heardText: String { String(localized: "Sound heard", comment: "Microphone test result while the meter runs; the same fact as “Allowed, sound heard” once the test ends") }
    private static var silentText: String {
        String(localized: "Vauta didn’t hear anything. Check the input in System Settings\u{00A0}→\u{00A0}Sound.", comment: "Microphone test result when nothing was heard")
    }

    private var micTestButton: some View {
        Button(micTestTitle) {
            model.micTest.running ? model.micTest.stop() : model.micTest.start()
        }
        .disabled(recorder.isRecording || recorder.isBusy)
        .help(String(localized: "Show your input level for five seconds. Nothing is recorded.", comment: "Microphone test help"))
    }

    private var micTestTitle: String {
        let test = model.micTest
        if test.running { return String(localized: "Stop Test", comment: "Microphone test button") }
        if test.finished || test.failure != nil { return String(localized: "Test Again", comment: "Microphone test button after a test") }
        return String(localized: "Test Microphone", comment: "Microphone test button")
    }

    /// A test result: the row's secondary text at its text column, as in Status. The row's own state icon turns into
    /// the warning mark when nothing was heard, so the meaning doesn't depend on colour and the column stays straight.
    private func testResult(_ text: String) -> some View {
        // Each sentence starts a line, and nothing is hyphenated: "System Settings" stays whole on its line.
        SentenceParagraphs(text: text).fixedSize(horizontal: false, vertical: true)
    }

    /// The test found nothing: the sentence on the whole text width, and under it the button that opens the pane where
    /// the input is chosen.
    private func problemDetail(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            testResult(text)
            Button("Open Sound Settings") { Permissions.open(.sound) }.fixedSize()
        }
    }

    /// What the test found, in the row's state column, where the person looks for it: the icon and the word agree.
    /// Nil: the permission's own state.
    private var micStateLabel: String? {
        let test = model.micTest
        guard model.microphone == .granted, !test.running else { return nil }
        if test.failure != nil { return String(localized: "Allowed, no input", comment: "Microphone state after a test that could not listen") }
        guard test.finished else { return nil }
        return test.heardSound
            ? String(localized: "Allowed, sound heard", comment: "Microphone state after a test that heard something")
            : String(localized: "Allowed, no sound", comment: "Microphone state after a test that heard nothing")
    }

    private var micTestFoundProblem: Bool {
        let test = model.micTest
        return test.failure != nil || (!test.running && test.finished && !test.heardSound)
    }

    /// The microphone's description, or the test in its place: one line either way, so the row keeps its height
    /// while the test runs, and the sentence has the whole width, so it never truncates.
    @ViewBuilder
    private var micDetail: some View {
        let test = model.micTest
        if let failure = test.failure {
            problemDetail(failure)
        } else if test.running {
            // The meter fills the room before the state column, so the result starts where the rows' states do.
            MeterResultLayout {
                MicLevelMeter(level: test.level)
                    .accessibilityLabel(String(localized: "Microphone level", comment: "Accessibility label"))
                if test.heardSound {
                    testResult(Self.heardText)
                } else {
                    Text("Say something…", comment: "Microphone test prompt").fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 16)
        } else if test.finished && !test.heardSound {
            problemDetail(Self.silentText)
        } else if model.microphone == .denied {
            // The same style as the test's own problems: one look for every problem text of the row.
            testResult(CaptureError.microphoneDeniedMessage)
        } else {
            Text(wrapping: String(localized: "Hears your voice, shown as “\(Channel.me.displayName)”.", comment: "Permission detail; argument is the user's channel name").avoidingWidow)
        }
    }
}

/// The input level of the microphone test. Its track is drawn with the text colour at a low opacity and a hairline,
/// so the whole length of the meter shows on the card in both appearances (the system bar's track nearly vanishes
/// on a light card), also while the level is low.
private struct MicLevelMeter: View {
    let level: Double

    var body: some View {
        let fraction = min(max(level, 0), 1)
        Capsule()
            .fill(Color.primary.opacity(0.12))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule().fill(Color.green)
                        .frame(width: fraction > 0 ? max(geometry.size.height, geometry.size.width * fraction) : 0)
                }
            }
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5) }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

/// The columns of the permission rows: the state starts `actions + spacing + state` before the trailing edge.
private enum PermissionColumns {
    static let state: CGFloat = 112
    /// Wide enough for the longest "Open System Settings" of the supported languages: a button never truncates.
    static let actions: CGFloat = 200
    static let spacing: CGFloat = 8

    /// The distance from the trailing edge to the state column's start.
    static var stateInset: CGFloat { actions + spacing + state }
}

/// The microphone test's meter and its result: the result starts in the state column of the rows, the meter takes
/// the room before it.
private struct MeterResultLayout: Layout {
    private let gap: CGFloat = 10
    private let minimumMeter: CGFloat = 60

    private func resultX(_ width: CGFloat) -> CGFloat { max(minimumMeter + gap, width - PermissionColumns.stateInset) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 320
        let result = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, width - resultX(width)), height: nil))
        return CGSize(width: width, height: max(result.height, 8))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let x = resultX(bounds.width)
        let resultProposal = ProposedViewSize(width: max(0, bounds.width - x), height: nil)
        let result = subviews[1].sizeThatFits(resultProposal)
        subviews[1].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), anchor: .topLeading, proposal: resultProposal)
        let meterHeight = subviews[0].sizeThatFits(.unspecified).height
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (min(result.height, 16) - meterHeight) / 2),
                          anchor: .topLeading, proposal: ProposedViewSize(width: x - gap, height: nil))
    }
}

/// One permission: its state icon, name and state with the action on the first line, a description below.
/// State and action have their own columns, so the states of all rows line up.
private struct PermissionRow<Detail: View, Actions: View>: View {
    let title: String
    let state: PermissionState
    /// Not allowing it is not an error: a refusal gets no red mark.
    var isOptional = false
    /// A row without a button leaves that column empty, so its state lines up with the others.
    var hasActions = true
    /// Something is wrong that the state alone doesn't say (the microphone test heard nothing): the icon warns.
    var warns = false
    /// The state column's text when it says more than the permission's own state ("Allowed, no sound").
    var stateLabel: String?
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let actions: () -> Actions

    private static var stateWidth: CGFloat { PermissionColumns.state }
    private static var actionsWidth: CGFloat { PermissionColumns.actions }
    private static var spacing: CGFloat { PermissionColumns.spacing }

    /// An optional permission that is off is the same state as in Status (needs attention): the same warning mark.
    private var showsWarning: Bool { warns || (state == .denied && isOptional) }

    private var iconColor: Color {
        switch state {
        case .granted: .green
        case .denied: .red
        default: .secondary
        }
    }

    private var titleText: some View {
        // A long compound (German) is never broken in the middle of a word.
        Text(title)
            .fontWeight(.medium)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    /// `fixedWidth`: the column's width; without it the text takes the width it is offered.
    private func stateText(fixedWidth: Bool = true) -> some View {
        Text(stateLabel ?? state.label)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: fixedWidth ? Self.stateWidth : nil, alignment: .leading)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: showsWarning ? StatusSymbol.warning.name : state.symbol)
                .font(.title3)
                .foregroundStyle(showsWarning ? StatusSymbol.warning.color : iconColor)
                .frame(width: 24, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // The name and its state are one thing for VoiceOver ("Microphone, Not allowed"); the button follows on its own.
                if hasActions {
                    // The state keeps its shared column and uses what the actual button leaves free, so it stays on
                    // one line next to a short button. The name and its state are one thing for VoiceOver.
                    TitleStateLayout(stateWidth: Self.stateWidth, reserve: Self.actionsWidth + Self.spacing, spacing: Self.spacing) {
                        titleText.accessibilityValue(Text(stateLabel ?? state.label))
                        stateText(fixedWidth: false).accessibilityHidden(true)
                        actions().fixedSize()
                    }
                    .frame(minHeight: 28)
                } else {
                    // No button: its column stays empty, so the state is where it is in the other rows, unless the
                    // name needs that room (a long compound in German): then the name wins and the state moves over.
                    TitleStateLayout(stateWidth: Self.stateWidth, reserve: Self.actionsWidth + Self.spacing, spacing: Self.spacing) {
                        titleText
                        stateText(fixedWidth: false)
                    }
                    .accessibilityElement(children: .combine)
                    .frame(minHeight: 28)
                }
                detail()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The name and the state of a permission row (and its button, when it has one, as a third subview at the trailing edge): the state starts in its column (`reserve` from the
/// trailing edge, where the other rows have their button) and may use that empty button column too, so it stays on
/// one line. The name takes the space before it (two lines at most). Both are aligned on their first baseline.
private struct TitleStateLayout: Layout {
    let stateWidth: CGFloat
    let reserve: CGFloat
    let spacing: CGFloat

    private struct Plan {
        var titleWidth: CGFloat
        var stateX: CGFloat
        var stateWidth: CGFloat
    }

    private func plan(width: CGFloat, title: LayoutSubview, state: LayoutSubview, actionWidth: CGFloat = 0) -> Plan {
        // Where the state may end: before the button, when there is one.
        let end = actionWidth > 0 ? width - actionWidth - spacing : width
        let wanted = title.sizeThatFits(.unspecified).width
        let alignedX = width - reserve - stateWidth
        let room = alignedX - spacing
        // The state is where it is in the other rows. A long name wraps to two lines in the room before it (so
        // the three states line up); only a name with a word too long for that room pushes the state over.
        let wraps = wanted > room && wanted <= room * 1.8 && title.sizeThatFits(.zero).width <= room
        if wanted <= room || wraps {
            // The button's column is empty: the state may use it, so it stays on one line.
            return Plan(titleWidth: max(0, min(wanted, room)), stateX: alignedX, stateWidth: max(stateWidth, end - alignedX))
        }
        let stateX = min(wanted + spacing, width - stateWidth)
        let pushedWidth = min(end - stateX, reserve + stateWidth)
        return Plan(titleWidth: max(0, min(wanted, stateX - spacing)), stateX: stateX, stateWidth: max(stateWidth, pushedWidth))
    }

    private func actionWidth(_ subviews: Subviews) -> CGFloat {
        subviews.count == 3 ? subviews[2].sizeThatFits(.unspecified).width : 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count >= 2 else { return .zero }
        let width = proposal.width ?? (reserve + stateWidth + spacing + subviews[0].sizeThatFits(.unspecified).width)
        let plan = plan(width: width, title: subviews[0], state: subviews[1], actionWidth: actionWidth(subviews))
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: plan.titleWidth, height: nil))
        let state = subviews[1].sizeThatFits(ProposedViewSize(width: plan.stateWidth, height: nil))
        let action = subviews.count == 3 ? subviews[2].sizeThatFits(.unspecified).height : 0
        return CGSize(width: width, height: max(title.height, state.height, action))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let actionWidth = actionWidth(subviews)
        let plan = plan(width: bounds.width, title: subviews[0], state: subviews[1], actionWidth: actionWidth)
        let titleProposal = ProposedViewSize(width: plan.titleWidth, height: nil)
        let stateProposal = ProposedViewSize(width: plan.stateWidth, height: nil)
        var baseline = max(subviews[0].dimensions(in: titleProposal)[.firstTextBaseline],
                           subviews[1].dimensions(in: stateProposal)[.firstTextBaseline])
        if subviews.count == 3 { baseline = max(baseline, subviews[2].dimensions(in: .unspecified)[.firstTextBaseline]) }
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + baseline - subviews[0].dimensions(in: titleProposal)[.firstTextBaseline]),
                          anchor: .topLeading, proposal: titleProposal)
        subviews[1].place(at: CGPoint(x: bounds.minX + plan.stateX, y: bounds.minY + baseline - subviews[1].dimensions(in: stateProposal)[.firstTextBaseline]),
                          anchor: .topLeading, proposal: stateProposal)
        if subviews.count == 3 {
            subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + baseline - subviews[2].dimensions(in: .unspecified)[.firstTextBaseline]),
                              anchor: .topTrailing, proposal: .unspecified)
        }
    }
}

/// Page 4: download the speech model of the chosen language.
struct SpeechModelPage: View {
    let preferences: Preferences
    let speech: SpeechSettingsModel

    /// The chosen language's speech model is on this Mac.
    private var installed: Bool {
        guard let language = speech.effectiveLanguage(preferences.transcriptionLanguage) else { return false }
        return speech.state(language) == .installed
    }

    var body: some View {
        VStack(spacing: 12) {
            // The header is the page's identity: the same outline in every state ("Installed" is said in the row).
            OnboardingHeader(symbol: "arrow.down.circle",
                             title: String(localized: "Speech Model", comment: "Setup page title"),
                             // Once installed there is no download to promise.
                             subtitle: installed
                                ? String(localized: "Vauta transcribes with Apple’s speech model, which runs on this Mac.",
                                         comment: "Setup page subtitle when the speech model is installed")
                                : String(localized: "Vauta transcribes with Apple’s speech model, which runs on this Mac. It downloads once from Apple.",
                                         comment: "Setup page subtitle"))
            if let language = speech.effectiveLanguage(preferences.transcriptionLanguage) {
                let failed = speech.errorMessage != nil
                OnboardingCard {
                    if speech.state(language) == .downloading {
                        // The bar takes the room between the name and the percent, so it starts right after the name.
                        SpeechDownloadingRow(language: language, speech: speech)
                    } else {
                        SetupFieldRow(title: language.displayName.standaloneCapitalized, alignment: .firstTextBaseline) {
                            SpeechDownloadControl(language: language, speech: speech)
                        }
                    }
                    if failed, speech.state(language) == .notInstalled, let error = speech.rowErrorMessage ?? speech.errorMessage {
                        // The same failure as on the last page: its mark, title and both buttons under the message.
                        TipWithAction(symbol: .error,
                                      title: String(localized: "The speech model couldn’t download.", comment: "Setup last page: title of the problem when the speech model download failed; the cause is under it"),
                                      text: error,
                                      actions: [(String(localized: "Try Again"), { speech.install(language) })]
                                        + (speech.failureNeedsSpace ? [(String(localized: "Open Storage Settings"), { Permissions.open(.storage) })] : []))
                    } else if let error = speech.rowErrorMessage ?? speech.errorMessage {
                        // Starts at the card's inset, like the language row above it.
                        SetupStatusLabel(text: error, onBulletGrid: false)
                    }
                }
                switch speech.state(language) {
                case .installed, .unsupported:
                    EmptyView()
                default:
                    // The same sentence before and during the download: it must not read as news once it starts.
                    Text(wrapping: (failed ? String(localized: "You can continue and download it later in Settings\u{00A0}→\u{00A0}Recording.", comment: "Setup speech model footnote after a failed download")
                                : String(localized: "The download goes on while you set up the rest.", comment: "Setup speech model footnote before and during the download; the Continue button starts it")).keepingLastWordsTogether)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        // The card's full width (as the permissions footnote): one line where it fits.
                        .padding(.horizontal, OnboardingMetrics.cardInset)
                        .frame(maxWidth: .infinity)
                }
            } else if speech.catalog == nil {
                ProgressView()
                    .accessibilityLabel(String(localized: "Checking the speech model…", comment: "VoiceOver: progress while the speech model catalog loads"))
            } else {
                SetupStatusLabel(text: String(localized: "Speech recognition isn’t available on this Mac.", comment: "Setup speech model unavailable"))
            }
        }
    }
}

/// The language, a bar that fills the room left, the percent and Cancel.
/// The speech model page and the last page show the same row for the same download. The last page has no heading to say what is
/// downloading, so there (`titled`) the row says it, and why it matters, and its bar and button name the download.
struct SpeechDownloadingRow: View {
    let language: SpeechLanguage
    let speech: SpeechSettingsModel
    var titled = false

    var body: some View {
        let progress = speech.progress(language) ?? 0
        VStack(alignment: .leading, spacing: 4) {
            if titled {
                Text("Downloading the speech model", comment: "Setup last page: heading of the speech model download row")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(alignment: .center, spacing: 12) {
                Text(language.displayName.standaloneCapitalized).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                ProgressView(value: progress)
                    .frame(minWidth: 80, maxWidth: .infinity)
                    .accessibilityLabel(titled
                        ? String(localized: "Speech model download", comment: "Accessibility label of the speech model download bar on the setup's last page")
                        : String(localized: "Download progress", comment: "Accessibility label"))
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
                Button(titled ? String(localized: "Cancel Download", comment: "Setup last page: stops the speech model download") : String(localized: "Cancel")) { speech.cancelInstall(language) }
                    .fixedSize()
            }
            .frame(minHeight: 28)
            if titled {
                Text("You can record once it finishes.", comment: "Setup last page: under the speech model download, why it matters")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SpeechDownloadControl: View {
    let language: SpeechLanguage
    let speech: SpeechSettingsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch speech.state(language) {
            case .installed:
                // The state in the secondary callout of the other rows (as in the permission rows), with its mark leading.
                Label {
                    Text("Installed").font(.callout).foregroundStyle(.secondary)
                } icon: {
                    StatusSymbol.ok.image
                }
            case .downloading:
                EmptyView()
            case .notInstalled:
                // The footer's "Download and Continue" is the one action that starts it: the card only says the state.
                // With its mark, as "Installed" has: every state of the row is a glyph and a word.
                Label {
                    Text(SpeechModelState.notInstalled.label).font(.callout).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                }
            case .unsupported:
                Text(SpeechModelState.unsupported.label).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
