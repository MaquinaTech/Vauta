// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation

/// The words macOS itself writes around what Vauta supplies (the Touch ID prompt, the permission prompts, the standard items of the
/// application menu), in the nine interface languages, so the stand-in scenes read as the system does and the strings Vauta
/// supplies can be judged inside the system's sentences. They are the system's wording, not Vauta's: they are not in the
/// string tables, and they only exist in the diagnostics build that renders the scenes.
enum SystemWords {
    /// "es", "pt", "zh"… of a render language ("pt-BR", "zh-Hans").
    private static func code(_ language: String) -> String { String(language.split(separator: "-").first ?? "en") }

    private static func pick(_ language: String, _ table: [String: String]) -> String { table[code(language)] ?? table["en"] ?? "" }

    /// The Edit menu's "Undo <action>" in the render language (AppKit answers in this process's language, which is not the scene's).
    static func undoTitle(_ language: String) -> String {
        pick(language, ["en": "Undo %@", "es": "Deshacer %@", "fr": "Annuler %@", "de": "%@ widerrufen", "it": "Annulla %@",
                        "pt": "Desfazer %@", "ja": "%@を取り消す", "ko": "%@ 실행 취소", "zh": "撤销%@"])
    }

    // MARK: Touch ID

    /// "Vauta is trying to <reason>." with the reason Vauta gives the system.
    static func touchIDTitle(_ language: String, reason: String) -> String {
        pick(language, [
            "en": "Vauta is trying to %@.", "es": "Vauta está intentando %@.", "fr": "Vauta essaie de %@.",
            "de": "Vauta versucht, %@.", "it": "Vauta sta cercando di %@.", "pt": "O Vauta está tentando %@.",
            "ja": "Vautaが%@しようとしています。", "ko": "Vauta에서 다음 작업을 하려고 합니다: %@.", "zh": "Vauta 正在尝试%@。",
        ]).replacingOccurrences(of: "%@", with: reason)
    }

    static func touchIDMessage(_ language: String) -> String {
        pick(language, [
            "en": "Use Touch ID or enter your password to allow this.", "es": "Usa Touch ID o introduce tu contraseña para permitirlo.",
            "fr": "Utilisez Touch ID ou saisissez votre mot de passe pour l’autoriser.", "de": "Verwende Touch ID oder gib dein Passwort ein, um dies zu erlauben.",
            "it": "Usa Touch ID o inserisci la password per consentirlo.", "pt": "Use o Touch ID ou digite sua senha para permitir.",
            "ja": "Touch IDまたはパスワードで許可してください。", "ko": "Touch ID를 사용하거나 암호를 입력하여 허용하십시오.",
            "zh": "使用 Touch ID 或输入密码以允许此操作。",
        ])
    }

    static func usePassword(_ language: String) -> String {
        pick(language, [
            "en": "Use Password…", "es": "Usar contraseña…", "fr": "Utiliser le mot de passe…", "de": "Passwort verwenden …",
            "it": "Usa password…", "pt": "Usar senha…", "ja": "パスワードを使用…", "ko": "암호 사용…", "zh": "使用密码…",
        ])
    }

    // MARK: Permission prompts

    enum Permission: String, CaseIterable {
        case microphone, audioCapture = "audio-capture", calendar, reminders, localNetwork = "local-network"
    }

