// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import LocalAuthentication

/// The lock on "Meetings" and "Context", and the system events that relock it
/// or stop the recording. The lock protects the interface: the decrypted
/// content still lives in the process's memory.
/// What the Touch ID or password prompt is for: the system words it as "Vauta is trying to <reason>.", so each
/// action says what it really is (the prompt also guards Back Up, Restore, Erase Everything and deleting meetings).
enum HistoryPurpose {
    case show, backUp, restore, erase, deleteOlder

    var reason: String {
        switch self {
        case .show: String(localized: "show your meetings and context", comment: "Touch ID prompt: “Vauta is trying to …”")
        case .backUp: String(localized: "back up your meetings, context and settings", comment: "Touch ID prompt: “Vauta is trying to …”")
        case .restore: String(localized: "restore a backup", comment: "Touch ID prompt: “Vauta is trying to …”")
        case .erase: String(localized: "erase all meetings and context", comment: "Touch ID prompt: “Vauta is trying to …”")
        case .deleteOlder: String(localized: "delete older meetings", comment: "Touch ID prompt: “Vauta is trying to …”")
        }
    }

    /// The alert title when the prompt itself failed: Meetings only for the action that opens them.
    var failureTitle: String {
        switch self {
        case .show: String(localized: "Meetings couldn’t be unlocked", comment: "Alert title")
        default: String(localized: "Couldn’t confirm it’s you", comment: "Alert title when Touch ID or the password could not be checked before a protected action")
        }
    }
}

extension HistoryPurpose {
    /// What to tell the person when the Touch ID or password prompt failed: what happened and what to do, in plain words. The system's own
    /// text for these errors carries the error domain and a code ("com.apple.LocalAuthentication error -8"), which says neither.
    static func failureMessage(for error: Error) -> String {
        switch (error as? LAError)?.code {
        case .authenticationFailed:
            String(localized: "Touch ID or the password didn’t match. Try again.", comment: "Alert text when Touch ID or the login password was refused")
        case .biometryLockout:
            String(localized: "Touch ID is locked after too many tries. Use your login password.", comment: "Alert text when Touch ID is locked out")
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryNotPaired, .biometryDisconnected:
            String(localized: "Touch ID isn’t available right now. Use your login password.", comment: "Alert text when Touch ID can’t be used")
        case .notInteractive:
            String(localized: "Vauta can’t ask for Touch ID or your password right now. Try again in a moment.", comment: "Alert text when the system can’t show the Touch ID prompt")
        default:
            String(localized: "Touch ID or the password couldn’t be checked. Try again.", comment: "Alert text when Touch ID or the login password could not be checked for another reason")
        }
    }
}

