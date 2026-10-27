// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The languages the question cues cover (the nine interface languages).
public enum CueLanguage: String, Sendable, CaseIterable {
    case en, es, fr, de, it, pt, ja, ko, zh

    /// From a locale identifier ("es-ES", "pt_BR", "zh-Hans-CN"); nil for any other language.
    public init?(identifier: String) {
        let code = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        guard let language = CueLanguage(rawValue: code) else { return nil }
        self = language
    }

    /// Written without spaces between words: cues are looked for as substrings, and lengths are in characters.
    public var isSpaceless: Bool { self == .ja || self == .zh }
    public var isCJK: Bool { self == .ja || self == .ko || self == .zh }
}

/// One language's cue words, all written in the folded form of `TextKeys.norm` (lower case, no accents, no punctuation, single
/// spaces; "¿Qué?" becomes "que", "qu'est-ce que" becomes "qu est ce que"). Deliberately recall-oriented: precision comes from the
/// evidence gate and the model check.
struct CueSet: Sendable {
    /// Interrogative words and phrases. Spaced scripts: at the start of the sentence (after up to two discourse words). Others:
    /// anywhere (a Japanese or Chinese question word sits in the middle of the sentence).
    var interrogatives: [String]
    /// Verb-first question openers (auxiliaries), for languages where inversion marks a question.
    var inversion: [String] = []
    /// Embedded requests for information ("do you know", "remind me").
    var embedded: [String]
    /// Sentence-final question particles (Japanese, Korean, Chinese), matched at the end of the sentence.
    var particles: [String] = []
    /// A-not-A patterns and other particle phrases matched anywhere (Chinese).
    var particlePhrases: [String] = []
    /// Tag questions: the whole sentence is one of these ("right?", "¿no?").
    var tags: Set<String>
    /// Social and audio or screen checks.
    var social: [String]
    /// Opinion or proposal forms.
    var opinion: [String]
    /// Words that may precede the interrogative ("so", "y", "et").
    var discourse: Set<String> = []
    /// Whether the language has a verb tagger worth asking (en, es, fr, de, it, pt).
    var verbFirstTagger = false
}

extension CueSet {
    static func set(for language: CueLanguage) -> CueSet {
        switch language {
        case .en: english
        case .es: spanish
        case .fr: french
        case .de: german
        case .it: italian
        case .pt: portuguese
        case .ja: japanese
        case .ko: korean
        case .zh: chinese
        }
    }

    static let english = CueSet(
        interrogatives: ["what", "when", "where", "who", "whom", "whose", "which", "why", "how", "is there", "are there", "did we", "have we"],
        inversion: ["do", "does", "did", "is", "are", "was", "were", "can", "could", "will", "would", "should", "have", "has", "had", "may", "might", "shall"],
        embedded: ["do you know", "does anyone know", "does anybody know", "does somebody know", "anyone know", "anybody know", "remind me", "i wonder",
                   "can someone tell me", "could someone tell me", "could you tell me", "can you tell me", "any idea", "do you remember", "does anyone remember"],
        tags: ["right", "ok", "okay", "yeah", "no", "huh", "eh", "you know", "isn t it", "don t you think", "correct", "yes", "alright", "all right"],
        social: ["can you hear me", "can you see my screen", "can you see me", "can everyone hear", "can everybody hear", "can everyone see", "how are you",
                 "how s it going", "is that ok", "is that okay", "am i muted", "are you there", "is this working", "you re on mute", "you are on mute",
                 "does that make sense", "are we good", "can you hear", "can you see", "is everyone here", "is everybody here", "is that clear"],
        opinion: ["what do you think", "what are your thoughts", "what s your opinion", "shall we", "why don t we", "how about", "should we", "do you agree",
                  "would you like", "do you want to", "do you mind", "what would you like"],
        discourse: ["so", "and", "but", "well", "okay", "ok", "then", "now", "um", "uh", "like", "also", "actually"],
        verbFirstTagger: false)

