// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

// The optional integrated language model (Gemma 4 E4B): every state of its Settings card, the provider choice on a Mac that qualifies and
// on one that does not, its About sheet and the confirmations, the Status row, the onboarding line, Network Activity, the minutes
// progress, and the states of an Ask answer (not verified, partly verified, cut short, not yet, checked, moved citation).

extension SnapshotScenes {
    private static let integratedSize = CGSize(width: 1020, height: 1180)
    private static let lmTotal = LanguageModelSpec.pinned.downloadSize
    private static let lmInstalled = LanguageModelSpec.pinned.installedSize

    private static func lmStatus(_ state: LanguageModelStatus.State, rate: Double? = nil, remaining: Int? = nil, installed: Int = 0,
                                 error: IntegratedModelError? = nil, source: String? = nil, cancellable: Bool = false, importPaused: Bool = false) -> LanguageModelStatus {
        var status = LanguageModelStatus()
        status.state = state
        status.bytesPerSecond = rate
        status.secondsRemaining = remaining
        status.installedBytes = installed
        status.lastError = error
        status.source = source
        status.cancellable = cancellable
        status.importPaused = importPaused
        return status
    }

    /// Settings → Models with the integrated model in `status`. `chat`: the saved choice. `memory`: the Mac the pane thinks it is on.
    private static func integratedPane(_ name: String, _ status: LanguageModelStatus, chat: ModelProviderSettings.Chat = .integrated,
                                       unsupported: LanguageModelUnsupported? = nil, memory: UInt64 = 16, liveTasks: ModelProviderSettings.LiveTasks = .integrated,
                                       draft: ModelProviderChoice? = nil, appleAvailable: Bool? = nil,
                                       size: CGSize = integratedSize, prepare: @escaping @MainActor (RecorderModel) -> Void = { _ in }) -> SnapshotScene {
        settingsScene("models-integrated-\(name)", .models, size: size) { recorder, fixture in
            fixture.settings.models.installSnapshotState(recorder, discovered: [], saved: ModelProviderSettings(chat: chat, embeddings: .none))
            fixture.settings.models.physicalMemory = memory * ModelRecommendation.gibibyte
            fixture.settings.models.appleAvailableOverride = appleAvailable
            // An unsaved choice: the radio is selected, the card is shown and the apply bar offers Save.
            if let draft { fixture.settings.models.provider = draft }
            recorder.integratedModel.installSnapshotState(status, unsupported: unsupported, liveTasks: liveTasks)
            prepare(recorder)
        }
    }

    /// `safe`: the button Return presses, as the real dialog names it ("Keep Downloading", "Keep Repairing", "Cancel").
    private static func alertScene(_ name: String, title: String, message: String, action: String,
                                   safe: String = String(localized: "Cancel", comment: "Alert button")) -> SnapshotScene {
        SnapshotScene(name: "models-integrated-\(name)", size: CGSize(width: 260, height: 160), isSheet: true) { _ in
            .init(view: AnyView(EmptyView()),
                  alert: SnapshotAlert(title: title, message: message,
                                       buttons: [.init(title: action, destructive: true), .init(title: safe)], defaultIndex: 1))
        }
    }

