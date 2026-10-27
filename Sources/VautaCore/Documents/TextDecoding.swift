// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Bytes to text for plain text, Markdown, CSV and HTML.
///
/// 1. A byte order mark (UTF-8, UTF-16 or UTF-32).
/// 2. Strict UTF-8.
/// 3. The encoding macOS detects, among the usual legacy ones, without lossy conversion.
/// 4. A NUL byte in the first 8 KB (outside UTF-16 and UTF-32) means the file is binary: not text.
public enum TextDecoding {
    static let candidateEncodings: [String.Encoding] = [
        .windowsCP1252, .isoLatin1, .macOSRoman, .shiftJIS, .japaneseEUC,
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
        .windowsCP1251,
    ]

    /// The decoded, unsanitized text, or nil for binary data.
    public static func decode(_ data: Data, hint: String.Encoding? = nil) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return String(data: data, encoding: .utf32LittleEndian) }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return String(data: data, encoding: .utf32BigEndian) }
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian) }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian) }
        if data.prefix(8192).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let hint, let text = String(data: data, encoding: hint) { return text }
        var converted: NSString?
        var lossy = ObjCBool(false)
        let detected = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: candidateEncodings.map { NSNumber(value: $0.rawValue) },
            .allowLossyKey: false,
            .useOnlySuggestedEncodingsKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        if detected != 0, !lossy.boolValue, let converted { return converted as String }
        return nil
    }

    /// The encoding a document names in a `<meta charset>` (or `http-equiv`) near its top.
    public static func declaredHTMLEncoding(_ data: Data) -> String.Encoding? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        guard let range = head.range(of: "charset=") else { return nil }
        let rest = head[range.upperBound...].drop { $0 == "\"" || $0 == "'" || $0 == " " }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" || $0 == "." }
        guard !name.isEmpty else { return nil }
        let cf = CFStringConvertIANACharSetNameToEncoding(String(name) as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}
