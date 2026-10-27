// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import Foundation

/// Invented folder, file, account and calendar names in the language being rendered, so no scene shows an English name among
/// localized text. The system folders (Users, Documents, Downloads, Volumes) keep their real, English path names.
struct SampleNames {
    let language: String
    /// The person's short account name and the address of their work account (the invented kobaltix.example domain).
    let user: String
    let email: String
    /// The shared team calendar, a long name that wraps.
    let teamCalendar: String
    /// English folder and file names of the fixtures, by the name they carry in the language.
    let names: [String: String]
    /// A long folder name and the folder that holds it (the long-names stress scene).
    let longFolder: String
    let collaboration: String

    /// The skipped-files sheet: 13 file names (one per skip reason), a scanned handbook, a folder, a panorama.
    // swiftlint:disable:next line_length
    static let skippedLists: [String: [String]] = [
        "es": "Diapositivas.key|Modelo.xls|Contrato.pdf|Archivo-grabaciones.pdf|Escaneo en blanco.png|Dañado.docx|Hoja de cálculo enorme.xlsx|Corrupto.pdf|Notas en la nube.docx|Informe de Dropbox.docx|Plan.gdoc|Volcado.txt|Tesis.pdf|Escaneo del manual.docx|Proyectos antiguos|Panorama.png".components(separatedBy: "|"),
        "fr": "Diapositives.key|Modèle.xls|Contrat.pdf|Archive-enregistrements.pdf|Scan vierge.png|Endommagé.docx|Énorme tableur.xlsx|Corrompu.pdf|Notes cloud.docx|Rapport Dropbox.docx|Plan.gdoc|Export brut.txt|Thèse.pdf|Scan du guide.docx|Anciens projets|Panorama.png".components(separatedBy: "|"),
        "de": "Folien.key|Modell.xls|Vertrag.pdf|Aufnahmenarchiv.pdf|Leerer Scan.png|Beschädigt.docx|Riesige Tabelle.xlsx|Defekt.pdf|Cloud-Notizen.docx|Dropbox-Bericht.docx|Plan.gdoc|Rohdaten.txt|Abschlussarbeit.pdf|Handbuch-Scan.docx|Alte Projekte|Panorama.png".components(separatedBy: "|"),
        "it": "Diapositive.key|Modello.xls|Contratto.pdf|Archivio-registrazioni.pdf|Scansione vuota.png|Danneggiato.docx|Foglio enorme.xlsx|Corrotto.pdf|Note nel cloud.docx|Report Dropbox.docx|Piano.gdoc|Dump.txt|Tesi.pdf|Scansione del manuale.docx|Vecchi progetti|Panorama.png".components(separatedBy: "|"),
        "pt-BR": "Slides.key|Modelo.xls|Contrato.pdf|Arquivo-gravações.pdf|Digitalização em branco.png|Danificado.docx|Planilha enorme.xlsx|Corrompido.pdf|Notas na nuvem.docx|Relatório do Dropbox.docx|Plano.gdoc|Despejo.txt|Tese.pdf|Digitalização do manual.docx|Projetos antigos|Panorama.png".components(separatedBy: "|"),
        "ja": "スライド.key|モデル.xls|契約書.pdf|録音アーカイブ.pdf|白紙のスキャン.png|破損.docx|巨大なスプレッドシート.xlsx|壊れたファイル.pdf|クラウドのメモ.docx|Dropboxのレポート.docx|計画.gdoc|ダンプ.txt|論文.pdf|ハンドブックのスキャン.docx|古いプロジェクト|パノラマ.png".components(separatedBy: "|"),
        "ko": "슬라이드.key|모델.xls|계약서.pdf|녹음 보관.pdf|빈 스캔.png|손상됨.docx|거대한 스프레드시트.xlsx|깨진 파일.pdf|클라우드 메모.docx|Dropbox 보고서.docx|계획.gdoc|덤프.txt|논문.pdf|핸드북 스캔.docx|오래된 프로젝트|파노라마.png".components(separatedBy: "|"),
        "zh-Hans": "幻灯片.key|模型.xls|合同.pdf|录音归档.pdf|空白扫描.png|已损坏.docx|超大表格.xlsx|损坏文件.pdf|云端笔记.docx|Dropbox 报告.docx|计划.gdoc|转储.txt|论文.pdf|手册扫描.docx|旧项目|全景.png".components(separatedBy: "|"),
        "en": "Slides.key|Model.xls|Contract.pdf|Recording-archive.pdf|Blank scan.png|Damaged.docx|Huge spreadsheet.xlsx|Corrupt.pdf|Cloud notes.docx|Dropbox report.docx|Plan.gdoc|Dump.txt|Thesis.pdf|Handbook scan.docx|Old projects|Panorama.png".components(separatedBy: "|"),
    ]

    func skipped(_ index: Int) -> String { SampleNames.skippedLists[language]?[index] ?? SampleNames.skippedLists["en"]![index] }

    func name(_ english: String) -> String { names[english] ?? english }

    /// A path of the English fixtures, with every component in the language and the user's own account name.
    func path(_ english: String) -> String {
        let parts = english.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        for (index, part) in parts.enumerated() {
            if index > 0, parts[index - 1] == "Users" { out.append(user) } else { out.append(name(part)) }
        }
        return out.joined(separator: "/")
    }