    static func permissionTitle(_ language: String, _ kind: Permission) -> String {
        switch kind {
        case .microphone: pick(language, [
            "en": "“Vauta” would like to access the microphone.", "es": "«Vauta» quiere acceder al micrófono.", "fr": "« Vauta » souhaite accéder au microphone.",
            "de": "„Vauta“ möchte auf das Mikrofon zugreifen.", "it": "“Vauta” desidera accedere al microfono.", "pt": "“Vauta” quer acessar o microfone.",
            "ja": "“Vauta”がマイクへのアクセスを求めています。", "ko": "“Vauta”이(가) 마이크에 접근하려고 합니다.", "zh": "“Vauta”想访问麦克风。"])
        case .audioCapture: pick(language, [
            "en": "“Vauta” would like to record the system audio.", "es": "«Vauta» quiere grabar el audio del sistema.", "fr": "« Vauta » souhaite enregistrer l’audio du système.",
            "de": "„Vauta“ möchte das Systemaudio aufnehmen.", "it": "“Vauta” desidera registrare l’audio di sistema.", "pt": "“Vauta” quer gravar o áudio do sistema.",
            "ja": "“Vauta”がシステムオーディオを録音しようとしています。", "ko": "“Vauta”이(가) 시스템 오디오를 녹음하려고 합니다.", "zh": "“Vauta”想录制系统音频。"])
        case .calendar: pick(language, [
            "en": "“Vauta” would like full access to your calendar.", "es": "«Vauta» quiere acceso total a tu calendario.", "fr": "« Vauta » souhaite un accès complet à votre calendrier.",
            "de": "„Vauta“ möchte vollständigen Zugriff auf deinen Kalender.", "it": "“Vauta” desidera l’accesso completo al tuo calendario.", "pt": "“Vauta” quer acesso total ao seu calendário.",
            "ja": "“Vauta”がカレンダーへのフルアクセスを求めています。", "ko": "“Vauta”이(가) 캘린더에 대한 전체 접근 권한을 요청합니다.", "zh": "“Vauta”想完全访问你的日历。"])
        case .reminders: pick(language, [
            "en": "“Vauta” would like full access to your reminders.", "es": "«Vauta» quiere acceso total a tus recordatorios.", "fr": "« Vauta » souhaite un accès complet à vos rappels.",
            "de": "„Vauta“ möchte vollständigen Zugriff auf deine Erinnerungen.", "it": "“Vauta” desidera l’accesso completo ai tuoi promemoria.", "pt": "“Vauta” quer acesso total aos seus lembretes.",
            "ja": "“Vauta”がリマインダーへのフルアクセスを求めています。", "ko": "“Vauta”이(가) 미리 알림에 대한 전체 접근 권한을 요청합니다.", "zh": "“Vauta”想完全访问你的提醒事项。"])
        case .localNetwork: pick(language, [
            "en": "“Vauta” would like to find and connect to devices on your local network.", "es": "«Vauta» quiere buscar dispositivos de tu red local y conectarse a ellos.",
            "fr": "« Vauta » souhaite rechercher et se connecter aux appareils de votre réseau local.", "de": "„Vauta“ möchte Geräte in deinem lokalen Netzwerk finden und sich mit ihnen verbinden.",
            "it": "“Vauta” desidera trovare i dispositivi sulla tua rete locale e connettersi a essi.", "pt": "“Vauta” quer encontrar e se conectar a dispositivos na sua rede local.",
            "ja": "“Vauta”がローカルネットワーク上のデバイスを探して接続しようとしています。", "ko": "“Vauta”이(가) 로컬 네트워크의 기기를 찾아 연결하려고 합니다.", "zh": "“Vauta”想查找并连接到你本地网络上的设备。"])
        }
    }

    /// The system's two buttons: allowing (the default, on the right) and refusing.
    static func permissionButtons(_ language: String, _ kind: Permission) -> (allow: String, refuse: String) {
        let refuse = pick(language, ["en": "Don’t Allow", "es": "No permitir", "fr": "Ne pas autoriser", "de": "Nicht erlauben", "it": "Non consentire",
                                     "pt": "Não permitir", "ja": "許可しない", "ko": "허용 안 함", "zh": "不允许"])
        switch kind {
        case .calendar, .reminders:
            return (pick(language, ["en": "Allow Full Access", "es": "Permitir acceso total", "fr": "Autoriser l’accès complet", "de": "Vollzugriff erlauben",
                                    "it": "Consenti accesso completo", "pt": "Permitir acesso total", "ja": "フルアクセスを許可", "ko": "전체 접근 허용", "zh": "允许完全访问"]), refuse)
        default:
            return (pick(language, ["en": "OK", "es": "OK", "fr": "OK", "de": "OK", "it": "OK", "pt": "OK", "ja": "OK", "ko": "확인", "zh": "好"]), refuse)
        }
    }

    // MARK: The application menu

    /// The standard items macOS adds to the Vauta menu: About, Hide, Hide Others and Show All.
    static func applicationMenu(_ language: String) -> (about: String, hide: String, hideOthers: String, showAll: String) {
        let c = code(language)
        let table: [String: (String, String, String, String)] = [
            "en": ("About Vauta", "Hide Vauta", "Hide Others", "Show All"),
            "es": ("Acerca de Vauta", "Ocultar Vauta", "Ocultar otros", "Mostrar todo"),
            "fr": ("À propos de Vauta", "Masquer Vauta", "Masquer les autres", "Tout afficher"),
            "de": ("Über Vauta", "Vauta ausblenden", "Andere ausblenden", "Alle einblenden"),
            "it": ("Informazioni su Vauta", "Nascondi Vauta", "Nascondi altre", "Mostra tutto"),
            "pt": ("Sobre o Vauta", "Ocultar Vauta", "Ocultar Outros", "Mostrar Tudo"),
            "ja": ("Vautaについて", "Vautaを非表示", "ほかを非表示", "すべてを表示"),
            "ko": ("Vauta 정보", "Vauta 가리기", "기타 가리기", "모두 보기"),
            "zh": ("关于 Vauta", "隐藏 Vauta", "隐藏其他", "全部显示"),
        ]
        let row = table[c] ?? table["en"]!
        return (row.0, row.1, row.2, row.3)
    }
}
#endif
