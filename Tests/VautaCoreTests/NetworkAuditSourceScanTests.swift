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
        ("URLSession(...)", #"\bURLSession\s*(\.\s*init\s*)?\("#),
        ("URLSession.shared", #"\bURLSession\s*\.\s*shared\b"#),
        ("URL task", #"\.(dataTask|uploadTask|downloadTask|streamTask|webSocketTask)\s*\("#),
        ("async URL loading", #"\.(bytes|data|upload|download)\s*\(\s*(for|from)\s*:(?![^\n]*purpose:)"#),   // AuditedSession's own calls name a purpose
        // The import on any line, with an attribute, an access level or a single declaration (`import struct Network.NWEndpoint`).
        ("Network framework", #"\bNW(Connection|Browser|Listener|PathMonitor)\b"#
            + #"|(?m:^\s*(@\w+\s+)*((public|package|internal|fileprivate|private)\s+)?"#
            + #"import\s+((typealias|struct|class|enum|protocol|let|var|func)\s+)?Network\b)"#),
        ("legacy URL loading", #"\b(NSURLConnection|NSURLSession|CFHTTPMessage|CFSocket|CFReadStream|CFWriteStream|CFStreamCreatePairWithSocket)\b"#),
        ("web view", #"\bWKWebView\b"#),
        ("raw sockets", #"\b(getaddrinfo|gethostbyname)\s*\(|\bsocket\s*\(\s*(AF_|PF_)|getStreamsToHost"#),
        ("remote contents", #"contentsOf:\s*(try\??\s*)?URL\s*\(\s*string"#),
        ("child process", #"\bProcess\s*(\.\s*init\s*)?\(|\bProcess\s*\.\s*(run|launchedProcess)\s*\(|\bNSTask\b"#
            + #"|\bposix_spawnp?\s*\(|\bpopen\s*\(|\bv?fork\s*\(\s*\)|(?<![.\w])(?<!func )system\s*\("#),
        ("exec", #"\bf?exec(l|le|lp|v|ve|vp|vP|vpe)\s*\("#),
        ("XPC service", #"\bNSXPCConnection\s*\(\s*machServiceName\s*:"#),
        // Initializers and functions that load the URL they are given, a remote one too (also written `Type.init(...)`). Only these:
        // another API that loads a URL is not caught.
        ("Data(contentsOf:)", #"\b(NS)?Data\s*(\.\s*init\s*)?\(\s*contentsOf\s*:"#),
        ("String(contentsOf:)", #"\b(NS)?String\s*(\.\s*init\s*)?\(\s*contentsOf\s*:"#),
        ("NSImage(contentsOf:)", #"\bNSImage\s*(\.\s*init\s*)?\(\s*contentsOf\s*:"#),
        ("PDFDocument(url:)", #"\bPDFDocument\s*(\.\s*init\s*)?\(\s*url\s*:"#),
        ("AVURLAsset(url:)", #"\bAV(URL)?Asset\s*(\.\s*init\s*)?\(\s*url\s*:"#),
        ("AVPlayer(url:)", #"\bAV(Queue)?Player(Item)?\s*(\.\s*init\s*)?\(\s*url\s*:"#),
        ("NSAttributedString(contentsOf:)", #"\bNSAttributedString\s*(\.\s*init\s*)?\(\s*(contentsOf|url)\s*:"#),
        ("XMLParser(contentsOf:)", #"\bXMLParser\s*(\.\s*init\s*)?\(\s*contentsOf\s*:"#),
        ("NSDictionary(contentsOf:)", #"\bNS(Mutable)?(Dictionary|Array)\s*(\.\s*init\s*)?\(\s*contentsOf\s*:"#),
        ("CGImageSourceCreateWithURL", #"\bCG(ImageSource|DataProvider|PDFDocument)CreateWithURL\s*\("#
            + #"|\bCGDataProvider\s*(\.\s*init\s*)?\(\s*url\s*:|\bCGPDFDocument\s*(\.\s*init\s*)?\("#),
        // `.init(contentsOf:)` or `.init(url:)` with the type left to inference: any of the above.
        ("implicit .init(contentsOf:)", #"(?<![\w)\].?!>])\.\s*init\s*\(\s*(contentsOf|url)\s*:"#),
    ]

    /// `forbidden`, compiled once. A pattern that does not compile is left out, and `everyPatternCompiles` fails.
    static let compiled: [(name: String, regex: NSRegularExpression)] = forbidden.compactMap { name, pattern in
        (try? NSRegularExpression(pattern: pattern)).map { (name, $0) }
    }

    /// Flagged calls that never leave this Mac, with how many each file has: a new call in one of these files is flagged again, and
    /// an entry the code no longer matches fails too. Each says why its URL is a local file.
    static let localUses: [(path: String, name: String, count: Int)] = [
        // The encrypted store: the snapshots in the store folder (current and legacy name, checked before a migration).
        ("Sources/VautaCore/Storage/StoreFiles.swift", "Data(contentsOf:)", 3),
        // The journal next to the snapshot.
        ("Sources/VautaCore/Storage/Journal.swift", "Data(contentsOf:)", 1),
        // The snapshot the store opens, in the store folder.
        ("Sources/VautaCore/Storage/MeetingStore.swift", "Data(contentsOf:)", 1),
        // The snapshot just written by a restore, read back from the store folder.
        ("Sources/VautaCore/Backup/MeetingStore+Backup.swift", "Data(contentsOf:)", 2),
        // The backup file the person chose in a file panel.
        ("Sources/Vauta/App/Settings/BackupModel.swift", "Data(contentsOf:)", 1),
        // The documents index (`vauta.docs.enc`) in the store folder.
        ("Sources/VautaCore/Documents/DocumentIndex.swift", "Data(contentsOf:)", 1),
        // The indexer's crash marker in the store folder.
        ("Sources/VautaCore/Documents/DocumentIndexer.swift", "Data(contentsOf:)", 1),
        // A PDF the person added as a document source (a file on this Mac, by bookmark).
        ("Sources/VautaCore/Documents/PDFExtractor.swift", "PDFDocument(url:)", 2),
        // An RTF or Word file the person added as a document source.
        ("Sources/VautaCore/Documents/TextExtractors.swift", "NSAttributedString(contentsOf:)", 1),
        // The PDF of a passage, from a document source.
        ("Sources/Vauta/App/Documents/PassageViewer.swift", "PDFDocument(url:)", 1),
        // An image the person added as a document source: its size and its pixels, for its text and for a passage's view.
        ("Sources/VautaCore/Documents/VisionOCR.swift", "CGImageSourceCreateWithURL", 2),
        // The audio file the person chose to import.
        ("Sources/VautaCore/Import/RecordingTranscriber.swift", "AVURLAsset(url:)", 1),
        ("Sources/VautaCore/Import/AudioFileDecoder.swift", "AVURLAsset(url:)", 1),
        // The search model's install record, in the models folder of the app's container.
        ("Sources/VautaCore/SearchModel/SearchModelStore.swift", "Data(contentsOf:)", 1),
        // A downloaded model's tokenizer, in the models folder.
        ("Sources/VautaCore/SearchModel/GemmaTokenizer.swift", "Data(contentsOf:)", 1),
        // The integrated model's install record, in the models folder.
        ("Sources/VautaCore/LanguageModel/LanguageModelStore.swift", "Data(contentsOf:)", 1),
        // The integrated model's progress journal, in the staging folder of the models folder.
        ("Sources/VautaCore/LanguageModel/LanguageModelDownloader.swift", "Data(contentsOf:)", 1),
        ("Sources/VautaCore/LanguageModel/LanguageModelController.swift", "Data(contentsOf:)", 1),
        // A downloaded model's weights, mapped from the models folder.
        ("Sources/VautaMLX/SafetensorsFile.swift", "Data(contentsOf:)", 1),
        // The golden files of `llm-selftest --goldens`, a folder given as a path.
        ("Sources/VautaCore/LanguageModel/LanguageModelSelfTest.swift", "String(contentsOf:)", 1),
        // Evaluation inputs given as paths on the command line (`URL(fileURLWithPath:)`).
        ("Sources/VautaCore/Diagnostics/BriefEvaluation.swift", "String(contentsOf:)", 1),
        ("Sources/VautaCore/Diagnostics/LLMEvaluation+LiveAnswers.swift", "String(contentsOf:)", 1),
        ("Sources/VautaCore/Diagnostics/LLMEvaluation+Notes.swift", "String(contentsOf:)", 2),
        ("Sources/VautaCore/Diagnostics/LLMEvaluation+AskRetrieval.swift", "String(contentsOf:)", 1),
        // The configuration file of `server-check`, given as a path.
        ("Sources/Vauta/CLI+Doctor.swift", "Data(contentsOf:)", 1),
        // The configuration file of `llm-eval --server`, given as a path.
        ("Sources/Vauta/CLI+LanguageModel.swift", "Data(contentsOf:)", 1),
        // The certificate files chosen in a file panel (Settings › Models).
        ("Sources/Vauta/App/Settings/ModelsSettingsModel.swift", "Data(contentsOf:)", 2),
        // UI snapshots (a developer tool): a PDF it just wrote to the temporary folder.
        ("Sources/Vauta/Snapshots/SnapshotScenesNotepad.swift", "PDFDocument(url:)", 1),
        // UI snapshots: the snapshot app relaunches itself (`execv` of its own binary) to change the interface language.
        ("Sources/Vauta/Snapshots/RenderUICommand.swift", "exec", 1),
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

    /// How many times each forbidden construct appears in the code of `source`.
    static func occurrences(in source: String) -> [String: Int] {
        let text = code(source)
        let range = NSRange(text.startIndex..., in: text)
        var counts: [String: Int] = [:]
        for (name, regex) in compiled {
            let matches = regex.numberOfMatches(in: text, range: range)
            if matches > 0 { counts[name] = matches }
        }
        return counts
    }

    /// The names of the forbidden constructs found in `source`.
    static func violations(in source: String) -> [String] {
        let counts = occurrences(in: source)
        return forbidden.map(\.name).filter { counts[$0] != nil }
    }

    /// The forbidden constructs in the file at `path` that its local uses do not account for.
    static func violations(in source: String, at path: String) -> [String] { violations(counts: occurrences(in: source), at: path) }

    /// The same, from the file's `occurrences`.
    static func violations(counts: [String: Int], at path: String) -> [String] {
        forbidden.map(\.name).filter { name in
            (counts[name] ?? 0) > (localUses.first { $0.path == path && $0.name == name }?.count ?? 0)
        }
    }

    /// The entries of `uses` that `files` (each with its `occurrences`) no longer match: a file with fewer calls than its entry
    /// allows, or no such file.
    static func stale(_ files: [(path: String, counts: [String: Int])],
                      uses: [(path: String, name: String, count: Int)] = localUses) -> [String] {
        var stale: [String] = []
        for (path, counts) in files {
            for use in uses where use.path == path && (counts[use.name] ?? 0) < use.count {
                stale.append("\(path): \(use.name) is allowed \(use.count) times, found \(counts[use.name] ?? 0)")
            }
        }
        let paths = Set(files.map(\.path))
        for use in uses where !paths.contains(use.path) { stale.append("\(use.path): no such file") }
        return stale
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
        let (count, problems, stale) = try await offPool { () -> (Int, [String], [String]) in
            let files = try Self.sourceFiles().filter { $0.path != Self.chokePoint }.map { ($0.path, Self.occurrences(in: $0.text)) }
            let problems = files.flatMap { path, counts in Self.violations(counts: counts, at: path).map { "\(path): \($0)" } }
            return (files.count, problems, Self.stale(files))
        }
        #expect(count > 50, "the scan must actually see the sources")
        #expect(problems.isEmpty, """
            Network access outside \(Self.chokePoint) bypasses the Network Activity log. \
            Route the request through AuditedSession instead (a call that only reads a local file goes in localUses, saying why):
            \(problems.joined(separator: "\n"))
            """)
        #expect(stale.isEmpty, "localUses no longer matches the code; update the entry:\n\(stale.joined(separator: "\n"))")
    }

    @Test func theScanSeesTheChokePoint() async throws {
        let found = try await offPool { () -> (choke: String, journal: String)? in
            let files = try Self.sourceFiles()
            guard let choke = files.first(where: { $0.path == Self.chokePoint }),
                  let journal = files.first(where: { $0.path == "Sources/VautaCore/Storage/Journal.swift" }) else { return nil }
            return (choke.text, journal.text)
        }
        let sources = try #require(found)
        #expect(Self.violations(in: sources.choke).contains("URLSession(...)"))
        // The same code anywhere else is a bypass.
        #expect(Self.violations(in: sources.choke, at: "Sources/VautaCore/Network/LLMClient.swift").contains("URLSession(...)"))
        // A file's local uses excuse only the calls they count, of the kinds they name.
        #expect(Self.violations(in: sources.journal, at: "Sources/VautaCore/Storage/Journal.swift").isEmpty)
        #expect(Self.violations(in: sources.journal + "\nlet more = try Data(contentsOf: remote)", at: "Sources/VautaCore/Storage/Journal.swift")
                == ["Data(contentsOf:)"])
        #expect(Self.violations(in: sources.journal + "\nlet d = PDFDocument(url: remote)", at: "Sources/VautaCore/Storage/Journal.swift")
                == ["PDFDocument(url:)"])
        #expect(Self.violations(in: sources.journal, at: "Sources/VautaCore/Storage/Other.swift") == ["Data(contentsOf:)"])
        // An entry the code no longer matches is stale: the call is gone, or the file moved.
        let journal = "Sources/VautaCore/Storage/Journal.swift"
        let uses = Self.localUses.filter { $0.path == journal }
        let withoutTheCall = sources.journal.replacingOccurrences(of: "Data(contentsOf: url)", with: "Data()")
        #expect(withoutTheCall != sources.journal)
        #expect(Self.stale([(journal, Self.occurrences(in: sources.journal))], uses: uses).isEmpty)
        #expect(Self.stale([(journal, Self.occurrences(in: withoutTheCall))], uses: uses)
                == ["\(journal): Data(contentsOf:) is allowed 1 times, found 0"])
        #expect(Self.stale([("Sources/VautaCore/Storage/Moved.swift", Self.occurrences(in: sources.journal))], uses: uses)
                == ["\(journal): no such file"])
    }

    @Test func everyPatternCompiles() {
        #expect(Self.compiled.map(\.name) == Self.forbidden.map(\.name))
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
            "exec": "execv(path, argv)",
            "XPC service": "let c = NSXPCConnection(machServiceName: \"com.example.helper\")",
            "Data(contentsOf:)": "let d = try Data(contentsOf: url)",
            "String(contentsOf:)": "let s = try String(contentsOf: url, encoding: .utf8)",
            "NSImage(contentsOf:)": "let i = NSImage(contentsOf: url)",
            "PDFDocument(url:)": "let p = PDFDocument(url: url)",
            "AVURLAsset(url:)": "let a = AVURLAsset(url: url)",
            "NSAttributedString(contentsOf:)": "let s = try NSAttributedString(url: url, options: [:], documentAttributes: nil)",
            "XMLParser(contentsOf:)": "let p = XMLParser(contentsOf: url)",
            "AVPlayer(url:)": "let p = AVPlayer(url: url)",
            "NSDictionary(contentsOf:)": "let d = NSDictionary(contentsOf: url)",
            "CGImageSourceCreateWithURL": "let s = CGImageSourceCreateWithURL(url as CFURL, nil)",
            "implicit .init(contentsOf:)": "let d: Data = try .init(contentsOf: url)",
        ]
        for (name, source) in samples { #expect(Self.violations(in: source).contains(name), "\(name) not detected") }
        #expect(Self.violations(in: "let p = Process()").contains("child process"))
        for source in ["import Network", "import Foundation\nimport Network", "internal import Network", "@preconcurrency import Network",
                       "@_implementationOnly import Network", "import struct Network.NWEndpoint"] {
            #expect(Self.violations(in: source).contains("Network framework"), "\(source)")
        }
        let variants: [(String, String)] = [
            ("URLSession(...)", "let s = URLSession.init(configuration: .default)"),
            ("child process", "let p = Process.init()"),
            ("child process", "let p = Process(); p.executableURL = tool"),
            ("child process", "try Process.run(tool, arguments: [\"-c\"])"),
            ("child process", "let p = Process.launchedProcess(launchPath: path, arguments: [])"),
            ("child process", "let f = popen(\"ls\", \"r\")"),
            ("child process", "posix_spawn(&pid, path, nil, nil, argv, environ)"),
            ("child process", "posix_spawnp(&pid, \"curl\", nil, nil, argv, environ)"),
            ("child process", "if fork() == 0 { }"),
            ("child process", "let pid = vfork()"),
            ("exec", "execve(path, argv, envp)"),
            ("exec", "execvp(\"curl\", argv)"),
            ("exec", "execl(path, path, nil)"),
            ("exec", "fexecve(fd, argv, envp)"),
            ("Data(contentsOf:)", "let d = NSData(contentsOf: url)"),
            ("String(contentsOf:)", "let s = try NSString(contentsOf: url, encoding: 4)"),
            ("AVURLAsset(url:)", "let a = AVAsset(url: url)"),
            ("NSAttributedString(contentsOf:)", "let s = try NSAttributedString(contentsOf: url, documentAttributes: nil)"),
            ("Data(contentsOf:)", "let d = try Data.init(contentsOf: url)"),
            ("String(contentsOf:)", "let s = try String.init(contentsOf: url, encoding: .utf8)"),
            ("PDFDocument(url:)", "let p = PDFDocument.init(url: url)"),
            ("AVPlayer(url:)", "let i = AVPlayerItem(url: url)"),
            ("AVPlayer(url:)", "let q = AVQueuePlayer(url: url)"),
            ("NSDictionary(contentsOf:)", "let a = NSArray(contentsOf: url)"),
            ("NSDictionary(contentsOf:)", "let d = try NSDictionary(contentsOf: url, error: ())"),
            ("CGImageSourceCreateWithURL", "let p = CGDataProviderCreateWithURL(url as CFURL)"),
            ("CGImageSourceCreateWithURL", "let p = CGDataProvider(url: url as CFURL)"),
            ("CGImageSourceCreateWithURL", "let d = CGPDFDocument(url as CFURL)"),
            ("implicit .init(contentsOf:)", "load(try .init(url: url))"),
        ]
        for (name, source) in variants { #expect(Self.violations(in: source).contains(name), "\(source)") }
        // Ordinary code and comments are not flagged.
        #expect(Self.violations(in: "let m = ChatMessage.system(text)\ntry await session.bytes(for: r, purpose: .ask)").isEmpty)
        #expect(Self.violations(in: "// URLSession(configuration:) is only in AuditedSession").isEmpty)
        #expect(Self.violations(in: "let u = URL(string: \"http://127.0.0.1/\")!\nfunc f(_ s: URLSession.AuthChallengeDisposition) {}").isEmpty)
        #expect(Self.violations(in: """
            let cores = ProcessInfo.processInfo.activeProcessorCount
            try db.execute("BEGIN")
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let data = try Data(contentsOfFile: path)
            let c = NSXPCConnection(serviceName: "local.vauta.helper")
            let p = RecordingProcess(url: url)
            let r = RecordingProcess.init(url: url)
            let i = CGImageSourceCreateWithData(data as CFData, nil)
            let n = ProcessInfo.processInfo.processName
            // the MLX build is a fork (it compiles its kernels)
            """).isEmpty)
    }
}
