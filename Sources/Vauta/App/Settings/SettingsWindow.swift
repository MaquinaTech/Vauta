// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The Settings window: a sidebar of panes, like System Settings.
struct SettingsWindow: View {
    /// The width a new Settings window opens at: the Context pane's list and editor fit comfortably beside the sidebar.
    static let defaultWidth: CGFloat = 1020
    /// The height a new Settings window opens at: the Context editor's Relations card fits above its footer even under the calendar review banner.
    static let defaultHeight: CGFloat = 820
    /// The narrowest window: the Context pane's list and editor (at least ~340 pt) still fit beside the sidebar.
    static let minimumWidth: CGFloat = 920

    @Bindable var recorder: RecorderModel
    @Bindable var preferences: Preferences
    @Bindable var model: SettingsModel
    /// What the sidebar's search field holds; with text, the sidebar lists what it finds (`SettingsSearch`).
    @ViewLocalState private var query = ""
    @ViewLocalState private var chosenResult: SettingsSearchEntry.ID?

    var body: some View {
        NavigationSplitView {
            sidebar
                .environment(\.defaultMinListRowHeight, 28)
                .navigationSplitViewColumnWidth(235)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(model.pane.title)
        }
        // As in System Settings: the field at the top of the sidebar.
        .searchable(text: $query, placement: .sidebar,
                    prompt: Text("Search Settings", comment: "Placeholder of the search field at the top of the Settings sidebar"))
        // On the split view, not on the sidebar list: set on the list it makes the column ignore its width.
        .toolbar(removing: .sidebarToggle)
        // One width for every pane: switching panes never resizes the window.
        .frame(minWidth: Self.minimumWidth, minHeight: 500)
        // The Context pane edits meeting knowledge: same copy rule as Meetings.
        .environment(\.copyProtection, preferences.copyProtection)
        // Using the window (the Context pane) keeps Meetings and Context unlocked.
        .background(ActivityReporter { recorder.touchHistory() })
        // Unapplied model server changes are asked about, not dropped silently.
        .background(ModelsCloseGuard(hasChanges: { model.models.hasChanges(recorder) },
                                     apply: { await model.models.apply(recorder) },
                                     discard: { model.models.discardDraft() },
                                     showModels: { model.pane = .models },
                                     failure: { model.models.applyFeedback?.text }))
        .onDisappear {
            // Unsaved edits and a half-typed key never outlive the window.
            model.models.discardDraft()
        }
    }

    /// The panes, or what the search finds: a pane, or a setting with its pane under it. Choosing one opens the pane.
    @ViewBuilder
    private var sidebar: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            List(SettingsModel.Pane.allCases, selection: Binding(get: { model.pane }, set: { if let pane = $0 { model.pane = pane } })) { pane in
                Label { Text(pane.title) } icon: { Self.icon(of: pane) }
                    .frame(height: 24)
                    .tag(pane)
            }
        } else {
            let results = SettingsSearch.results(for: query)
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(results, selection: Binding(get: { chosenResult }, set: { id in
                    chosenResult = id
                    if let entry = results.first(where: { $0.id == id }) { model.pane = entry.pane }
                })) { entry in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: entry.title)
                            if entry.key != entry.pane.rawValue {
                                Text(verbatim: entry.pane.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: { Self.icon(of: entry.pane) }
                    .accessibilityElement(children: .combine)
                    .tag(entry.id)
                }
            }
        }
    }

    /// As in System Settings: a white symbol on a rounded square in the pane's colour. One fixed box for every row, so no
    /// glyph's height or baseline moves its label off the rhythm.
    private static func icon(of pane: SettingsModel.Pane) -> some View {
        Image(systemName: pane.symbol)
            .symbolVariant(.fill)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.pane {
        case .general: GeneralPane(recorder: recorder, preferences: preferences, model: model)
        case .recording: RecordingPane(recorder: recorder, preferences: preferences, speech: model.speech, showModels: { model.pane = .models })
        case .speakers: SpeakersPane(recorder: recorder, preferences: preferences, voices: model.savedVoices)
        case .translation: TranslationPane(recorder: recorder, preferences: preferences, speech: model.speech,
                                          setUpModelServer: { model.pane = .models; model.models.guidePresented = true },
                                          showModels: { model.pane = .models },
                                          showRecording: { model.pane = .recording })
        case .models: ModelsPane(recorder: recorder, preferences: preferences, models: model.models)
        case .privacy: PrivacyPane(recorder: recorder, preferences: preferences, model: model)
        case .context: ContextPane(recorder: recorder)
        case .documents: DocumentsPane(recorder: recorder)
        case .calendar: CalendarPane(calendar: recorder.calendar, brief: recorder.brief.prefs, after: model.afterMeetings, actionsPreferences: preferences.actions)
        case .status: StatusPane(recorder: recorder, preferences: preferences, model: model)
        case .about: AboutPane()
        }
    }
}

