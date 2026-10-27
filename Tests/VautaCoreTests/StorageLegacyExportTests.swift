// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Storage: schema 13 exports")
struct StorageLegacyExportTests {
    @Test func aSchema13MeetingExportsByteForByteAsBefore() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 13) { db in
            try db.query("INSERT INTO meetings(id, started_at, ended_at, title) VALUES (1, 1700000000, 1700003600, 'Reunión heredada')")
            try db.query("""
                INSERT INTO segments(meeting_id, speaker, start, end, text)
                VALUES (1, 'Yo', 0, 2, 'texto heredado'), (1, 'Otros', 3, 5, 'respuesta')
                """)
        }
        let store = try fx.open()
        let export = try #require(try await store.meetingExport(1))
        let options = ExportRendererTests.options
        // Rendered by 0.1.0-format code: no speaker key anywhere.
        let json = [
            "{",
            "  \"attendees\" : [",
            "",
            "  ],",
            "  \"decisions\" : [",
            "",
            "  ],",
            "  \"durationSeconds\" : 3600,",
            "  \"endedAt\" : \"2023-11-14T23:13:20Z\",",
            "  \"format\" : \"vauta.meeting\",",
            "  \"language\" : null,",
            "  \"notes\" : [",
            "",
            "  ],",
            "  \"openQuestions\" : [",
            "",
            "  ],",
            "  \"participantsInformedAt\" : null,",
            "  \"startedAt\" : \"2023-11-14T22:13:20Z\",",
            "  \"summary\" : \"\",",
            "  \"tasks\" : [",
            "",
            "  ],",
            "  \"title\" : \"Reunión heredada\",",
            "  \"topics\" : [",
            "",
            "  ],",
            "  \"transcript\" : [",
            "    {",
            "      \"channel\" : \"me\",",
            "      \"end\" : 2,",
            "      \"name\" : null,",
            "      \"speaker\" : \"Me\",",
            "      \"start\" : 0,",
            "      \"text\" : \"texto heredado\"",
            "    },",
            "    {",
            "      \"channel\" : \"others\",",
            "      \"end\" : 5,",
            "      \"name\" : null,",
            "      \"speaker\" : \"Others\",",
            "      \"start\" : 3,",
            "      \"text\" : \"respuesta\"",
            "    }",
            "  ],",
            "  \"version\" : 1",
            "}",
            "",
        ].joined(separator: "\n")
        let markdown = [
            "# Reunión heredada",
            "",
            "- **Date:** Tuesday, November 14, 2023 at 10:13 PM – 11:13 PM (60 min)",
            "",
            "## Transcript",
            "",
            "**[00:00] Me:** texto heredado",
            "",
            "**[00:03] Others:** respuesta",
            "",
        ].joined(separator: "\n")
        let srt = [
            "1",
            "00:00:00,000 --> 00:00:02,000",
            "Me: texto heredado",
            "",
            "2",
            "00:00:03,000 --> 00:00:05,000",
            "Others: respuesta",
            "",
            "",
        ].joined(separator: "\n")
        let vtt = [
            "WEBVTT",
            "",
            "1",
            "00:00:00.000 --> 00:00:02.000",
            "<v Me>texto heredado",
            "",
            "2",
            "00:00:03.000 --> 00:00:05.000",
            "<v Others>respuesta",
            "",
            "",
        ].joined(separator: "\n")
        #expect(try MeetingExportJSON.encode(export, options: options) == json)
        #expect(MeetingExportRenderer.markdown(export, options: options) == markdown)
        #expect(SubtitleRenderer.srt(export.transcript, options: options) == srt)
        #expect(SubtitleRenderer.webVTT(export.transcript, options: options) == vtt)
    }
}
