// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// "What do you think, Ana?", "Thanks, Ana.": where a line says a name to someone, and whose turn it points to.
@Suite("Speakers: names said to someone")
struct SpeakerAddressesTests {
    /// The turn each name of `names` points to in `text` (every place the line has it).
    static func turns(_ text: String, _ names: [String], _ languages: [String] = ["en"]) -> [String: SpeakerAddresses.Turn] {
        var ranges: [Range<String.Index>] = []
        for name in names {
            var from = text.startIndex
            while let r = text.range(of: name, range: from..<text.endIndex) {
                ranges.append(r)
                from = r.upperBound
            }
        }
        var out: [String: SpeakerAddresses.Turn] = [:]
        for address in SpeakerAddresses.addresses(in: text, names: ranges, languages: languages) { out[String(text[address.range])] = address.turn }
        return out
    }

    @Test func aQuestionOrAHandoverByNamePointsToTheNextSpeaker() {
        #expect(Self.turns("Uh-huh. What do you have, Tomás?", ["Tomás"]) == ["Tomás": .next])
        #expect(Self.turns("Julia, we can start with you?", ["Julia"]) == ["Julia": .next])
        #expect(Self.turns("Okay. So Ana, what do you think?", ["Ana"]) == ["Ana": .next])
        #expect(Self.turns("What do you think, Ana, about the budget?", ["Ana"]) == ["Ana": .next])
        #expect(Self.turns("Over to you, Ana.", ["Ana"]) == ["Ana": .next])
        #expect(Self.turns("Go ahead Ana.", ["Ana"]) == ["Ana": .next])
        #expect(Self.turns("Ana?", ["Ana"]) == ["Ana": .next])
        #expect(Self.turns("You prefer that too, Mr Okoro?", ["Okoro"]) == ["Okoro": .next])
        #expect(Self.turns("Ana, ¿lo has visto?", ["Ana"], ["es-ES"]) == ["Ana": .next])
        #expect(Self.turns("¿Y tú qué opinas, Ana?", ["Ana"], ["es-ES"]) == ["Ana": .next])
        #expect(Self.turns("Adelante, Ana.", ["Ana"], ["es-ES"]) == ["Ana": .next])
        #expect(Self.turns("Tiene la palabra, señora Ruiz.", ["Ruiz"], ["es-ES"]) == ["Ruiz": .next])
        #expect(Self.turns("Qu’en penses-tu, Ana\u{00A0}?", ["Ana"], ["fr-FR"]) == ["Ana": .next])
        #expect(Self.turns("Ana, c’est à toi.", ["Ana"], ["fr-FR"]) == ["Ana": .next])
        #expect(Self.turns("Was meinst du, Ana?", ["Ana"], ["de-DE"]) == ["Ana": .next])
        #expect(Self.turns("Ana, du bist dran.", ["Ana"], ["de-DE"]) == ["Ana": .next])
        #expect(Self.turns("Tu che ne pensi, Ana?", ["Ana"], ["it-IT"]) == ["Ana": .next])
        #expect(Self.turns("Ana, você viu o relatório?", ["Ana"], ["pt-BR"]) == ["Ana": .next])
        #expect(Self.turns("É com você, Ana.", ["Ana"], ["pt-BR"]) == ["Ana": .next])
    }

    @Test func thanksPointToTheSpeakerBefore() {
        #expect(Self.turns("Thanks, Ana. Let's look at the budget.", ["Ana"]) == ["Ana": .previous])
        #expect(Self.turns("Okay, thanks Ana for the update.", ["Ana"]) == ["Ana": .previous])
        #expect(Self.turns("Thank you so much for that, Ana.", ["Ana"]) == ["Ana": .previous])
        #expect(Self.turns("Ana, thanks, that was clear.", ["Ana"]) == ["Ana": .previous])
        #expect(Self.turns("Muchas gracias, señor Ibarra, como siempre su aporte es muy valioso.", ["Ibarra"], ["es-ES"]) == ["Ibarra": .previous])
        #expect(Self.turns("Merci, Ana\u{00A0}!", ["Ana"], ["fr-FR"]) == ["Ana": .previous])
        #expect(Self.turns("Vielen Dank, Ana.", ["Ana"], ["de-DE"]) == ["Ana": .previous])
        #expect(Self.turns("Grazie mille, Ana.", ["Ana"], ["it-IT"]) == ["Ana": .previous])
        #expect(Self.turns("Muito obrigada, Ana.", ["Ana"], ["pt-BR"]) == ["Ana": .previous])
    }

