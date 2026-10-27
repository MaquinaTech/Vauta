// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// Copy protection for meeting text (Settings → Privacy & Security). Views that show
/// meeting content read it; window roots set it from `Preferences`.
/// Defaults to on, the safe choice for a view nobody configured.
private struct CopyProtectionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var copyProtection: Bool {
        get { self[CopyProtectionKey.self] }
        set { self[CopyProtectionKey.self] = newValue }
    }
}

/// The editable text field for meeting content (titles, summaries, tasks,
/// questions, notes).
///
/// With copy protection off it behaves like any Mac text view: copy, cut,
/// drag, Services, Look Up and spell checking all work.
///
/// With copy protection on, text can be typed and pasted but not taken out:
/// no copy or cut (a short explanation appears instead), no dragging the
/// selection, no Services, no Share or Look Up, and spell checking is off so
/// the text isn't handed to the spelling service. Writing Tools stay off in
/// both modes (they may send text off the Mac). Accessibility clients such as
/// VoiceOver can always read the text.
struct NoCopyText: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    /// Read by VoiceOver; defaults to the placeholder.
    var accessibilityLabel: String?
    var singleLine = false
    /// With `singleLine`: a long value wraps onto more lines (the caller sizes the field to fit them) instead of ending in an ellipsis. Still no line breaks in the value.
    var wraps = false
    /// What a line break pasted into a single-line field becomes.
    var lineBreakReplacement = " "
    var font: NSFont = .preferredFont(forTextStyle: .body)
    /// Continuous spell checking (when copy protection allows it). Off for
    /// text full of names, which the checker would underline.
    var checksSpelling = true
    /// The field doesn't take the window's initial focus (no caret when a
    /// window opens); clicking it or tabbing to it still works.
    var avoidsInitialFocus = false
    /// The field asks for the keyboard when it appears, whatever the layout around it decides (the quick note of the
    /// menu-bar panel), instead of leaving it to the window's own choice of first field.
    var takesInitialFocus = false
    /// Each new value asks the field for the keyboard, with its text selected (a follow-up question after an answer).
    var focusRequest = 0
    /// Return in a single-line field (⌘Return in a multi-line one).
    var onCommit: (() -> Void)?
    /// The field has the keyboard (it is the first responder of the key window), or lost it.
    var onFocusChange: ((Bool) -> Void)?
    /// ↑ in an empty single-line field (the notepad edits the last note). Returns whether it did something.
    var onMoveUp: (() -> Bool)?
    /// Esc. Without it Esc keeps its usual meaning.
    var onCancel: (() -> Void)?
    @Environment(\.copyProtection) private var copyProtection
    /// `.disabled(_)` on the field: it stops taking the keyboard and is drawn dimmed, like any text field.
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = SingleLineScrollView()
        scroll.singleLine = singleLine && !wraps
        scroll.hasVerticalScroller = !singleLine
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let view = NoCopyTextView()
        view.delegate = context.coordinator
        view.singleLine = singleLine
        view.wraps = wraps
        view.onCommit = { [weak coordinator = context.coordinator] in coordinator?.parent.onCommit?() }
        view.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.parent.onFocusChange?(focused) }
        view.onMoveUp = { [weak coordinator = context.coordinator] in coordinator?.parent.onMoveUp?() ?? false }
        view.onCancel = { [weak coordinator = context.coordinator] in coordinator?.parent.onCancel?() }
        view.hasCancelAction = onCancel != nil
        view.font = font
        view.isRichText = false
        view.importsGraphics = false
        view.allowsImageEditing = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.usesFindBar = false
        view.allowsUndo = true
        view.writingToolsBehavior = .none
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 2, height: 4)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = !singleLine || wraps
        if singleLine && !wraps {
            // One line that scrolls sideways under the caret instead of truncating.
            view.isHorizontallyResizable = true
            view.autoresizingMask = [.height]
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.maximumNumberOfLines = 1
            view.textContainer?.lineBreakMode = .byClipping
        } else {
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
        }
        view.string = text
        apply(to: view)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NoCopyTextView else { return }
        if view.string != text { view.string = text }
        if view.font != font { view.font = font }
        apply(to: view)
        if view.focusRequest != focusRequest {
            view.focusRequest = focusRequest
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isEnabled, let window = view.window, window.isKeyWindow else { return }
                if window.firstResponder !== view { window.makeFirstResponder(view) }
                view.selectAll(nil)
            }
        }
    }

    private func apply(to view: NoCopyTextView) {
        view.hasCancelAction = onCancel != nil
        if view.placeholder != placeholder {
            view.placeholder = placeholder
            view.needsDisplay = true
        }
        view.protected = copyProtection
        view.setEnabled(isEnabled)
        view.lineBreakReplacement = lineBreakReplacement
        view.isContinuousSpellCheckingEnabled = !copyProtection && checksSpelling
        view.avoidsInitialFocus = avoidsInitialFocus
        view.takesInitialFocus = takesInitialFocus
        view.setAccessibilityLabel(accessibilityLabel ?? placeholder)
        view.setAccessibilityPlaceholderValue(placeholder)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoCopyText
        init(_ parent: NoCopyText) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

/// Keeps a single-line text view at least as wide as the visible area, so
/// clicks anywhere in the field place the caret.
private final class SingleLineScrollView: NSScrollView {
    var singleLine = false

    override func tile() {
        super.tile()
        guard singleLine, let view = documentView else { return }
        let width = contentSize.width
        if view.frame.width < width || view.frame.height != contentSize.height {
            view.setFrameSize(NSSize(width: max(view.frame.width, width), height: contentSize.height))
        }
        (view as? NSTextView)?.minSize = NSSize(width: width, height: contentSize.height)
    }
}

final class NoCopyTextView: NSTextView {
    var singleLine = false
    var wraps = false
    var lineBreakReplacement = " "
    var placeholder = ""
    var onCommit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onMoveUp: (() -> Bool)?
    var onCancel: (() -> Void)?
    var hasCancelAction = false
    private var focusObservers: [NSObjectProtocol] = []
    /// Copy protection on: nothing leaves the view.
    var protected = true
    /// Refuses the focus the window hands out by itself when it opens (only a
    /// click or the Tab key put the caret here).
    var avoidsInitialFocus = false
    var takesInitialFocus = false
    var focusRequest = 0
    /// Off while the field is disabled: no keyboard, no caret, dimmed text.
    private(set) var isEnabled = true
    /// The field had the keyboard when it was disabled, so it gets it back when it is enabled again
    /// (a keyboard user can ask the next question straight away).
    private var hadFocusWhenDisabled = false

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        isEditable = enabled
        textColor = enabled ? .textColor : .secondaryLabelColor
        needsDisplay = true
        if !enabled {
            if let window, window.firstResponder === self {
                hadFocusWhenDisabled = true
                window.makeFirstResponder(nil)
            }
        } else if hadFocusWhenDisabled {
            hadFocusWhenDisabled = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEnabled, let window = self.window, window.isKeyWindow,
                      window.firstResponder == nil || window.firstResponder === window else { return }
                window.makeFirstResponder(self)
            }
        }
        setAccessibilityEnabled(enabled)
    }

    override var acceptsFirstResponder: Bool {
        guard isEnabled else { return false }
        if avoidsInitialFocus {
            guard let event = NSApp.currentEvent else { return false }
            switch event.type {
            case .keyDown: break
            case .leftMouseDown, .rightMouseDown:
                guard event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
            default: return false
            }
        }
        return super.acceptsFirstResponder
    }

    // MARK: Copy protection

    override func copy(_ sender: Any?) {
        guard protected else { return super.copy(sender) }
        explainProtection()
    }

    override func cut(_ sender: Any?) {
        guard protected else { return super.cut(sender) }
        explainProtection()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if protected, item.action == #selector(NSTextView.startSpeaking(_:)) { return false }
        // Copy and Cut stay enabled while protected so ⌘C explains instead of beeping.
        return super.validateUserInterfaceItem(item)
    }

    /// Services: while protected, the text is never offered to other apps.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if protected, sendType != nil { return nil }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        protected ? false : super.writeSelection(to: pboard, types: types)
    }

    /// Look Up (force click, ⌃⌘D) would hand the selection to the system
    /// dictionary, which may look it up online.
    override func quickLook(with event: NSEvent) {
        if !protected { super.quickLook(with: event) }
    }

    override func showDefinition(for attrString: NSAttributedString?, at textBaselineOrigin: NSPoint) {
        if !protected { super.showDefinition(for: attrString, at: textBaselineOrigin) }
    }

    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        protected ? false : super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
    }

    /// While protected: a minimal menu (no Copy, Share, Services, Look Up,
    /// Translate or Writing Tools).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard protected else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Paste", comment: "Context menu of a protected text field"),
                     action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Select All", comment: "Context menu of a protected text field"),
                     action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    private var notice: NSPopover?

    /// A short explanation next to the field instead of a silent beep.
    private func explainProtection() {
        let message = String(localized: "Meeting text is protected from copying. To copy it, turn off “Protect meeting text from copying” in Settings\u{00A0}→\u{00A0}Privacy & Security.",
                             comment: "Shown when the user tries to copy text while copy protection is on")
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        guard notice == nil else { return }
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .preferredFont(forTextStyle: .callout)
        label.preferredMaxLayoutWidth = 260
        let controller = NSViewController()
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        controller.view = container
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        let range = selectedRange()
        var anchor = visibleRect
        if let layout = layoutManager, let container = textContainer, range.length > 0 {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            anchor = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                .intersection(visibleRect)
            if anchor.isEmpty { anchor = visibleRect }
        }
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        notice = popover
        Task { @MainActor [weak self, weak popover] in
            try? await Task.sleep(for: .seconds(4))
            popover?.performClose(nil)
            self?.notice = nil
        }
    }

    // MARK: Keys

    override func moveUp(_ sender: Any?) {
        if singleLine, string.isEmpty, onMoveUp?() == true { return }
        super.moveUp(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasCancelAction { onCancel?() } else { super.cancelOperation(sender) }
    }

    override func insertNewline(_ sender: Any?) {
        if singleLine {
            if let onCommit {
                onCommit()
            } else if let event = NSApp.currentEvent, event.type == .keyDown {
                // No commit action: let the window's default button (or any
                // Return shortcut) handle Return, as in a normal text field.
                _ = window?.performKeyEquivalent(with: event)
            }
            return
        }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true, let onCommit {
            onCommit()
            return
        }
        super.insertNewline(sender)
    }

    /// Tab moves to the next control, as in any form field (meeting text
    /// never needs a literal tab).
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }

    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }

    /// A single-line field never takes a line break, however it arrives
    /// (typing, paste, drop, Services): every kind of break becomes a space
    /// (or `lineBreakReplacement`).
    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        guard singleLine, let replacement = replacementString, SingleLineText.containsBreak(replacement) else {
            return super.shouldChangeText(in: range, replacementString: replacementString)
        }
        let flat = SingleLineText.flatten(replacement, separator: lineBreakReplacement)
        if super.shouldChangeText(in: range, replacementString: flat) {
            replaceCharacters(in: range, with: flat)
            didChangeText()
            setSelectedRange(NSRange(location: range.location + (flat as NSString).length, length: 0))
        }
        return false
    }

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: isEnabled ? NSColor.placeholderTextColor : NSColor.disabledControlTextColor,
                                                    .font: font ?? .preferredFont(forTextStyle: .body)]
        // One point past the caret, so the insertion point never sits on the first letter.
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5) + 1,
                             y: textContainerInset.height)
        NSAttributedString(string: placeholder, attributes: attrs).draw(at: origin)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        let accepted = super.becomeFirstResponder()
        if accepted {
            updateTruncation(editing: true)
            reportFocus(window?.isKeyWindow == true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        let resigned = super.resignFirstResponder()
        if resigned {
            updateTruncation(editing: false)
            reportFocus(false)
        }
        return resigned
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTruncation(editing: window?.firstResponder === self)
    }

    /// A single line that is not being edited ends in an ellipsis when it is too long; while it is edited it scrolls
    /// sideways under the caret instead.
    private func updateTruncation(editing: Bool) {
        guard singleLine, !wraps, let container = textContainer, let scroll = enclosingScrollView else { return }
        let mode: NSLineBreakMode = editing ? .byClipping : .byTruncatingTail
        let width = editing ? CGFloat.greatestFiniteMagnitude : max(scroll.contentSize.width - textContainerInset.width * 2, 20)
        if container.lineBreakMode != mode { container.lineBreakMode = mode }
        if container.size.width != width { container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
    }

    /// Only the field that has the keyboard shows the focus ring and the caret: when the window stops being the key
    /// window, the ring goes with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers = []
        guard let window else { return }
        if takesInitialFocus {
            // Once the view is laid out: the field has the keyboard in every language and layout.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window, window.firstResponder !== self else { return }
                window.makeFirstResponder(self)
            }
        }
        focusObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.reportFocus(self.window?.firstResponder === self) } }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportFocus(false) }
            },
        ]
    }

    private func reportFocus(_ focused: Bool) {
        // Never while SwiftUI is updating its views.
        DispatchQueue.main.async { [weak self] in self?.onFocusChange?(focused) }
    }
}

