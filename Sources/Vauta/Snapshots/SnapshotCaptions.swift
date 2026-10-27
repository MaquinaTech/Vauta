// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// Invented captions for the snapshots: what the others say and its translation into the interface language.
struct CaptionSample {
    let pair: TranslationPair
    let originals: [String]
    let translations: [String]
    /// The third translation as it reads while the third original is still being spoken: cut at the same point as the
    /// original (a partial translation never holds words the speaker has not said yet).
    var partialThird: String? = nil
    /// The third original while it is being spoken, when cutting it by words would leave it ahead of its translation.
    var partialThirdOriginal: String? = nil
    /// The second translation and original while being spoken, cut after the verb (never on a dangling article).
    var partialSecond: String? = nil
    var partialSecondOriginal: String? = nil

    /// English speakers translated into `language`; for English, Spanish speakers.
    static func forLanguage(_ language: String) -> CaptionSample {
        let english = [
            "Let’s move the launch to the second week of March.",
            "Legal still needs to review the new contract.",
            "Can everyone send me their estimates by Friday?",
        ]
        let spanish = [
            "Pasemos el lanzamiento a la segunda semana de marzo.",
            "Legal todavía tiene que revisar el nuevo contrato.",
            "¿Podéis enviarme vuestras estimaciones antes del viernes?",
        ]
        let translations: [String: [String]] = [
            "en": english,
            "es": spanish,
            "fr": ["Reportons le lancement à la deuxième semaine de mars.", "Le service juridique doit encore relire le nouveau contrat.",
                   "Pouvez-vous tous m’envoyer vos estimations avant vendredi ?"],
            "de": ["Verschieben wir den Start auf die zweite Märzwoche.", "Die Rechtsabteilung muss den neuen Vertrag noch prüfen.",
                   "Könnt ihr mir bitte bis Freitag eure Schätzungen schicken?"],
            "it": ["Spostiamo il lancio alla seconda settimana di marzo.", "L’ufficio legale deve ancora rivedere il nuovo contratto.",
                   "Potete mandarmi le vostre stime entro venerdì?"],
            "pt-BR": ["Passemos o lançamento para a segunda semana de março.", "O jurídico ainda precisa revisar o novo contrato.",
                      "Podem me enviar suas estimativas até sexta-feira?"],
            "ja": ["発売を3月の第2週に延期しましょう。", "法務部はまだ新しい契約書を確認する必要があります。", "皆さん、金曜日までに見積もりを送っていただけますか。"],
            "ko": ["출시를 3월 둘째 주로 옮기죠.", "법무팀이 아직 새 계약서를 검토해야 합니다.", "다들 금요일까지 견적서를 보내 주실 수 있나요?"],
            "zh-Hans": ["我们把发布推迟到三月第二周吧。", "法务部还需要审核新合同。", "大家能在周五之前把估算发给我吗？"],
        ]
        if language == "en" {
            return CaptionSample(pair: TranslationPair(source: Locale.Language(identifier: "es"), target: Locale.Language(identifier: "en")),
                                 originals: spanish, translations: english,
                                 partialThird: "Can everyone send me their estimates",
                                 partialThirdOriginal: "¿Podéis enviarme vuestras estimaciones",
                                 partialSecond: "Legal still needs to review", partialSecondOriginal: "Legal todavía tiene que revisar")
        }
        // The English original is cut after "…their estimates".
        let partialThirds: [String: String] = [
            "fr": "Pouvez-vous tous m’envoyer vos estimations",
            "de": "Könnt ihr mir eure Schätzungen",
            "es": "¿Podéis enviarme vuestras estimaciones",
            "it": "Potete mandarmi le vostre stime",
            "pt-BR": "Podem me enviar suas estimativas",
            "ja": "皆さん、見積もりを送っ",
            "ko": "다들 견적서를 보내",
            "zh-Hans": "大家能把估算发给我",
        ]
        let partialSeconds: [String: String] = [
            "es": "Legal todavía tiene que revisar",
            "fr": "Le service juridique doit encore relire",
            "de": "Die Rechtsabteilung muss den neuen Vertrag",
            "it": "L’ufficio legale deve ancora rivedere",
            "pt-BR": "O jurídico ainda precisa revisar",
            "ja": "法務部はまだ新しい契約書を",
            "ko": "법무팀이 아직 새 계약서를",
            "zh-Hans": "法务部还需要审核",
        ]
        return CaptionSample(pair: TranslationPair(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: language)),
                             originals: english, translations: translations[language] ?? english, partialThird: partialThirds[language],
                             partialSecond: partialSeconds[language], partialSecondOriginal: "Legal still needs to review")
    }

    /// Two sentences in one caption: a space between them, except in a script written without spaces, where the
    /// sentence's own full-width punctuation already leaves the gap.
    static func joined(_ first: String, _ second: String, language: Locale.Language) -> String {
        switch CaptionText.unspacedScript(language) {
        case .japanese, .chinese: first + second
        default: first + " " + second
        }
    }

    /// The third sentence cut short, as it is while being spoken.
    func partial(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 3 else { return String(text.prefix(max(1, text.count * 2 / 3))) }
        return words.dropLast(max(1, words.count / 4)).joined(separator: " ")
    }

    func lines(upTo count: Int, partialLast: Bool) -> [CaptionLine] {
        (0..<count).map { index in
            let isPartial = partialLast && index == count - 1
            let original = index == 2 ? partialThirdOriginal : index == 1 ? partialSecondOriginal : nil
            let translation = index == 2 ? partialThird : index == 1 ? partialSecond : nil
            return CaptionLine(id: index,
                               original: isPartial ? original ?? partial(originals[index]) : originals[index],
                               translation: isPartial ? translation ?? partial(translations[index]) : translations[index],
                               state: isPartial ? .partial : .final)
        }
    }

    /// Languages offered in Settings.
    var targets: [TranslationTarget] {
        ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "ru", "nl"]
            .map(Locale.Language.init(identifier:))
            .filter { !$0.isSameLanguage(as: pair.source) }
            .enumerated()
            // The language the scene is rendered in is the one subtitles are translated into, so it is installed (the pane says "Automatic
            // (Japanese)" and cannot list Japanese as missing); the first few of the others are too.
            .map { TranslationTarget(language: $0.element, availability: $0.element.isSameLanguage(as: pair.target) || $0.offset < 5 ? .installed : .downloadable) }
    }

    /// A short conversation for the Meetings transcript: the others in their language, then the user.
    func transcript() -> (segments: [MeetingStore.StoredSegment], translations: [Int64: String]) {
        var segments: [MeetingStore.StoredSegment] = []
        var texts: [Int64: String] = [:]
        for (index, original) in originals.enumerated() {
            let id = Int64(index + 1)
            segments.append(MeetingStore.StoredSegment(id: id, meetingID: 1, channel: .others, start: Double(index) * 12,
                                                       end: Double(index) * 12 + 8, text: original))
            texts[id] = translations[index]
        }
        return (segments, texts)
    }
}