    @Test func aRemarkANameTalkedAboutOrAListGivesNothing() {
        // On the public AMI meetings these pointed to the wrong speaker as often as to the right one.
        #expect(Self.turns("That's your fault, Tomás.", ["Tomás"]).isEmpty)
        #expect(Self.turns("Yeah you could put me there. I mean, Iván.", ["Iván"]).isEmpty)
        #expect(Self.turns("I'll ask Ana tomorrow.", ["Ana"]).isEmpty)
        #expect(Self.turns("Did Ana send it?", ["Ana"]).isEmpty)
        #expect(Self.turns("Ana's report is late, right?", ["Ana"]).isEmpty)
        #expect(Self.turns("Hi, I'm Ana.", ["Ana"]).isEmpty, "an introduction is not a name said to someone")
        // Lists of people, and a name said twice.
        #expect(Self.turns("So, where were we? Uh Paula, uh Iván, Lena?", ["Lena"]).isEmpty)
        #expect(Self.turns("Um so Tomás, Big Fish. Julia, Hugo?", ["Tomás", "Julia", "Hugo"]).isEmpty)
        #expect(Self.turns("Hugo, Hugo, could you give me the list?", ["Hugo"]).isEmpty)
        #expect(Self.turns("¿Ana me lo mandas mañana?", ["Ana"], ["es-ES"]).isEmpty, "without the comma it could be about Ana")
    }

    @Test func japaneseKoreanAndChinese() {
        #expect(Self.turns("田中さん、どう思いますか？", ["田中"], ["ja-JP"]) == ["田中": .next])
        #expect(Self.turns("どう思いますか、田中さん？", ["田中"], ["ja-JP"]) == ["田中": .next])
        #expect(Self.turns("田中さんはどう思いますか？", ["田中"], ["ja-JP"]) == ["田中": .next])
        #expect(Self.turns("では田中さん、お願いします。", ["田中"], ["ja-JP"]) == ["田中": .next])
        #expect(Self.turns("ありがとうございます、田中さん。", ["田中"], ["ja-JP"]) == ["田中": .previous])
        #expect(Self.turns("田中さんが資料を送りました。", ["田中"], ["ja-JP"]).isEmpty)
        #expect(Self.turns("안나 씨, 어떻게 생각하세요?", ["안나"], ["ko-KR"]) == ["안나": .next])
        #expect(Self.turns("안나 씨는 어떻게 생각하세요?", ["안나"], ["ko-KR"]) == ["안나": .next])
        #expect(Self.turns("감사합니다, 안나 씨.", ["안나"], ["ko-KR"]) == ["안나": .previous])
        #expect(Self.turns("안나 씨가 보낸 보고서예요.", ["안나"], ["ko-KR"]).isEmpty)
        #expect(Self.turns("王伟，你怎么看？", ["王伟"], ["zh-CN"]) == ["王伟": .next])
        #expect(Self.turns("你怎么看，王伟？", ["王伟"], ["zh-CN"]) == ["王伟": .next])
        #expect(Self.turns("谢谢王伟。", ["王伟"], ["zh-CN"]) == ["王伟": .previous])
        #expect(Self.turns("王伟昨天发了报告。", ["王伟"], ["zh-CN"]).isEmpty)
    }

    @Test func theQuoteIsTheClauseThatSaysTheName() {
        let line = "Uh-huh. And I have a uh well just a piece of paper with some suggestions. What about you, Hugo?"
        #expect(SpeakerAddresses.quote(line, naming: "Hugo Marín") == "What about you, Hugo?")
        #expect(SpeakerAddresses.quote("Good morning. Hi, I'm Ana, from Kobaltix.", naming: "Ana García") == "Hi, I'm Ana, from Kobaltix.")
        #expect(SpeakerAddresses.quote("私はアナです。よろしくお願いします。", naming: "アナ") == "私はアナです。")
        let long = String(repeating: "word ", count: 60) + "and that is all."
        let cut = SpeakerAddresses.quote(long, naming: "Ana")
        #expect(cut.count == 138 && cut.hasSuffix("…"), "no clause says it: the line, cut")
    }
}