    static var integratedModelScenes: [SnapshotScene] {
        let total = lmTotal, installed = lmInstalled
        let sixGB = 6_100_000_000
        return [
            // The card in each state.
            // The opt-in: the radio chosen but not saved, the card with Download and Import, and Save waiting in the bar.
            integratedPane("not-installed", lmStatus(.notInstalled), chat: .onDevice, draft: .integrated),
            integratedPane("not-installed-no-apple", lmStatus(.notInstalled), chat: .server, draft: .integrated, appleAvailable: false),
            integratedPane("unsupported-memory", lmStatus(.notInstalled), chat: .onDevice, unsupported: .memory(installedGB: 8), memory: 8, size: CGSize(width: 1020, height: 760)),
            integratedPane("unsupported-selftest", lmStatus(.unsupported(.selfTestFailed)), chat: .onDevice, size: CGSize(width: 1020, height: 760)),
            integratedPane("preflight-disk-full", lmStatus(.failed(.diskFull(needed: installed + LanguageModelStore.headroom)))),
            integratedPane("downloading-start", lmStatus(.downloading(received: 0, total: total, phase: .tokenizer), source: "download", cancellable: true)),
            integratedPane("downloading-no-apple", lmStatus(.downloading(received: sixGB, total: total, phase: .downloading), rate: 9_800_000, remaining: 25 * 60, installed: sixGB, source: "download", cancellable: true),
                           appleAvailable: false),
            integratedPane("downloading", lmStatus(.downloading(received: sixGB, total: total, phase: .downloading), rate: 9_800_000, remaining: 25 * 60, installed: sixGB, source: "download", cancellable: true)),
            integratedPane("paused-recording", lmStatus(.pausedForRecording(received: sixGB, total: total), installed: sixGB)),
            integratedPane("checking-partial", lmStatus(.checkingPartial, installed: sixGB)),
            integratedPane("partial", lmStatus(.partial(verified: sixGB, total: total), installed: sixGB)),
            integratedPane("partial-repair", lmStatus(.partial(verified: sixGB, total: total), installed: sixGB, source: "repair")),
            integratedPane("partial-offline", lmStatus(.partial(verified: sixGB, total: total), installed: sixGB, error: .offline)),
            integratedPane("importing", lmStatus(.importing(0.38), source: "import", cancellable: true)),
            integratedPane("importing-paused-recording", lmStatus(.importing(0.38), source: "import", cancellable: true, importPaused: true)),
            integratedPane("imported-weights", lmStatus(.needsFile(.tokenizer), installed: installed - LanguageModelSpec.pinned.tokenizerSize)),
            integratedPane("imported-tokenizer", lmStatus(.needsFile(.weights), installed: LanguageModelSpec.pinned.tokenizerSize)),
            integratedPane("import-wrong-file", lmStatus(.failed(.importWrongFile))),
            integratedPane("verifying", lmStatus(.verifying)),
            integratedPane("preparing", lmStatus(.preparing)),
            integratedPane("ready-chosen", lmStatus(.ready, installed: installed)),
            integratedPane("ready-not-chosen", lmStatus(.ready, installed: installed), chat: .onDevice),
            integratedPane("ready-live-apple", lmStatus(.ready, installed: installed), liveTasks: .apple),
            integratedPane("damaged", lmStatus(.damaged, installed: installed)),
            integratedPane("damaged-no-apple", lmStatus(.damaged, installed: installed), appleAvailable: false),
            integratedPane("repairing", lmStatus(.repairing(received: 1_200_000_000, total: 9_800_000_000), rate: 9_000_000, remaining: 16 * 60, installed: installed, source: "repair", cancellable: true)),
            integratedPane("error-mismatch", lmStatus(.failed(.mismatch))),
            integratedPane("error-host", lmStatus(.failed(.hostNotAllowed))),
            integratedPane("error-offline", lmStatus(.failed(.offline))),
            integratedPane("error-revision-gone", lmStatus(.failed(.revisionGone))),
            integratedPane("error-io", lmStatus(.failed(.ioError))),
            integratedPane("error-engine", lmStatus(.failed(.engineFailed("The model could not be loaded.")), installed: installed)),
            integratedPane("error-engine-no-apple", lmStatus(.failed(.engineFailed("The model could not be loaded.")), installed: installed), appleAvailable: false),
            integratedPane("deleting", lmStatus(.deleting)),

            // Confirmations (the default button is always the safe one).
            alertScene("cancel-confirm", title: IntegratedModelText.cancelTitle, message: IntegratedModelText.cancelMessage(downloaded: sixGB),
                       action: String(localized: "Delete Download", comment: "Alert button; cancelling the download of the integrated model deletes what was downloaded"),
                       safe: String(localized: "Keep Downloading", comment: "Alert button; keeps the download of the integrated model going")),
            alertScene("repairing-cancel-confirm", title: IntegratedModelText.cancelRepairTitle, message: IntegratedModelText.cancelRepairMessage(downloadSize: IntegratedModelText.downloadSize),
                       action: String(localized: "Delete Model", comment: "Alert button; stopping the repair of the integrated model deletes the damaged model"),
                       safe: String(localized: "Keep Repairing", comment: "Alert button; keeps the repair of the integrated model going")),
            alertScene("repair-discard-confirm", title: IntegratedModelText.cancelRepairTitle, message: IntegratedModelText.cancelRepairMessage(downloadSize: IntegratedModelText.downloadSize),
                       action: String(localized: "Delete Model", comment: "Alert button; stopping the repair of the integrated model deletes the damaged model")),
            alertScene("discard-confirm", title: IntegratedModelText.discardTitle, message: IntegratedModelText.discardMessage,
                       action: String(localized: "Discard", comment: "Alert button")),
            alertScene("delete-confirm", title: IntegratedModelText.deleteTitle, message: IntegratedModelSection.deleteDialogMessage(chosen: true, liveIntegrated: false, installedBytes: installed, appleAvailable: true),
                       action: String(localized: "Delete", comment: "Alert button")),
            alertScene("delete-confirm-recording", title: IntegratedModelText.deleteTitle, message: IntegratedModelSection.deleteDialogMessage(chosen: true, liveIntegrated: true, installedBytes: installed, appleAvailable: true),
                       action: String(localized: "Delete", comment: "Alert button")),
            alertScene("delete-confirm-no-apple", title: IntegratedModelText.deleteTitle,
                       message: IntegratedModelSection.deleteDialogMessage(chosen: true, liveIntegrated: true, installedBytes: installed, appleAvailable: false),
                       action: String(localized: "Delete", comment: "Alert button")),
            alertScene("delete-confirm-not-chosen", title: IntegratedModelText.deleteTitle, message: IntegratedModelSection.deleteDialogMessage(chosen: false, liveIntegrated: false, installedBytes: installed, appleAvailable: true),
                       action: String(localized: "Delete", comment: "Alert button")),

            SnapshotScene(name: "sheet-integrated-model-about", size: CGSize(width: 440, height: 520), fitHeight: true, isSheet: true) { _ in
                .init(view: AnyView(IntegratedModelAboutSheet(close: {}).background(Color(nsColor: .windowBackgroundColor))))
            },

            // The provider choice on a Mac that qualifies (four options) and on one that does not (three, and the reason).
            integratedPane("provider-picker-16gb", lmStatus(.notInstalled), chat: .onDevice, size: CGSize(width: 1020, height: 760)),
            integratedPane("provider-picker-8gb", lmStatus(.notInstalled), chat: .onDevice, unsupported: .memory(installedGB: 8), memory: 8, size: CGSize(width: 1020, height: 760)),
            // Clicking Download saves the choice at once: the apply bar says what writes the minutes until the model is ready.
            settingsScene("models-integrated-saved-fallback-feedback", .models, size: CGSize(width: 1020, height: 1180)) { recorder, fixture in
                fixture.settings.models.installSnapshotState(recorder, discovered: [], saved: ModelProviderSettings(chat: .integrated, embeddings: .none))
                fixture.settings.models.physicalMemory = 16 * ModelRecommendation.gibibyte
                recorder.integratedModel.installSnapshotState(lmStatus(.downloading(received: 4_000_000, total: total, phase: .tokenizer), source: "download", cancellable: true))
                fixture.settings.models.installSnapshotFeedback(apply: .init(kind: .success, text: IntegratedModelText.appliedFallback()))
            },
            // Activity: the note about reading the meeting as it goes, and the line when Apple's stands in.
            integratedPane("activity-integrated", lmStatus(.ready, installed: installed), size: CGSize(width: 1020, height: 1500)) { recorder in
                recorder.llmStatus.readingMeeting = true
            },
            integratedPane("activity-fallback-issue", lmStatus(.downloading(received: sixGB, total: total, phase: .downloading), rate: 9_800_000, remaining: 25 * 60, installed: sixGB),
                           size: CGSize(width: 1020, height: 1500)) { recorder in
                recorder.llmStatus.integratedFallback = .notReady
            },

            // Settings → Status.
            integratedStatus("status-integrated-ready", lmStatus(.ready, installed: installed)),
            integratedStatus("status-integrated-downloading", lmStatus(.downloading(received: sixGB, total: total, phase: .downloading), installed: sixGB)),
            integratedStatus("status-integrated-damaged", lmStatus(.damaged, installed: installed)),
            integratedStatus("status-integrated-paused-recording", lmStatus(.pausedForRecording(received: sixGB, total: total), installed: sixGB)),
            integratedStatus("status-integrated-repairing", lmStatus(.repairing(received: 1_200_000_000, total: 9_800_000_000), installed: installed, source: "repair", cancellable: true)),
            integratedStatus("status-integrated-paused", lmStatus(.partial(verified: sixGB, total: total), installed: sixGB)),
            integratedStatus("status-integrated-importing", lmStatus(.importing(0.38), source: "import", cancellable: true)),
            integratedStatus("status-integrated-importing-paused-recording", lmStatus(.importing(0.38), source: "import", cancellable: true, importPaused: true)),
            integratedStatus("status-integrated-verifying", lmStatus(.verifying)),
            integratedStatus("status-integrated-failed", lmStatus(.failed(.mismatch))),

            // Onboarding: one secondary line under the Apple option, only on a Mac with 16 GB or more.
            // (models, models-small-mac, models-no-apple and models-no-apple-off already show the line at 16 GB, and its absence at 8 GB.)
        ] + integratedNetworkScenes + integratedProgressScenes + integratedAskScenes
    }

