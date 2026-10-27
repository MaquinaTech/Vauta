// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
@testable import VautaCore

/// Items and vectors for the link tests, with invented words.
enum LinkFixture {
    static let day: TimeInterval = 86_400
    static let base = Date(timeIntervalSince1970: 1_780_000_000)

    static func item(_ id: Int64, _ kind: LinkKind = .task, meeting: Int64, daysAgo: Double = 0, _ text: String, locale: String = "en",
                     series: Int64? = nil, people: Set<Int64> = [], owner: Int64? = nil, projects: Set<Int64> = [], status: TaskItem.Status = .open) -> LinkItem {
        var item = LinkItem(id: id, kind: kind, meetingID: meeting, startedAt: base.addingTimeInterval(-daysAgo * day), text: text,
                            language: Locale(identifier: locale).language.languageCode?.identifier ?? locale, locale: locale)
        item.seriesID = series
        item.people = people
        item.ownerID = owner
        item.projects = projects
        item.status = status
        return item
    }

    /// A unit vector along `axis`, tilted toward `other` by `mix` (0 = same direction, 1 = orthogonal), so the cosine is known.
    static func vector(_ cosineToAxis0: Double, dims: Int = 8) -> LinkVector {
        var v = [Float](repeating: 0, count: dims)
        v[0] = Float(cosineToAxis0)
        v[1] = Float((1 - cosineToAxis0 * cosineToAxis0).squareRoot())
        return LinkVector(v)!
    }

    static func engine(sources: [LinkItem], pool: [LinkItem], vectors: [String: LinkVector] = [:], exclusions: LinkExclusions = LinkExclusions(),
                       policy: LinkPolicy = LinkPolicy()) -> [LinkProposal] {
        LinkEngine(sources: sources, pool: pool, vectors: vectors, exclusions: exclusions, policy: policy).run()
    }

    static func key(_ item: LinkItem) -> String { LinkExclusions.item(item.kind, item.id) }

    /// A search-model space for the fake embedder (the prefix is what makes it the search model's).
    static let space = EmbeddingSpace(model: "embeddinggemma-2@test", dimensions: 8)
}
