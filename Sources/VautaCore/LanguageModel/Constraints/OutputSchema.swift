// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The shape of a JSON value that a model may write, in the subset Vauta's outputs use: objects with fixed keys in a fixed order
/// (all required, nothing else), arrays with a length range, strings with a byte cap, closed sets of strings or integers,
/// integers, `YYYY-MM-DD` dates, booleans and `null` alternatives. `SchemaGrammar` turns it into a decoding constraint, and
/// `jsonSchema` renders the same shape as JSON Schema (also usable later as a server `responseFormat`).
public indirect enum OutputSchema: Sendable, Equatable {
    public struct Property: Sendable, Equatable {
        public let name: String
        public let schema: OutputSchema
        public init(_ name: String, _ schema: OutputSchema) {
            self.name = name
            self.schema = schema
        }
    }

    case object([Property])
    case array(OutputSchema, min: Int, max: Int)
    /// Free text: at most `maxBytes` bytes of UTF-8 inside the quotes (escapes count by their bytes).
    case string(maxBytes: Int)
    /// Free text of at least `minBytes` and at most `maxBytes` bytes (a text that cannot be empty).
    case text(minBytes: Int, maxBytes: Int)
    case enumStrings([String])
    case integers(Set<Int>)
    case anyInteger(maxDigits: Int)
    case date
    case boolean
    case nullable(OutputSchema)
    /// An object whose first key holds one of a few JSON words (`true`, `false`) and whose other properties depend on the word:
    /// `{"key": <word>, <the properties of that word's case>}`. Used where one field decides what the rest must look like (an
    /// answer that was found needs claims; one that was not has none).
    case tagged(key: String, cases: [TaggedCase])

    public struct TaggedCase: Sendable, Equatable {
        /// A JSON word written as is: `true`, `false`, or a quoted string such as `"yes"`.
        public let value: String
        public let rest: [Property]
        public init(_ value: String, _ rest: [Property]) {
            self.value = value
            self.rest = rest
        }
    }

    /// The value a tagged word stands for in JSON Schema: a boolean for `true` and `false`, else the string without its quotes.
    static func wordValue(_ word: String) -> Any {
        if word == "true" || word == "false" { return word == "true" }
        return word.hasPrefix("\"") && word.hasSuffix("\"") && word.count >= 2 ? String(word.dropFirst().dropLast()) : word
    }

    /// The JSON Schema of this shape.
    public var jsonSchema: Any {
        switch self {
        case .object(let props):
            return ["type": "object", "properties": Dictionary(uniqueKeysWithValues: props.map { ($0.name, $0.schema.jsonSchema) }),
                    "required": props.map(\.name), "additionalProperties": false] as [String: Any]
        case .array(let item, let lo, let hi): return ["type": "array", "items": item.jsonSchema, "minItems": lo, "maxItems": hi] as [String: Any]
        case .string(let n): return ["type": "string", "maxLength": n] as [String: Any]
        case .text(let lo, let hi): return ["type": "string", "minLength": lo, "maxLength": hi] as [String: Any]
        case .enumStrings(let values): return ["type": "string", "enum": values.sorted()] as [String: Any]
        case .integers(let set): return ["type": "integer", "enum": set.sorted()] as [String: Any]
        case .anyInteger: return ["type": "integer"] as [String: Any]
        case .date: return ["type": "string", "pattern": "^\\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\\d|3[01])$"] as [String: Any]
        case .boolean: return ["type": "boolean"] as [String: Any]
        case .nullable(let inner): return ["anyOf": [inner.jsonSchema, ["type": "null"]]] as [String: Any]
        case .tagged(let key, let cases):
            // One object per case, with the tag fixed to its word.
            let branches: [[String: Any]] = cases.map { c in
                var properties = Dictionary(uniqueKeysWithValues: c.rest.map { ($0.name, $0.schema.jsonSchema) })
                properties[key] = ["enum": [Self.wordValue(c.value)]] as [String: Any]
                return ["type": "object", "properties": properties, "required": [key] + c.rest.map(\.name), "additionalProperties": false]
            }
            return ["anyOf": branches] as [String: Any]
        }
    }

    /// The JSON Schema as compact UTF-8 JSON in which every `properties` map lists its keys in the order they were declared (the
    /// order the model must write them in). A server's grammar converter (llama.cpp, Ollama, vLLM) writes object properties in the
    /// order of that map, so `found` has to come first there and not wherever a sorted dictionary would put it.
    public func jsonSchemaData() -> Data { Data(orderedJSONSchema().utf8) }

    private static func literal(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ properties: [Property], tag: (key: String, word: String)? = nil, required: [String]) -> String {
        var members: [String] = []
        if let tag { members.append("\(literal(tag.key)):{\"enum\":[\(tag.word)]}") }   // a word is valid JSON as written: true, false or "yes"
        members += properties.map { "\(literal($0.name)):\($0.schema.orderedJSONSchema())" }
        return "{\"type\":\"object\",\"properties\":{\(members.joined(separator: ","))},\"required\":\(literal(required)),\"additionalProperties\":false}"
    }

    func orderedJSONSchema() -> String {
        switch self {
        case .object(let props): return Self.object(props, required: props.map(\.name))
        case .array(let item, let lo, let hi): return "{\"type\":\"array\",\"items\":\(item.orderedJSONSchema()),\"minItems\":\(lo),\"maxItems\":\(hi)}"
        case .nullable(let inner): return "{\"anyOf\":[\(inner.orderedJSONSchema()),{\"type\":\"null\"}]}"
        case .tagged(let key, let cases):
            return "{\"anyOf\":[" + cases.map { Self.object($0.rest, tag: (key, $0.value), required: [key] + $0.rest.map(\.name)) }.joined(separator: ",") + "]}"
        default:
            return Self.literal(jsonSchema)
        }
    }
}
