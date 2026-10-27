// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing

/// "Audio is never written to disk" is the app's headline promise. This scans the source of the shipped app and fails
/// when any shipped code (everything except the blocks behind `#if VAUTA_DIAGNOSTICS`, compiled out of every release) can
/// create an audio file or record to one, and when code that handles audio buffers writes raw bytes to any file.
@Suite("Audio is never written")
struct AudioNeverWrittenScanTests {
    static let forbidden: [(name: String, pattern: String)] = [
        ("AVAudioFile for writing", #"AVAudioFile\s*\(\s*forWriting"#),
        ("AVAssetWriter", #"\bAVAssetWriter\b"#),
        ("AVAudioRecorder", #"\bAVAudioRecorder\b"#),
        ("AVCaptureAudioFileOutput", #"\bAVCaptureAudioFileOutput\b"#),
        ("Audio File Services", #"\b(ExtAudioFileCreateWithURL|ExtAudioFileWrite|AudioFileCreateWithURL|AudioFileWriteBytes|AudioFileWritePackets)\b"#),
        ("AVAudioEngine file tap", #"\bAVAudioPlayerNode\b.*\bscheduleFile\b|\.write\s*\(\s*from\s*:\s*[A-Za-z_]*(buffer|Buffer)"#),
    ]

    /// Raw byte writes: they cannot be told apart from other file writes in general, so they are banned only in the code
    /// that touches audio buffers or the capture pipeline (the rest of the app writes exports, backups and the store).
    static let rawWrites: [(name: String, pattern: String)] = [
        ("Data or String written to a file", #"\.write\s*\((to|toFile|contentsOf)\b"#),
        ("FileHandle opened for writing", #"\bFileHandle\s*\(\s*for(Writing|Updating)"#),
        ("FileManager.createFile", #"\bcreateFile\s*\("#),
        ("C file writing", #"\b(fwrite|fopen|pwrite|O_WRONLY|O_RDWR|O_CREAT)\b"#),
        ("OutputStream to a file", #"\bOutputStream\s*\(\s*(url|toFileAtPath)"#),
    ]

    /// Code that handles audio buffers or captures audio: where a raw write would be audio reaching the disk.
    static func handlesAudio(path: String, text: String) -> Bool {
        let dirs = ["Sources/VautaCore/Audio/", "Sources/VautaCore/Capture/", "Sources/VautaCore/Transcription/",
                    "Sources/VautaCore/Diarization/", "Sources/VautaCore/Import/"]
        if dirs.contains(where: { path.hasPrefix($0) }) || path == "Sources/VautaCore/MeetingCapture.swift" { return true }
        if path.hasPrefix("Sources/Vauta/App/RecorderModel") { return true }
        return text.range(of: #"\b(floatChannelData|AudioBufferList|AVAudioPCMBuffer|CMSampleBuffer)\b"#, options: .regularExpression) != nil
    }

    /// The source as the shipped app sees it: the text between `#if VAUTA_DIAGNOSTICS` and its `#else` or `#endif` is
    /// removed (that build is never shipped), everything else stays, including the rest of a file that has such a block.
    static func shipped(_ source: String) -> String {
        var depth = 0          // nesting inside a diagnostics-only region (0 = shipped code)
        var inner = 0          // other #if levels opened inside it
        var out: [Substring] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if depth == 0 {
                if t.range(of: #"^#if\s+VAUTA_DIAGNOSTICS\s*$"#, options: .regularExpression) != nil { depth = 1; inner = 0; continue }
                out.append(line)
            } else if t.hasPrefix("#if") {
                inner += 1
            } else if t.hasPrefix("#endif") {
                if inner > 0 { inner -= 1 } else { depth = 0 }
            } else if t.hasPrefix("#else"), inner == 0 {
                depth = 0   // the #else branch is compiled into the release build
            }
        }
        return out.joined(separator: "\n")
    }

    static func violations(in source: String) -> [String] {
        let text = NetworkAuditSourceScanTests.code(source)
        return forbidden.filter { text.range(of: $0.pattern, options: .regularExpression) != nil }.map(\.name)
    }

    static func rawWriteViolations(in source: String) -> [String] {
        let text = NetworkAuditSourceScanTests.code(source)
        return rawWrites.filter { text.range(of: $0.pattern, options: .regularExpression) != nil }.map(\.name)
    }

    @Test func noShippedSourceCanWriteAnAudioFile() async throws {
        let (count, audioFiles, problems) = try await offPool { () -> (Int, Int, [String]) in
            let files = try NetworkAuditSourceScanTests.sourceFiles()
            var problems: [String] = []
            var audioFiles = 0
            for (path, text) in files {
                let shipped = Self.shipped(text)
                for name in Self.violations(in: shipped) { problems.append("\(path): \(name)") }
                if Self.handlesAudio(path: path, text: shipped) {
                    audioFiles += 1
                    for name in Self.rawWriteViolations(in: shipped) { problems.append("\(path): \(name)") }
                }
            }
            return (files.count, audioFiles, problems)
        }
        #expect(count > 50, "the scan must actually see the sources")
        #expect(audioFiles >= 10, "the scan must actually see the audio code")
        #expect(problems.isEmpty, "Audio must never reach the disk:\n\(problems.joined(separator: "\n"))")
    }

    @Test func aDiagnosticsBlockDoesNotExemptTheRestOfTheFile() {
        let mixed = """
            #if VAUTA_DIAGNOSTICS
            let ok = try AVAudioFile(forWriting: url, settings: s)
            #endif
            func shippedCode() throws { _ = try AVAudioFile(forWriting: other, settings: s) }
            """
        #expect(Self.violations(in: Self.shipped(mixed)).contains("AVAudioFile for writing"))
        let onlyDiagnostics = """
            #if VAUTA_DIAGNOSTICS
            #if os(macOS)
            let ok = try AVAudioFile(forWriting: url, settings: s)
            #endif
            let more = AVAssetWriter.self
            #endif
            func shipped() {}
            """
        #expect(Self.violations(in: Self.shipped(onlyDiagnostics)).isEmpty)
        let elseBranch = "#if VAUTA_DIAGNOSTICS\nlet a = 1\n#else\nlet w = try AVAssetWriter(url: u, fileType: .m4a)\n#endif"
        #expect(Self.violations(in: Self.shipped(elseBranch)).contains("AVAssetWriter"))
    }

    @Test func rawByteWritesAreFlaggedInAudioCode() {
        #expect(Self.handlesAudio(path: "Sources/Vauta/App/RecorderModel.swift", text: ""))
        #expect(Self.handlesAudio(path: "Sources/Vauta/App/X.swift", text: "let b: AVAudioPCMBuffer"))
        #expect(!Self.handlesAudio(path: "Sources/Vauta/App/Settings/BackupModel.swift", text: "data.write(to: url)"))
        #expect(Self.rawWriteViolations(in: "try Data(bytes).write(to: url, options: .atomic)").contains("Data or String written to a file"))
        #expect(Self.rawWriteViolations(in: "let h = try FileHandle(forWritingTo: u)").contains("FileHandle opened for writing"))
        #expect(Self.rawWriteViolations(in: "FileManager.default.createFile(atPath: p, contents: d)").contains("FileManager.createFile"))
        #expect(Self.rawWriteViolations(in: "let h = try FileHandle(forReadingFrom: u)").isEmpty)
    }

    @Test func detectorFlagsWritingAndIgnoresReading() {
        #expect(Self.violations(in: "let f = try AVAudioFile(forWriting: url, settings: s)").contains("AVAudioFile for writing"))
        #expect(Self.violations(in: "let w = try AVAssetWriter(url: u, fileType: .m4a)").contains("AVAssetWriter"))
        #expect(Self.violations(in: "ExtAudioFileCreateWithURL(u, kAudioFileCAFType, &fmt, nil, 0, &ref)").contains("Audio File Services"))
        #expect(Self.violations(in: "try file.write(from: pcmBuffer)").contains("AVAudioEngine file tap"))
        #expect(Self.violations(in: "let f = try AVAudioFile(forReading: url)\n// AVAssetWriter is not used").isEmpty)
    }
}