    static let spanish = CueSet(
        interrogatives: ["que", "cual", "cuales", "cuando", "donde", "adonde", "quien", "quienes", "como", "cuanto", "cuanta", "cuantos", "cuantas",
                         "por que", "para que", "alguien sabe", "sabeis si", "saben si", "sabes si", "sabe si"],
        embedded: ["alguien sabe", "sabes si", "sabeis si", "saben si", "sabe si", "recuerdas", "recuerdan", "recordais", "me recuerdas", "me recordais",
                   "me pregunto", "le pregunto", "les pregunto", "quisiera saber", "quiero saber", "alguien me puede decir", "alguien recuerda", "alguien podria decirme", "me podeis decir", "me puedes decir"],
        tags: ["no", "verdad", "cierto", "vale", "eh", "si", "ok", "okay", "de acuerdo", "sabes", "no es verdad", "no es cierto"],
        social: ["me oyes", "me ois", "me oyen", "me escuchas", "me escuchan", "me escuchais", "se me escucha", "se me oye", "me veis", "me ves",
                 "ven mi pantalla", "veis mi pantalla", "ves mi pantalla", "como estas", "como estais", "como esta usted", "esta bien", "estan ahi",
                 "estas ahi", "esta en silencio", "estoy en silencio", "tiene sentido", "esta claro", "se entiende", "se ve mi pantalla"],
        opinion: ["que opinas", "que opinan", "que opinais", "que os parece", "que te parece", "que les parece", "que pensais", "que piensas", "que piensan",
                  "y si", "deberiamos", "queremos", "quereis", "quieres", "quieren", "estais de acuerdo", "estas de acuerdo", "estan de acuerdo", "te parece"],
        discourse: ["y", "pero", "entonces", "bueno", "pues", "bien", "ahora", "ya", "a ver", "eh", "este", "o sea"],
        verbFirstTagger: true)

    static let french = CueSet(
        interrogatives: ["qu est ce que", "qu est ce qui", "est ce que", "est ce qu", "quand", "ou", "qui", "que", "quoi", "comment", "combien", "pourquoi", "quel", "quelle", "quels",
                         "quelles", "lequel", "laquelle", "lesquels", "savez vous", "sais tu", "tu sais si", "vous savez si"],
        embedded: ["savez vous", "sais tu", "tu sais si", "vous savez si", "quelqu un sait", "quelqu un se souvient", "rappelez moi", "rappelle moi",
                   "je me demande", "pouvez vous me dire", "peux tu me dire", "vous souvenez vous", "tu te souviens"],
        tags: ["non", "hein", "n est ce pas", "d accord", "ok", "okay", "oui", "vrai", "pas vrai", "right", "c est ca"],
        social: ["on m entend", "vous m entendez", "tu m entends", "m entendez vous", "vous voyez mon ecran", "tu vois mon ecran", "ca va", "comment ca va",
                 "comment allez vous", "comment vas tu", "c est bon", "ca marche", "vous etes la", "tu es la", "mon micro", "suis je en sourdine",
                 "c est clair", "vous me voyez"],
        opinion: ["qu en pensez vous", "qu est ce que vous en pensez", "qu en penses tu", "qu est ce que tu en penses", "et si", "on pourrait", "on devrait",
                  "voulez vous", "veux tu", "ca vous va", "ca te va", "vous etes d accord", "tu es d accord", "si on"],
        discourse: ["et", "mais", "alors", "donc", "bon", "ben", "euh", "bien", "maintenant", "puis", "ou bien", "et puis"],
        verbFirstTagger: true)

