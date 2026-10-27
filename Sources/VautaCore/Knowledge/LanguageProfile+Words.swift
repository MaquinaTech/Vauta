// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Word lists for `LanguageProfile`. They are normalized with `TextKeys.norm`
/// when a profile is built, so accents and case do not matter here. Stopwords
/// cover function words plus the vocabulary every question about a meeting
/// shares ("meeting", "said", "decided"), which carries no search signal.
extension LanguageProfile {
    static let stopwordLists: [String: [String]] = [
        "en": """
            a about above after again against all also am an and any are as at be because been before being below between both \
            but by can could did do does doing down during each else few for from further had has have having he her here hers \
            him his how i if in into is it its itself just me more most my no nor not now of off on once only or other our ours \
            out over own same she should so some such than that the their theirs them then there these they this those through \
            to too under until up very was we were what when where which while who whom whose why will with would you your yours \
            meeting meetings call said say says told talk talked discuss discussed decide decided agreed thing things something \
            anything everything someone anyone last next week today yesterday tomorrow ago
            """.split(separator: " ").map(String.init),
        "es": """
            a al algo algun alguna algunas alguno algunos ante antes aqui asi aun bajo bien cada como con contra cual cuales \
            cuando cuanto de del desde donde dos el ella ellas ello ellos en entre era eran es esa esas ese eso esos esta estaba \
            estas este esto estos fue fueron ha habia hace han hasta hay la las le les lo los mas me mi mis mucho muy nada ni no \
            nos nosotros o otra otras otro otros para pero poco por porque que quien quienes se sea segun ser si sin sobre son \
            su sus tambien tan tanto te tiene tienen todo todos tu tus un una unas uno unos y ya yo hemos dijo dije dijimos \
            reunion reuniones cosas hablamos hablo decidio decidimos quedamos semana hoy ayer manana pasado ultima ultimo
            """.split(separator: " ").map(String.init),
        "fr": """
            a ai au aux avec avoir c ce ces cet cette comme dans de des du elle elles en est et etait ete eu il ils je la le les \
            leur leurs lui ma mais me meme mes moi mon ne nos notre nous on ou par pas pour qu quand que quel quelle quels qui \
            sa sans se ses son sont sur ta te tes toi ton tous tout tu un une vos votre vous y quoi comment pourquoi ou dit \
            reunion reunions decide decidé chose choses semaine aujourd hui hier demain dernier derniere
            """.split(separator: " ").map(String.init),
        "de": """
            aber alle als also am an auch auf aus bei bin bis bist da damit dann das dass dein dem den der des dich die dir du \
            durch ein eine einem einen einer eines er es fur hat hatte haben ich ihr im in ist ja jetzt kann kein mich mir mit \
            nach nicht noch nur oder schon sein sich sie sind so uber um und uns unser vom von vor war waren was wer wie wir \
            wo wurde zu zum zur welche welcher warum wann wo gesagt besprechung meeting termin entschieden beschlossen sache \
            woche heute gestern morgen letzte letzten
            """.split(separator: " ").map(String.init),
        "it": """
            a ad al alla alle allo ai agli anche come con da dal dalla dei del della delle dello di e ed era gli ha hanno ho i \
            il in io la le lei lo loro lui ma mi mio ne nei nel nella noi non o per perche piu quale quali quando quanto que \
            questa questo qui se si sono su sua sue suo suoi tra tu un una uno vi chi cosa come dove detto riunione riunioni \
            deciso settimana oggi ieri domani ultimo ultima abbiamo avete avuto hai siamo siete sei stato stata essere avere \
            fatto fare
            """.split(separator: " ").map(String.init),
        "pt": """
            a ao aos as com como da das de do dos e ela elas ele eles em entre era essa esse esta este eu foi foram ha isso \
            isto ja la mais mas me meu minha muito na nas nao nem no nos o os ou para pela pelo por porque quando que quem se \
            sem ser seu sua sao tambem te tem um uma umas uns voce voces qual quais onde disse reuniao reunioes decidimos \
            decidiu coisa coisas semana hoje ontem amanha ultimo ultima
            """.split(separator: " ").map(String.init),
        "nl": """
            aan al als bij dat de den der des deze die dit doch door een en er had heb hebben heeft het hier hij hoe hun ik in \
            is je kan maar me met mij na naar niet nog nu of om ook op over te tot u uit van veel voor waar wat was we wel \
            werd wie wij worden zal ze zich zij zijn zo waarom wanneer welke gezegd vergadering besloten week vandaag gisteren \
            morgen vorige
            """.split(separator: " ").map(String.init),
        "ca": """
            a al als amb aquell aquella aquest aquesta aqui com de del dels el ella ells els en entre era es esta fins ha han \
            hem hi i jo la les li lo mes meu molt no nos o on per perque pero que qui quan se sense ser seu seva si sobre son \
            tambien tambe te tot tots un una uns unes va van vaig dir reunio reunions decidir setmana avui ahir dema
            """.split(separator: " ").map(String.init),
        "ja": [
            "の", "に", "は", "を", "た", "が", "で", "て", "と", "し", "れ", "さ", "ある", "いる", "も", "する", "から", "な",
            "こと", "として", "い", "や", "など", "なっ", "ない", "この", "ため", "その", "あっ", "よう", "また", "もの",
            "あり", "まで", "られ", "なる", "へ", "か", "だ", "これ", "によって", "により", "おり", "より", "による", "ず",
            "なり", "れる", "でも", "です", "ます", "ました", "何", "誰", "いつ", "どこ", "なぜ", "どう", "会議",
            "ミーティング", "言っ", "決め", "について", "まし", "ませ", "でし", "しょ", "う", "ござい", "くださ", "ください", "ね", "よ",
            "ん", "ので", "のか", "ですか", "ますか", "でしょ", "ただ", "ませんでした",
        ],
        "zh": [
            "的", "了", "和", "是", "就", "都", "而", "及", "与", "着", "或", "一个", "没有", "我们", "你们", "他们", "她们",
            "我", "你", "他", "她", "它", "这", "那", "这个", "那个", "在", "有", "也", "很", "吗", "呢", "吧", "啊", "什么",
            "谁", "哪", "哪里", "怎么", "为什么", "什么时候", "关于", "会议", "开会", "说", "说了", "决定", "上次", "今天",
            "昨天", "明天", "做", "做了", "对", "对于", "让", "给", "把", "被", "会", "要", "能", "可以", "应该", "还", "又", "才",
            "但", "但是", "怎样", "如何", "哪些", "多少",
        ],
        "ko": [
            "이", "그", "저", "것", "수", "등", "들", "및", "에서", "에", "의", "가", "을", "를", "은", "는", "으로", "로",
            "와", "과", "도", "다", "고", "하다", "있다", "없다", "무엇", "누구", "언제", "어디", "왜", "어떻게", "회의",
            "미팅", "말했", "결정",
        ],
    ]

