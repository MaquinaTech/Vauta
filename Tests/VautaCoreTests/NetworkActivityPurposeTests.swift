// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The language model's download has its own purpose in Network Activity; both model downloads are downloads.
@Suite("Network activity: the language model download")
struct NetworkActivityPurposeTests {
    @Test func theNewPurposeIsANewRawValueAndTheOldOnesStay() {
        #expect(NetworkPurpose.languageModelDownload.rawValue == "languageModelDownload")
        #expect(NetworkPurpose.modelDownload.rawValue == "modelDownload")
        #expect(NetworkPurpose.allCases.contains(.languageModelDownload))
        #expect(NetworkPurpose.modelDownload.isModelDownload && NetworkPurpose.languageModelDownload.isModelDownload && !NetworkPurpose.ask.isModelDownload)
    }

    @Test func bothDownloadsAreDownloadsAndTheirRedirectsAreTheAnswerAskedFor() async throws {
        let log = NetworkActivityLog()
        for purpose in [NetworkPurpose.modelDownload, .languageModelDownload] {
            let id = await log.begin(purpose: purpose, url: URL(string: "https://huggingface.co/google/gemma-4-E4B-it/resolve/x/model.safetensors")!, method: "GET", bytesSent: 0)
            await log.finish(id, status: 302, error: nil, bytesReceived: 0, duration: 0.1)
        }
        let entries = await log.snapshot()
        #expect(entries.allSatisfy { $0.scope == .download && $0.isSuccess && !$0.isFailure })
        let json = String(decoding: try await log.exportJSON(), as: UTF8.self)
        #expect(json.contains("\"languageModelDownload\"") && json.contains("\"modelDownload\""))
        // Another purpose to the same host is outside.
        let other = await log.begin(purpose: .ask, url: URL(string: "https://huggingface.co/x")!, method: "GET", bytesSent: 0)
        await log.finish(other, status: 200, error: nil, bytesReceived: 5, duration: 0.1)
        #expect(await log.snapshot().last?.scope == .outside)
    }
}
