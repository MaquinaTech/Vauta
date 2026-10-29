// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension OutputSchema {
    /// The shape as a model server's `response_format` schema: the same keys in the same order, all required and nothing else, the
    /// types and the most items of each list. It leaves out what only the integrated model's grammar needs and what a server's grammar
    /// converter handles badly: the byte caps of strings (a cap of thousands of characters becomes thousands of grammar states in
    /// llama.cpp), the closed sets of segment and person numbers (a long enumeration slows the grammar down), the date pattern and the
    /// fewest items of a list (the item floor of the integrated request). The app checks all of these in the reply anyway.
    public func serverJSONSchemaData() -> Data { Data(serverJSONSchema().utf8) }

    func serverJSONSchema() -> String {
        switch self {
        case .object(let props): return Self.serverObject(props, tag: nil)
        case .array(let item, _, let hi): return "{\"type\":\"array\",\"items\":\(item.serverJSONSchema()),\"maxItems\":\(hi)}"
        case .string, .text, .date: return "{\"type\":\"string\"}"
        case .integers, .anyInteger: return "{\"type\":\"integer\"}"
        case .enumStrings, .boolean: return orderedJSONSchema()
        case .nullable(let inner): return "{\"anyOf\":[\(inner.serverJSONSchema()),{\"type\":\"null\"}]}"
        case .tagged(let key, let cases): return "{\"anyOf\":[" + cases.map { Self.serverObject($0.rest, tag: (key, $0.value)) }.joined(separator: ",") + "]}"
        }
    }

    private static func serverObject(_ properties: [Property], tag: (key: String, word: String)?) -> String {
        var members: [String] = []
        if let tag { members.append("\(literal(tag.key)):{\"enum\":[\(tag.word)]}") }
        members += properties.map { "\(literal($0.name)):\($0.schema.serverJSONSchema())" }
        let required = (tag.map { [$0.key] } ?? []) + properties.map(\.name)
        return "{\"type\":\"object\",\"properties\":{\(members.joined(separator: ","))},\"required\":\(literal(required)),\"additionalProperties\":false}"
    }
}
