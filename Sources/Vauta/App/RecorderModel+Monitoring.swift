// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit

/// Meters, the silence warning, the automatic stop, autosave and retention.
extension RecorderModel {
    /// Stops after `autoStopMinutes` without audio on "Others" (the meeting
    /// ended), provided "Me" has also been quiet for `autoStopMeQuiet`:
    /// meeting apps don't echo your own voice into "Others", so presenting
    /// doesn't trigger it.
    var autoStopAfterSilence: TimeInterval { TimeInterval(autoStopMinutes * 60) }
    static let autoStopMeQuiet: TimeInterval = 2 * 60
    /// The warning comes at 80 % of both thresholds.
    static let autoStopWarnFraction = 0.8
    /// Below this level "Others" counts as silent.
    static let othersSilenceDBFS = -65.0
    /// Above this level "Me" counts as speaking.
    static let meHeardDBFS = -50.0
    /// "Others" silent this long while "Me" is heard: probably the wrong source.
    static let silenceWarningAfter: TimeInterval = 15

    /// Stops like the Stop button (everything is saved), with a sound and a notification.
    func autoStop(_ reason: RecordingStopReason) {
        switch phase {
        case .starting:
            stopRequested = true
        case .recording:
            stop()
        default:
            return
        }
        lastStopReason = reason
        NSSound(named: "Funk")?.play()
        post(.recordingStopped(reason, meetingID: meetingID))
    }

    /// Meters (~7 Hz) and the clock. Never waits for I/O.
    func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func tick() {
        guard let capture else { return }
        let mono = ContinuousClock.now
        let db = capture.drainLevels()
        if !db.isEmpty {
            var next = levels
            for (k, v) in db { next[k] = max(0, min(1, (v + 60) / 60)) }
            if next.keys != levels.keys || next.contains(where: { abs($0.value - (levels[$0.key] ?? 0)) > 0.02 }) {
                levels = next
            }
            if let o = db[.others], o > Self.othersSilenceDBFS { lastOthersHeard = mono }
            if let m = db[.me], m > Self.meHeardDBFS { lastMeHeard = mono }
        }
        func quiet(since last: ContinuousClock.Instant?, for seconds: TimeInterval) -> Bool {
            last.map { mono - $0 >= .seconds(seconds) } ?? true
        }
        // Wrong-source safeguard: warn, never switch to all system audio by itself.
        let othersSilent = quiet(since: lastOthersHeard, for: Self.silenceWarningAfter) && !quiet(since: lastMeHeard, for: Self.silenceWarningAfter)
        let warning = othersSilent ? silenceMessage : nil
        if warning != silenceWarning { silenceWarning = warning }
        updateCaptureAlert(now: mono)
        if phase == .recording && quiet(since: lastOthersHeard, for: autoStopAfterSilence)
            && quiet(since: lastMeHeard, for: Self.autoStopMeQuiet) {
            autoStop(.silence(minutes: autoStopMinutes))
            return
        }
        // Advance warning: countdown in the panel and the menu bar, plus a notification.
        let f = Self.autoStopWarnFraction
        if phase == .recording && quiet(since: lastOthersHeard, for: autoStopAfterSilence * f)
            && quiet(since: lastMeHeard, for: Self.autoStopMeQuiet * f) {
            if pendingAutoStopAt == nil {
                func left(_ last: ContinuousClock.Instant?, _ limit: TimeInterval) -> TimeInterval {
                    guard let last else { return 0 }
                    let gone = mono - last
                    return max(0, limit - Double(gone.components.seconds))
                }
                let remaining = max(left(lastOthersHeard, autoStopAfterSilence), left(lastMeHeard, Self.autoStopMeQuiet))
                pendingAutoStopAt = .now + remaining
                post(.autoStopWarning(secondsLeft: Int(remaining.rounded())))
            }
        } else if pendingAutoStopAt != nil {
            pendingAutoStopAt = nil
            notifier.remove(.autoStopWarning)
        }
        let left = pendingAutoStopAt.map { max(0, Int($0.timeIntervalSinceNow.rounded(.up))) }
        if left != autoStopRemaining { autoStopRemaining = left }
        if let startedAt {
            let s = Int(AppClock.now.timeIntervalSince(startedAt))
            if s != elapsedSeconds { elapsedSeconds = s }
        }
    }

    /// A meeting app has held the microphone for a minute and nothing has reached "Others": explain, once per silent
    /// stretch. It goes away by itself when sound really returns (not for one chime); the user can also dismiss it.
    private func updateCaptureAlert(now mono: ContinuousClock.Instant) {
        guard phase == .recording else { return }
        let silentFor = lastOthersHeard.map { Self.monotonicSeconds(mono) - Self.monotonicSeconds($0) } ?? OthersSilenceDetector.silenceThreshold
        // Only a call app the recording source includes: when the source is another app, Vauta is not capturing the call at
        // all, and the silence banner (which names the recorded source) is the right advice, not this alert.
        let raise = silenceDetector.observe(now: Self.monotonicSeconds(mono),
                                            appHoldsMicrophone: callInProgress && sourceIncludesCallApp,
                                            othersSilentFor: silentFor)
        if captureAlert != nil, !silenceDetector.coversCurrentSilence { captureAlert = nil }
        if raise {
            let notice = captureAlertMessage
            captureAlert = notice
            // VoiceOver is not looking at the panel while a call is on: say it, in the words the card shows.
            // Only when the panel shows the card: it is hidden while a channel warning already explains why Others is silent.
            if channelWarnings[.others] == nil {
                AccessibilityNotification.Announcement("\(notice.title.withoutTerminalPunctuation). \(notice.detail)").post()
            }
        }
        if silenceDetector.coversCurrentSilence != captureAlertCoversSilence {
            captureAlertCoversSilence = silenceDetector.coversCurrentSilence
        }
    }

