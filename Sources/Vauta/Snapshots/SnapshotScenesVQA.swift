// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import ServiceManagement
import LocalAuthentication
import SwiftUI

// States found missing by the coverage review: alerts, panel and Settings states, setup states, the accessibility settings
// (Increase Contrast, Reduce Transparency, VoiceOver), and the words of the system's open and save panels.

extension SnapshotScenes {
    static var vqa: [SnapshotScene] { vqaMenus + vqaDialogs + vqaPanel + vqaSettings + vqaOnboarding + vqaAccessibility + vqaFilePanels }

    // MARK: Alerts

    private static func vqaDialog(_ name: String, title: String, message: String, buttons: [SnapshotAlert.Button], warning: Bool = false, defaultIndex: Int = 0) -> SnapshotScene {
        SnapshotScene(name: "dialog-\(name)", size: CGSize(width: 260, height: 160), isSheet: true) { _ in
            .init(view: AnyView(EmptyView()), alert: SnapshotAlert(title: title, message: message, buttons: buttons, warning: warning, defaultIndex: defaultIndex))
        }
    }

    private static var vqaCancel: SnapshotAlert.Button { .init(title: String(localized: "Cancel", comment: "Alert button")) }
    private static var vqaOK: SnapshotAlert.Button { .init(title: String(localized: "OK", comment: "Alert button")) }

    /// The alert of the Meetings window, with the buttons SwiftUI gives it (the recovery, then Cancel; just OK without one).
    private static func vqaMeetingsAlert(_ name: String, _ alert: MeetingsAlert) -> SnapshotScene {
        switch alert.recovery {
        case .openSettings(let pane)?: vqaDialog(name, title: alert.title, message: alert.message, buttons: [.init(title: pane.openTitle), vqaCancel])
        case .retry?: vqaDialog(name, title: alert.title, message: alert.message, buttons: [.init(title: String(localized: "Try Again", comment: "Alert button")), vqaCancel])
        case nil: vqaDialog(name, title: alert.title, message: alert.message, buttons: [vqaOK])
        }
    }

    private static func vqaContextFailure(_ name: String, _ operation: ContextOperation, _ error: Error) -> SnapshotScene {
        let failure = ContextFailure(error, during: operation)
        return vqaDialog("context-failure-\(name)", title: failure.title,
                         message: [failure.message, failure.recovery].compactMap { $0 }.joined(separator: "\n\n"), buttons: [vqaOK])
    }

