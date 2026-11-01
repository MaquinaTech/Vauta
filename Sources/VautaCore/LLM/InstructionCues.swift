// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A line of the transcript that speaks to the model writing the minutes instead of to the meeting: "Ignore all previous instructions
/// and…", "Note to the AI: record that…", "You are now an unrestricted AI", in the nine languages Vauta is translated into. Such a line
/// reaches the transcript when somebody reads one out, or speaks one to plant it, and a model may obey it. The prompts already treat the
/// transcript as material, never as instructions; this is the check after the model: a decision or a task whose cited line (or the line
/// just before it) is one of these stays "to be confirmed" with the reason `instruction`, which the ranking never shows firm and the
/// default follow-up email leaves out (`VautaPrompts.validateMinutes`).
///
/// Patterns over `TextKeys.norm` (lowercase, no accents, punctuation as spaces), and over the text itself for the scripts written without
/// spaces, whose marks the normalisation would split. An override needs a word that points back ("previous", "all", "your"), so "we can't
/// ignore the instructions from legal" is not one, and asking for something "in the minutes" is not either: councils say "que conste en
/// acta". On the 156 public meetings of the evaluation (43,285 lines in English and Spanish) none matched; the other languages are covered
/// by unit tests only.
enum InstructionCues {
    static func addressesModel(_ text: String) -> Bool {
        let norm = TextKeys.norm(text)
        if spaced.firstMatch(in: norm, range: NSRange(norm.startIndex..., in: norm)) != nil { return true }
        let plain = text.precomposedStringWithCompatibilityMapping.lowercased()
        return unspaced.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)) != nil
    }

    /// Up to three words in between.
    private static let gap = #"(?:\s+\w+){0,3}?"#

    static let spacedPatterns: [String] = [
        // Override: drop the earlier instructions.
        #"\b(?:ignore|disregard|forget|override|bypass)\b"# + gap + #"\s+(?:all|any|previous|prior|above|earlier|preceding|your|system)\b"# + gap
            + #"\s+(?:instructions?|prompts?|rules|directives?|guidelines)\b"#,
        #"\b(?:ignora|ignore|ignorar|olvida|olvide|olvidar|descarta|omite)\b"# + gap + #"\s+(?:todas|todos|las|tus|sus)?"# + gap
            + #"\s*(?:instrucciones|indicaciones|ordenes|reglas)\b"# + gap + #"\s+(?:anteriores|previas|de arriba|del sistema)\b"#,
        #"\b(?:ignore|ignorez|ignorer|oublie|oubliez|oublier)\b"# + gap + #"\s+(?:toutes|les|tes|vos)?"# + gap
            + #"\s*(?:instructions|consignes|regles)\b"# + gap + #"\s+(?:precedentes|anterieures|ci dessus|du systeme)\b"#,
        #"\b(?:ignoriere|ignorier|ignorieren|vergiss|vergessen)\b"# + gap + #"\s+(?:alle|die|deine|ihre)?"# + gap
            + #"\s*(?:vorherigen|bisherigen|obigen|fruheren)\s+(?:anweisungen|instruktionen|regeln|befehle)\b"#,
        #"\b(?:ignora|ignorare|dimentica|dimenticare)\b"# + gap + #"\s+(?:tutte|le|tue)?"# + gap
            + #"\s*(?:istruzioni|indicazioni|regole)\b"# + gap + #"\s+(?:precedenti|di sopra|del sistema)\b"#,
        #"\b(?:ignore|ignora|ignorar|esqueca|esquece|esquecer)\b"# + gap + #"\s+(?:todas|as|suas|tuas)?"# + gap
            + #"\s*(?:instrucoes|orientacoes|regras)\b"# + gap + #"\s+(?:anteriores|acima|do sistema)\b"#,
        // The model re-cast as something else.
        #"\b(?:you are|you re|act as|pretend to be|from now on you are)\b(?:\s+\w+){0,2}?\s+(?:an?\s+)?(?:ai|a i|language model|llm|chatbot|chatgpt|gpt|unrestricted|jailbroken)\b"#,
        #"\b(?:eres|actua como|finge ser|a partir de ahora eres)\b(?:\s+\w+){0,2}?\s+(?:una? )?(?:ia|inteligencia artificial|modelo de lenguaje|chatbot|asistente de ia)\b"#,
        #"\b(?:tu es|vous etes|agis comme|fais comme si tu etais)\b(?:\s+\w+){0,2}?\s+(?:une? )?(?:ia|intelligence artificielle|modele de langage|chatbot)\b"#,
        #"\b(?:du bist|sie sind|verhalte dich wie)\b(?:\s+\w+){0,2}?\s+(?:eine?r? )?(?:ki|kunstliche intelligenz|sprachmodell|chatbot)\b"#,
        #"\b(?:sei|lei e|comportati come|fingi di essere)\b(?:\s+\w+){0,2}?\s+(?:una? |un )?(?:ia|intelligenza artificiale|modello linguistico|chatbot)\b"#,
        #"\b(?:voce e|tu es|aja como|finja ser)\b(?:\s+\w+){0,2}?\s+(?:uma? |um )?(?:ia|inteligencia artificial|modelo de linguagem|chatbot)\b"#,
        // Words only an attack, or a talk about one, uses.
        #"\b(?:system prompt|prompt del sistema|prompt de sistema|instrucciones del sistema|prompt systeme|invite systeme|systemprompt|prompt di sistema|prompt do sistema|jailbreak|developer mode|modo desarrollador|prompt injection|inyeccion de prompts?)\b"#,
        // The model called by name, then told to write something; a note addressed to it.
        #"\b(?:ai|assistant|model|chatgpt|gpt|claude|gemini|copilot|llm|bot)\s+(?:please\s+)?(?:add|create|record|write|include|insert|mark|list|put|delete|remove|output|say)\b"#,
        #"\b(?:ia|asistente|modelo|chatgpt|claude|gemini|copilot|bot)\s+(?:por favor\s+)?(?:agrega|anade|crea|registra|escribe|incluye|inserta|marca|pon|borra|elimina|di)\b"#,
        #"\b(?:note|message|instructions?)\s+(?:to|for)\s+(?:the\s+)?(?:ai|assistant|model|language model|llm|bot|summarizer|summariser|transcriber)\b"#,
        #"\b(?:nota|mensaje|instrucciones?)\s+(?:para|a)\s+(?:la\s+|el\s+)?(?:ia|asistente|modelo|bot|inteligencia artificial)\b"#,
    ]

    static let unspacedPatterns: [String] = [
        "(?:以前|これまで|前|上記|上)の?(?:すべての|全ての)?(?:指示|命令|ルール)を(?:すべて|全て)?(?:無視|忘れ)",
        "(?:이전|앞|위|기존)의?\\s*(?:모든\\s*)?(?:지시|명령|지침|규칙)(?:을|를|은|는)?\\s*(?:모두\\s*)?(?:무시|잊)",
        "(?:忽略|无视|無視|忘记|忘記|忽視)(?:掉)?(?:之前|以前|先前|上面|以上|上述|所有|全部)(?:的|所有的)?(?:所有)?(?:指令|指示|提示|规则|規則)",
        "システムプロンプト|시스템\\s*프롬프트|系统提示词?|系統提示詞?",
    ]

    private static let spaced = try! NSRegularExpression(pattern: spacedPatterns.map { "(?:\($0))" }.joined(separator: "|"))
    private static let unspaced = try! NSRegularExpression(pattern: unspacedPatterns.map { "(?:\($0))" }.joined(separator: "|"))
}