extension SnapshotFixture {
    var captionSample: CaptionSample { CaptionSample.forLanguage(language) }

    /// Settings → Translation for the caption sample: the meeting is transcribed in the sample's source language (Recording says the same) and
    /// translated into the interface language, so "Translate from" and "Translate to" can never be the same language.
    func installTranslationSettings(on live: LiveTranslationModel) {
        let sample = captionSample
        let source = sample.pair.source.minimalIdentifier
        preferences.transcriptionLanguage = SnapshotMode.catalog?.language(matching: source)?.id ?? (source == "es" ? "es-ES" : "en-US")
        live.installSnapshotTargets(sample.targets, source: sample.pair.source)
    }

    /// A captions model showing `snapshot`, with its own preferences.
    func captionsModel(_ snapshot: CaptionSnapshot, original: Bool = false, size: CaptionTextSize = .medium,
                       controls: Bool = false, downloadFailed: Bool = false, speakers: CaptionSpeakers = CaptionSpeakers()) -> LiveTranslationModel {
        let preferences = makeScratchPreferences()
        preferences.captionShowOriginal = original
        preferences.captionTextSize = size
        let model = LiveTranslationModel(snapshotPreferences: preferences, snapshot: snapshot, targets: captionSample.targets, speakers: speakers)
        model.controlsVisible = controls
        if downloadFailed { model.installSnapshotDownloadFailed() }
        return model
    }
}