    private static var vqaDialogs: [SnapshotScene] {
        let disk = CocoaError(.fileWriteOutOfSpace)
        let reasons: [(String, HistoryPurpose)] = [("show", .show), ("back-up", .backUp), ("restore", .restore), ("erase", .erase), ("delete-older", .deleteOlder)]
        let infoKeys: [(String, String)] = [("microphone", "NSMicrophoneUsageDescription"), ("audio-capture", "NSAudioCaptureUsageDescription"),
                                            ("calendar", "NSCalendarsFullAccessUsageDescription"), ("reminders", "NSRemindersFullAccessUsageDescription"),
                                            ("local-network", "NSLocalNetworkUsageDescription")]
        return [
            // Unlocking Meetings or confirming a protected action failed.
            vqaDialog("unlock-failed", title: HistoryPurpose.show.failureTitle, message: HistoryPurpose.failureMessage(for: LAError(.authenticationFailed)), buttons: [vqaOK]),
            vqaDialog("confirm-failed", title: HistoryPurpose.backUp.failureTitle, message: HistoryPurpose.failureMessage(for: LAError(.biometryLockout)), buttons: [vqaOK]),
            // One scene for each of the other plain messages.
            vqaDialog("confirm-failed-biometry-unavailable", title: HistoryPurpose.erase.failureTitle, message: HistoryPurpose.failureMessage(for: LAError(.biometryNotAvailable)), buttons: [vqaOK]),
            vqaDialog("confirm-failed-not-interactive", title: HistoryPurpose.restore.failureTitle, message: HistoryPurpose.failureMessage(for: LAError(.notInteractive)), buttons: [vqaOK]),
            vqaDialog("confirm-failed-other", title: HistoryPurpose.deleteOlder.failureTitle, message: HistoryPurpose.failureMessage(for: LAError(.invalidContext)), buttons: [vqaOK]),
            vqaDialog("auth-unavailable", title: HistoryPurpose.show.failureTitle,
                      message: String(localized: "Authentication isn’t available on this Mac.", comment: "Alert text"), buttons: [vqaOK]),
            vqaDialog("auth-unavailable-protected", title: HistoryPurpose.erase.failureTitle,
                      message: String(localized: "Authentication isn’t available on this Mac.", comment: "Alert text"), buttons: [vqaOK]),
            // The Meetings window's other alerts.
            vqaMeetingsAlert("save-changes-failed", MeetingsAlert(String(localized: "Couldn’t save your changes", comment: "Alert title"), error: disk, recovery: .retry {})),
            vqaMeetingsAlert("link-save-failed", MeetingsAlert(String(localized: "Couldn’t save the link", comment: "Alert title"), error: disk)),
            vqaMeetingsAlert("task-delete-failed", MeetingsAlert(String(localized: "Couldn’t delete the task", comment: "Alert title"), error: disk)),
            vqaMeetingsAlert("erase-recording", MeetingsAlert(title: String(localized: "A meeting is being recorded", comment: "Alert title"),
                                                             message: String(localized: "Stop the recording before erasing all meetings.", comment: "Alert message"))),
            vqaMeetingsAlert("erase-key-failed", MeetingsAlert(title: String(localized: "All meetings were erased", comment: "Alert title"),
                                                              message: String(localized: "But the new encryption key couldn’t be created in the Keychain, so Vauta can’t record until it has one. Unlock the Keychain and restart Vauta.",
                                                                              comment: "Alert message after erasing when the Keychain refused the new key"))),
            vqaMeetingsAlert("erase-failed", MeetingsAlert(String(localized: "Couldn’t erase all meetings", comment: "Alert title"), error: disk)),
        ]
        // The Touch ID prompt: macOS writes "Vauta is trying to …" and Vauta supplies the end.
        + reasons.map { name, purpose in
            SnapshotScene(name: "dialog-touch-id-\(name)", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
                .init(view: AnyView(EmptyView()), alert: SnapshotAlert(
                    title: SystemWords.touchIDTitle(fixture.language, reason: purpose.reason), message: SystemWords.touchIDMessage(fixture.language),
                    buttons: [.init(title: SystemWords.usePassword(fixture.language)), .init(title: String(localized: "Cancel", comment: "Touch ID prompt button"))],
                    symbol: "touchid"))
            }
        }
        // The permission prompts: macOS writes the question and Vauta supplies the explanation (InfoPlist.strings).
        + infoKeys.map { name, key in
            SnapshotScene(name: "dialog-permission-\(name)", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
                let kind = SystemWords.Permission(rawValue: name) ?? .microphone
                let buttons = SystemWords.permissionButtons(fixture.language, kind)
                return .init(view: AnyView(EmptyView()), alert: SnapshotAlert(
                    title: SystemWords.permissionTitle(fixture.language, kind), message: Bundle.main.localizedString(forKey: key, value: key, table: "InfoPlist"),
                    buttons: [.init(title: buttons.allow), .init(title: buttons.refuse)]))
            }
        }
        // Settings → Context: the operations whose failure had no alert in the review.
        + [
            // Each failure gets the cause it really has: a read error to load, "no longer exists" to delete or remove, a full disk to write.
            vqaContextFailure("load", .load, CocoaError(.fileReadCorruptFile)),
            vqaContextFailure("delete", .deleteEntity, KnowledgeError.entityGone),
            vqaContextFailure("dismiss", .dismiss, KnowledgeError.suggestionGone),
            vqaContextFailure("confirm", .confirm, KnowledgeError.suggestionGone),
            vqaContextFailure("merge", .merge, KnowledgeError.entityGone),
            vqaContextFailure("add-relation", .addRelation, disk),
            vqaContextFailure("remove-relation", .removeRelation, KnowledgeError.entityGone),
            vqaContextFailure("save-term", .saveTerm, disk),
            vqaContextFailure("delete-term", .deleteTerm, disk),
            vqaContextFailure("save-series", .saveSeries, disk),
            vqaContextFailure("delete-series", .deleteSeries, disk),
            vqaContextFailure("reanalyze", .reanalyze, disk),
        ]
    }

    // MARK: Panel