/// A section header with a small button (and spinner) at its trailing edge. The action sits in an overlay, so it adds no
/// height: every pane's first card starts at the same y, and the Status and Models buttons are the same size.
struct SectionHeaderWithAction<Title: View, Action: View>: View {
    @ViewBuilder let title: Title
    @ViewBuilder let action: Action

    var body: some View {
        title
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                HStack(spacing: 8) { action }
                    .controlSize(.small)
            }
    }
}

/// Secondary explanatory text under a setting.
struct SettingsNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    // The size of the system's own row descriptions (the second Text of a LabeledContent label), so every
    // explanation in a card has the same size.
    var body: some View {
        Text(description: text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Text {
    /// A sentence of Settings that explains a row or a section: never hyphenated (macOS System Settings never
    /// splits a word in its descriptions), the last words joined so the last line is never a single word, and
    /// Korean broken at its spaces.
    init(description string: String) {
        let joined = SheetFootnote.keepingLastWordsTogether(string)
        var text = joined.containsHangulSyllables ? AttributedString.hangulWordPriority(joined) : AttributedString(joined)
        text.disableHyphenation(of: joined)
        self.init(text)
    }
}

/// A line with a coloured icon and text in the normal colours: orange or red text on the light
/// background has too little contrast, so the colour is only on the icon (the words carry the meaning).
struct NoticeLabel: View {
    let text: Text
    let symbol: String
    let tint: Color
    /// Hints (a strength, a tip) read as secondary text; warnings and errors as primary.
    var secondary = false
    /// The icon column; a status under radio buttons uses the radios' (16 pt) so both text columns coincide.
    var iconWidth: CGFloat = 20
    /// A second line in the text column under the status, in the size of a row's description.
    var note: Text?
    /// The text size: a callout, or a subheadline where the line is a note under a switch.
    var font: Font = .callout

    init(_ text: Text, symbol: String, tint: Color, secondary: Bool = false, iconWidth: CGFloat = 20, note: Text? = nil, font: Font = .callout) {
        self.font = font
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.secondary = secondary
        self.iconWidth = iconWidth
        self.note = note
    }

    init(_ text: Text, status: StatusSymbol, secondary: Bool = false, iconWidth: CGFloat = 20, note: Text? = nil, font: Font = .callout) {
        self.init(text, symbol: status.name, tint: status.color, secondary: secondary, iconWidth: iconWidth, note: note, font: font)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                text
                    .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .labelStyle(AlignedIconLabelStyle(width: iconWidth))
            .font(font)
            if let note {
                // Lined up with the status text, past the icon column.
                note
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, iconWidth + 8)
            }
        }
    }
}

/// A status at the trailing edge of a row ("In use", "Installed"): the same callout, secondary words in every pane, the
/// colour only on the icon.
struct TrailingStatus<Icon: View>: View {
    let text: Text
    @ViewBuilder let icon: Icon

    var body: some View {
        Label {
            text.foregroundStyle(.secondary)
        } icon: {
            icon
        }
        .font(.callout)
    }
}

/// A one-line result: success, warning or error, with an icon so the meaning
/// never depends on color alone.
struct FeedbackLabel: View {
    let feedback: ModelsSettingsModel.Feedback

    private let iconWidth: CGFloat = 20