/// A bordered text field for forms, sized for the system text size.
struct NoCopyField: View {
    let title: String
    @Binding var text: String
    var singleLine = true
    var accessibilityLabel: String?
    /// What a pasted line break becomes in a single-line field.
    var lineBreakReplacement = " "
    var avoidsInitialFocus = false
    var takesInitialFocus = false
    /// Changing this asks the field for the keyboard, with its text selected.
    var focusRequest = 0
    /// The text style of the field and its placeholder; cards that use smaller type pass theirs.
    var font: NSFont = .preferredFont(forTextStyle: .body)
    var onCommit: (() -> Void)?
    /// The field gained or lost the keyboard.
    var onFocus: ((Bool) -> Void)?
    var onMoveUp: (() -> Bool)?
    var onCancel: (() -> Void)?
    @ViewLocalState private var isFocused = false
    @Environment(\.isEnabled) private var isEnabled

    init(title: String, text: Binding<String>, singleLine: Bool = true, accessibilityLabel: String? = nil,
         lineBreakReplacement: String = " ", avoidsInitialFocus: Bool = false, takesInitialFocus: Bool = false,
         focusRequest: Int = 0, font: NSFont = .preferredFont(forTextStyle: .body), onCommit: (() -> Void)? = nil,
         onFocus: ((Bool) -> Void)? = nil, onMoveUp: (() -> Bool)? = nil, onCancel: (() -> Void)? = nil) {
        self.onFocus = onFocus
        self.onMoveUp = onMoveUp
        self.onCancel = onCancel
        self.focusRequest = focusRequest
        self.font = font
        self.avoidsInitialFocus = avoidsInitialFocus
        self.takesInitialFocus = takesInitialFocus
        self.title = title
        self._text = text
        self.singleLine = singleLine
        self.accessibilityLabel = accessibilityLabel
        self.lineBreakReplacement = lineBreakReplacement
        self.onCommit = onCommit
    }

