// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What every Office Open XML reader shares: part names, relationships, the core properties and the kind of package.
enum OOXML {
    /// Normalizes `target` (as written in a relationships part) against the folder of the part that owns it.
    /// Returns nil for anything that leaves the package or is not a plain path.
    static func resolve(_ target: String, from base: String) -> String? {
        guard !target.contains("://"), !target.contains("\0"), !target.contains("\\") else { return nil }
        var parts: [String] = target.hasPrefix("/") ? [] : base.split(separator: "/").map(String.init)
        for component in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(component))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    struct Relationship {
        let id: String
        let type: String
        let path: String
    }

    /// The relationships of `part` (a path inside the package), with their targets resolved.
    static func relationships(of part: String, in zip: SafeZip, limits: SafeXML.Limits = SafeXML.Limits()) throws -> [Relationship] {
        let folder = part.split(separator: "/").dropLast().joined(separator: "/")
        let name = part.split(separator: "/").last.map(String.init) ?? part
        let relsPath = (folder.isEmpty ? "" : folder + "/") + "_rels/" + name + ".rels"
        guard let data = try zip.read(relsPath, maxBytes: 4 << 20) else { return [] }
        var out: [Relationship] = []
        try SafeXML.parse(data, limits: limits, start: { element, attrs in
            guard element == "Relationship", attrs["TargetMode"] != "External",
                  let id = attrs["Id"], let target = attrs["Target"],
                  let path = resolve(target, from: folder) else { return }
            out.append(Relationship(id: id, type: attrs["Type"] ?? "", path: path))
        })
        return out
    }

    /// `docProps/core.xml` title, if any.
    static func title(in zip: SafeZip) -> String? {
        guard let data = try? zip.read("docProps/core.xml", maxBytes: 1 << 20) else { return nil }
        var inTitle = false
        var title = ""
        try? SafeXML.parse(data, start: { name, _ in if name == "title" { inTitle = true } },
                           end: { name in if name == "title" { inTitle = false } },
                           text: { if inTitle { title += $0 } })
        let clean = TextSanitizer.oneLine(title, limit: 160)
        return clean.isEmpty ? nil : clean
    }

    enum Kind { case docx, pptx, xlsx, other }

    static func kind(of zip: SafeZip) -> Kind {
        if zip.contains("word/document.xml") { return .docx }
        if zip.contains("ppt/presentation.xml") { return .pptx }
        if zip.contains("xl/workbook.xml") { return .xlsx }
        return .other
    }

    /// An encrypted Office file is not a ZIP: it is a compound (OLE) file holding an `EncryptedPackage` stream.
    static func isEncryptedCompoundFile(_ data: Data) -> Bool {
        guard data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else { return false }
        // The stream names are stored as UTF-16 in the directory.
        let marker = Data("EncryptedPackage".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        return data.range(of: marker) != nil
    }
}

/// The deadline every extractor checks between units.
struct ExtractionClock: Sendable {
    let deadline: Date

    init(seconds: TimeInterval) { deadline = Date().addingTimeInterval(seconds) }

    func check() throws {
        if Task.isCancelled { throw CancellationError() }
        if Date() > deadline { throw DocumentExtractionError(.timedOut) }
    }

    var xmlLimits: SafeXML.Limits {
        var limits = SafeXML.Limits()
        limits.deadline = deadline
        return limits
    }
}