    private static var vqaPanel: [SnapshotScene] {
        [
            // An automatic stop that was not silence: the sentence the banner shows.
            panelScene("stop-sleep") { recorder, _ in recorder.lastStopReason = .sleep },
            panelScene("stop-screen-locked") { recorder, _ in recorder.lastStopReason = .screenLocked },
            panelScene("stop-user-switched") { recorder, _ in recorder.lastStopReason = .userSwitched },
            panelScene("stop-silence") { recorder, _ in recorder.lastStopReason = .silence(minutes: 10) },
            // Launch at login needs the user's approval in System Settings.
            panelScene("login-items-approval") { recorder, _ in
                SnapshotMode.loginItem = .requiresApproval
                recorder.launchAtLoginStatus = .requiresApproval
            },
            // The meeting app let go of the microphone and Vauta doesn't know which app it was.
            panelScene("hangup-no-app") { recorder, fixture in
                recording(recorder, fixture)
                recorder.recordingApp = nil
                recorder.hangupNotice = true
            },
            // The consent notice read to the end ("Show Full Notice" pressed).
            panelScene("consent-full-notice") { recorder, fixture in
                recording(recorder, fixture)
                SnapshotMode.consentExpanded = true
                recorder.consentPrompt = ConsentPrompt(ConsentNotice.resolve(meetingLocale: fixture.language, recognizesVoices: true))
            },
        ]
    }

    // MARK: Settings