    private static func integratedStatus(_ name: String, _ status: LanguageModelStatus) -> SnapshotScene {
        settingsScene(name, .status, size: CGSize(width: 1020, height: 760)) { recorder, fixture in
            fixture.settings.models.installSnapshotState(recorder, discovered: [], saved: ModelProviderSettings(chat: .integrated, embeddings: .none))
            recorder.integratedModel.installSnapshotState(status)
        }
    }

    // MARK: Network Activity

    private static func languageModelEntries(both: Bool) -> [NetworkActivityEntry] {
        var out = sampleNetworkEntries(problems: false)
        let base = SampleWorld.snapshotNow.addingTimeInterval(-35 * 60)
        let hf = "https://huggingface.co/google/gemma-4-E4B-it/resolve/ee0ef6023621cff504d758262d4e04895a5af4a2"
        let cdn = "https://us.aws.cdn.hf.co/xet-bridge-us/6aa80a7682023d2e774f1c9a/47a68c5b4bb3b43eb611ba512b8a0830e80ce08dfd"
        func add(_ seconds: Double, _ purpose: NetworkPurpose, _ url: String, status: Int, received: Int = 0, duration: Double) {
            out.append(NetworkActivityEntry(id: UInt64(out.count + 1), timestamp: base.addingTimeInterval(seconds), purpose: purpose, url: URL(string: url)!, method: "GET",
                                            bytesSent: 0, bytesReceived: received, status: status, duration: duration, blocked: nil))
        }
        if both {
            add(1_900, .modelDownload, "https://huggingface.co/google/embeddinggemma-2/resolve/914f7f89142e33e77833254d9c9b90c3cef7303b/model.safetensors", status: 302, duration: 0.2)
            add(1_901, .modelDownload, cdn, status: 206, received: 33_554_432, duration: 1.9)
        }
        add(2_000, .languageModelDownload, "\(hf)/tokenizer.json", status: 302, duration: 0.2)
        add(2_001, .languageModelDownload, cdn, status: 200, received: 32_169_626, duration: 3.1)
        add(2_005, .languageModelDownload, "\(hf)/model.safetensors", status: 302, duration: 0.2)
        for block in 0..<5 { add(2_006 + Double(block) * 6, .languageModelDownload, cdn, status: 206, received: 67_108_864, duration: 5.4) }
        return out
    }

