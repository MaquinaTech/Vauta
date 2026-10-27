// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A SAX reader for the XML inside Office files, with the limits a hostile file needs.
///
/// - No DTD at all: a `<!DOCTYPE` or `<!ENTITY` anywhere aborts before parsing (so no external entity is ever read and
///   no entity can expand: XXE and "billion laughs" are impossible). Office never needs one.
/// - External entities are never resolved.
/// - Depth is capped at 256, the total number of elements at 4 million, the text of the entry at 8 million characters,
///   and the parse stops at a deadline.
/// - Element names are reported without their namespace prefix (`w:p` is `p`), so the readers do not depend on the
///   prefix a producer chose. Attribute names keep theirs (`r:id` and `id` differ): use `Attributes.value(_:)`.
public final class SafeXML: NSObject, XMLParserDelegate {
    public struct Limits: Sendable {
        public var maxDepth = 256
        public var maxElements = 4_000_000
        public var maxTextCharacters = 8_000_000
        public var maxAttributeCharacters = 4_096
        public var deadline: Date?
        public init() {}
    }

    public typealias Attributes = [String: String]

    private let onStart: (_ name: String, _ attributes: Attributes) -> Void
    private let onEnd: (_ name: String) -> Void
    private let onText: (_ text: String) -> Void
    private let limits: Limits
    private var depth = 0
    private var elements = 0
    private var characters = 0
    private var failure: DocumentExtractionError?
    private weak var parser: XMLParser?

    private init(limits: Limits, onStart: @escaping (String, Attributes) -> Void, onEnd: @escaping (String) -> Void,
                 onText: @escaping (String) -> Void) {
        self.limits = limits
        self.onStart = onStart
        self.onEnd = onEnd
        self.onText = onText
    }

    /// Parses `data`, calling the closures in document order. Throws `.unreadable` for malformed or hostile XML.
    public static func parse(_ data: Data, limits: Limits = Limits(),
                             start: @escaping (_ name: String, _ attributes: Attributes) -> Void,
                             end: @escaping (_ name: String) -> Void = { _ in },
                             text: @escaping (_ text: String) -> Void = { _ in }) throws {
        // Office writes UTF-8: any other encoding (UTF-16 or UTF-32, which would hide `<!DOCTYPE` from the byte search below) is refused.
        guard isPlainASCIIStart(data) else { throw DocumentExtractionError(.unreadable) }
        // A DTD is never needed and is where every XML attack lives.
        if contains(data, "<!DOCTYPE") || contains(data, "<!ENTITY") || contains(data, "<!doctype") {
            throw DocumentExtractionError(.unreadable)
        }
        let reader = SafeXML(limits: limits, onStart: start, onEnd: end, onText: text)
        let parser = XMLParser(data: data)
        reader.parser = parser
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        if let failure = reader.failure { throw failure }
        guard ok else { throw DocumentExtractionError(.unreadable) }
    }

    /// The entry starts with `<` (after a UTF-8 byte order mark and white space) followed by an ASCII byte, and its XML declaration
    /// does not announce a wide encoding.
    static func isPlainASCIIStart(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(256))
        var i = 0
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 }
        guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "<"), bytes[i + 1] != 0 else { return false }
        let head = String(decoding: bytes, as: UTF8.self).lowercased()
        if let range = head.range(of: "encoding") {
            let rest = head[range.upperBound...].prefix(30)
            if rest.contains("16") || rest.contains("32") || rest.contains("ucs") { return false }
        }
        return true
    }

    private static func contains(_ data: Data, _ needle: String) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }

    private func abort(_ reason: DocumentSkipReason = .unreadable) {
        if failure == nil { failure = DocumentExtractionError(reason) }
        parser?.abortParsing()
    }

    static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    // MARK: XMLParserDelegate

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                       attributes attributeDict: [String: String] = [:]) {
        depth += 1
        elements += 1
        if depth > limits.maxDepth || elements > limits.maxElements { return abort() }
        if elements & 0x3FFF == 0, let deadline = limits.deadline, Date() > deadline { return abort(.timedOut) }
        var attributes: Attributes = [:]
        for (key, value) in attributeDict {
            guard value.count <= limits.maxAttributeCharacters else { continue }
            attributes[key] = value
        }
        onStart(Self.localName(elementName), attributes)
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
        onEnd(Self.localName(elementName))
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        characters += string.utf16.count
        if characters > limits.maxTextCharacters { return abort(.tooLarge) }
        onText(string)
    }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        characters += CDATABlock.count
        if characters > limits.maxTextCharacters { return abort(.tooLarge) }
        onText(String(decoding: CDATABlock, as: UTF8.self))
    }

    public func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { abort() }
    public func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { abort() }
    public func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?,
                       notationName: String?) { abort() }
    public func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { abort() }
    public func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String,
                       type: String?, defaultValue: String?) { abort() }
    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil { failure = DocumentExtractionError(.unreadable) }
    }
}

extension Dictionary where Key == String, Value == String {
    /// The value of an attribute by its local name: `val` finds `w:val` and `val`.
    public func value(_ local: String) -> String? {
        if let exact = self[local] { return exact }
        return first { $0.key.hasSuffix(":" + local) }?.value
    }

    /// The value of the namespaced form only (`r:id`, never plain `id`).
    public func prefixed(_ local: String) -> String? {
        first { $0.key.hasSuffix(":" + local) }?.value
    }
}
