// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

extension SnapshotScenes {
    // MARK: Sheets

    static func sheetScene(_ name: String, width: CGFloat, build: @escaping @MainActor (SnapshotFixture, RecorderModel) async -> AnyView)
        -> SnapshotScene {
        SnapshotScene(name: "sheet-\(name)", size: CGSize(width: width, height: 300), fitHeight: true, isSheet: true) { fixture in
            let recorder = await fixture.makeRecorder()
            let view = await build(fixture, recorder)
            return .init(view: AnyView(view.background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    private static func backup(_ configure: @escaping @MainActor (BackupModel) -> Void) -> @MainActor (SnapshotFixture, RecorderModel) async -> AnyView {
        { _, recorder in
            let model = BackupModel()
            configure(model)
            return AnyView(BackUpSheet(recorder: recorder, model: model))
        }
    }

    private static func restore(_ configure: @escaping @MainActor (BackupModel) -> Void) -> @MainActor (SnapshotFixture, RecorderModel) async -> AnyView {
        { _, recorder in
            let model = BackupModel()
            configure(model)
            return AnyView(RestoreSheet(recorder: recorder, model: model))
        }
    }

    /// A sample backup file and the day it was made, so the restore sheet shows its file and date line.
    /// The name is the default one the save panel offers, in the language being rendered.
    private static func sampleFile(day: String = "2026-10-08") -> URL {
        URL(fileURLWithPath: "/Users/maya/Documents/" + BackupModel.defaultFileName(day: day))
    }

    private static var sampleBackupFile: URL { sampleFile() }
    private static let sampleBackupDate = Date(timeIntervalSince1970: 1_791_450_000)

    static var sheetStates: [SnapshotScene] {
        [
            sheetScene("retention", width: 440) { _, _ in
                AnyView(RetentionConfirmSheet(change: RetentionChange(from: .untilDeleted, to: .oneYear), count: 12, confirm: {}, cancel: {}))
            },
            sheetScene("erase-everything", width: 440) { fixture, recorder in
                // No old copies and not erasing: what an earlier scene staged in this fixture must not show up here.
                fixture.world.clearLeftovers()
                fixture.settings.eraseLeftoverBytes = nil
                fixture.settings.installSnapshotErasing(false)
                return AnyView(EraseEverythingSheet(recorder: recorder, model: fixture.settings, isPresented: .constant(true)))
            },
            // Old copies from the earlier-version migration exist: the sheet names them.
            sheetScene("erase-everything-leftovers", width: 440) { fixture, recorder in
                fixture.world.clearLeftovers()
                try? fixture.world.stageLeftovers(setAside: 2, oldFolder: true)
                fixture.settings.eraseLeftoverBytes = await recorder.storeLeftovers()?.totalBytes
                fixture.settings.installSnapshotErasing(false)
                return AnyView(EraseEverythingSheet(recorder: recorder, model: fixture.settings, isPresented: .constant(true)))
            },
            // Erasing: the words say what is happening, and Cancel and Erase wait.
            sheetScene("erase-everything-working", width: 440) { fixture, recorder in
                // The same old copies as the Status pane's "both" scene (6.6 MB), whatever scene ran before.
                fixture.world.clearLeftovers()
                try? fixture.world.stageLeftovers(setAside: 2, oldFolder: true)
                fixture.settings.eraseLeftoverBytes = await recorder.storeLeftovers()?.totalBytes
                fixture.settings.installSnapshotErasing()
                return AnyView(EraseEverythingSheet(recorder: recorder, model: fixture.settings, isPresented: .constant(true), typedWord: String(localized: "erase", comment: "Word the user types to confirm erasing everything; lowercase")))
            },
            sheetScene("backup-form", width: 440, build: backup { _ in }),
            sheetScene("backup-too-short", width: 440, build: backup {
                $0.password = "meeting1234"
                $0.confirmation = "meeting1234"
            }),
            sheetScene("backup-weak", width: 440, build: backup {
                $0.password = "meetings2026"
                $0.confirmation = "meetings2026"
            }),
            sheetScene("backup-good", width: 440, build: backup {
                $0.password = "Meetings2026!"
                $0.confirmation = "Meetings2026!"
            }),
            sheetScene("backup-mismatch", width: 440, build: backup {
                $0.password = "blue harbor drifts under the quiet lantern"
                $0.confirmation = "blue harbor drifts under the quiet lantern."
            }),
            sheetScene("backup-strong", width: 440, build: backup {
                $0.password = "blue harbor drifts under the quiet lantern"
                $0.confirmation = "blue harbor drifts under the quiet lantern"
            }),
            sheetScene("backup-working", width: 440, build: backup {
                $0.password = "blue harbor drifts under the quiet lantern"
                $0.confirmation = "blue harbor drifts under the quiet lantern"
                $0.installSnapshotMeetingsToBackUp(312)
                $0.stage = .working
            }),
            sheetScene("backup-done", width: 440, build: backup {
                $0.installSnapshotFile(saved: sampleBackupFile, date: sampleBackupDate)
                $0.stage = .done(BackupModel.savedMessage)
            }),
            sheetScene("backup-failed", width: 440, build: backup {
                $0.password = "blue harbor drifts under the quiet lantern"
                $0.confirmation = "blue harbor drifts under the quiet lantern"
                $0.installSnapshotError(CocoaError(.fileWriteOutOfSpace))
            }),
            sheetScene("restore-form", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
            }),
            sheetScene("restore-wrong-password", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.password = "not the password"
                $0.installSnapshotError(StoreError(.backupAuthentication, detail: "sample"))
            }),
            sheetScene("restore-opening", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.password = "blue harbor drifts under the quiet lantern"
                $0.stage = .working
                $0.installSnapshotWork(.opening)
            }),
            sheetScene("restore-restoring", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.installSnapshotBackupHasSettings()
                $0.installSnapshotCounts(current: 12, backup: 48)
                $0.stage = .working
                $0.installSnapshotWork(.restoring)
            }),
            sheetScene("restore-confirm", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.installSnapshotBackupHasSettings()
                $0.stage = .confirm(current: 12, backup: 48)
            }),
            // The backup holds saved voices: the sheet says restoring brings them back.
            sheetScene("restore-confirm-voices", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.installSnapshotBackupHasSettings()
                $0.installSnapshotBackupHasVoices()
                $0.stage = .confirm(current: 12, backup: 48)
            }),
            sheetScene("restore-confirm-backed-up", width: 440) { _, recorder in
                let model = BackupModel()
                model.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                model.installSnapshotBackupHasSettings()
                model.stage = .confirm(current: 12, backup: 48)
                return AnyView(RestoreSheet(recorder: recorder, model: model,
                                            safetyBackup: sampleFile(day: "2026-10-09")))
            },
            // No meetings and no context: nothing is replaced, so the plain Restore button.
            sheetScene("restore-confirm-empty", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.stage = .confirm(current: 0, backup: 48)
            }),
            // No meetings, but 17 context entries that the restore replaces too.
            sheetScene("restore-confirm-context-only", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.installSnapshotContext(17)
                $0.stage = .confirm(current: 0, backup: 48)
            }),
            sheetScene("restore-confirm-recording", width: 440) { _, recorder in
                recorder.phase = .recording
                let model = BackupModel()
                model.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                model.stage = .confirm(current: 12, backup: 48)
                return AnyView(RestoreSheet(recorder: recorder, model: model))
            },
            // The stopped recording is still being written: the restore waits for it.
            sheetScene("restore-confirm-stopping", width: 440) { _, recorder in
                recorder.phase = .stopping
                let model = BackupModel()
                model.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                model.stage = .confirm(current: 12, backup: 48)
                return AnyView(RestoreSheet(recorder: recorder, model: model))
            },
            sheetScene("restore-done", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.stage = .done(String(localized: "Restored \(48) meetings and your context from the backup.",
                                        comment: "Backup sheet: shown after a successful restore; argument is a number of meetings"))
            }),
            sheetScene("restore-done-context-only", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.installSnapshotRestored(meetings: 0)
                $0.stage = .done(String(localized: "Restored your context from the backup.",
                                        comment: "Backup sheet: shown after a successful restore of a backup with no meetings"))
            }),
            sheetScene("restore-done-settings", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.installSnapshotRestoredNote(String(localized: "Your settings were restored too. The model server and its key aren’t included.",
                                                      comment: "Backup sheet: under the restore result when the backup carried the settings"), needsServer: false)
                $0.stage = .done(BackupModel.restoredMessage(meetings: 48))
            }),
            // A new Mac: the settings chose a model server this Mac doesn't have.
            sheetScene("restore-done-needs-server", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.installSnapshotRestoredNote(String(localized: "Your settings were restored too.", comment: "Backup sheet: under the restore result when the backup carried the settings and no model server"), needsServer: true)
                $0.stage = .done(BackupModel.restoredMessage(meetings: 48))
            }),
            sheetScene("restore-done-needs-server-no-apple", width: 440, build: restore {
                $0.installSnapshotFile(restoring: sampleBackupFile, date: sampleBackupDate)
                $0.installSnapshotRestoredNote(String(localized: "Your settings were restored too.", comment: "Backup sheet: under the restore result when the backup carried the settings and no model server"), needsServer: true, appleAvailable: false)
                $0.stage = .done(BackupModel.restoredMessage(meetings: 48))
            }),
            sheetScene("import-ready", width: 440) { fixture, _ in
                AnyView(ImportRecordingSheet(model: await importer(fixture, phase: .ready)))
            },
            sheetScene("import-transcribing", width: 440) { fixture, _ in
                AnyView(ImportRecordingSheet(model: await importer(fixture, phase: .transcribing(0.37))))
            },
            sheetScene("import-downloading", width: 440) { fixture, _ in
                AnyView(ImportRecordingSheet(model: await importer(fixture, phase: .downloading(0.2))))
            },
            sheetScene("import-failed", width: 440) { fixture, _ in
                // The error names the language the picker shows.
                let model = await importer(fixture, phase: .ready)
                let language = model.selectedLanguage?.id ?? "en-US"
                model.failure = CaptureError(.speechModelMissing, localeIdentifier: language).localizedDescription
                model.failureIsLanguage = true
                model.failureIsModelMissing = true
                return AnyView(ImportRecordingSheet(model: model))
            },
            sheetScene("merge", width: 440) { fixture, recorder in
                guard let context = recorder.context else { return AnyView(EmptyView()) }
                await context.reload()
                if let source = context.entity(fixture.world.peopleIDs[1]) { await context.requestMerge(of: source) }
                guard let request = context.mergeRequest else { return AnyView(EmptyView()) }
                return AnyView(MergeSheet(model: context, request: request))
            },
            // A target is chosen: every line of what moves.
            sheetScene("merge-target", width: 440) { fixture, recorder in
                guard let context = recorder.context else { return AnyView(EmptyView()) }
                await context.reload()
                if let source = context.entity(fixture.world.peopleIDs[1]) { await context.requestMerge(of: source) }
                context.mergeRequest?.targetID = fixture.world.peopleIDs[2]
                guard let request = context.mergeRequest else { return AnyView(EmptyView()) }
                return AnyView(MergeSheet(model: context, request: request))
            },
            // Dismissing a person suggested by the calendar.
            sheetScene("delete-entity-dismiss", width: 440) { fixture, recorder in
                guard let context = recorder.context else { return AnyView(EmptyView()) }
                await context.reload()
                let id = fixture.world.peopleIDs[2]
                context.entities = context.entities.map { $0.id == id ? $0.snapshotPending : $0 }
                if let entity = context.entity(id) { await context.dismiss(entity) }
                guard let request = context.deleteRequest else { return AnyView(EmptyView()) }
                return AnyView(DeleteEntitySheet(model: context, request: request))
            },
            sheetScene("delete-entity", width: 440) { fixture, recorder in
                guard let context = recorder.context else { return AnyView(EmptyView()) }
                await context.reload()
                if let entity = context.entity(fixture.world.peopleIDs[1]) { await context.requestDelete(entity) }
                guard let request = context.deleteRequest else { return AnyView(EmptyView()) }
                return AnyView(DeleteEntitySheet(model: context, request: request))
            },
        ]
    }

    static func importer(_ fixture: SnapshotFixture, phase: RecordingImportModel.Phase, failure: String? = nil) async -> RecordingImportModel {
        let model = RecordingImportModel(store: fixture.world.store)
        let catalog = SnapshotMode.catalog
        model.languages = catalog?.languages ?? []
        model.languageID = catalog?.language(matching: fixture.world.locale.identifier(.bcp47))?.id ?? ""
        model.file = .init(fileName: "Design review 2026-10-01.m4a", duration: 2_283, recordedAt: nil)
        model.phase = phase
        model.failure = failure
        return model
    }
}
#endif