    private static var integratedNetworkScenes: [SnapshotScene] {
        [
            networkScene("language-model-download") { languageModelEntries(both: false) },
            networkScene("language-model-download-filtered", entries: { languageModelEntries(both: false) }, filter: .languageModelDownload),
            networkScene("both-model-downloads") { languageModelEntries(both: true) },
        ]
    }

    // MARK: Progress of the minutes

    private static func readingStatus(_ recorder: RecorderModel, _ fixture: SnapshotFixture, stage: LLMService.Stage, done: Int? = nil) {
        recorder.llmStatus.activity = String(localized: "Writing minutes", comment: "Model server activity in the menu bar panel")
        recorder.llmStatus.activityStarted = Date(timeIntervalSince1970: 1_800_000_000)
        recorder.llmStatus.activityMeeting = fixture.world.featuredMeetingID
        recorder.llmStatus.stage = stage
        if let done { recorder.llmStatus.prefill = LLMService.PrefillProgress(done: done, total: 10_000) }
    }

    private static var integratedProgressScenes: [SnapshotScene] {
        let clock = Date(timeIntervalSince1970: 1_800_000_035)
        return [
            panelScene("minutes-reading-42", clock: clock) { recorder, fixture in readingStatus(recorder, fixture, stage: .readingTranscript, done: 4_200) },
            panelScene("minutes-writing", clock: clock) { recorder, fixture in readingStatus(recorder, fixture, stage: .writingMinutes) },
            panelScene("minutes-finding-items-2of4", clock: clock) { recorder, fixture in readingStatus(recorder, fixture, stage: .findingItems(part: 2, of: 4)) },
            meetingsScene("statusbar-reading") { history, fixture in
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            } configureRecorder: { recorder, fixture in
                readingStatus(recorder, fixture, stage: .readingTranscript, done: 4_200)
            },
            meetingsScene("summary-tab-reading-progress") { history, fixture in
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            } configureRecorder: { recorder, fixture in
                readingStatus(recorder, fixture, stage: .readingTranscript, done: 4_200)
            } after: { history, _ in
                history.cardSource = nil
                history.draft?.summary = ""
            },
            // Owners: a task of a speaker nobody has named, and after naming the speaker.
            meetingsAfterScene("minutes-owner-speaker-label", prepare: featured) { history, _ in
                history.tab = .tasks
                if var task = history.tasks.first {
                    task.ownerID = nil
                    task.ownerName = MeetingSpeaker.defaultLabel(channel: .others, ordinal: 2)
                    task.ownerSpeakerID = 2
                    history.tasks[0] = task
                }
            },
            // A plain "yes" from a speaker nobody has named: the label is shown with the "not confirmed" mark.
            meetingsAfterScene("minutes-owner-speaker-label-uncertain", prepare: featured) { history, _ in
                history.tab = .tasks
                if var task = history.tasks.first {
                    task.ownerID = nil
                    task.ownerName = MeetingSpeaker.defaultLabel(channel: .others, ordinal: 2)
                    task.ownerSpeakerID = 2
                    task.ownerUncertain = true
                    history.tasks[0] = task
                }
            },
            meetingsAfterScene("minutes-owner-named-after", prepare: featured) { history, _ in history.tab = .tasks },
        ]
    }

