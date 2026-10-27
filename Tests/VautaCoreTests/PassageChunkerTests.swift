// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite struct PassageChunkerTests {
    private func sentence(_ n: Int) -> String { "Sentence number \(n) talks about the quarterly planning process and who owns each step of it." }

    private func longText(sentences: Int) -> String { (1...sentences).map(sentence).joined(separator: " ") }

    @Test func aPassageNeverCrossesAPageOrSlide() {
        let document = ExtractedDocument(units: [
            DocumentUnit(locator: .page(1), text: "First page text about alpha."),
            DocumentUnit(locator: .page(2), text: "Second page text about beta."),
        ])
        let passages = PassageChunker.chunk(document, fileName: "Report.pdf")
        #expect(passages.count == 2)
        #expect(passages.map(\.locator) == [.page(1), .page(2)])
        #expect(passages[0].text.contains("alpha") && !passages[0].text.contains("beta"))
        #expect(passages[1].ordinal == 2000)
    }

    @Test func targetAndMaximumSizesAreRespected() {
        let document = ExtractedDocument(units: [DocumentUnit(locator: .section(path: [], block: 1), text: longText(sentences: 60))])
        let passages = PassageChunker.chunk(document, fileName: "n.txt")
        #expect(passages.count > 3)
        for passage in passages {
            let body = passage.text.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? ""
            #expect(body.count <= PassageChunker.targetCharacters * 3 / 2, "a passage is at most one and a half targets")
        }
        // Most passages are close to the target, not tiny.
        let big = passages.filter { $0.text.count > PassageChunker.targetCharacters / 2 }.count
        #expect(big >= passages.count - 1)
    }

    @Test func denseScriptsGetASmallerTarget() {
        let japanese = String(repeating: "第三四半期の予算が承認されました。合計は千二百万円です。", count: 60)
        #expect(PassageChunker.isDense(japanese))
        #expect(!PassageChunker.isDense(longText(sentences: 5)))
        let passages = PassageChunker.chunk(ExtractedDocument(units: [DocumentUnit(locator: .section(path: [], block: 1), text: japanese)]), fileName: "j.txt")
        #expect(passages.count > 2)
        for passage in passages { #expect(passage.text.count <= PassageChunker.denseTargetCharacters * 3 / 2 + 80) }
    }

    @Test func consecutivePassagesOverlapByOneSentence() {
        let document = ExtractedDocument(units: [DocumentUnit(locator: .section(path: [], block: 1), text: longText(sentences: 40))])
        let passages = PassageChunker.chunk(document, fileName: "n.txt")
        #expect(passages.count >= 3)
        let lastOfFirst = passages[0].text.components(separatedBy: ". ").last?.replacingOccurrences(of: ".", with: "") ?? ""
        #expect(!lastOfFirst.isEmpty && passages[1].text.contains(lastOfFirst))
    }

    @Test func everyPassageStartsWithItsContextLine() {
        let doc = ExtractedDocument(title: "Handbook", units: [DocumentUnit(locator: .section(path: ["Pricing", "Enterprise"], block: 4), text: "Contact sales.", headings: ["Pricing", "Enterprise"])])
        #expect(PassageChunker.chunk(doc, fileName: "h.md").first?.text.hasPrefix("Handbook › Pricing › Enterprise\n") == true)
        let sheet = ExtractedDocument(units: [DocumentUnit(locator: .sheet(name: "Q3", firstRow: 12, lastRow: 40), text: "Region: North", columns: "Region | Revenue | Owner")])
        #expect(PassageChunker.chunk(sheet, fileName: "Budget 2027.xlsx").first?.text.hasPrefix("Budget 2027 — Sheet \"Q3\", rows 12–40 — columns: Region | Revenue | Owner\n") == true)
    }

    @Test func keysAreStableAcrossRunsRenamesAndUnrelatedEdits() {
        let a = ExtractedDocument(units: [DocumentUnit(locator: .section(path: [], block: 1), text: longText(sentences: 30))])
        let first = PassageChunker.chunk(a, fileName: "one.txt")
        let again = PassageChunker.chunk(a, fileName: "one.txt")
        #expect(first.map(\.key) == again.map(\.key))
        // The key does not include the path: the same text under another name keeps its keys.
        #expect(PassageChunker.chunk(a, fileName: "one.txt").map(\.key) == first.map(\.key))
        // An edit near the end changes only the passages it touches.
        var edited = a
        edited.units[0].text = edited.units[0].text.replacingOccurrences(of: "Sentence number 29 talks", with: "Sentence number 29 now says something else, and")
        let changed = PassageChunker.chunk(edited, fileName: "one.txt")
        let kept = Set(first.map(\.key)).intersection(changed.map(\.key))
        #expect(kept.count >= first.count - 3)
        #expect(changed.map(\.key) != first.map(\.key))
    }

    @Test func aRunningTextPassageKnowsItsParagraph() {
        let text = (1...12).map { "Paragraph \($0) says that \(String(repeating: "word ", count: 40))" }.joined(separator: "\n")
        let doc = ExtractedDocument(units: [DocumentUnit(locator: .section(path: ["A"], block: 5), text: text, headings: ["A"], firstBlock: 5)])
        let passages = PassageChunker.chunk(doc, fileName: "p.txt")
        guard case .section(_, let first) = passages[0].locator, case .section(_, let last) = passages.last!.locator else { Issue.record("not sections"); return }
        #expect(first == 5 && last > first)
    }

    @Test func ocrPagesSlotInByPageNumber() {
        let text = PassageChunker.chunk(ExtractedDocument(units: [DocumentUnit(locator: .page(1), text: "text page"), DocumentUnit(locator: .page(3), text: "text page three")]), fileName: "s.pdf")
        let ocr = PassageChunker.chunk(ExtractedDocument(units: [DocumentUnit(locator: .page(2), text: "scanned page words", ocr: true)]), fileName: "s.pdf")
        let all = (text + ocr).sorted { $0.ordinal < $1.ordinal }
        #expect(all.map(\.locator) == [.page(1), .page(2), .page(3)])
        #expect(ocr.first?.ocr == true)
    }

    @Test func aHugeSentenceIsCutAtTheMaximum() {
        let blob = (1...200).map { "supercalifragilistic\($0) " }.joined()
        let passages = PassageChunker.chunk(ExtractedDocument(units: [DocumentUnit(locator: .section(path: [], block: 1), text: blob)]), fileName: "b.txt")
        #expect(passages.count > 2)
        for p in passages { #expect(p.text.count <= PassageChunker.targetCharacters * 3 / 2 + 40) }
    }

    @Test func aTwoMillionCharacterLineWithoutPunctuationChunksQuickly() {
        let line = String(repeating: "漢字", count: 1_000_000)
        var cuts: [String] = []
        let cpu = cpuSeconds { cuts = PassageChunker.hardCut(line, maximum: 600) }
        #expect(cpu < 1, "cutting took \(cpu) s of CPU")
        #expect(cuts.allSatisfy { $0.count <= 600 })
        #expect(cuts.joined().count == 2_000_000)
    }

    @Test func hardCutKeepsEveryCharacterAndBreaksAtSpaces() {
        let words = (1...300).map { "word\($0)" }.joined(separator: " ")
        let cuts = PassageChunker.hardCut(words, maximum: 100)
        #expect(cuts.count > 3)
        #expect(cuts.allSatisfy { $0.count <= 100 })
        #expect(cuts.joined(separator: " ") == words)
    }
}
