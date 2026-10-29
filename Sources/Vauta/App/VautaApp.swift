// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

struct VautaApp: App {
    // The model lives in the delegate (a property wrapper, not a macro: it
    // builds with the Command Line Tools), which can then close the recording
    // before quitting.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model: RecorderModel { appDelegate.model }

    var body: some Scene {
        MenuBarExtra {
            RecorderPanel(model: model)
        } label: {
            MenuBarLabel(model: model, preferences: appDelegate.preferences)
        }
        .menuBarExtraStyle(.window)

        Window("Meetings", id: "meetings") {
            Group {
                // Gated here too: an unlocked window never outlives the lock.
                if let history = model.history, model.historyUnlocked {
                    MeetingsWindow(model: history, recorder: model, preferences: appDelegate.preferences,
                                   settings: appDelegate.settings)
                        // Using the window keeps it unlocked (see the relock policy).
                        .background(ActivityReporter { model.touchHistory() })
                } else {
                    MeetingsLockedView(recorder: model)
                }
            }
            .background(WindowHardening())
            .writingToolsBehavior(.disabled)
        }
        .defaultSize(width: 900, height: 600)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // The automatic Window-menu item would open the window without Touch ID; "Meetings Window" below does it right.
        .commandsRemoved()
        .commands {
            MeetingsCommands()
            AppCommands(model: model)
        }

        // Plain windows (not the Settings scene): in a menu-bar app they open
        // and come to the front reliably.
        Window(String(localized: "Set Up Vauta", comment: "Window title of the first-run setup"), id: "onboarding") {
            OnboardingView(recorder: model, preferences: appDelegate.preferences, settings: appDelegate.settings)
                .background(WindowHardening())
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window(String(localized: "Network Activity", comment: "Window title"), id: "network-activity") {
            NetworkActivityWindow(model: appDelegate.network, settings: appDelegate.settings)
                .background(WindowHardening())
        }
        .defaultSize(width: 1240, height: 660)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Vauta Settings", id: "settings") {
            SettingsWindow(recorder: model, preferences: appDelegate.preferences, model: appDelegate.settings)
                .background(WindowHardening())
                .writingToolsBehavior(.disabled)
        }
        .defaultSize(width: SettingsWindow.defaultWidth, height: SettingsWindow.defaultHeight)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

/// The Vauta menu's "Settings…" (⌘,) and the Help menu. While a window is open Vauta is a
/// regular app with a menu bar, and macOS users expect both.
struct AppCommands: Commands {
    let model: RecorderModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showWindow("settings") }
                .keyboardShortcut(",")
        }
        // ⌘Q asks first while a recording runs, like the panel's Quit button. System terminations skip the menu.
        CommandGroup(replacing: .appTermination) {
            Button("Quit Vauta") { model.quit() }
                .keyboardShortcut("q")
                // As the panel's Quit button: a restore or a save in progress finishes first.
                .disabled(model.phase == .stopping || model.isReplacingData)
        }
        CommandGroup(after: .windowArrangement) {
            // Dock icon shown, no panel in sight: Meetings must be one shortcut away (after Touch ID, as usual).
            // Named for the window: View ▸ Meetings (⌘1) is the mode inside it.
            Button("Meetings Window") { Task { await model.openMeeting(nil) } }
                .keyboardShortcut("0")
            // ⌥⌘N: ⌘N is "New" inside the Meetings window and ⇧⌘N is the system's new-folder shortcut.
            Button("Network Activity") { model.showWindow("network-activity") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        // Every command of the panel is also in the menu bar (Full Keyboard Access, VoiceOver, a shortcut taken by another
        // app), with the same rules as the panel: grey while the data is closed or a start or a save is under way.
        CommandMenu("Recording") {
            Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggle() }
                .keyboardShortcut(Self.shortcut(model.preferences.recordHotKey, available: model.hotKeyAvailable))
                .disabled(model.isBusy || model.isReplacingData || (!model.isRecording && model.panelDataUnavailable))
            Button("Mark a Moment") { model.markMoment() }
                .keyboardShortcut(Self.shortcut(model.preferences.markHotKey, available: model.markHotKeyAvailable))
                .disabled(!model.isRecording)
            Toggle("Live Translation", isOn: Binding(get: { model.liveTranslation.isEnabled },
                                                     set: { model.liveTranslation.setEnabled($0) }))
                .keyboardShortcut(Self.shortcut(model.preferences.translationHotKey, available: model.translationHotKeyAvailable))
                .disabled(model.panelDataUnavailable)
        }
        CommandGroup(replacing: .help) {
            // Setup closed by mistake (or skipped) is one click away, from the first page.
            Button("Set Up Vauta") { model.showWindow("onboarding") }
            Button("Vauta Help") { NSWorkspace.shared.open(ModelQuality.helpURL) }
        }
    }
}

