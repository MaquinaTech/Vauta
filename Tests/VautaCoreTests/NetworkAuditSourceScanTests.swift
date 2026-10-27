// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing

/// The audit is only worth anything if nothing can bypass it. This scans every
/// source file and fails when a file other than the choke point can reach the network.
@Suite("Network audit: no bypass")
struct NetworkAuditSourceScanTests {
    /// The only file allowed to create sessions, start tasks or open sockets.
    static let chokePoint = "Sources/VautaCore/Network/AuditedSession.swift"

    /// Ways to reach the network (checked on code, not comments).
    static let forbidden: [(name: String, pattern: String)] = [
        ("URLSession(...)", #"\bURLSession\s*\("#),
        ("URLSession.shared", #"\bURLSession\s*\.\s*shared\b"#),
        ("URL task", #"\.(dataTask|uploadTask|downloadTask|streamTask|webSocketTask)\s*\("#),
        ("async URL loading", #"\.(bytes|data|upload|download)\s*\(\s*(for|from)\s*:(?![^\n]*purpose:)"#),   // AuditedSession's own calls name a purpose
        ("Network framework", #"\bNW(Connection|Browser|Listener|PathMonitor)\b|^\s*(@\w+\s+)?import\s+Network\b"#),
        ("legacy URL loading", #"\b(NSURLConnection|NSURLSession|CFHTTPMessage|CFSocket|CFReadStream|CFWriteStream|CFStreamCreatePairWithSocket)\b"#),
        ("web view", #"\bWKWebView\b"#),
        ("raw sockets", #"\b(getaddrinfo|gethostbyname)\s*\(|\bsocket\s*\(\s*(AF_|PF_)|getStreamsToHost"#),
        ("remote contents", #"contentsOf:\s*(try\??\s*)?URL\s*\(\s*string"#),
        ("child process", #"\bProcess\s*\(\s*\)|\bNSTask\b|\bposix_spawn\s*\(|(?<![.\w])(?<!func )system\s*\("#),
    ]

    static func packageRoot(from file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The code of a Swift file without `//` comments (a `//` inside a URL literal is kept).
    static func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.contains("//"), let range = line.range(of: #"(?<![:"\\])//.*$"#, options: .regularExpression) else { return String(line) }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")
    }

    /// The names of the forbidden constructs found in `source`.
    static func violations(in source: String) -> [String] {
        let text = code(source)
        return forbidden.filter { text.range(of: $0.pattern, options: .regularExpression) != nil }.map(\.name)
    }

    static func sourceFiles() throws -> [(path: String, text: String)] {
        let root = packageRoot()
        let dir = root.appending(path: "Sources")
        let walker = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            out.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    @Test func onlyTheChokePointReachesTheNetwork() async throws {
        let (count, problems) = try await offPool { () -> (Int, [String]) in
            let files = try Self.sourceFiles()
            var problems: [String] = []
            for (path, text) in files where path != Self.chokePoint {
                for name in Self.violations(in: text) { problems.append("\(path): \(name)") }
            }
            return (files.count, problems)
        }
        #expect(count > 50, "the scan must actually see the sources")
        #expect(problems.isEmpty, """
            Network access outside \(Self.chokePoint) bypasses the Network Activity log. \
            Route the request through AuditedSession instead:
            \(problems.joined(separator: "\n"))
            """)
    }

    @Test func theScanSeesTheChokePoint() async throws {
        let found = try await offPool { () -> [String]? in
            try Self.sourceFiles().first { $0.path == Self.chokePoint }.map { Self.violations(in: $0.text) }
        }
        let violations = try #require(found)
        #expect(violations.contains("URLSession(...)"))
    }

    @Test func detectorFlagsEveryKindOfBypass() {
        let samples: [String: String] = [
            "URLSession(...)": "let s = URLSession(configuration: .ephemeral)",
            "URLSession.shared": "try await URLSession.shared.data(from: u)",
            "URL task": "session.dataTask(with: r).resume()",
            "async URL loading": "let (d, _) = try await s.data(for: request)",
            "child process": "system(\"curl x\")",
            "Network framework": "let c = NWConnection(host: h, port: p, using: .tcp)",
            "legacy URL loading": "let c = NSURLConnection()",
            "web view": "let v = WKWebView()",
            "raw sockets": "let fd = socket(AF_INET, SOCK_STREAM, 0)",
            "remote contents": "let d = try Data(contentsOf: URL(string: \"https://x.test\")!)",
        ]
        for (name, source) in samples { #expect(Self.violations(in: source).contains(name), "\(name) not detected") }
        #expect(Self.violations(in: "let p = Process()").contains("child process"))
        #expect(Self.violations(in: "import Network").contains("Network framework"))
        // Ordinary code and comments are not flagged.
        #expect(Self.violations(in: "let m = ChatMessage.system(text)\ntry await session.bytes(for: r, purpose: .ask)").isEmpty)
        #expect(Self.violations(in: "// URLSession(configuration:) is only in AuditedSession").isEmpty)
        #expect(Self.violations(in: "let u = URL(string: \"http://127.0.0.1/\")!\nfunc f(_ s: URLSession.AuthChallengeDisposition) {}").isEmpty)
    }
}
