// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation

/// Settings → General → Updates: whether a newer release exists (`UpdateChecker`, once a day while the switch is on, and on Check
/// Now) and Update…, which starts `scripts/update.sh` in Terminal through the launcher `install.sh` wrote (`UpdateRunner`).
@MainActor
@Observable
final class UpdateModel {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(ReleaseVersion)
        case available(ReleaseVersion)
        case failed(UpdateCheckError)
        /// This build has no release number (a development build): there is nothing to compare.
        case noVersion
    }

    /// What the last Update… did.
    enum Launch: Equatable {
        case none
        /// The update is running in Terminal.
        case started
        /// A recording is in progress, or ending: nothing was started.
        case recording
        /// No launcher (an install from before it, or not made with install.sh): the command was copied instead.
        case copiedCommand
        /// The launcher is not exactly what install.sh writes for this app: nothing was run.
        case invalidLauncher
        /// Terminal couldn't be opened.
        case failed
    }

    /// How often the automatic check runs, and how long after launch the first one waits (so it never slows the start).
    static let interval: TimeInterval = 24 * 3600
    static let firstDelay: TimeInterval = 60

    /// Defaults to on (the person can turn it off). Off, Vauta never asks GitHub on its own.
    var checksAutomatically: Bool {
        didSet {
            defaults.set(checksAutomatically, forKey: Keys.automatic)
            reschedule()
        }
    }
    private(set) var state: State = .idle
    private(set) var lastChecked: Date?
    private(set) var launch: Launch = .none
    let installed = ReleaseVersion.running

    /// For the recording guard and the notification.
    @ObservationIgnored weak var recorder: RecorderModel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let checker: UpdateChecker
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, checker: UpdateChecker = UpdateChecker()) {
        self.defaults = defaults
        self.checker = checker
        checksAutomatically = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        // A release found earlier stays offered after a relaunch, until a check says otherwise (or it is installed).
        if let installed, let known = defaults.string(forKey: Keys.latestKnown).flatMap({ ReleaseVersion($0) }), known > installed {
            state = .available(known)
        } else if installed == nil {
            state = .noVersion
        }
    }

    var availableVersion: ReleaseVersion? {
        if case .available(let version) = state { version } else { nil }
    }

    /// Starts the daily check (after launch).
    func start() { reschedule() }

    func checkNow() {
        // One check at a time, the automatic one included.
        guard running == nil, state != .checking else { return }
        launch = .none
        running = Task { [weak self] in
            await self?.check(automatic: false)
            self?.running = nil
        }
    }

    private func reschedule() {
        schedule?.cancel()
        schedule = nil
        guard checksAutomatically, installed != nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // A last check "in the future" (a clock set ahead, then corrected) counts as now, so the check is never put off for long.
                let due = min(lastChecked ?? .distantPast, .now).addingTimeInterval(Self.interval).timeIntervalSinceNow
                let wait = max(Self.firstDelay, due)
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                if running == nil, state != .checking { await check(automatic: true) }
            }
        }
    }

    private func check(automatic: Bool) async {
        guard let installed else { state = .noVersion; return }
        // What to go back to if the check gives no answer (never "checking" itself).
        let before: State = state == .checking ? .idle : state
        state = .checking
        do {
            let result = try await checker.check(installed: installed)
            record(.now)
            if result.isUpdateAvailable {
                state = .available(result.latest)
                defaults.set(result.latest.description, forKey: Keys.latestKnown)
                // Once per version, and only from the automatic check (Check Now shows it right here).
                if automatic, defaults.string(forKey: Keys.notifiedVersion) != result.latest.description {
                    defaults.set(result.latest.description, forKey: Keys.notifiedVersion)
                    recorder?.post(.updateAvailable(result.latest))
                }
            } else {
                state = .upToDate(installed)
                defaults.removeObject(forKey: Keys.latestKnown)
            }
        } catch let error as UpdateCheckError {
            // A failed automatic check waits for the next day like a successful one: GitHub is never asked in a loop.
            if automatic { record(.now) }
            // A release already found stays offered: one failed check doesn't hide it.
            if case .available = before { state = before } else { state = .failed(error) }
        } catch {
            state = before
        }
    }

    private func record(_ date: Date) {
        lastChecked = date
        defaults.set(date, forKey: Keys.lastChecked)
    }

    /// Update…: never during a recording; the launcher if it passes every check, else the command to paste.
    func update() {
        // A click while Terminal is being opened, or right after, opens nothing more (update.sh also takes a lock in the checkout).
        guard !launching else { return }
        if launch == .started, let startedAt, Date.now.timeIntervalSince(startedAt) < Self.relaunchPause { return }
        if let recorder, [.recording, .stopping, .starting].contains(recorder.phase) {
            launch = .recording
            return
        }
        switch UpdateRunner.prepare() {
        case .success(let ready):
            launching = true
            Task {
                defer { launching = false }
                do {
                    try await UpdateRunner.run(ready)
                    launch = .started
                    startedAt = .now
                } catch let problem as UpdateLauncher.Problem {
                    launch = problem == .missing ? .copiedCommand : .invalidLauncher
                } catch {
                    launch = .failed
                }
            }
        case .failure(.missing):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.manualCommand, forType: .string)
            launch = .copiedCommand
        case .failure(.invalid):
            launch = .invalidLauncher
        }
    }

    /// How long after Update… opened Terminal another click does nothing.
    static let relaunchPause: TimeInterval = 120
    @ObservationIgnored private var launching = false
    @ObservationIgnored private var startedAt: Date?

    /// What to paste in Terminal, in the folder Vauta was built from, when there is no launcher.
    static let manualCommand = "./scripts/update.sh"

    private enum Keys {
        static let automatic = "updates.checkAutomatically"
        static let lastChecked = "updates.lastChecked"
        static let latestKnown = "updates.latestKnown"
        static let notifiedVersion = "updates.notifiedVersion"
    }
}