extension AppCommands {
    /// The menu's key equivalent for a global shortcut, so the menu shows it; nil when it isn't registered or has no letter.
    static func shortcut(_ combo: HotKeyCombo, available: Bool) -> KeyboardShortcut? {
        guard available, let label = GlobalHotKey.keyLabel(combo.keyCode)?.lowercased(), label.count == 1,
              let character = label.first else { return nil }
        var modifiers: EventModifiers = []
        if combo.modifiers & HotKeyCombo.control != 0 { modifiers.insert(.control) }
        if combo.modifiers & HotKeyCombo.option != 0 { modifiers.insert(.option) }
        if combo.modifiers & HotKeyCombo.shift != 0 { modifiers.insert(.shift) }
        if combo.modifiers & HotKeyCombo.command != 0 { modifiers.insert(.command) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}

/// Every way out (menu, ⌘Q, log out, shut down, `osascript quit`, SIGTERM)
/// goes through applicationShouldTerminate: the recording stops, the meeting
/// is closed and saved encrypted before quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Decided before RecorderModel opens (and possibly creates) the store.
    let preferences: Preferences
    let model: RecorderModel
    let settings: SettingsModel
    let network = NetworkActivityModel()
    private var sigterm: DispatchSourceSignal?
    private var terminating = false
    private var waitingForRestore = false
    private var askingAboutModels = false

    override init() {
        preferences = Preferences(legacyInstall: MeetingStore.existsAtDefaultLocation)
        model = RecorderModel(preferences: preferences)
        settings = SettingsModel(speech: model.speechDownloads)
        super.init()
        model.settingsModel = settings
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockPresence.shared.start()
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        sigterm = source
        // Window state AppKit might have saved (outside the encrypted store).
        if let bundleID = Bundle.main.bundleIdentifier,
           let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: library.appendingPathComponent("Saved Application State/\(bundleID).savedState"))
        }
        // Event files handed to Calendar in an earlier session are removed (they are also cleared 10 minutes after a hand-off).
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first { ICSHandoff.purge(in: caches, everything: true) }
    }

    /// Opening Vauta again (Finder, Spotlight, Apps) while it runs: with no window open, bring one
    /// forward. The menu bar icon can be hidden (behind the notch, by a menu bar manager), and this is
    /// then the only way back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !DockPresence.shared.hasOpenWindow else { return true }
        if preferences.needsOnboarding {
            model.showWindow("onboarding")
        } else if model.history == nil {
            model.showSettings(.general)
        } else {
            Task { await model.openMeeting(nil) }
        }
        return false
    }

    /// A quit the person asked for from outside Vauta's own menus (Dock → Quit, ⌘Tab then Q): a plain quit Apple event.
    /// Log out, restart and shut down carry a reason and are never asked about.
    private var isUserQuitEvent: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else { return false }
        guard let reason = event.paramDescriptor(forKeyword: AEKeyword(0x7768_793F /* 'why?' */)) else { return true }
        return reason.enumCodeValue == OSType(0x7175_6961 /* 'quia' */)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The same question as ⌘Q and the panel's Quit when a recording runs.
        if isUserQuitEvent, model.isRecording, !terminating, !model.confirmQuit() { return .terminateCancel }
        // The store is being replaced by a restore: quitting now could leave it half written.
        // The quit is put off until the restore ends, then asked again (the normal path).
        if model.isReplacingData {
            guard !waitingForRestore else { return .terminateLater }
            waitingForRestore = true
            Task { @MainActor in
                while model.isReplacingData { try? await Task.sleep(for: .milliseconds(200)) }
                waitingForRestore = false
                sender.reply(toApplicationShouldTerminate: false)
                NSApp.terminate(nil)
            }
            return .terminateLater
        }
        // Unapplied model server changes in an open Settings window are asked about, as when closing it.
        if !askingAboutModels, ModelsCloseGuard.confirmQuit(completion: { [self] proceed in
            askingAboutModels = false
            sender.reply(toApplicationShouldTerminate: false)
            if proceed { NSApp.terminate(nil) }
        }) {
            askingAboutModels = true
            return .terminateLater
        }
        if askingAboutModels { return .terminateLater }
        guard model.needsGracefulStop else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await model.shutdown()
            reply()
        }
        // Cap: never block logging out if something hangs. After 7 s, whatever
        // is there is flushed (waiting up to 4 s more for pending writes) and
        // the app quits.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(7))
            guard !replied else { return }
            await model.emergencySave(within: .seconds(4))
            reply()
        }
        return .terminateLater
    }
}

/// Extra defence (not guaranteed against ScreenCaptureKit): the window stays
/// out of screen sharing and screenshots, and AppKit doesn't save its state.
/// It also registers the window with `DockPresence`.
private final class HardeningView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.sharingType = .none
        window?.isRestorable = false
        if let window { DockPresence.shared.track(window) }
    }
}

struct WindowHardening: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HardeningView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The same defence for a sheet: its own window asks to stay out of screen sharing (not guaranteed either). A sheet is not a main window, so it is
/// not registered with `DockPresence`.
private final class SheetHardeningView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.sharingType = .none
        window?.isRestorable = false
    }
}

struct SheetHardening: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SheetHardeningView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Calls `onActivity` for keyboard, click and scroll events in its window
/// (throttled to once a second). Local events only: Vauta never sees other
/// apps' input.
struct ActivityReporter: NSViewRepresentable {
    let onActivity: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView { ActivityView(onActivity: onActivity) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ActivityView: NSView {
        let onActivity: @MainActor () -> Void
        private var monitor: Any?
        private var last = Date.distantPast

        init(onActivity: @escaping @MainActor () -> Void) {
            self.onActivity = onActivity
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, self.isActivity(in: event.window), Date.now.timeIntervalSince(self.last) > 1 {
                        self.last = .now
                        self.onActivity()
                    }
                }
                return event
            }
        }

        /// An event in the window or in a sheet of it (Back Up, Restore, Erase, a save or open panel shown as a sheet):
        /// typing a password there is activity in the window, or the relock would close the sheet under the typing.
        private func isActivity(in eventWindow: NSWindow?) -> Bool {
            guard let window else { return false }
            var current = eventWindow
            while let candidate = current {
                if candidate === window { return true }
                current = candidate.sheetParent ?? candidate.parent
            }
            // A file panel that ran app-modal because a sheet was already open.
            return eventWindow is NSSavePanel && window.attachedSheet != nil
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}
