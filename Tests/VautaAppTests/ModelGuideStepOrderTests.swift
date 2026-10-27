// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
import VautaCore
@testable import Vauta

/// Ollama's download command needs its app open, so the guide opens the app before the download; LM Studio keeps its order.
@MainActor
@Suite("Model guide step order")
struct ModelGuideStepOrderTests {
    private func guide(_ app: LocalModelApp) -> ModelGuideModel {
        let guide = ModelGuideModel(physicalMemory: 16 * ModelRecommendation.gibibyte, polls: false,
                                    locate: { _ in URL(fileURLWithPath: "/Applications/App.app") }, freeSpace: { 180 * 1_000_000_000 })
        guide.app = app
        return guide
    }

    @Test func lmStudioDownloadsBeforeItStartsTheServer() {
        let guide = guide(.lmStudio)
        #expect(guide.stepOrder == [1, 2, 3, 4])
        #expect(guide.number(of: 2) == 2 && guide.number(of: 3) == 3)
        #expect(guide.stepState(2) == .current && guide.stepState(3) == .upcoming)
    }

    @Test func ollamaOpensItsAppBeforeTheDownload() {
        let guide = guide(.ollama)
        #expect(guide.stepOrder == [1, 3, 2, 4])
        #expect(guide.number(of: 3) == 2 && guide.number(of: 2) == 3)
        // Installed, not running: opening the app is the step to do, the download waits.
        #expect(guide.stepState(1) == .done && guide.stepState(3) == .current && guide.stepState(2) == .upcoming)
    }

    @Test func ollamaPutsTheContextFixAfterTheDownload() {
        let guide = guide(.ollama)
        let model = DiscoveredModel(id: "qwen3.5:9b", kind: .chat, contextLength: 4096, loaded: true)
        let server = DiscoveredServer(kind: .ollama, baseURL: URL(string: "http://127.0.0.1:11434/v1/")!, version: nil, models: [model])
        guide.status = SetupEvaluation.evaluate([server], configuration: SetupConfiguration(app: .ollama, recommendation: guide.recommendation))
        guard case .contextTooSmall = guide.status else { Issue.record("\(guide.status)"); return }
        #expect(guide.stepOrder == [1, 2, 3, 4])
        #expect(guide.number(of: 3) == 3)
        #expect(guide.stepState(2) == .done && guide.stepState(3) == .current)
    }
}