    // MARK: Ask

    /// `recordingThis`: the featured meeting is being recorded and Ask is scoped to it, the only place "That hasn't come up yet" can
    /// be said (it answers a question about the meeting being recorded, so "this meeting" has a referent and the passages are its own).
    private static func askScene(_ name: String, busy: Bool = false, recordingThis: Bool = false, status: ((inout LLMService.Status) -> Void)? = nil,
                                 consulted: ((VerifiedAnswer, [Int64]) -> VerifiedAnswer?)? = nil,
                                 answer: @escaping (VerifiedAnswer, SnapshotFixture) -> VerifiedAnswer?) -> SnapshotScene {
        meetingsScene(name) { history, fixture in
            history.mode = .ask
            await prepareAsk(history.ask, fixture)
            var consultedIDs: [Int64] = []
            if recordingThis {
                let featured = fixture.world.featuredMeetingID
                // It began a few minutes ago, so "Recording" and the passages (the latest 5:04 in) belong to one live meeting.
                try? await fixture.world.startFeaturedMeeting(minutesAgo: 6)
                await history.reload()
                history.activeMeetingID = featured
                history.selectedID = featured
                history.ask.meetingID = featured
                history.ask.thisMeeting = true
                history.ask.answeredThisMeeting = true
                // A question the recorded part has not reached (the budget was never mentioned), so "not yet" is true. The passages
                // are the lines that mention the launch, the nearest the search finds.
                let topic = notYetTopic(fixture.language)
                history.ask.question = topic.question
                history.ask.answeredQuestion = topic.question
                history.ask.passages = ((try? await fixture.world.store.retrieve(topic.query, queryVector: nil, within: nil)) ?? [])
                    .filter { $0.meeting.id == featured }
                for passage in history.ask.passages {
                    for segment in passage.segments {
                        history.ask.segments[segment.id] = segment
                        history.ask.segmentMeeting[segment.id] = featured
                        if !consultedIDs.contains(segment.id) { consultedIDs.append(segment.id) }
                    }
                }
            }
            if busy {
                history.ask.answer = nil
                history.ask.busy = true
                history.ask.progressTokens = 0
            } else if let base = history.ask.answer {
                history.ask.answer = consulted.map { $0(base, consultedIDs) } ?? answer(base, fixture)
            }
        } configureRecorder: { recorder, _ in
            if let status { status(&recorder.llmStatus) }
        } after: { history, fixture in
            // Loading the meeting reads the store, which has no recording; the sidebar row says "Recording" like in a live meeting.
            if recordingThis { history.activeMeetingID = fixture.world.featuredMeetingID }
        }
    }

