// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreAudio
import Foundation
import Testing
@testable import VautaCore

/// A UserDefaults suite of its own, removed afterwards.
final class CaptureTestDefaults {
    let name = "vauta.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: name)! }
    deinit { defaults.removePersistentDomain(forName: name) }
}

private let ownPID: pid_t = 4242

private func process(_ id: AudioObjectID, _ bundleID: String, pid: pid_t? = nil, input: Bool = false, output: Bool = false) -> AudioProcess {
    AudioProcess(objectID: id, pid: pid ?? pid_t(1000 + id), bundleID: bundleID, isRunningOutput: output, isRunningInput: input)
}

@Suite("Capture: system audio scope")
struct CaptureScopeTests {
    /// The capture alert only speaks for a call the recording source includes: another app's call is the wrong-source case.
    @Test func aSourceCapturesTheCallsItIncludes() {
        #expect(SystemAudioScope.auto.capturesCall(of: .zoom))
        #expect(SystemAudioScope.allSystem.capturesCall(of: .zoom))
        #expect(SystemAudioScope.apps([.zoom]).capturesCall(of: .zoom))
        #expect(!SystemAudioScope.apps([.webkit]).capturesCall(of: .zoom))
        #expect(SystemAudioScope.apps([.webkit]).capturesCall(of: nil))
    }

    @Test func legacyPreferenceMapsToTheSameCapture() {
        #expect(SystemAudioScope.legacy(captureAllSystemAudio: false) == .apps([.webkit]))
        #expect(SystemAudioScope.legacy(captureAllSystemAudio: true) == .allSystem)
        #expect(SystemAudioScope.legacyDefault == .apps([.webkit]))
    }

    @Test func freshInstallReadsAsSafariOnly() {
        let temp = CaptureTestDefaults()
        #expect(SystemAudioScope(defaults: temp.defaults) == .apps([.webkit]))
    }

    @Test func newInstallStartsOnAutoButAnUpgradeKeepsSafari() {
        let temp = CaptureTestDefaults()
        #expect(SystemAudioScope(defaults: temp.defaults, newInstall: true) == .auto)
        #expect(SystemAudioScope(defaults: temp.defaults, newInstall: false) == .apps([.webkit]))
        temp.defaults.set(false, forKey: "captureAllSystemAudio")
        #expect(SystemAudioScope(defaults: temp.defaults, newInstall: true) == .apps([.webkit]))
        SystemAudioScope.allSystem.save(to: temp.defaults)
        #expect(SystemAudioScope(defaults: temp.defaults, newInstall: true) == .allSystem)
    }

    @Test func legacyDefaultsKeyIsHonoured() {
        let temp = CaptureTestDefaults()
        temp.defaults.set(true, forKey: "captureAllSystemAudio")
        #expect(SystemAudioScope(defaults: temp.defaults) == .allSystem)
        temp.defaults.set(false, forKey: "captureAllSystemAudio")
        #expect(SystemAudioScope(defaults: temp.defaults) == .apps([.webkit]))
    }

    @Test func savedScopeWinsAndKeepsTheLegacyKeyMeaningful() {
        let temp = CaptureTestDefaults()
        temp.defaults.set(true, forKey: "captureAllSystemAudio")
        SystemAudioScope.apps([.zoom, .chromium]).save(to: temp.defaults)
        #expect(SystemAudioScope(defaults: temp.defaults) == .apps([.zoom, .chromium]))
        #expect(temp.defaults.bool(forKey: "captureAllSystemAudio") == false)
        SystemAudioScope.allSystem.save(to: temp.defaults)
        #expect(temp.defaults.bool(forKey: "captureAllSystemAudio") == true)
        #expect(SystemAudioScope(defaults: temp.defaults) == .allSystem)
    }

    @Test func unreadableSavedValueFallsBackToLegacy() {
        let temp = CaptureTestDefaults()
        temp.defaults.set("apps:nonexistent", forKey: "systemAudioScope")
        temp.defaults.set(true, forKey: "captureAllSystemAudio")
        #expect(SystemAudioScope(defaults: temp.defaults) == .allSystem)
    }

    @Test(arguments: [SystemAudioScope.auto, .allSystem, .apps([.webkit]), .apps([.firefox, .chromium, .teams])])
    func storageValueRoundTrips(scope: SystemAudioScope) {
        #expect(SystemAudioScope(storageValue: scope.storageValue) == scope)
    }

    @Test func storageValuesAreStable() {
        #expect(SystemAudioScope.auto.storageValue == "auto")
        #expect(SystemAudioScope.allSystem.storageValue == "all")
        #expect(SystemAudioScope.apps([.zoom, .chromium]).storageValue == "apps:chromium,zoom")
        #expect(SystemAudioScope(storageValue: "apps:") == nil)
        #expect(SystemAudioScope(storageValue: "safari") == nil)
    }

    @Test func autoFollowsTheAppHoldingTheMicrophone() {
        let zoom = PresenceState(processes: [process(1, "us.zoom.xos", input: true)], ownPID: ownPID)
        #expect(SystemAudioScope.auto.resolved(with: zoom) == .apps([.zoom]))
        #expect(SystemAudioScope.auto.resolved(with: .idle) == .allSystem)
        #expect(SystemAudioScope.auto.resolved(with: nil) == .allSystem)
        #expect(SystemAudioScope.apps([.slack]).resolved(with: zoom) == .apps([.slack]))
    }

