// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import FoundationModels

/// The shape of an Ask answer as Apple's guided generation takes it. The same `OutputSchema` that the integrated model decodes within
/// and a model server receives as `response_format` is turned into a `GenerationSchema`, so Apple's model is held to it too: `found`
/// first, a claim with a citation and a quote under `found: true` (at least one), none under `found: false`, a bounded number of claims,
/// citations among the segment numbers that were sent (a list, never a range: the numbers are sparse). Only the parts of `OutputSchema` an answer uses are supported; anything
/// else returns nil and the prompt alone describes the shape, as before.
enum AppleGuidedSchema {
    /// The most numbers a citation can choose among before the guide is left out.
    static let maxListedIntegers = 400

    static func make(_ schema: OutputSchema) -> GenerationSchema? {
        guard let root = node(schema, name: "answer") else { return nil }
        return try? GenerationSchema(root: root, dependencies: [])
    }

    /// The names of the properties of every object of the schema, for tests (the framework gives no way to read a built schema back).
    static func shape(_ schema: OutputSchema) -> [String] {
        switch schema {
        case .object(let props): return props.flatMap { [$0.name] + shape($0.schema).map { "\($0)" } }
        case .tagged(let key, let cases): return [key] + cases.flatMap { c in c.rest.flatMap { [$0.name] + shape($0.schema) } }
        case .array(let item, _, _): return shape(item)
        case .nullable(let inner): return shape(inner)
        default: return []
        }
    }

    private static func node(_ schema: OutputSchema, name: String) -> DynamicGenerationSchema? {
        switch schema {
        case .object(let props):
            var properties: [DynamicGenerationSchema.Property] = []
            for p in props {
                guard let child = node(p.schema, name: "\(name)_\(p.name)") else { return nil }
                properties.append(.init(name: p.name, schema: child))
            }
            return DynamicGenerationSchema(name: name, properties: properties)
        case .tagged(let key, let cases):
            // Two (or three) object schemas that differ in the word of the first key: `found` decides what the rest must be.
            var choices: [DynamicGenerationSchema] = []
            for c in cases {
                let word = c.value.hasPrefix("\"") ? String(c.value.dropFirst().dropLast()) : c.value
                var properties: [DynamicGenerationSchema.Property] = [
                    .init(name: key, schema: DynamicGenerationSchema(type: String.self, guides: [.constant(word)]))]
                for p in c.rest {
                    guard let child = node(p.schema, name: "\(name)_\(word)_\(p.name)") else { return nil }
                    properties.append(.init(name: p.name, schema: child))
                }
                choices.append(DynamicGenerationSchema(name: "\(name)_\(word)", properties: properties))
            }
            return DynamicGenerationSchema(name: name, anyOf: choices)
        case .array(let item, let lo, let hi):
            guard let child = node(item, name: name + "_item") else { return nil }
            return DynamicGenerationSchema(arrayOf: child, minimumElements: lo > 0 ? lo : nil, maximumElements: hi)
        case .string, .text:
            return DynamicGenerationSchema(type: String.self)
        case .integers(let set):
            // The numbers that were sent, exactly: segment numbers are sparse, and a range over them lets the model cite lines it was
            // never given. Integer guides have no list of values, so the choice is a list of the numbers as text; the reader of the
            // answer accepts "12" for 12. A very long list (a whole long meeting) is left to the prompt and the checks.
            guard !set.isEmpty else { return DynamicGenerationSchema(type: Int.self) }
            guard set.count <= maxListedIntegers else { return nil }
            return DynamicGenerationSchema(name: name, anyOf: set.sorted().map(String.init))
        case .anyInteger:
            return DynamicGenerationSchema(type: Int.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .enumStrings(let values):
            return values.isEmpty ? DynamicGenerationSchema(type: String.self) : DynamicGenerationSchema(name: name, anyOf: values)
        case .date, .nullable:
            return nil
        }
    }
}