    private var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) + 10 }

    var body: some View {
        NoCopyText(text: $text, placeholder: title, accessibilityLabel: accessibilityLabel, singleLine: singleLine,
                   lineBreakReplacement: lineBreakReplacement, font: font, avoidsInitialFocus: avoidsInitialFocus, takesInitialFocus: takesInitialFocus, focusRequest: focusRequest, onCommit: onCommit,
                   onFocusChange: { isFocused = $0; onFocus?($0) }, onMoveUp: onMoveUp, onCancel: onCancel)
            .frame(height: singleLine ? lineHeight : nil)
            .frame(minHeight: singleLine ? lineHeight : lineHeight * 3)
            .padding(.horizontal, 4)
            .background(Color(nsColor: .textBackgroundColor).opacity(isEnabled ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 6))
            // A disabled field takes no input, so it never draws the focus ring even while it still holds the cursor.
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isFocused && isEnabled ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                    lineWidth: isFocused && isEnabled ? 2 : 1)
                .opacity(isEnabled ? 1 : 0.6))
            // The system's focus ring: a soft halo around the field that has the keyboard.
            .overlay {
                if isFocused && isEnabled {
                    RoundedRectangle(cornerRadius: 7.5).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 3).padding(-3)
                        .allowsHitTesting(false)
                }
            }
    }
}