    @Test func legacyScopeTapsExactlyTheLegacyBundleIDsWhenOnlySafariRuns() {
        let processes = [
            process(10, "com.apple.Safari"), process(11, "com.apple.WebKit.GPU", output: true),
            process(12, "com.apple.WebKit.WebContent"), process(13, "com.apple.Music", output: true),
        ]
        let target = SystemAudioScope.legacyDefault.tapTarget(processes: processes, ownPID: ownPID)
        #expect(target == TapTarget(bundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"],
                                    processes: [], excludes: false))
    }

    @Test func appScopeAddsRunningHelpersByObjectID() {
        let processes = [
            process(20, "com.google.Chrome"), process(21, "com.google.Chrome.helper", input: true, output: true),
            process(22, "com.google.Chrome.helper.renderer"), process(23, "com.google.Chrome.app.meetpwa"),
            process(24, "us.zoom.xos"), process(25, "com.spotify.client", output: true),
        ]
        let target = SystemAudioScope.apps([.chromium]).tapTarget(processes: processes, ownPID: ownPID)
        #expect(!target.excludes)
        #expect(target.bundleIDs.contains("com.google.Chrome"))
        #expect(target.bundleIDs.contains("com.google.Chrome.helper"))
        // Main app and audio helper are covered by bundle ID; the rest by object ID.
        #expect(target.processes == [22, 23])
    }

    @Test func appScopeNeverIncludesVauta() {
        let processes = [process(30, "com.apple.WebKit.GPU"), process(31, "com.apple.Safari.WebApp.ABC", pid: ownPID)]
        #expect(SystemAudioScope.apps([.webkit]).tapTarget(processes: processes, ownPID: ownPID).processes.isEmpty)
    }

    @Test func allSystemExcludesOnlyVauta() {
        let processes = [process(40, "local.vauta.app", pid: ownPID), process(41, "com.apple.Music", output: true)]
        #expect(SystemAudioScope.allSystem.tapTarget(processes: processes, ownPID: ownPID)
                == TapTarget(bundleIDs: [], processes: [40], excludes: true))
        // Before Vauta opens any audio it has no process object: nothing to exclude yet.
        #expect(SystemAudioScope.allSystem.tapTarget(processes: [processes[1]], ownPID: ownPID).processes.isEmpty)
    }

    @Test func autoScopeResolvesFromTheProcessSnapshot() {
        let teams = [process(50, "com.microsoft.teams2", input: true, output: true), process(51, "local.vauta.app", pid: ownPID, input: true)]
        let target = SystemAudioScope.auto.tapTarget(processes: teams, ownPID: ownPID)
        #expect(!target.excludes)
        #expect(target.bundleIDs.contains("com.microsoft.teams2"))
        // Only Vauta holds the microphone: everything except Vauta.
        let alone = SystemAudioScope.auto.tapTarget(processes: [teams[1]], ownPID: ownPID)
        #expect(alone == TapTarget(bundleIDs: [], processes: [51], excludes: true))
    }
}

@Suite("Capture: presence")
struct CapturePresenceTests {
    @Test func ignoresVautaItself() {
        let state = PresenceState(processes: [process(1, "local.vauta.app", pid: ownPID, input: true, output: true)], ownPID: ownPID)
        #expect(state == .idle)
    }

    @Test func reportsTheFamilyAndHelperHoldingTheMicrophone() {
        let state = PresenceState(processes: [
            process(1, "com.google.Chrome"), process(2, "com.google.Chrome.helper", input: true, output: true),
        ], ownPID: ownPID)
        #expect(state.family == .chromium)
        #expect(state.bundleID == "com.google.Chrome.helper")
        #expect(state.inputActive)
        #expect(state.outputActive)
        #expect(state.isInputActive(.chromium))
        #expect(!state.isInputActive(.webkit))
    }

    @Test func outputIsJudgedPerFamily() {
        // Firefox records in the parent process and may play from a content process.
        let state = PresenceState(processes: [
            process(1, "org.mozilla.firefox", input: true), process(2, "org.mozilla.plugincontainer", output: true),
        ], ownPID: ownPID)
        #expect(state.family == .firefox)
        #expect(state.outputActive)
    }

    @Test func knownAppsWinOverUnknownOnes() {
        let state = PresenceState(processes: [
            process(1, "com.example.recorder", input: true, output: true), process(2, "us.zoom.xos", input: true),
        ], ownPID: ownPID)
        #expect(state.family == .zoom)
        #expect(state.inputFamilies == [.zoom])
    }

    @Test func aFamilyThatIsPlayingWinsOverOneThatOnlyRecords() {
        let state = PresenceState(processes: [
            process(1, "com.apple.WebKit.GPU", input: true), process(2, "us.zoom.xos", input: true, output: true),
        ], ownPID: ownPID)
        #expect(state.family == .zoom)
        #expect(state.inputFamilies == [.webkit, .zoom])
        #expect(state.isInputActive(.webkit))
    }

    @Test func unknownAppHoldingTheMicrophone() {
        let state = PresenceState(processes: [process(1, "", input: true)], ownPID: ownPID)
        #expect(state.family == nil)
        #expect(state.bundleID == nil)
        #expect(state.inputActive)
    }

    @Test func outputAloneIsNotACall() {
        let state = PresenceState(processes: [process(1, "com.apple.WebKit.GPU", output: true)], ownPID: ownPID)
        #expect(!state.inputActive)
        #expect(state.family == nil)
        #expect(state.inputFamilies.isEmpty)
    }

    @Test func debounce() {
        let call = PresenceState(processes: [process(1, "us.zoom.xos", input: true)], ownPID: ownPID)
        #expect(PresenceState.publishDelay(current: nil, new: .idle) == 0)
        #expect(PresenceState.publishDelay(current: .idle, new: .idle) == nil)
        #expect(PresenceState.publishDelay(current: .idle, new: call) == 2)
        #expect(PresenceState.publishDelay(current: call, new: .idle) == 2)
        #expect(PresenceState.publishDelay(current: call, new: call) == nil)
    }
}
