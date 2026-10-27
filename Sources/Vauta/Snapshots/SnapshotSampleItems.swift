// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import Foundation

/// Invented task, reminder and calendar names for the actions scenes, in the language being rendered, so no scene shows an English
/// item among localized rows. Nothing here is real data.
struct SampleItems {
    /// A task the stored due day of which is wrong (the Follow-up sheet and the reminder editor warn about it).
    let venueTask: String
    /// A reminder Vauta added, and the list it is in ("Work · iCloud" in the language's word for Work).
    let reminder: String
    let list: String

    /// The wrong due day the scenes store on `venueTask`: found by this day, not by its words.
    static let skippedDueDay = DueDay(year: 2005, month: 1, day: 3)

    static func forLanguage(_ language: String) -> SampleItems {
        let work = BriefSample.forLanguage(language).lists[0] + " · iCloud"
        switch language.split(separator: "-").first.map(String.init) ?? language {
        case "es": return SampleItems(venueTask: "Confirmar el local con el proveedor", reminder: "Enviar el presupuesto revisado", list: work)
        case "fr": return SampleItems(venueTask: "Confirmer la salle avec le fournisseur", reminder: "Envoyer le budget révisé", list: work)
        case "de": return SampleItems(venueTask: "Veranstaltungsort mit dem Lieferanten bestätigen", reminder: "Überarbeitetes Budget senden", list: work)
        case "it": return SampleItems(venueTask: "Confermare la sede con il fornitore", reminder: "Inviare il budget rivisto", list: work)
        case "pt": return SampleItems(venueTask: "Confirmar o local com o fornecedor", reminder: "Enviar o orçamento revisado", list: work)
        case "ja": return SampleItems(venueTask: "会場について取引先に確認する", reminder: "改訂した予算を送る", list: work)
        case "ko": return SampleItems(venueTask: "공급업체에 장소 확인하기", reminder: "수정된 예산 보내기", list: work)
        case "zh": return SampleItems(venueTask: "与供应商确认场地", reminder: "发送修订后的预算", list: work)
        default: return SampleItems(venueTask: "Confirm the venue with the supplier", reminder: "Send the revised budget", list: work)
        }
    }

    /// The Reminders lists and the Calendar the fake store offers, named in the language ("Work" and "Personal" in iCloud).
    static func reminderLists(_ language: String) -> [ActionContainer] {
        let names = BriefSample.forLanguage(language).lists
        return [ActionContainer(id: "list-work", title: names[0], account: "iCloud"), ActionContainer(id: "list-home", title: names[1], account: "iCloud")]
    }

    static func calendars(_ language: String) -> [ActionContainer] {
        [ActionContainer(id: "cal-work", title: BriefSample.forLanguage(language).lists[0], account: "iCloud")]
    }

    /// The default title of a follow-up event for the featured meeting, as the app names a new one.
    static func followUpEventTitle(_ fixture: SnapshotFixture) -> String {
        String(localized: "Follow-up: \(SampleContent.forLanguage(fixture.language).featuredTitle)", comment: "Default title of a calendar event for the next meeting; the argument is the meeting’s name")
    }
}
#endif