    /// Whether what is being recorded includes the app that is in the call: always for Auto and All system audio, and for
    /// specific apps only when the call app is one of them (an unknown call app counts as included).
    var sourceIncludesCallApp: Bool {
        recordingSource?.capturesCall(of: callApp ?? currentCall?.family) ?? true
    }

    private static let clockOrigin = ContinuousClock.now

    private static func monotonicSeconds(_ instant: ContinuousClock.Instant) -> TimeInterval {
        let c = (instant - clockOrigin).components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// What is wrong and what to check when a meeting app is in a call but "Others" stays silent.
    var captureAlertMessage: SilenceNotice {
        let channel = Channel.others.displayName
        if let name = currentCall?.appName ?? callApp?.shortName ?? recordingApp?.appName {
            return SilenceNotice(
                title: String(localized: "\(name) is in a call, but Vauta hears nothing from it",
                              comment: "Panel alert title: a meeting app uses the microphone but no sound reaches Others; the argument is an app name such as Zoom"),
                detail: String(localized: "Nothing has come through on “\(channel)” for a minute. Check that \(name) isn’t muted, that its sound plays through this Mac, and that Vauta is allowed to record system audio.",
                               comment: "Panel alert: what to check; the first argument is the channel name (Others), the second an app name such as Zoom"))
        }
        return SilenceNotice(
            title: String(localized: "A meeting app is in a call, but Vauta hears nothing from it",
                          comment: "Panel alert title: a meeting app uses the microphone but no sound reaches Others"),
            detail: String(localized: "Nothing has come through on “\(channel)” for a minute. Check that the meeting app isn’t muted, that its sound plays through this Mac, and that Vauta is allowed to record system audio.",
                           comment: "Panel alert: what to check; the argument is the channel name (Others)"))
    }

    /// "Others" is silent while "Me" is heard: name the source being captured. The title says what is wrong, the detail
    /// what to check.
    var silenceMessage: SilenceNotice {
        switch recordingSource {
        case .allSystem, nil:
            SilenceNotice(title: String(localized: "No audio is coming through on “\(Channel.others.displayName)”",
                                        comment: "Silence warning title; the argument is the channel name (Others)"),
                          detail: String(localized: "Is the meeting’s sound on?", comment: "Silence warning: what to check"))
        case .apps(let families):
            if let name = recordingApp?.appName ?? (families.count == 1 ? families.first?.shortName : nil) {
                SilenceNotice(title: String(localized: "No audio is coming from \(name)",
                                            comment: "Silence warning title; the argument is an app name such as Zoom"),
                              detail: String(localized: "Is the meeting in \(name), with its sound on?",
                                             comment: "Silence warning: what to check; the argument is an app name such as Zoom"))
            } else {
                SilenceNotice(title: String(localized: "No audio is coming from the selected apps", comment: "Silence warning title"),
                              detail: String(localized: "Is the meeting in one of them, with its sound on?", comment: "Silence warning: what to check"))
            }
        case .auto:
            if let name = recordingApp?.appName {
                SilenceNotice(title: String(localized: "No audio is coming from \(name)",
                                            comment: "Silence warning title; the argument is an app name such as Zoom"),
                              detail: String(localized: "Is the meeting in \(name), with its sound on?",
                                             comment: "Silence warning: what to check; the argument is an app name such as Zoom"))
            } else {
                SilenceNotice(title: String(localized: "No audio is coming from the meeting app", comment: "Silence warning title"),
                              detail: String(localized: "Is its sound on?", comment: "Silence warning: what to check; “its” is the meeting app"))
            }
        }
    }

    /// An encrypted save every 10 s: only what is new is appended to the
    /// journal (a few KB), in its own task so the meters never freeze.
    func startAutosave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            var interval = Duration.seconds(10)
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, let store = self.store else { return }
                await self.writes?.value
                do {
                    try await store.saveIfNeeded()
                    if self.saveError != nil { self.saveError = nil }
                    interval = .seconds(10)
                } catch {
                    self.saveError = self.saveFailure(String(localized: "The meeting couldn’t be saved to disk. Vauta will keep trying.",
                                                             comment: "Warning while recording"), error)
                    interval = .seconds(5)
                }
            }
        }
    }

    // MARK: Retention

    /// Retention runs when the store opens and then once a day.
    func startRetention() {
        retention?.cancel()
        retention = Task { [weak self] in
            // A recording that was recorded with "Keep detected questions" off and quit before its own cleanup ran. Meetings recorded with
            // the setting on are not listed, so their questions stay whatever the setting is now.
            if let self, let store = self.store { await self.preferences.questionCleanup.sweep(store, active: self.phase == .recording ? self.meetingID : nil) }
            while true {
                do { try await Task.sleep(for: .seconds(86_400)) } catch { return }
                guard let self, let store = self.store else { return }
                await self.maintainVoices()
                do {
                    // Before the text is lost (85–90 days), the model writes the minutes.
                    for id in (try? await store.meetingsNeedingDistill()) ?? [] { await self.llm?.regenerateMinutes(id) }
                    if try await store.purgeExpired() > 0 {
                        await self.llm?.forgetPastTranscripts()
                        await self.history?.reloadIfShowing()
                    }
                } catch {
                    self.lastError = String(localized: "Meetings older than \(MeetingStore.retentionDays) days couldn’t be deleted. \(error.localizedDescription)",
                                            comment: "Retention error; the first argument is a number of days, the second the error")
                }
            }
        }
    }
}