    /// Fillers and pronouns that transcribers capitalize mid-sentence.
    static let fillerLists: [String: [String]] = [
        "es": ["yo", "vale", "bueno", "claro", "vamos", "venga", "mira", "oye", "hola", "gracias", "perfecto", "vale",
               "pues", "entonces", "exacto", "genial", "usted", "ustedes", "dios"],
        "ca": ["jo", "vale", "bueno", "clar", "doncs", "hola", "gracies", "perfecte", "molt"],
        "gl": ["eu", "vale", "bo", "claro", "ola", "grazas", "perfecto"],
        "en": ["yeah", "yes", "hello", "thanks", "right", "well", "sure", "great", "cool", "alright", "anyway", "actually",
               "basically", "okay", "god"],
        "fr": ["oui", "bon", "bien", "voila", "alors", "merci", "bonjour", "d'accord", "parfait", "dieu", "monsieur", "madame"],
        "it": ["ecco", "allora", "bene", "grazie", "ciao", "perfetto", "certo", "dio", "signore", "signora"],
        "pt": ["sim", "bom", "entao", "obrigado", "obrigada", "ola", "perfeito", "certo", "deus", "senhor", "senhora"],
        "nl": ["ja", "nee", "goed", "dus", "dank", "hallo", "prima", "precies", "meneer", "mevrouw"],
        "de": ["ja", "nein", "gut", "also", "danke", "hallo", "genau", "okay", "herr", "frau"],
    ]
}
