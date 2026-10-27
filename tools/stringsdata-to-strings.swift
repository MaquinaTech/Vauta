// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
//
// Turns the `.stringsdata` files the Swift compiler writes with `-emit-localized-strings`
// into the English source table, Resources/en.lproj/Localizable.strings.
//
// The compiler records every literal passed where Foundation or SwiftUI expects a
// localizable string (LocalizedStringKey, LocalizedStringResource, String(localized:)),
// with interpolations already turned into format specifiers ("\(count) meetings" ->
// "%lld meetings") and the `comment:` given in the code. Keys are the English text and
// the English value is the key itself, except for the few context keys that need a
// `defaultValue:` because the same English word must translate differently.
//
// Keys defined in Localizable.stringsdict (plurals) are left out of Localizable.strings:
// the .stringsdict entry is what macOS uses for them.
//
//   swift tools/stringsdata-to-strings.swift <build-dir> <en.lproj-dir>
//
// Exits 1 when a string uses a table other than Localizable, or when Localizable.stringsdict
// has keys the code no longer uses.

import Foundation

struct Entry {
    var value: String?
    var comments: Set<String> = []
    var locations: [String] = []
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: stringsdata-to-strings.swift <build-dir> <en.lproj-dir>") }
let inputDir = URL(fileURLWithPath: args[1], isDirectory: true)
let outputDir = URL(fileURLWithPath: args[2], isDirectory: true)
let root = FileManager.default.currentDirectoryPath + "/"

// Searched recursively: depending on the build system the compiler writes them to the
// requested directory or next to the object files.
let files = (FileManager.default.enumerator(at: inputDir, includingPropertiesForKeys: nil)?
    .compactMap { $0 as? URL } ?? [])
    .filter { $0.pathExtension == "stringsdata" }
    .sorted { $0.path < $1.path }
guard !files.isEmpty else { fail("no .stringsdata files in \(inputDir.path)") }

var entries: [String: Entry] = [:]
var problems: [String] = []
var seenSources: Set<String> = []
for file in files {
    guard let data = try? Data(contentsOf: file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tables = json["tables"] as? [String: [[String: Any]]]
    else { fail("cannot read \(file.lastPathComponent)") }
    let source = (json["source"] as? String ?? file.lastPathComponent).replacingOccurrences(of: root, with: "")
    // The same source can be reported twice (both locations); count it once.
    guard seenSources.insert(source).inserted else { continue }
    for (table, items) in tables {
        for item in items {
            guard let key = item["key"] as? String else { continue }
            let line = (item["location"] as? [String: Any])?["startingLine"] as? Int ?? 0
            guard table == "Localizable" else {
                problems.append("\(source):\(line): \"\(key)\" uses table \"\(table)\"; use Localizable")
                continue
            }
            var entry = entries[key, default: Entry()]
            // A context key (String(localized: "state.recording", defaultValue: "Recording")) carries
            // its English text as the value; otherwise the key is the English text.
            let value = item["value"] as? String ?? key
            if let previous = entry.value, previous != value {
                problems.append("\(source):\(line): \"\(key)\" has two English values: \"\(previous)\" and \"\(value)\"")
            }
            entry.value = value
            if let comment = item["comment"] as? String, !comment.isEmpty { entry.comments.insert(comment) }
            entry.locations.append("\(source):\(line)")
            entries[key] = entry
        }
    }
}

// Plural keys live in the .stringsdict only.
var pluralKeys: Set<String> = []
let stringsdict = outputDir.appendingPathComponent("Localizable.stringsdict")
if let data = try? Data(contentsOf: stringsdict) {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { fail("\(stringsdict.path) is not a valid property list") }
    pluralKeys = Set(plist.keys)
    for key in pluralKeys.sorted() where entries[key] == nil {
        problems.append("Localizable.stringsdict: \"\(key)\" is not used in the code any more")
    }
}

func escaped(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default: out.unicodeScalars.append(ch)
        }
    }
    return out
}

func commentText(_ comments: Set<String>) -> String {
    let text = comments.isEmpty ? "No comment provided by engineer." : comments.sorted().joined(separator: "\n   ")
    return text.replacingOccurrences(of: "*/", with: "* /")
}

var out = """
/* SPDX-License-Identifier: Apache-2.0
   SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
   English source strings. Generated by scripts/extract-strings.sh from the code: do not edit
   by hand; change the text or its comment in the code and run the script again.
   Plural strings are in Localizable.stringsdict. */


"""
var written = 0
var uncommented = 0
for key in entries.keys.sorted() where !pluralKeys.contains(key) {
    let entry = entries[key]!
    if entry.comments.isEmpty { uncommented += 1 }
    out += "/* \(commentText(entry.comments)) */\n\"\(escaped(key))\" = \"\(escaped(entry.value ?? key))\";\n\n"
    written += 1
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let target = outputDir.appendingPathComponent("Localizable.strings")
do {
    try Data(out.utf8).write(to: target, options: .atomic)
} catch {
    fail("cannot write \(target.path): \(error.localizedDescription)")
}
print("Wrote \(written) strings to \(target.path) (\(pluralKeys.count) plural keys in Localizable.stringsdict, \(uncommented) strings without a translator comment).")

if !problems.isEmpty {
    for problem in problems { FileHandle.standardError.write(Data("ERROR: \(problem)\n".utf8)) }
    exit(1)
}