    private var isTitle: Bool { feedback.note != nil || feedback.isTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: NoticeMetrics.gap) {
            Label {
                // A result with a note under it is a title (the same weight as every notice); alone it is a plain line.
                // As NoticeText: a title over a detail has no final stop; a one-line result keeps it.
                Text(isTitle ? feedback.text.droppingFinalStop : feedback.text)
                    .fontWeight(isTitle ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            .labelStyle(AlignedIconLabelStyle(width: iconWidth))
            .textSelection(.enabled)
            if let note = feedback.note {
                // Lined up with the text, past the icon column.
                noteText(note)
                    .font(feedback.noteIsValue ? .system(.callout, design: .monospaced) : .subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, iconWidth + 8)
            }
        }
        .font(.callout)
        // The result and its note are one thing for VoiceOver.
        .accessibilityElement(children: .combine)
    }

    /// A note of several sentences flows as one paragraph, like every other note in Settings.
    @ViewBuilder
    private func noteText(_ note: String) -> some View {
        if feedback.noteIsValue { Text(note) } else { Text(description: note) }
    }

    private var symbol: String {
        switch feedback.kind {
        case .success: StatusSymbol.ok.name
        case .warning: StatusSymbol.warning.name
        case .error: StatusSymbol.error.name
        }
    }

    private var color: Color {
        switch feedback.kind {
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

/// A label whose icon sits in a fixed-width column, so the text of stacked
/// rows lines up whatever the symbol (SF Symbols differ in width).
struct AlignedIconLabelStyle: LabelStyle {
    var width: CGFloat = 20
    @Environment(\.iconColumnAlignment) private var alignment

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.frame(width: width, alignment: alignment)
            configuration.title
        }
    }
}

private struct IconColumnAlignmentKey: EnvironmentKey {
    static let defaultValue: Alignment = .center
}

extension EnvironmentValues {
    /// Where the icon sits in its column: centred in a form's rows, flush with the margin in a sheet,
    /// where every icon line starts at the same left edge as the paragraphs.
    var iconColumnAlignment: Alignment {
        get { self[IconColumnAlignmentKey.self] }
        set { self[IconColumnAlignmentKey.self] = newValue }
    }
}

extension String {
    /// The first letter capitalized for the current language, for names shown on
    /// their own (list rows, menu values): `Locale` returns language names in
    /// mid-sentence case ("español", "anglais (États-Unis)").
    var standaloneCapitalized: String {
        guard let first else { return self }
        return String(first).capitalized(with: .current) + dropFirst()
    }
}

/// A title above a vertical list of radio options, the same in every language: a
/// radio-group Picker moves its label beside the options when they fit (CJK)
/// and above them when they don't, and inside a Form it puts the buttons at the
/// trailing edge. Each option is a toggle, so VoiceOver and the keyboard still work.
struct RadioGroupRow<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let options: [(value: Selection, label: String)]
    /// A capsule after the label of some options.
    var badges: [Selection: (text: String, style: BadgeCapsule.Style)] = [:]
    /// Gap between the radio and its label (a group next to system checkboxes uses theirs, so the text shares one edge).
    var labelSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Toggle(isOn: Binding(get: { selection == option.value }, set: { if $0 { selection = option.value } })) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(option.label)
                            if let badge = badges[option.value] { BadgeCapsule(badge.text, style: badge.style) }
                        }
                    }
                    .toggleStyle(RadioToggleStyle(labelSpacing: labelSpacing))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A radio button with its label to the right.
struct RadioToggleStyle: ToggleStyle {
    var labelSpacing: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: labelSpacing) {
                Image(systemName: configuration.isOn ? "circle.inset.filled" : "circle")
                    .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}

/// A single-line, bordered field at the trailing edge of a row, with its own placeholder: a bare field in a grouped
/// form reads as a fixed value, and the system prompt is drawn like entered text, so "Optional" would read as saved.
/// The same look as the certificate fields of the same card.
struct TrailingField: View {
    /// One width for every field of the server card (address, key and model names), so they all end on one edge.
    static var width: CGFloat { 296 }

    let title: String
    @Binding var text: String
    let placeholder: String
    var secure = false

    var body: some View {
        Group {
            if secure {
                SecureField(title, text: $text, prompt: Text(verbatim: placeholder))
            } else {
                TextField(title, text: $text, prompt: Text(verbatim: placeholder))
            }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        // What is typed starts at the leading edge, like every text field; the field itself stays trailing in its row.
        .multilineTextAlignment(.leading)
        .frame(width: Self.width)
        .accessibilityLabel(title)
    }
}

/// Takes the keyboard focus off a text or time field that the window focused by itself
/// when the pane opened, so the saved text isn't selected and typing can't replace it.
struct ClearInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The field takes the focus, and the form scrolls it into view, a moment after the pane appears: clear both, at the
        // start and once the layout has settled (a person has not scrolled yet in the first half second).
        for delay in [0.0, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let view, let window = view.window else { return }
                if window.firstResponder is NSText || window.firstResponder is NSDatePicker { window.makeFirstResponder(nil) }
                // The field that had focus was scrolled into view: the pane opens at its top, where its first choice is.
                Self.scrollToTop(from: view)
            }
        }
        return view
    }

    /// The form's own scroll view: the one that encloses the view (never a sidebar or a list nested in the form).
    private static func scrollToTop(from view: NSView) {
        guard let scroll = view.enclosingScrollView, scroll.documentView != nil else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// SwiftUI's `@State` property wrapper. Recent SDKs resolve the `@State`
/// attribute to a macro whose plugin the Command Line Tools don't ship; the
/// alias names the property wrapper itself.
typealias ViewLocalState<Value> = SwiftUI.State<Value>