extension SnapshotScenes {
    /// The captions panel on a mock video call, in each state.
    static func captionScene(_ name: String, original: Bool = false, size: CaptionTextSize = .medium, controls: Bool = false,
                             width: CGFloat = 640, downloadFailed: Bool = false,
                             speakers: (@MainActor (SnapshotFixture) -> CaptionSpeakers)? = nil,
                             snapshot: @escaping @MainActor (CaptionSample) -> CaptionSnapshot) -> SnapshotScene {
        let height = size.panelHeight(showOriginal: original)
        return SnapshotScene(name: "captions-\(name)", size: CGSize(width: max(720, width + 80), height: height + 80), isFloating: true) { fixture in
            let sample = fixture.captionSample
            let model = fixture.captionsModel(snapshot(sample), original: original, size: size, controls: controls, downloadFailed: downloadFailed,
                                              speakers: speakers?(fixture) ?? CaptionSpeakers())
            // The meeting's language is known while the captions wait for a target (the message names it).
            model.installSnapshotTargets(sample.targets, source: sample.pair.source)
            let view = ZStack {
                CallBackdrop()
                CaptionsView(model: model)
                    .frame(width: width, height: height)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            }
            return .init(view: AnyView(view))
        }
    }

    static var captions: [SnapshotScene] {
        [
            captionScene("idle") { CaptionSnapshot(pair: $0.pair, status: .listening) },
            captionScene("live") { CaptionSnapshot(pair: $0.pair, status: .listening, lines: $0.lines(upTo: 3, partialLast: true)) },
            captionScene("original", original: true) {
                CaptionSnapshot(pair: $0.pair, status: .listening, lines: $0.lines(upTo: 3, partialLast: true))
            },
            captionScene("controls", original: true, controls: true) { CaptionSnapshot(pair: $0.pair, status: .listening, lines: $0.lines(upTo: 3, partialLast: true)) },
            // The largest text in the default width: sentences wrap, so the oldest lines run up under the fade.
            captionScene("extra-large", size: .extraLarge) {
                CaptionSnapshot(pair: $0.pair, status: .listening, lines: $0.lines(upTo: 3, partialLast: true))
            },
            // The largest text in the narrowest panel: the newest caption alone can be taller than the room, so its last
            // lines stay and an ellipsis stands for the words before them.
            captionScene("extra-large-narrow", original: true, size: .extraLarge, width: CaptionTextSize.minimumWidth) { sample in
                var lines = sample.lines(upTo: 3, partialLast: false)
                // Two sentences in one caption, as a long run of speech arrives.
                // The original carries the same two sentences, so its end matches the end of the translation.
                lines[2].translation = CaptionSample.joined(lines[2].translation, sample.translations[0], language: sample.pair.target)
                lines[2].original = CaptionSample.joined(lines[2].original, sample.originals[0], language: sample.pair.source)
                return CaptionSnapshot(pair: sample.pair, status: .listening, lines: lines)
            },
            // The server improved the latest sentences: the hover bar says so.
            captionScene("refined", original: true, controls: true) { sample in
                var lines = sample.lines(upTo: 3, partialLast: true)
                lines[0].isRefined = true
                lines[1].isRefined = true
                return CaptionSnapshot(pair: sample.pair, status: .listening, lines: lines, refinement: .improved)
            },
            // The server was too slow or unreachable: Apple's captions stay, a discreet note in the hover bar.
            captionScene("server-unavailable", original: true, controls: true) { sample in
                CaptionSnapshot(pair: sample.pair, status: .listening, lines: sample.lines(upTo: 3, partialLast: true), refinement: .unavailable)
            },
            // A narrow panel: the status is a symbol only.
            captionScene("refined-narrow", controls: true, width: CaptionTextSize.minimumWidth) { sample in
                var lines = sample.lines(upTo: 2, partialLast: true)
                lines[0].isRefined = true
                return CaptionSnapshot(pair: sample.pair, status: .listening, lines: lines, refinement: .improved)
            },
            captionScene("starting") { CaptionSnapshot(pair: $0.pair, status: .starting) },
            captionScene("needs-download") { CaptionSnapshot(pair: $0.pair, status: .needsDownload) },
            // Apple's sheet was declined or the download failed: back to the offer, with the reason.
            captionScene("download-failed", downloadFailed: true) { CaptionSnapshot(pair: $0.pair, status: .needsDownload) },
            captionScene("downloading") { CaptionSnapshot(pair: $0.pair, status: .downloading) },
            // A pair Apple's Translation really lacks (Esperanto is not one of its languages), never a common pair that a reader would take for a bug.
            captionScene("unsupported") { CaptionSnapshot(pair: TranslationPair(source: Locale.Language(identifier: "eo"), target: $0.pair.target), status: .unsupported) },
            captionScene("paused") { CaptionSnapshot(pair: $0.pair, status: .paused) },
            // Paused while captions are on screen: dimmed, with the badge that says why.
            captionScene("paused-lines", original: true) { CaptionSnapshot(pair: $0.pair, status: .paused, lines: $0.lines(upTo: 3, partialLast: false)) },
            // Narrow and paused: the bar and the badge never overlap.
            captionScene("paused-narrow", width: CaptionTextSize.minimumWidth) { CaptionSnapshot(pair: $0.pair, status: .paused, lines: $0.lines(upTo: 3, partialLast: false)) },
            // Long sentences wrap: the oldest caption runs up under a fade and the pointer arriving changes nothing.
            captionScene("controls-large", size: .large, controls: true) {
                CaptionSnapshot(pair: $0.pair, status: .listening, lines: $0.lines(upTo: 3, partialLast: true))
            },
            captionScene("same-language") { _ in CaptionSnapshot(status: .sameLanguage) },
            captionScene("failed") { CaptionSnapshot(pair: $0.pair, status: .failed) },
            captionScene("original-large", original: true, size: .large) {
                CaptionSnapshot(pair: $0.pair, status: .listening, lines: $0.lines(upTo: 3, partialLast: true))
            },
            // A right-to-left target: short captions sit against the right edge.
            captionScene("rtl", original: true) { sample in
                let pair = TranslationPair(source: sample.pair.source, target: Locale.Language(identifier: "ar"))
                let lines = [
                    CaptionLine(id: 0, original: sample.originals[0], translation: "لننقل الإطلاق إلى الأسبوع الثاني من مارس.", state: .final),
                    CaptionLine(id: 1, original: sample.originals[1], translation: "ما زال على الفريق القانوني مراجعة العقد الجديد.", state: .final),
                    CaptionLine(id: 2, original: sample.lines(upTo: 3, partialLast: true)[2].original, translation: "هل يمكن للجميع أن يرسلوا", state: .partial),
                ]
                return CaptionSnapshot(pair: pair, status: .listening, lines: lines)
            },
        ]
    }
}

/// A stand-in for the video call behind the panel, so the translucent material has something to blur.
private struct CallBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.34), Color(red: 0.33, green: 0.22, blue: 0.4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 18) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.09 + Double(index) * 0.03))
                        .frame(width: 190, height: 120)
                        .overlay(Image(systemName: "person.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.35)))
                }
            }
            .offset(y: -34)
        }
    }
}
#endif