    static let german = CueSet(
        interrogatives: ["was", "wann", "wo", "woher", "wohin", "wer", "wen", "wem", "wessen", "wie", "warum", "weshalb", "wieso", "welche", "welcher", "welches",
                         "welchen", "welchem", "gibt es", "weisst du", "wisst ihr", "wissen sie", "weiss jemand"],
        inversion: ["ist", "sind", "war", "waren", "hat", "haben", "hatte", "kann", "konnen", "kannst", "konnt", "wird", "werden", "wurde", "soll", "sollen",
                    "darf", "durfen", "muss", "mussen", "gibt", "hast", "habt", "bist", "seid", "will", "wollen", "wollt", "stimmt", "geht", "gehen", "reicht",
                    "passt", "funktioniert"],
        embedded: ["weisst du", "wisst ihr", "wissen sie", "weiss jemand", "weiss einer", "erinnert sich jemand", "erinnerst du dich", "erinnern sie sich",
                   "ich frage mich", "kann mir jemand sagen", "kannst du mir sagen", "konnen sie mir sagen", "wisst ihr noch"],
        tags: ["oder", "ne", "nicht", "richtig", "ja", "gell", "nicht wahr", "stimmt", "ok", "okay", "oder nicht", "stimmt s", "ne wahr"],
        social: ["hort ihr mich", "hort ihr", "hort ihr mich alle", "konnt ihr mich horen", "konnen sie mich horen", "kannst du mich horen", "seht ihr meinen bildschirm",
                 "sehen sie meinen bildschirm", "konnt ihr meinen bildschirm sehen", "wie geht", "wie gehts", "ist das okay", "ist das ok", "bin ich stumm",
                 "seid ihr da", "ist das klar", "passt das", "bin ich zu horen", "sieht man meinen bildschirm"],
        opinion: ["was denkt ihr", "was meint ihr", "was denken sie", "was meinst du", "was haltet ihr", "was halten sie", "sollen wir", "wollen wir", "warum nicht",
                  "seid ihr einverstanden", "bist du einverstanden", "was haltet ihr davon"],
        discourse: ["und", "aber", "also", "dann", "ja", "na", "ahm", "ahh", "okay", "ok", "jetzt", "dazu"],
        verbFirstTagger: false)

    static let italian = CueSet(
        interrogatives: ["che cosa", "cosa", "che", "quando", "dove", "chi", "come", "quanto", "quanta", "quanti", "quante", "perche", "quale", "quali", "qual",
                         "sai se", "sapete se", "qualcuno sa"],
        embedded: ["sai se", "sapete se", "sa se", "qualcuno sa", "ti ricordi", "vi ricordate", "qualcuno ricorda", "mi ricordate", "mi chiedo",
                   "puoi dirmi", "potete dirmi", "mi puoi dire", "mi potete dire"],
        tags: ["vero", "no", "giusto", "eh", "ok", "okay", "sì", "si", "d accordo", "non e vero", "capito"],
        social: ["mi sentite", "mi senti", "mi sentite bene", "vedete lo schermo", "vedete il mio schermo", "vedi il mio schermo", "come stai", "come state",
                 "va bene", "sono muto", "sono in muto", "tutto ok", "ci siete", "ci sei", "e chiaro", "mi vedete", "si sente"],
        opinion: ["che ne pensate", "che ne pensi", "cosa ne pensate", "cosa ne pensi", "e se", "dovremmo", "vogliamo", "volete", "vuoi", "siete d accordo",
                  "sei d accordo", "che ne dite", "che ne dici"],
        discourse: ["e", "ma", "allora", "quindi", "beh", "dunque", "ecco", "ok", "okay", "adesso", "ora", "poi"],
        verbFirstTagger: true)

    static let portuguese = CueSet(
        interrogatives: ["o que", "que", "quando", "onde", "quem", "como", "quanto", "quanta", "quantos", "quantas", "por que", "porque", "qual", "quais",
                         "voce sabe", "alguem sabe", "voces sabem"],
        embedded: ["voce sabe", "voces sabem", "o senhor sabe", "alguem sabe", "alguem lembra", "voce lembra", "voces lembram", "me lembra", "me pergunto",
                   "pode me dizer", "podem me dizer", "alguem pode me dizer", "voce se lembra"],
        tags: ["ne", "certo", "ta", "nao", "ok", "okay", "ne nao", "sim", "verdade", "ta bom", "nao e", "entendeu", "ta certo"],
        social: ["voces me ouvem", "voce me ouve", "me ouvem", "me escutam", "voces me escutam", "voces estao vendo", "estao vendo minha tela",
                 "vendo minha tela", "voce ve minha tela", "como vai", "como voce esta", "como voces estao", "tudo bem", "esta ok", "estou mudo", "estou no mudo",
                 "esta claro", "voces estao ai", "voce esta ai", "da pra ouvir"],
        opinion: ["o que voce acha", "o que voces acham", "o que acham", "o que acha", "e se", "devemos", "vamos", "voce quer", "voces querem", "concordam",
                  "voce concorda", "que tal", "que tal se"],
        discourse: ["e", "mas", "entao", "bom", "bem", "ne", "ah", "ok", "okay", "agora", "tipo", "ai"],
        verbFirstTagger: true)