    /// A question about something the featured meeting never mentions, and a word its launch lines do contain.
    private static func notYetTopic(_ language: String) -> (question: String, query: String) {
        switch language.split(separator: "-").first.map(String.init) ?? language {
        case "es": ("¿Qué presupuesto fijamos para el lanzamiento?", "lanzamiento")
        case "fr": ("Quel budget avons-nous fixé pour le lancement ?", "lancement")
        case "de": ("Welches Budget haben wir für den Start festgelegt?", "Start")
        case "it": ("Che budget abbiamo fissato per il lancio?", "lancio")
        case "pt": ("Que orçamento definimos para o lançamento?", "lançamento")
        case "ja": ("ローンチの予算はいくらに決めましたか？", "ローンチ")
        case "ko": ("출시 예산은 얼마로 정했나요?", "출시")
        case "zh": ("我们为发布定了多少预算？", "发布")
        default: ("What budget did we set for the launch?", "launch")
        }
    }

    private static var integratedAskScenes: [SnapshotScene] {
        [
            // None of the claims could be checked: the badge first, then the moments the model pointed to and the caution.
            askScene("ask-unverified-badge") { base, _ in
                VerifiedAnswer(answer: base.answer, claims: base.claims.map { .init(id: $0.id, text: $0.text, citations: $0.citations, verified: false) })
            },
            askScene("ask-partly-verified") { base, _ in
                VerifiedAnswer(answer: base.answer, claims: base.claims.enumerated().map { i, c in .init(id: c.id, text: c.text, citations: c.citations, verified: i == 0) })
            },
            askScene("ask-cut-short") { base, _ in VerifiedAnswer(answer: base.answer, claims: [], found: true, cutShort: true) },
            // The quotes were checked but the text reached its length limit: the note says the last sentence may be incomplete.
            askScene("ask-ends-incomplete") { base, _ in VerifiedAnswer(answer: base.answer, claims: base.claims, found: true, cutShort: true) },
            askScene("ask-partly-ends-incomplete") { base, _ in
                VerifiedAnswer(answer: base.answer, claims: base.claims.enumerated().map { i, c in .init(id: c.id, text: c.text, citations: c.citations, verified: i == 0) },
                               found: true, cutShort: true)
            },
            askScene("ask-not-yet", recordingThis: true) { base, _ in VerifiedAnswer(answer: "", claims: [], found: false, withheld: base.answer, notYet: true) },
            // The quotes are in the transcript, but a second reading judged that they only touch the topic.
            askScene("ask-related-only") { base, _ in VerifiedAnswer(answer: base.answer, claims: base.claims, found: true, touchesOnly: true) },
            // The moments it points to are the launch date and the public launch, the nearest things said, not an answer about the budget.
            askScene("ask-not-yet-related", recordingThis: true, consulted: { base, consulted in
                // The same lines the passages above show, so "related so far" and "passages consulted" name the same moments.
                let nearest = consulted.isEmpty ? [] : Array(consulted.prefix(2))
                guard !nearest.isEmpty else { return nil }
                let claims = base.claims.enumerated().map { i, c in
                    VerifiedAnswer.Claim(id: c.id, text: c.text, citations: [nearest[min(i, nearest.count - 1)]], verified: true)
                }
                return VerifiedAnswer(answer: "", claims: claims, found: false, withheld: base.answer, notYet: true)
            }) { _, _ in nil },
            askScene("ask-checking-answer", busy: true, status: { $0.stage = .checkingAnswer; $0.activityIsAsk = true; $0.activity = String(localized: "Answering your question", comment: "Model server activity in the menu bar panel") }) { _, _ in nil },
            askScene("ask-reading-meeting", busy: true, status: {
                $0.stage = .readingTranscript
                $0.prefill = LLMService.PrefillProgress(done: 4_000, total: 10_000)
                $0.activityIsAsk = true
                $0.activity = String(localized: "Answering your question", comment: "Model server activity in the menu bar panel")
            }) { _, _ in nil },
            // The model cited another moment than the one that holds the quote: the citation points where the words are, and looks like any other.
            askScene("ask-reanchored-citation") { base, _ in
                VerifiedAnswer(answer: base.answer, claims: base.claims.map { .init(id: $0.id, text: $0.text, citations: $0.citations, verified: true, reanchoredFrom: 1) })
            },
        ]
    }
}
#endif
