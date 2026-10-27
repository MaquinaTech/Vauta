// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation

/// Invented speaker data for the UI snapshot renderer, in the nine interface languages. Nothing here is real.
public struct SampleSpeakerText: Sendable {
    /// A name that does not fit a speaker column, with a role as it would be typed.
    public let longName: String
    /// Names of people in the many-speakers meeting.
    public let names: [String]
    public let meetingTitle: String
    /// A second person who goes by the same short name as the third person of the sample content, when "short name +
    /// surname of the first speaker" does not make a name in the language (Japanese, Korean and Chinese write the surname first).
    public var namesake: String?
    /// Short things people say, cycled through the many-speakers meeting.
    public let lines: [String]

    public static func forLanguage(_ code: String) -> SampleSpeakerText {
        switch code.split(separator: "-").first.map(String.init) ?? code {
        case "es": .spanish
        case "fr": .french
        case "de": .german
        case "it": .italian
        case "pt": .portuguese
        case "ja": .japanese
        case "ko": .korean
        case "zh": .chinese
        default: .english
        }
    }

    static let english = SampleSpeakerText(
        longName: "Dr. Alexandria Montgomery-Featherstonehaugh, Customer Success (EMEA)",
        names: ["Tomás Reyes", "Aiko Tanaka", "Sam Okoro", "Elena Petrova"], meetingTitle: "Quarterly planning",
        lines: ["Can everyone see my screen?", "Yes, it looks good.", "Let me share the numbers.", "Sorry, I was on mute.",
                "I disagree with the timeline.", "Could you repeat that?", "Let’s take that offline.", "Agreed, moving on."])
    static let spanish = SampleSpeakerText(
        longName: "Dra. María Fernanda Gutiérrez-Santamaría de la Vega, Éxito del Cliente (EMEA)",
        names: ["Tomás Reyes", "Aiko Tanaka", "Samuel Okoro", "Elena Petrova"], meetingTitle: "Planificación trimestral",
        lines: ["¿Todos ven mi pantalla?", "Sí, se ve bien.", "Os enseño las cifras.", "Perdón, estaba en silencio.",
                "No estoy de acuerdo con el calendario.", "¿Puedes repetirlo?", "Eso lo vemos aparte.", "De acuerdo, seguimos."])
    static let french = SampleSpeakerText(
        longName: "Dr Jean-Baptiste Montmorency-Delacroix de la Tour d’Auvergne, Succès client (EMEA)",
        names: ["Tomás Reyes", "Aiko Tanaka", "Samuel Okoro", "Elena Petrova"], meetingTitle: "Planification trimestrielle",
        lines: ["Tout le monde voit mon écran ?", "Oui, c’est bon.", "Je vous montre les chiffres.", "Désolé, j’étais en sourdine.",
                "Je ne suis pas d’accord avec le calendrier.", "Pouvez-vous répéter ?", "Voyons cela en dehors de la réunion.", "D’accord, on continue."])
    static let german = SampleSpeakerText(
        longName: "Dr. Friedrich-Wilhelm von Hohenstaufen-Habsburg-Lothringen, Kundenerfolg (EMEA)",
        names: ["Tomás Reyes", "Aiko Tanaka", "Samuel Okoro", "Elena Petrova"], meetingTitle: "Quartalsplanung",
        lines: ["Sehen alle meinen Bildschirm?", "Ja, sieht gut aus.", "Ich zeige euch die Zahlen.", "Entschuldigung, ich war stumm geschaltet.",
                "Ich bin mit dem Zeitplan nicht einverstanden.", "Kannst du das wiederholen?", "Das klären wir separat.", "Einverstanden, weiter."])
    static let italian = SampleSpeakerText(
        longName: "Dott.ssa Maria Alessandra Colonna di Montefeltro-Della Rovere, Customer Success (EMEA)",
        names: ["Tomás Reyes", "Aiko Tanaka", "Samuele Okoro", "Elena Petrova"], meetingTitle: "Pianificazione trimestrale",
        lines: ["Tutti vedono il mio schermo?", "Sì, si vede bene.", "Vi mostro i numeri.", "Scusate, ero senza audio.",
                "Non sono d’accordo con la tempistica.", "Puoi ripetere?", "Ne parliamo a parte.", "D’accordo, andiamo avanti."])
    static let portuguese = SampleSpeakerText(
        longName: "Dra. Maria Fernanda de Albuquerque Cavalcanti-Vasconcelos Neto, Sucesso do Cliente (EMEA)",
        names: ["Tomás Reyes", "Aiko Tanaka", "Samuel Okoro", "Elena Petrova"], meetingTitle: "Planejamento trimestral",
        lines: ["Todo mundo está vendo minha tela?", "Sim, está bom.", "Vou mostrar os números.", "Desculpe, eu estava no mudo.",
                "Não concordo com o cronograma.", "Pode repetir?", "Vamos tratar disso depois.", "Combinado, vamos em frente."])
    static let japanese = SampleSpeakerText(
        longName: "佐々木・アレクサンドラ・モンゴメリー＝フェザーストンホー（カスタマーサクセスEMEA担当）",
        names: ["田中愛子", "鈴木トマス", "サム・オコロ", "エレナ・ペトロヴァ"], meetingTitle: "四半期計画", namesake: "佐藤健太",
        lines: ["私の画面は見えていますか？", "はい、見えています。", "数字を共有します。", "すみません、ミュートでした。",
                "スケジュールには賛成できません。", "もう一度お願いできますか？", "それは別の場で話しましょう。", "了解です、先に進みましょう。"])
    static let korean = SampleSpeakerText(
        longName: "알렉산드리아 몽고메리-페더스톤호 박사 (고객 성공팀, EMEA 담당)",
        names: ["김도윤", "이서연", "샘 오코로", "엘레나 페트로바"], meetingTitle: "분기 계획", namesake: "최대현",
        lines: ["제 화면이 보이시나요?", "네, 잘 보여요.", "숫자를 공유할게요.", "죄송해요, 음소거 상태였어요.",
                "일정에는 동의하기 어려워요.", "다시 말씀해 주시겠어요?", "그건 따로 이야기해요.", "좋아요, 다음으로 넘어가요."])
    static let chinese = SampleSpeakerText(
        longName: "亚历山德里娅·蒙哥马利-费瑟斯通豪博士（客户成功部 EMEA 区域负责人）",
        names: ["王雨桐", "李明轩", "萨姆·奥科罗", "埃琳娜·彼得罗娃"], meetingTitle: "季度规划", namesake: "张大伟",
        lines: ["大家都能看到我的屏幕吗？", "能，看得很清楚。", "我来分享一下数据。", "抱歉，我刚才静音了。",
                "我不同意这个时间安排。", "你能再说一遍吗？", "这个我们会后再谈。", "同意，我们继续。"])
}