extension RecorderModel {
    /// Asks for Touch ID or the password before opening "Meetings" (or before an action on their data).
    /// Once unlocked, activity in the window (`touchHistory`) keeps it open.
    func authorizeHistory(for purpose: HistoryPurpose = .show) async -> Bool {
        if unlock.isUnlocked(at: .now) {
            unlock.touch(at: .now)
            return true
        }
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel", comment: "Touch ID prompt button")
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
            return authenticationUnavailable(unavailable, purpose: purpose)
        }
        do {
            // The system shows it as "Vauta is trying to <reason>."
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: purpose.reason) else { return false }
            unlockHistory()
            return true
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return false
        } catch {
            showAlert(purpose.failureTitle, HistoryPurpose.failureMessage(for: error))
            return false
        }
    }

    /// No Touch ID and no password: without a login password nothing can
    /// protect the window, so say so and let the user decide.
    private func authenticationUnavailable(_ error: NSError?, purpose: HistoryPurpose) -> Bool {
        if let error, error.domain == LAError.errorDomain, error.code == LAError.Code.passcodeNotSet.rawValue {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Your Mac has no login password", comment: "Alert title")
            if purpose == .show {
                alert.informativeText = String(localized: "Vauta protects Meetings and Context with your login password or Touch ID. Without a password, anyone using this Mac can open them. You can set one in System Settings\u{00A0}→\u{00A0}Users & Groups.",
                                               comment: "Alert text when the Mac has no password")
            } else {
                alert.informativeText = String(localized: "Vauta asks for your login password or Touch ID before a backup, restore or erase. Without a password, anyone using this Mac can do these. You can set one in System Settings\u{00A0}→\u{00A0}Users & Groups.",
                                               comment: "Alert text when the Mac has no password and the action is a backup, restore or erase")
            }
            // The safe choice is the default (Return); going on unprotected is the second button, named for what it does.
            alert.addButton(withTitle: String(localized: "Open Users & Groups Settings", comment: "Alert button"))
            alert.addButton(withTitle: purpose == .show
                            ? String(localized: "Open Meetings", comment: "Alert button")
                            : String(localized: "Continue Without a Password", comment: "Alert button: go on with a backup, restore or erase although the Mac has no login password"))
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let url = URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
                return false
            case .alertSecondButtonReturn:
                unlockHistory()
                return true
            default:
                return false
            }
        }
        // The same plain words as a failed prompt; with no error at all, the Mac simply can't ask.
        showAlert(purpose.failureTitle,
                  error.map { HistoryPurpose.failureMessage(for: $0) } ?? String(localized: "Authentication isn’t available on this Mac.", comment: "Alert text"))
        return false
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private func unlockHistory() {
        unlock.unlock(at: .now)
        historyUnlocked = true
        scheduleRelock()
        brief.unlocked()
    }

    /// Activity in the meetings window: postpones the automatic lock.
    func touchHistory() {
        unlock.touch(at: .now)
    }

    /// Locks when the unlock window expires; activity moves the expiry, so the
    /// timer sleeps again until the new one.
    func scheduleRelock() {
        relockTimer?.cancel()
        guard unlock.expiresAt != nil else { return }
        relockTimer = Task { [weak self] in
            while let expires = self?.unlock.expiresAt {
                let wait = ContinuousClock.now.duration(to: expires)
                if wait <= .zero { break }
                do { try await Task.sleep(for: wait) } catch { return }
            }
            guard let self, self.historyUnlocked, !self.unlock.isUnlocked(at: .now) else { return }
            self.lockHistory()
        }
    }

    /// The relock preference changed: applies from now to an open window.
    func relockPolicyChanged() {
        unlock.setInterval(preferences.relockPolicy.interval, at: .now)
        if historyUnlocked { scheduleRelock() }
    }

    func lockHistory() {
        // Something the person was looking at is about to disappear: say why (VoiceOver, or someone who looked away).
        let hadOpenWindow = NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("meetings") == true && $0.isVisible }
        // Settings → Context empties when Meetings lock, too: someone editing there is told as well.
        let hadOpenContext = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix("settings") == true } && settingsModel?.pane == .context
        let hadOpenSheet = settingsModel.map { ($0.backup.sheet != nil) || $0.showErase || $0.pendingRetention != nil } ?? false
        let announce = historyUnlocked && (hadOpenWindow || hadOpenContext || hadOpenSheet)
        unlock.lock()
        historyUnlocked = false
        relockTimer?.cancel()
        relockTimer = nil
        showTranscript = false
        history?.purgeVisible()
        brief.locked()
        context?.saveUnsavedInBackground()
        context?.purge()
        // Back Up and Restore were opened behind Touch ID: an open sheet doesn't outlive the unlock (unless it is
        // working, which finishes).
        if let backup = settingsModel?.backup, backup.stage != .working { backup.reset() }
        if let settings = settingsModel, !settings.erasing {
            settings.showErase = false
            settings.pendingRetention = nil
        }
        if let dismissWindowAction {
            dismissWindowAction(id: "meetings")
        } else {
            for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("meetings") == true { window.close() }
        }
        if announce {
            AccessibilityNotification.Announcement(
                String(localized: "Meetings and context locked. Unlock them with Touch ID or your password.", comment: "VoiceOver announcement when the Meetings window closes, or Settings → Context empties, because Meetings were locked")).post()
        }
    }

    /// Screen lock, sleep and user switch lock "Meetings"; sleep and user
    /// switch also stop the recording (saving everything), and screen lock
    /// does when the preference says so. Display sleep only locks.
    func observeSystemEvents() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (RecorderModel) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }
            observers.append((center, token))
        }
        observe(distributed, .init("com.apple.screenIsLocked")) { model in
            model.lockHistory()
            if model.preferences.stopRecordingOnScreenLock { model.autoStop(.screenLocked) }
        }
        observe(workspace, NSWorkspace.willSleepNotification) { model in
            model.lockHistory()
            model.autoStop(.sleep)
            // macOS doesn't wait for the app: what was transcribed goes to
            // disk now, without waiting for the capture and endMeeting.
            let writes = model.writes
            Task { [store = model.store] in
                await writes?.value
                try? await store?.flush()
            }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { model in
            model.lockHistory()
            model.autoStop(.userSwitched)
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { model in model.lockHistory() }
        observe(distributed, .init("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged")) { model in
            model.keyboardLayoutRevision += 1
        }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { model in
            model.refreshLaunchAtLogin()
        }
    }
}
