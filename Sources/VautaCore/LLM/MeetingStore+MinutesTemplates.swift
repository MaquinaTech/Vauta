// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The template each meeting's minutes are written with, and the templates the person wrote (`CustomMinutesTemplate`).
extension MeetingStore {
    // MARK: A meeting's template

    /// The template a meeting's minutes are written with. nil = not chosen (meetings before templates existed): the general template.
    public func minutesTemplate(_ meetingID: Int64) throws -> MinutesTemplateChoice? {
        MinutesTemplateChoice(stored: try db.query("SELECT template FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.optionalString(0))
    }

    public func setMinutesTemplate(_ template: MinutesTemplateChoice?, for meetingID: Int64) async throws {
        try run("UPDATE meetings SET template = ? WHERE id = ?", [template.map { .text($0.storedValue) }, .integer(meetingID)])
        try await commitEdit()
    }

    /// The template of the meeting's recurring series, if the series has one: it comes before the default in Settings.
    public func seriesTemplate(of meetingID: Int64) throws -> MinutesTemplateChoice? {
        MinutesTemplateChoice(stored: try db.query("SELECT s.template FROM meetings m JOIN series s ON s.id = m.series_id WHERE m.id = ?",
                                                   [.integer(meetingID)]).first?.optionalString(0))
    }

    // MARK: The person's templates

    /// By name.
    public func customMinutesTemplates() throws -> [CustomMinutesTemplate] {
        try db.query("SELECT id, name, instructions, created_at FROM minutes_templates").map(Self.customTemplate)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func customMinutesTemplate(_ id: Int64) throws -> CustomMinutesTemplate? {
        try db.query("SELECT id, name, instructions, created_at FROM minutes_templates WHERE id = ?", [.integer(id)]).first.map(Self.customTemplate)
    }

    /// Saves a template, a new one without `id`, and returns its id. The name (one line) and the instructions are cleaned and cut to
    /// their limits (`CustomMinutesTemplate`); neither may be empty.
    @discardableResult
    public func saveCustomMinutesTemplate(id: Int64? = nil, name: String, instructions: String) async throws -> Int64 {
        let name = Self.clean(SingleLineText.flatten(name), max: CustomMinutesTemplate.nameLimit)
        let instructions = Self.clean(instructions, max: CustomMinutesTemplate.instructionsLimit)
        guard !name.isEmpty else { throw KnowledgeError.emptyName }
        guard !instructions.isEmpty else { throw KnowledgeError.emptyTemplate }
        let saved: Int64
        if let id {
            try run("UPDATE minutes_templates SET name = ?, instructions = ? WHERE id = ?", [.text(name), .text(instructions), .integer(id)])
            saved = id
        } else {
            try run("INSERT INTO minutes_templates(name, instructions, created_at) VALUES (?, ?, ?)",
                    [.text(name), .text(instructions), .real(Date.now.timeIntervalSince1970)])
            saved = db.lastInsertRowID
        }
        try await commitEdit()
        return saved
    }

    /// Deletes a template. The series that used it go back to the default; a meeting still says which template its minutes were
    /// written with, and minutes written again use the general template.
    public func deleteCustomMinutesTemplate(_ id: Int64) async throws {
        try transaction {
            try run("DELETE FROM minutes_templates WHERE id = ?", [.integer(id)])
            try run("UPDATE series SET template = NULL WHERE template = ?", [.text(MinutesTemplateChoice.custom(id).storedValue)])
        }
        try await commitEdit()
    }

    private static func customTemplate(_ row: Row) -> CustomMinutesTemplate {
        CustomMinutesTemplate(id: row.int(0), name: row.string(1), instructions: row.string(2), createdAt: Date(timeIntervalSince1970: row.double(3)))
    }
}
