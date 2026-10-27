// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

// The Network Activity window: empty, a normal session, filtered, with problems and
// with a destination outside the local network (which Vauta's rules never allow).

extension SnapshotScenes {
    static let networkSize = CGSize(width: 1240, height: 660)

    static func networkScene(_ name: String, size: CGSize = networkSize, entries: @escaping () -> [NetworkActivityEntry],
                                     filter: NetworkPurpose? = nil) -> SnapshotScene {
        SnapshotScene(name: "network-activity-\(name)", size: size) { _ in
            let model = NetworkActivityModel(entries: entries(), filter: filter)
            return .init(view: AnyView(NetworkActivityView(model: model, openModels: {}).background(Color(nsColor: .windowBackgroundColor))),
                         title: String(localized: "Network Activity", comment: "Window title"))
        }
    }

    /// A typical session: a local model server, probes while looking for it, and a refinement that failed.
    static func sampleNetworkEntries(outside: Bool = false, problems: Bool = true) -> [NetworkActivityEntry] {
        let base = SampleWorld.snapshotNow.addingTimeInterval(-35 * 60)
        var out: [NetworkActivityEntry] = []
        func add(_ seconds: Double, _ purpose: NetworkPurpose, _ method: String, _ url: String, sent: Int = 0, received: Int = 0,
                 status: Int? = 200, error: NetworkErrorKind? = nil, duration: Double? = 0.2) {
            out.append(NetworkActivityEntry(id: UInt64(out.count + 1), timestamp: base.addingTimeInterval(seconds), purpose: purpose,
                                            url: URL(string: url)!, method: method, bytesSent: sent, bytesReceived: received,
                                            status: status, error: error, duration: duration))
        }
        let lm = "http://127.0.0.1:1234"
        add(0, .discovery, "GET", "http://127.0.0.1:1234/v1/models", received: 1_420, duration: 0.02)
        add(0.1, .discovery, "GET", "http://127.0.0.1:11434/v1/models", status: nil, error: .unreachable, duration: 0.01)
        add(0.2, .discovery, "GET", "http://127.0.0.1:1234/api/v0/models", received: 18_300, duration: 0.03)
        add(31, .connectionTest, "GET", "\(lm)/v1/models", received: 1_420, duration: 0.04)
        add(95, .statusCheck, "GET", "\(lm)/v1/models", received: 1_420, duration: 0.03)
        add(240, .liveNotes, "POST", "\(lm)/v1/chat/completions", sent: 9_800, received: 2_150, duration: 4.1)
        add(300, .liveNotes, "POST", "\(lm)/v1/chat/completions", sent: 10_400, received: 1_960, duration: 3.8)
        add(900, .minutes, "POST", "\(lm)/v1/chat/completions", sent: 61_000, received: 14_300, duration: 48)
        add(960, .embeddings, "POST", "\(lm)/v1/embeddings", sent: 22_500, received: 131_000, duration: 1.6)
        add(1_200, .ask, "POST", "\(lm)/v1/chat/completions", sent: 15_700, received: 3_300, duration: 12.5)
        add(1_260, .translation, "POST", "\(lm)/v1/chat/completions", sent: 1_800, received: 420, duration: 2.4)
        if problems {
            add(1_270, .translation, "POST", "\(lm)/v1/chat/completions", sent: 1_750, status: nil, error: .timedOut, duration: 4)
            add(1_500, .minutes, "POST", "\(lm)/v1/chat/completions", sent: 58_000, received: 180, status: 503, duration: 0.3)
        }
        if outside {
            add(1_520, .other, "GET", "https://example.com/v1/models", received: 900, duration: 0.5)
        }
        add(1_800, .ask, "POST", "\(lm)/v1/chat/completions", sent: 16_100, status: nil, duration: nil)
        return out
    }

    /// Repeated discovery probes as one row each, and requests refused before they were sent.
    static func sampleNetworkEntriesWithRepeatsAndBlocks() -> [NetworkActivityEntry] {
        var out = sampleNetworkEntries(problems: false)
        let base = SampleWorld.snapshotNow.addingTimeInterval(-35 * 60)
        func next() -> UInt64 { UInt64(out.count + 1) }
        out.append(NetworkActivityEntry(id: next(), timestamp: base.addingTimeInterval(1_900), purpose: .discovery,
                                        url: URL(string: "http://127.0.0.1:11434/api/version")!, method: "GET", bytesSent: 0,
                                        error: .unreachable, duration: 0.01, count: 37, lastTimestamp: base.addingTimeInterval(1_974)))
        out.append(NetworkActivityEntry(id: next(), timestamp: base.addingTimeInterval(1_950), purpose: .discovery,
                                        url: URL(string: "http://127.0.0.1:1234/v1/models")!, method: "GET", bytesSent: 0,
                                        bytesReceived: 52_540, status: 200, duration: 0.02, count: 37,
                                        lastTimestamp: base.addingTimeInterval(1_974)))
        out.append(NetworkActivityEntry(id: next(), timestamp: base.addingTimeInterval(2_000), purpose: .translation,
                                        url: URL(string: "https://203.0.113.9:8443/v1/chat/completions")!, method: "POST", bytesSent: 0,
                                        duration: 0, blocked: .destinationNotAllowed))
        out.append(NetworkActivityEntry(id: next(), timestamp: base.addingTimeInterval(2_010), purpose: .ask,
                                        url: URL(string: "https://studio.local/v1/chat/completions")!, method: "POST", bytesSent: 0,
                                        duration: 0, blocked: .untrustedAddress))
        return out
    }