    /// The sources of a Documents snapshot with their names and paths in the language.
    func localized(_ snapshot: DocumentsSnapshot) -> DocumentsSnapshot {
        var out = snapshot
        out.sources = snapshot.sources.map { status in
            var copy = status
            if status.source.displayName == "Long" {
                // The stress scene: the language's own long folder name, in a folder with a long path.
                copy.source.displayName = longFolder
                copy.source.path = "/Users/\(user)/Documents/\(collaboration)/\(longFolder)"
            } else {
                copy.source.displayName = name(status.source.displayName)
                copy.source.path = path(status.source.path)
            }
            return copy
        }
        return out
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func forLanguage(_ language: String) -> SampleNames {
        func table(_ values: [String]) -> [String: String] {
            let keys = ["Projects", "Handbook", "Finance", "Photos Archive", "Backup Drive", "Archive", "Notes", "Reports", "Notes export",
                        "Budget 2027.xlsx", "Contract.pdf"]
            return Dictionary(uniqueKeysWithValues: zip(keys, values))
        }
        switch language {
        case "es":
            return SampleNames(language: language, user: "lucia", email: "lucia.navarro@kobaltix.example", teamCalendar: "Equipo de producto: planificación, revisiones y reuniones generales",
                               names: table(["Proyectos", "Manual", "Finanzas", "Archivo de fotos", "Copia de seguridad", "Archivo", "Notas", "Informes", "Notas exportadas", "Presupuesto 2027.xlsx", "Contrato.pdf"]),
                               longFolder: "Documentos compartidos de planificación trimestral y coordinación con los equipos regionales", collaboration: "Colaboración")
        case "fr":
            return SampleNames(language: language, user: "camille", email: "camille.laurent@kobaltix.example", teamCalendar: "Équipe produit : planification, revues et réunions générales",
                               names: table(["Projets", "Guide", "Finances", "Archives photos", "Sauvegarde", "Archives", "Notes", "Rapports", "Notes exportées", "Budget 2027.xlsx", "Contrat.pdf"]),
                               longFolder: "Documents partagés de la planification trimestrielle et de la coordination avec les équipes régionales", collaboration: "Collaboration")
        case "de":
            return SampleNames(language: language, user: "laura", email: "laura.becker@kobaltix.example", teamCalendar: "Produktteam: Planung, Reviews und Betriebsversammlungen",
                               names: table(["Projekte", "Handbuch", "Finanzen", "Fotoarchiv", "Sicherung", "Archiv", "Notizen", "Berichte", "Notizen-Export", "Budget 2027.xlsx", "Vertrag.pdf"]),
                               longFolder: "Gemeinsame Projektunterlagen für die Quartalsplanung und die Abstimmung mit den Regionalteams", collaboration: "Zusammenarbeit")
        case "it":
            return SampleNames(language: language, user: "giulia", email: "giulia.ferrari@kobaltix.example", teamCalendar: "Team prodotto: pianificazione, revisioni e riunioni generali",
                               names: table(["Progetti", "Manuale", "Finanze", "Archivio foto", "Backup", "Archivio", "Note", "Rapporti", "Note esportate", "Budget 2027.xlsx", "Contratto.pdf"]),
                               longFolder: "Documenti condivisi per la pianificazione trimestrale e il coordinamento con i team regionali", collaboration: "Collaborazione")
        case "pt-BR":
            return SampleNames(language: language, user: "beatriz", email: "beatriz.almeida@kobaltix.example", teamCalendar: "Equipe de produto: planejamento, revisões e reuniões gerais",
                               names: table(["Projetos", "Manual", "Finanças", "Arquivo de fotos", "Backup", "Arquivo", "Notas", "Relatórios", "Notas exportadas", "Orçamento 2027.xlsx", "Contrato.pdf"]),
                               longFolder: "Documentos compartilhados do planejamento trimestral e da coordenação com as equipes regionais", collaboration: "Colaboração")
        case "ja":
            return SampleNames(language: language, user: "misaki", email: "misaki.tanaka@kobaltix.example", teamCalendar: "プロダクトチーム：計画、レビュー、全体会議",
                               names: table(["プロジェクト", "ハンドブック", "経理", "写真アーカイブ", "バックアップ", "アーカイブ", "メモ", "レポート", "書き出したメモ", "予算2027.xlsx", "契約書.pdf"]),
                               longFolder: "四半期計画と各地域チームとの調整に使う共有プロジェクト資料", collaboration: "共同作業")
        case "ko":
            return SampleNames(language: language, user: "seoyeon", email: "seoyeon.kim@kobaltix.example", teamCalendar: "프로덕트 팀: 기획, 리뷰, 전체 회의",
                               names: table(["프로젝트", "핸드북", "재무", "사진 보관함", "백업", "보관", "메모", "보고서", "내보낸 메모", "예산 2027.xlsx", "계약서.pdf"]),
                               longFolder: "분기 계획과 지역 팀과의 조율을 위한 공유 프로젝트 자료", collaboration: "협업")
        case "zh-Hans":
            return SampleNames(language: language, user: "siyu", email: "siyu.chen@kobaltix.example", teamCalendar: "产品团队：规划、评审和全员会议",
                               names: table(["项目", "手册", "财务", "照片归档", "备份", "归档", "备忘录", "报告", "导出的备忘录", "预算 2027.xlsx", "合同.pdf"]),
                               longFolder: "用于季度规划和与各区域团队协调的共享项目资料", collaboration: "协作")
        default:
            return SampleNames(language: language, user: "maya", email: "maya.chen@kobaltix.example", teamCalendar: "Product team — planning, reviews and all-hands",
                               names: [:], longFolder: "Shared project documents for the quarterly planning and the alignment with the regional teams", collaboration: "Collaboration")
        }
    }
}
#endif
