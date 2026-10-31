// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A speaker who says who they are, in the nine languages: the name is among the candidates, and lines that only look like it give none.
@Suite("Speakers: introductions in what was said")
struct SpeakerIntroductionsTests {
    /// (language, line, the name among the candidates).
    static let introductions: [(String, String, String)] = [
        ("en", "Hi, I'm Ana García from Kobaltix.", "Ana García"), ("en", "Hello everyone, my name is Lucía.", "Lucía"),
        ("en", "Hi, this is Ana.", "Ana"), ("en", "Ana here, sorry I'm late.", "Ana"), ("en", "I am Jean-Luc van Damme.", "Jean-Luc van Damme"),
        ("es", "Hola a todos, soy Ana, de Kobaltix.", "Ana"), ("es", "Buenos días, me llamo Lucía Pérez.", "Lucía Pérez"),
        ("es", "Hola, les habla Pedro.", "Pedro"),
        ("fr", "Bonjour à tous, je suis Claire.", "Claire"), ("fr", "Je m'appelle Jean-Pierre.", "Jean-Pierre"), ("fr", "Salut, c'est Marc.", "Marc"),
        ("de", "Hallo zusammen, ich bin Jonas.", "Jonas"), ("de", "Mein Name ist Anna Schmidt.", "Anna Schmidt"), ("de", "Guten Morgen, hier ist Lena.", "Lena"),
        ("it", "Ciao a tutti, sono Giulia.", "Giulia"), ("it", "Mi chiamo Marco Rossi.", "Marco Rossi"),
        ("pt", "Olá pessoal, sou a Beatriz.", "Beatriz"), ("pt", "Meu nome é João.", "João"), ("pt", "Bom dia, aqui é o Rafael.", "Rafael"),
        ("ja", "皆さん、私はアナです。", "アナ"), ("ja", "営業部のアナと申します。", "アナ"), ("ja", "私は田中と申します。", "田中"),
        ("ko", "안녕하세요, 저는 아나입니다.", "아나"), ("ko", "저는 마케팅팀 김민수입니다.", "김민수"), ("ko", "제 이름은 지수예요.", "지수"),
        ("zh", "大家好，我是安娜。", "安娜"), ("zh", "我叫王伟，负责销售。", "王伟"), ("zh", "我的名字是李娜。", "李娜"),
    ]

    /// Lines that give no name: an opinion, someone else's, a name not at the start of a clause, "this is" without a greeting.
    static let notIntroductions: [(String, String)] = [
        ("en", "I'm sure we can ship it on Friday."), ("en", "I'm Ana's manager, so send it to me."), ("en", "They told me I'm Ana now."),
        ("en", "This is Ana, she joins us from Madrid."), ("en", "It's Friday, so let's wrap up."), ("en", "I am not convinced."),
        ("es", "Soy consciente del riesgo."), ("es", "Yo soy de Madrid."), ("es", "Habla Pedro con el cliente."),
        ("fr", "Je suis d'accord avec Claire."), ("fr", "C'est Marc qui s'en occupe."),
        ("de", "Ich bin dafür."), ("de", "Hier ist das Budget."),
        ("it", "Sono d'accordo."), ("pt", "Sou contra essa ideia."),
        ("ja", "その件は田中さんです。"), ("ko", "그건 내일입니다."), ("zh", "这是我们的计划。"),
    ]

    @Test(arguments: introductions)
    func anIntroductionGivesTheName(language: String, line: String, name: String) {
        let cues = SpeakerIntroductions.cues(in: line, languages: [language])
        #expect(cues.contains { $0.candidates.contains(name) }, "\(language): \(line) → \(cues.map(\.candidates))")
    }

    @Test(arguments: notIntroductions)
    func otherLinesGiveNoName(language: String, line: String) {
        let cues = SpeakerIntroductions.cues(in: line, languages: [language])
        // A Latin-script line may offer a capitalized word that is no person ("Friday"); it must not offer one here.
        #expect(cues.isEmpty, "\(language): \(line) → \(cues.map(\.candidates))")
    }

    @Test func onlyTheLanguagesOfTheMeetingAreRead() {
        #expect(SpeakerIntroductions.cues(in: "Soy Ana.", languages: ["en"]).isEmpty, "Spanish \"soy\" means nothing in English")
        #expect(!SpeakerIntroductions.cues(in: "Soy Ana.", languages: ["en", "es"]).isEmpty)
    }

    @Test func theQuoteIsTheClauseThatSaysIt() throws {
        let cue = try #require(SpeakerIntroductions.cues(in: "Good morning. Hi, I'm Ana. Let's start with the budget.", languages: ["en"]).first)
        #expect(cue.quote == "Hi, I'm Ana" && cue.candidates == ["Ana"])
    }
}
