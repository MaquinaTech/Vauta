// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// Settings → Translation → "Better translations": the model server improves finished sentences, in each state.
extension SnapshotScenes {
    private static let refinementSize = CGSize(width: 1020, height: 1400)

    /// The test sentence and its (invented) translation in the interface language.
    private static func testSample(_ fixture: SnapshotFixture) -> RefinementTest.Sample {
        let sample = fixture.captionSample
        return RefinementTest.Sample(text: sample.originals[2], source: sample.pair.source, target: sample.pair.target)
    }

    private static func refinementScene(_ name: String, enabled: Bool = true, server: Bool = true, model: String = "",
                                        test: @escaping @MainActor (SnapshotFixture) -> LiveTranslationModel.RefinementTestState = { _ in .idle },
                                        status: RefinementStatus = .off) -> SnapshotScene {
        settingsScene("translation-\(name)", .translation, size: refinementSize) { recorder, fixture in
            fixture.preferences.translationRefinementEnabled = enabled
            fixture.preferences.translationModel = model
            recorder.llmStatus.serverConfigured = server
            recorder.llmStatus.models = ["qwen3.5-9b", "qwen3-30b-a3b-instruct", "text-embedding-nomic-embed-text-v1.5"]
            let live = recorder.liveTranslation
            fixture.installTranslationSettings(on: live)
            live.installSnapshotRefinementTest(test(fixture))
            live.installSnapshotRefinementStatus(status, pair: fixture.captionSample.pair)
        }
    }

    static var refinement: [SnapshotScene] {
        [
            refinementScene("refine-on"),
            refinementScene("refine-model", model: "qwen3.5-9b", status: .improved),
            refinementScene("refine-off", enabled: false),
            refinementScene("refine-no-server", server: false),
            refinementScene("test-running", test: { _ in .running }),
            refinementScene("test-ok", model: "qwen3.5-9b", test: { fixture in
                let sample = fixture.captionSample
                return .finished(RefinementTest(sample: testSample(fixture), outcome: .translated(sample.translations[2]), seconds: 1.84))
            }),
            refinementScene("test-slow", model: "qwen3-30b-a3b-instruct", test: { fixture in
                let sample = fixture.captionSample
                return .finished(RefinementTest(sample: testSample(fixture), outcome: .translated(sample.translations[2]), seconds: 5.62))
            }, status: .unavailable),
            refinementScene("test-timeout", test: { fixture in
                .finished(RefinementTest(sample: testSample(fixture), outcome: .timedOut, seconds: 20))
            }),
            refinementScene("test-failed", test: { fixture in
                .finished(RefinementTest(sample: testSample(fixture),
                                         outcome: .failed(LLMError.network(from: URLError(.cannotConnectToHost)).localizedDescription), seconds: 0.2))
            }),
        ]
    }
}
#endif