    static let japanese = CueSet(
        interrogatives: ["何", "なに", "なん", "いつ", "どこ", "誰", "だれ", "どう", "どうして", "なぜ", "いくら", "どれ", "どの", "どちら", "どんな", "どなた"],
        embedded: ["知っていますか", "知ってる", "知っていますでしょうか", "教えてください", "教えて", "覚えていますか", "覚えてる", "分かりますか", "わかりますか", "確認させてください"],
        particles: ["ですか", "ますか", "でしょうか", "ましたか", "ませんか", "ですかね", "かな", "かね", "か", "の", "っけ", "かしら"],
        tags: ["ね", "でしょ", "よね", "じゃない", "でしょう", "ですよね", "ですね", "そうですね", "ない"],
        social: ["聞こえますか", "聞こえてますか", "聞こえてる", "見えますか", "見えてますか", "画面", "大丈夫ですか", "お元気ですか", "元気", "よろしいですか", "音声", "ミュート", "繋がって", "つながって"],
        opinion: ["どう思います", "どうでしょう", "どうでしょうか", "しませんか", "しましょうか", "ましょうか", "どう思う", "いかがでしょう", "してはどう", "どうかな"])

    static let korean = CueSet(
        interrogatives: ["뭐", "무엇", "언제", "어디", "누구", "어떻게", "왜", "얼마", "어느", "몇", "무슨", "어떤"],
        embedded: ["아세요", "알아요", "알고 계세요", "기억나", "기억하세요", "기억해", "알려 주", "알려주", "말씀해 주", "궁금"],
        particles: ["습니까", "ㅂ니까", "나요", "가요", "까요", "니까", "죠", "까", "니", "나", "지요", "어요", "을까", "ㄹ까"],
        tags: ["맞죠", "그렇죠", "맞지", "그치", "그렇지", "죠", "네", "응", "그렇지 않나요"],
        social: ["들리", "들려요", "들리세요", "보이", "보여요", "화면", "괜찮", "잘 지내", "음소거", "안녕하세요", "연결"],
        opinion: ["어떻게 생각", "어때요", "할까요", "하면 어떨까", "어떨까요", "하는 게 어때", "동의", "찬성"])

    static let chinese = CueSet(
        interrogatives: ["什么", "什么时候", "哪里", "哪儿", "谁", "怎么", "怎么样", "为什么", "多少", "几", "哪个", "哪些", "甚麼", "為什麼", "哪裡", "怎樣", "多久", "是否"],
        embedded: ["你知道", "有人知道", "还记得", "还记不记得", "请问", "告诉我", "提醒我", "有谁知道", "您知道", "能告诉", "可以告诉"],
        particles: ["吗", "呢", "么", "嘛", "吧"],
        particlePhrases: ["是不是", "有没有", "能不能", "可不可以", "对不对", "好不好", "行不行", "会不会", "要不要", "是否"],
        tags: ["对吧", "是吧", "好吗", "对不对", "对吗", "是不是", "好吧", "行吗", "可以吗"],
        social: ["听得到", "听得见", "看得到", "看得见", "屏幕", "你好吗", "您好吗", "没问题吧", "听到吗", "看到吗", "静音", "能听到", "能看到"],
        opinion: ["你觉得", "你认为", "你们觉得", "我们是不是应该", "好不好", "要不要", "大家觉得", "你们认为", "怎么看"])
}