    /// The person clicked Download for the search model: the lookups at Hugging Face (302), the ranges from its download server
    /// (206), and a redirect to a host that is not allowed, which was blocked before anything was sent.
    static func sampleNetworkEntriesWithModelDownload() -> [NetworkActivityEntry] {
        var out = sampleNetworkEntries(problems: false)
        let base = SampleWorld.snapshotNow.addingTimeInterval(-35 * 60)
        let hf = "https://huggingface.co/google/embeddinggemma-2/resolve/914f7f89142e33e77833254d9c9b90c3cef7303b"
        let cdn = "https://us.aws.cdn.hf.co/xet-bridge-us/6aa80a7682023d2e774f1c9a/47a68c5b4bb3b43eb611ba512b8a0830e80ce08dfd"
        func add(_ seconds: Double, _ url: String, status: Int, received: Int = 0, duration: Double, blocked: NetworkBlockReason? = nil) {
            out.append(NetworkActivityEntry(id: UInt64(out.count + 1), timestamp: base.addingTimeInterval(seconds), purpose: .modelDownload,
                                            url: URL(string: url)!, method: "GET", bytesSent: 0, bytesReceived: received,
                                            status: blocked == nil ? status : nil, duration: duration, blocked: blocked))
        }
        add(2_000, "\(hf)/tokenizer.json", status: 302, duration: 0.2)
        add(2_001, "\(cdn)", status: 200, received: 32_170_510, duration: 3.1)
        add(2_005, "\(hf)/model.safetensors", status: 302, duration: 0.2)
        for block in 0..<4 { add(2_006 + Double(block) * 2, "\(cdn)", status: 206, received: 33_554_432, duration: 1.9) }
        add(2_020, "https://cdn.example.net/xet-bridge-us/6aa80a7682023d2e774f1c9a/47a68c5b4bb3b43e", status: 0, duration: 0, blocked: .destinationNotAllowed)
        return out
    }

    /// A session in which the model server also wrote the suggested agenda of two briefs ("Preparing a brief"); one of them timed out.
    static func sampleNetworkEntriesWithBriefs() -> [NetworkActivityEntry] {
        var out = sampleNetworkEntries(problems: false)
        let base = SampleWorld.snapshotNow.addingTimeInterval(-35 * 60)
        func add(_ seconds: Double, sent: Int, received: Int = 0, status: Int? = 200, error: NetworkErrorKind? = nil, duration: Double) {
            out.append(NetworkActivityEntry(id: UInt64(out.count + 1), timestamp: base.addingTimeInterval(seconds), purpose: .brief,
                                            url: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!, method: "POST", bytesSent: sent, bytesReceived: received,
                                            status: status, error: error, duration: duration))
        }
        add(2_400, sent: 4_900, received: 1_100, duration: 9.8)
        add(3_300, sent: 5_200, status: nil, error: .timedOut, duration: 90)
        return out
    }

    static var networkActivity: [SnapshotScene] {
        [
            networkScene("empty", size: CGSize(width: 1240, height: 560)) { [] },
            networkScene("session") { sampleNetworkEntries(problems: false) },
            networkScene("problems") { sampleNetworkEntries() },
            networkScene("filtered", entries: { sampleNetworkEntries() }, filter: .liveNotes),
            networkScene("repeated-and-blocked") { sampleNetworkEntriesWithRepeatsAndBlocks() },
            networkScene("filtered-blocked", entries: { sampleNetworkEntriesWithRepeatsAndBlocks() }, filter: .discovery),
            networkScene("outside") { sampleNetworkEntries(outside: true) },
            networkScene("model-download") { sampleNetworkEntriesWithModelDownload() },
            networkScene("model-download-filtered", entries: { sampleNetworkEntriesWithModelDownload() }, filter: .modelDownload),
            networkScene("brief-row") { sampleNetworkEntriesWithBriefs() },
            networkScene("brief-row-filtered", entries: { sampleNetworkEntriesWithBriefs() }, filter: .brief),
        ]
    }
}
#endif