    private static var vqaSettings: [SnapshotScene] {
        let size = CGSize(width: 1020, height: 1150)
        let note = String(localized: "Couldn’t save the server settings.", comment: "Settings → Models apply error")
        return [
            settingsScene("general-icon-hidden", .general) { _, fixture in fixture.settings.menuBarIconMayBeHidden = true },
            settingsScene("general-login-items-approval", .general) { _, _ in SnapshotMode.loginItem = .requiresApproval },
            settingsScene("general-notifications-denied", .general, size: CGSize(width: 1020, height: 820)) { _, _ in SnapshotMode.notifications = .denied },
            settingsScene("general-notifications-not-asked", .general, size: CGSize(width: 1020, height: 820)) { _, _ in SnapshotMode.notifications = .notDetermined },
            settingsScene("general-translation-shortcut-taken", .general) { recorder, _ in recorder.translationHotKeyAvailable = false },
            settingsScene("general-note-shortcut-taken", .general) { recorder, fixture in
                recording(recorder, fixture)
                recorder.noteHotKeyAvailable = false
            },
            settingsScene("translation-voiceover", .translation, size: CGSize(width: 1020, height: 700)) { recorder, fixture in
                SnapshotMode.voiceOver = true
                fixture.preferences.translationRefinementEnabled = true
                fixture.preferences.translationModel = ""
                fixture.installTranslationSettings(on: recorder.liveTranslation)
            },
            // The Keychain is locked: the saved server can't be read, so Save is off.
            settingsScene("models-keychain-locked", .models, size: size) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: SampleWorld.discoveredServers())
                recorder.serverConfigUnavailable = true
                models.draft.baseURL = "http://127.0.0.1:11434/v1"
            },
            settingsScene("models-unsaved", .models, size: size) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: SampleWorld.discoveredServers())
                models.draft.baseURL = "http://127.0.0.1:11434/v1"
            },
            settingsScene("models-save-error", .models, size: size) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: SampleWorld.discoveredServers())
                models.draft.baseURL = "http://127.0.0.1:11434/v1"
                models.installSnapshotFeedback(apply: .init(kind: .error, text: note))
            },
            settingsScene("models-activity-cache-and-search-issue", .models, size: size) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: SampleWorld.discoveredServers())
                recorder.llmStatus.lastCacheHit = 1_840
                recorder.llmStatus.searchIssue = .searchModelNotInstalled
            },
            settingsScene("models-finding-servers", .models, size: size) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: [])
                models.installSnapshotScanning()
            },
            // The store did not open: Back Up, Restore and Erase are grey, with the reason and the way to Status.
            settingsScene("privacy-data-unavailable", .privacy, size: CGSize(width: 1020, height: 800)) { recorder, _ in recorder.history = nil },
            // Tall enough for the Erase row and the line under it: that line is what these two scenes show.
            settingsScene("privacy-erase-done", .privacy, size: CGSize(width: 1020, height: 1180)) { _, fixture in
                fixture.settings.installSnapshotEraseResult(done: true, error: nil)
            },
            settingsScene("privacy-erase-failed", .privacy, size: CGSize(width: 1020, height: 1180)) { _, fixture in
                fixture.settings.installSnapshotEraseResult(done: false, error: [String(localized: "Couldn’t erase all meetings", comment: "Alert title"), CocoaError(.fileWriteOutOfSpace).localizedDescription].joinedAsSentences())
            },
            // Status while its checks run.
            SnapshotScene(name: "settings-status-checking", size: settingsSize) { fixture in
                let recorder = await fixture.makeRecorder()
                fixture.settings.pane = .status
                fixture.settings.installSnapshotChecking()
                let view = SettingsWindow(recorder: recorder, preferences: fixture.preferences, model: fixture.settings).environment(\.copyProtection, false)
                return .init(view: AnyView(view), title: SettingsModel.Pane.status.title)
            },
            // Context: finding the names again in every meeting, running.
            contextAfterScene("context-reanalysis-running") { context, _ in
                context.section = .people
                context.reanalysis.start(total: 14)
                for _ in 0..<5 { context.reanalysis.record(AnalysisSummary()) }
            },
        ]
    }

    // MARK: Setup

    private static var vqaOnboarding: [SnapshotScene] {
        [
            // The list of languages is still loading.
            onboardingScene("language-loading", .language) { _ in SnapshotMode.languagesLoading = true },
        ]
    }

    // MARK: Increase Contrast and Reduce Transparency

    /// An existing scene again with an accessibility setting on.
    private static func accessibilityVariant(_ scene: SnapshotScene, _ suffix: String, contrast: Bool, transparency: Bool) -> SnapshotScene {
        SnapshotScene(name: "\(scene.name)-\(suffix)", size: scene.size, fitHeight: scene.fitHeight, isPanel: scene.isPanel,
                      isSheet: scene.isSheet, isFloating: scene.isFloating, fitWidth: scene.fitWidth) { fixture in
            let prepared = await scene.make(fixture)
            // Read by the renderer for this image only (the window gets the high-contrast appearance).
            SnapshotMode.highContrast = contrast
            SnapshotMode.reduceTransparency = transparency
            return prepared
        }
    }

    private static var vqaAccessibility: [SnapshotScene] {
        // Only scenes whose views read the contrast or transparency setting: a card, a stroked step badge, a destructive button, the captions'
        // material. Others would render byte for byte like the normal scene and only overstate the coverage.
        let wanted = ["panel-idle", "panel-recording", "panel-stop-countdown", "panel-translation", "panel-suggestion", "captions-live", "captions-controls",
                      "guide-no-app", "onboarding-welcome", "onboarding-models", "settings-models", "meetings-ask", "sheet-erase-everything"]
        let pool = panel + panelStates + captions + guide + onboarding + settings + meetings + sheets + sheetStates + coverage + meetingStates + gaps
        return wanted.flatMap { name -> [SnapshotScene] in
            guard let scene = pool.first(where: { $0.name == name }) else {
                // A name that is not found would silently drop its variants: say so.
                FileHandle.standardError.write(Data("WARNING: accessibility variant scene not found: \(name)\n".utf8))
                return []
            }
            let contrast = accessibilityVariant(scene, "increased-contrast", contrast: true, transparency: false)
            // Only the captions window (its material) and the menu-bar panel (the card edge) ask the system whether transparency is reduced.
            // The setup window and the panel draw no material of their own: macOS draws the panel's translucent material around the app's
            // view, so Reduce Transparency has nothing to change there that Increase Contrast does not (the same edge). Their reduce-transparency
            // images would be byte for byte the contrast ones, or the normal one, and only overstate the coverage.
            guard name.hasPrefix("captions-") else { return [contrast] }
            return [contrast, accessibilityVariant(scene, "reduce-transparency", contrast: false, transparency: true)]
        }
    }

    // MARK: Words of the system's open and save panels

    private static func filePanel(_ name: String, width: CGFloat = 500, title: String? = nil, message: String? = nil, saveName: String? = nil,
                                  prompt: String? = nil) -> SnapshotScene {
        mockScene("sheet-filepanel-\(name)", width: width) { _ in
            AnyView(FilePanelMock(title: title, message: message, saveName: saveName, prompt: prompt))
        }
    }

    private static var vqaFilePanels: [SnapshotScene] {
        let day = SampleWorld.snapshotNow.formatted(.iso8601.year().month().day())
        let searchRevision = SearchModelText.shortRevision, modelRevision = IntegratedModelText.shortRevision
        let importModel = String(localized: "Import", comment: "Open panel button that installs the search model from the chosen files")
        let importLanguage = String(localized: "Import", comment: "Open panel button that installs the integrated model from the chosen files")
        let add = String(localized: "Add", comment: "Open panel button that adds the chosen folders as document sources")
        return [
            filePanel("export-meeting", title: String(localized: "Export Meeting", comment: "Save panel title"),
                      saveName: MeetingExporter.fileName(for: "Weekly product sync") + ".md"),
            filePanel("attach-files", message: String(localized: "Choose files to attach to this meeting. Ask about the meeting can use them. Your files are never changed.",
                                                      comment: "Open panel message when attaching files to a meeting"),
                      prompt: String(localized: "Attach", comment: "Open panel button that attaches the chosen files to a meeting")),
            filePanel("import-recording", title: String(localized: "Import Recording", comment: "Open panel title"),
                      message: String(localized: "Choose an audio or video recording of a meeting. Vauta transcribes it on this Mac; the file isn’t changed or copied.",
                                      comment: "Open panel message when importing a recording"),
                      prompt: String(localized: "Choose", comment: "Open panel button")),
            filePanel("save-backup", title: String(localized: "Save Backup", comment: "Save panel title for a backup"),
                      saveName: BackupModel.defaultFileName(day: day)),
            filePanel("choose-backup", title: String(localized: "Choose a Backup", comment: "Open panel title for restoring a backup")),
            filePanel("export-network-activity", title: String(localized: "Export Network Activity", comment: "Save panel title"),
                      saveName: String(localized: "Vauta Network Activity \(day)", comment: "Default file name of the Network Activity export; the argument is the date as yyyy-MM-dd") + ".json",
                      ),
            filePanel("search-model-both", message: String(localized: "Choose model.safetensors and tokenizer.json of EmbeddingGemma 2 (revision \(searchRevision)). Vauta checks them before using them; your files are never changed.",
                                                           comment: "Open panel message when importing the search model from files; the file names and the argument (the revision) are not translated"),
                      prompt: importModel),
            filePanel("search-model-tokenizer", message: String(localized: "Choose tokenizer.json of EmbeddingGemma 2 (revision \(searchRevision)). Vauta checks it before using it; your file is never changed.",
                                                                comment: "Open panel message when importing the tokenizer of the search model; the file name and the argument (the revision) are not translated"),
                      prompt: importModel),
            filePanel("search-model-weights", message: String(localized: "Choose model.safetensors of EmbeddingGemma 2 (revision \(searchRevision)). Vauta checks it before using it; your file is never changed.",
                                                              comment: "Open panel message when importing the weights of the search model; the file name and the argument (the revision) are not translated"),
                      prompt: importModel),
            filePanel("integrated-model-both", message: String(localized: "Choose model.safetensors and tokenizer.json of Gemma 4 E4B (revision \(modelRevision)). Vauta checks them before using them; your files are never changed.",
                                                               comment: "Open panel message when importing the integrated model from files; the file names, the model name and the argument (the revision) are not translated"),
                      prompt: importLanguage),
            filePanel("integrated-model-tokenizer", message: String(localized: "Choose tokenizer.json of Gemma 4 E4B (revision \(modelRevision)). Vauta checks it before using it; your file is never changed.",
                                                                    comment: "Open panel message when importing the tokenizer of the integrated model; the file name, the model name and the argument (the revision) are not translated"),
                      prompt: importLanguage),
            filePanel("integrated-model-weights", message: String(localized: "Choose model.safetensors of Gemma 4 E4B (revision \(modelRevision)). Vauta checks it before using it; your file is never changed.",
                                                                  comment: "Open panel message when importing the weights of the integrated model; the file name, the model name and the argument (the revision) are not translated"),
                      prompt: importLanguage),
            filePanel("certificate-authority", message: String(localized: "Choose the private certificate authority of your model server (PEM).", comment: "Open panel message"),
                      ),
            filePanel("server-certificate", message: String(localized: "Choose the server’s certificate (PEM).", comment: "Open panel message")),
            filePanel("documents-folders", message: String(localized: "Choose folders Vauta may read. Your files are never changed.", comment: "Open panel message when adding document folders"), prompt: add),
            filePanel("documents-files", message: String(localized: "Choose files Vauta may read. Your files are never changed.", comment: "Open panel message when adding document files"),
                      prompt: String(localized: "Add", comment: "Open panel button that adds the chosen files as document sources")),
            filePanel("documents-locate", message: String(localized: "Choose the new place of “\("Quarterly plans")”.", comment: "Open panel message when locating a moved source; the argument is its name"),
                      prompt: String(localized: "Choose", comment: "Open panel button when locating a moved folder or file")),
        ]
    }
}
#endif