extension SampleWorld {
    public var speakerText: SampleSpeakerText { .forLanguage(locale.language.languageCode?.identifier ?? "en") }

    /// The sample meetings as they were before any speaker scene: no speakers, separation on, and none of the
    /// meetings and people the scenes added.
    public func resetSpeakerSamples() async throws {
        try await store.deleteAllVoiceProfiles()
        for id in meetingIDs {
            _ = try await store.clearSpeakers(meetingID: id)
            try await store.setSpeakersOff(false, meetingID: id)
        }
        for meeting in try await store.meetings() where !meetingIDs.contains(meeting.id) {
            try await store.deleteMeeting(meeting.id)
        }
        let added = Set(speakerText.names + [speakerText.longName])
        for entity in try await store.entities() where added.contains(entity.name) {
            try await store.deleteEntity(entity.id)
        }
    }

    /// Four speakers in the featured meeting: the user; Speaker 1 (not named, with a line said over somebody else);
    /// Daniel (named, with a line the diarizer is unsure about) and Priya (named).
    /// The calendar lists Maya, who is not assigned to anybody: she is only a suggestion.
    public func seedFeaturedSpeakers() async throws {
        try await resetSpeakerSamples()
        // Who said each of the 14 lines: nil = the user; else (ordinal of Others, confidence, overlap).
        let plan: [(ordinal: Int, confidence: Double, overlap: Bool)?] = [
            (1, 0.95, false), (2, 0.97, false), nil, (3, 0.93, false), (1, 0.70, true), nil, (2, 0.90, false), nil,
            (2, 0.45, false), (1, 0.88, false), (1, 0.91, false), nil, (2, 0.96, false), (1, 0.90, false),
        ]
        var assignments: [SegmentSpeakerAssignment] = []
        for (index, id) in featuredSegmentIDs.enumerated() where index < plan.count {
            if let line = plan[index] {
                assignments.append(SegmentSpeakerAssignment(segmentID: id, channel: .others, ordinal: line.ordinal, confidence: line.confidence, overlap: line.overlap))
            } else {
                assignments.append(SegmentSpeakerAssignment(segmentID: id, channel: .me, ordinal: 1, confidence: 0.99))
            }
        }
        try await store.finalizeSpeakers(meetingID: featuredMeetingID, speakers: [
            SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1),
            SpeakerDraft(channel: .others, ordinal: 2), SpeakerDraft(channel: .others, ordinal: 3),
        ], assignments: assignments)
        let speakers = try await store.speakers(of: featuredMeetingID)
        for (ordinal, person) in [(2, peopleIDs[2]), (3, peopleIDs[3])] {
            if let speaker = speakers.first(where: { $0.channel == .others && $0.ordinal == ordinal }) {
                try await store.assignSpeaker(speaker.id, toEntity: person)
            }
        }
    }

    /// A meeting with nine voices and a name that does not fit: Others 1 has the long name, 2, 3, 5 and 7 are
    /// named, 4, 6 and 8 are not. Returns its ID.
    @discardableResult
    public func seedSpeakerStress() async throws -> Int64 {
        try await resetSpeakerSamples()
        let text = speakerText
        let day = Calendar.current.date(byAdding: .day, value: -3, to: AppClock.now) ?? AppClock.now
        let start = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: day) ?? day
        let id = try await store.startMeeting(at: start, locale: locale)
        // Others 1…8 in turn, with the user in between; every 7th line is a guess.
        var plan: [(channel: Channel, ordinal: Int)] = []
        for round in 0..<2 {
            for ordinal in 1...8 {
                plan.append((.others, ordinal))
                if (ordinal + round) % 4 == 0 { plan.append((.me, 1)) }
            }
        }
        var ids: [Int64] = []
        for (index, entry) in plan.enumerated() {
            let begin = Double(index) * 20
            ids.append(try await store.append(Segment(channel: entry.channel, start: begin, end: begin + 15,
                                                      text: text.lines[index % text.lines.count], isFinal: true), to: id))
        }
        try await store.setTitle(text.meetingTitle, of: id)
        try await store.endMeeting(id, at: start.addingTimeInterval(Double(plan.count) * 20 + 60))
        try await store.finalizeSpeakers(meetingID: id,
            speakers: [SpeakerDraft(channel: .me, ordinal: 1)] + (1...8).map { SpeakerDraft(channel: .others, ordinal: $0) },
            assignments: plan.enumerated().map { index, entry in
                SegmentSpeakerAssignment(segmentID: ids[index], channel: entry.channel, ordinal: entry.ordinal,
                                         confidence: index % 7 == 6 ? 0.5 : 0.92, overlap: index == 9)
            })
        let speakers = try await store.speakers(of: id)
        let named: [Int: String] = [1: text.longName, 2: text.names[0], 3: text.names[1], 5: text.names[2], 7: text.names[3]]
        for (ordinal, name) in named {
            guard let speaker = speakers.first(where: { $0.channel == .others && $0.ordinal == ordinal }) else { continue }
            let person = try await store.saveEntity(EntityDraft(kind: .person, name: name))
            try await store.assignSpeaker(speaker.id, toEntity: person)
        }
        return id
    }

    /// The featured meeting's speakers, and Daniel in two more meetings, so the person's card says how many meetings
    /// they spoke in and quotes lines that fit him: what the other side says in the one-to-one with Daniel after the opening answer, and the
    /// last remark of the design review (so the three quotes come from three different moments) (the sample meeting with the client is not his).
    public func seedSpeakerAcrossMeetings() async throws {
        try await seedFeaturedSpeakers()
        for (index, id) in meetingIDs.enumerated() where index == 1 || index == 3 {
            let lines = try await store.segments(of: id)
            let othersLines = lines.filter { $0.channel == .others }
            // In the design review only the last remark is his; the rest is said by somebody else.
            let his = index == 1 ? Array(othersLines.dropFirst()) : Array(othersLines.suffix(1))
            let hisIDs = Set(his.map(\.id))
            let hasOthers = othersLines.contains { !hisIDs.contains($0.id) }
            var drafts = [SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1)]
            if hasOthers { drafts.append(SpeakerDraft(channel: .others, ordinal: 2)) }
            try await store.finalizeSpeakers(meetingID: id, speakers: drafts, assignments: lines.map { line in
                let ordinal = line.channel == .me ? 1 : (hisIDs.contains(line.id) ? 1 : 2)
                return SegmentSpeakerAssignment(segmentID: line.id, channel: line.channel, ordinal: ordinal, confidence: 0.9)
            })
            if let speaker = try await store.speakers(of: id).first(where: { $0.channel == .others && $0.ordinal == 1 }) {
                try await store.assignSpeaker(speaker.id, toEntity: peopleIDs[2])
            }
        }
    }

    /// Two people of the user's context who are not on the calendar of the meetings, so the person list of the speaker
    /// popover has more than the attendees.
    public func seedExtraPeople() async throws {
        for name in speakerText.names.prefix(2) { _ = try await store.saveEntity(EntityDraft(kind: .person, name: name)) }
    }

    /// A second person who answers to the alias of the first named speaker's person (two Daniels), so typing that alias
    /// is ambiguous. Returns the alias ("" when the person has none).
    public func seedSecondPersonWithSameAlias() async throws -> String {
        guard let alias = try await store.entities(.person).first(where: { $0.id == peopleIDs[2] })?.aliases.first else { return "" }
        let surname = speakerText.names[0].split(separator: " ").last.map(String.init) ?? "Reyes"
        _ = try await store.saveEntity(EntityDraft(kind: .person, name: speakerText.namesake ?? "\(alias) \(surname)", aliases: [alias]))
        return alias
    }

    /// The alias of the first named speaker's person ("Daniel"): typed, it names exactly one person.
    public func firstPersonAlias() async throws -> String {
        try await store.entities(.person).first(where: { $0.id == peopleIDs[2] })?.aliases.first ?? ""
    }

    /// The featured meeting with stored translations (the others speak another language) and the speakers on top.
    public func seedFeaturedSpeakersTranslated(into language: String) async throws {
        try await useForeignSourceTranscript(translatedInto: language)
        try await seedFeaturedSpeakers()
    }

    /// The second meeting with "Don't separate speakers in this meeting" on, as after the user turned it on
    /// before the meeting ended.
    public func seedSpeakersOffMeeting() async throws -> Int64 {
        try await resetSpeakerSamples()
        let id = meetingIDs[1]
        try await store.setSpeakersOff(true, meetingID: id)
        return id
    }
}
#endif
