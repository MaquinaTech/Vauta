// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension Schema {
    /// Migrations 1 to 13, in order; `Schema.migrations` continues them.
    static let migrationsThrough13: [Migration] = [
        // Meetings and transcript segments with their full-text index.
        Migration(1, .sql("""
            CREATE TABLE meetings(
                id INTEGER PRIMARY KEY,
                started_at REAL NOT NULL,
                ended_at REAL,
                title TEXT
            );
            CREATE TABLE segments(
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                speaker TEXT NOT NULL,
                start REAL NOT NULL,
                end REAL NOT NULL,
                text TEXT NOT NULL
            );
            CREATE INDEX segments_by_meeting ON segments(meeting_id, start);
            CREATE VIRTUAL TABLE segments_fts USING fts5(
                text, content='segments', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
                INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
                INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END;
            """)),
        Migration(2, .sql("CREATE INDEX IF NOT EXISTS meetings_by_start ON meetings(started_at DESC);")),
        // Snapshot generation (links it to its journal), and the user's marks and
        // notes (a meeting with notes is not removed as empty).
        Migration(3, .sql("""
            CREATE TABLE store_meta(k TEXT PRIMARY KEY, v) WITHOUT ROWID;
            CREATE TABLE marks(
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                t REAL NOT NULL,
                label TEXT
            );
            CREATE INDEX marks_by_meeting ON marks(meeting_id, t);
            CREATE TABLE notes(
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                t REAL NOT NULL,
                text TEXT NOT NULL
            );
            CREATE INDEX notes_by_meeting ON notes(meeting_id, t);
            """)),
        // User context and knowledge graph, in the SAME database as the meetings
        // (foreign keys and cascading deletes do not cross databases): everything
        // goes with "Delete meeting" and "Erase everything". Full-text indexes use
        // encoded rowids (id * 8 + kind) so triggers delete by rowid without a scan.
        Migration(4, .sql("""
            CREATE TABLE entities(
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL CHECK(kind IN ('person','project','client','topic','team','system')),
                name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 200),
                note TEXT,
                email TEXT,
                source TEXT NOT NULL DEFAULT 'user' CHECK(source IN ('user','calendar','llm')),
                confirmed INTEGER NOT NULL DEFAULT 1,
                first_seen REAL,
                last_seen REAL,
                merged_into INTEGER REFERENCES entities(id) ON DELETE SET NULL,
                created_at REAL NOT NULL
            );
            CREATE INDEX entities_by_kind ON entities(kind, name) WHERE merged_into IS NULL;
            CREATE UNIQUE INDEX entities_by_email ON entities(email) WHERE email IS NOT NULL;

            CREATE TABLE aliases(
                id INTEGER PRIMARY KEY,
                alias_norm TEXT NOT NULL,
                alias TEXT NOT NULL,
                entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                source TEXT NOT NULL CHECK(source IN ('user','calendar','llm','learned')),
                weight REAL NOT NULL DEFAULT 1,
                UNIQUE(alias_norm, entity_id)
            );
            CREATE INDEX aliases_by_entity ON aliases(entity_id);

            CREATE TABLE glossary(
                id INTEGER PRIMARY KEY,
                term TEXT NOT NULL CHECK(length(term) BETWEEN 1 AND 200),
                expansion TEXT,
                note TEXT,
                entity_id INTEGER REFERENCES entities(id) ON DELETE SET NULL,
                pinned INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE series(
                id INTEGER PRIMARY KEY,
                calendar_key TEXT UNIQUE,
                title_pattern TEXT NOT NULL,
                default_entities TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(default_entities))
            );
            ALTER TABLE meetings ADD COLUMN series_id INTEGER REFERENCES series(id) ON DELETE SET NULL;

            -- Who/what is in each meeting: attendees, who the "others" channel is, topics.
            CREATE TABLE meeting_entities(
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                role TEXT NOT NULL CHECK(role IN ('attendee','others','topic')),
                PRIMARY KEY(meeting_id, entity_id, role)
            ) WITHOUT ROWID;
            CREATE INDEX meeting_entities_by_entity ON meeting_entities(entity_id);

            CREATE TABLE mentions(
                id INTEGER PRIMARY KEY,
                entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                segment_id INTEGER REFERENCES segments(id) ON DELETE SET NULL,
                t REAL NOT NULL,
                surface TEXT NOT NULL,
                confidence REAL NOT NULL,
                resolved_by TEXT NOT NULL CHECK(resolved_by IN ('exact','context','user','llm'))
            );
            CREATE INDEX mentions_by_entity ON mentions(entity_id, meeting_id, t);
            CREATE INDEX mentions_by_meeting ON mentions(meeting_id, t);
            CREATE INDEX mentions_by_segment ON mentions(segment_id);

            -- What the user decides: ambiguous names and possible recognizer errors.
            CREATE TABLE suggestions(
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                segment_id INTEGER REFERENCES segments(id) ON DELETE CASCADE,
                t REAL NOT NULL,
                kind TEXT NOT NULL CHECK(kind IN ('ambiguous','correction')),
                surface TEXT NOT NULL,
                candidates TEXT NOT NULL CHECK(json_valid(candidates)),
                status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','accepted','rejected'))
            );
            CREATE INDEX suggestions_open ON suggestions(meeting_id, t) WHERE status = 'open';

            CREATE TABLE decisions(
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                segment_id INTEGER REFERENCES segments(id) ON DELETE SET NULL,
                t REAL,
                text TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'user' CHECK(source IN ('user','llm')),
                created_at REAL NOT NULL
            );
            CREATE INDEX decisions_by_meeting ON decisions(meeting_id, t);

            CREATE TABLE tasks(
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER REFERENCES meetings(id) ON DELETE CASCADE,
                segment_id INTEGER REFERENCES segments(id) ON DELETE SET NULL,
                t REAL,
                text TEXT NOT NULL,
                owner_id INTEGER REFERENCES entities(id) ON DELETE SET NULL,
                due REAL,
                status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','done','dropped')),
                source TEXT NOT NULL DEFAULT 'user' CHECK(source IN ('user','llm')),
                created_at REAL NOT NULL,
                done_at REAL
            );
            CREATE INDEX tasks_open ON tasks(owner_id, due) WHERE status = 'open';
            CREATE INDEX tasks_by_meeting ON tasks(meeting_id, t);

            -- Typed edges between nodes (entity | decision | task | meeting).
            CREATE TABLE relations(
                id INTEGER PRIMARY KEY,
                src_kind TEXT NOT NULL CHECK(src_kind IN ('entity','decision','task','meeting')),
                src_id INTEGER NOT NULL,
                rel TEXT NOT NULL CHECK(length(rel) BETWEEN 1 AND 40),
                dst_kind TEXT NOT NULL CHECK(dst_kind IN ('entity','decision','task','meeting')),
                dst_id INTEGER NOT NULL,
                meeting_id INTEGER REFERENCES meetings(id) ON DELETE CASCADE,
                t REAL,
                confidence REAL NOT NULL DEFAULT 1,
                source TEXT NOT NULL DEFAULT 'user' CHECK(source IN ('user','calendar','llm','auto')),
                valid_from REAL,
                valid_to REAL,
                CHECK(NOT (src_kind = dst_kind AND src_id = dst_id))
            );
            CREATE UNIQUE INDEX rel_unique ON relations(src_kind, src_id, rel, dst_kind, dst_id, ifnull(meeting_id, 0));
            CREATE INDEX rel_src ON relations(src_kind, src_id);
            CREATE INDEX rel_dst ON relations(dst_kind, dst_id);
            -- Polymorphic edges: no FK is possible, these triggers clean them up.
            CREATE TRIGGER entities_ad AFTER DELETE ON entities BEGIN
                DELETE FROM relations WHERE src_kind = 'entity' AND src_id = old.id;
                DELETE FROM relations WHERE dst_kind = 'entity' AND dst_id = old.id;
            END;
            CREATE TRIGGER decisions_ad AFTER DELETE ON decisions BEGIN
                DELETE FROM relations WHERE src_kind = 'decision' AND src_id = old.id;
                DELETE FROM relations WHERE dst_kind = 'decision' AND dst_id = old.id;
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 1;
            END;
            CREATE TRIGGER tasks_ad AFTER DELETE ON tasks BEGIN
                DELETE FROM relations WHERE src_kind = 'task' AND src_id = old.id;
                DELETE FROM relations WHERE dst_kind = 'task' AND dst_id = old.id;
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 2;
            END;
            CREATE TRIGGER meetings_ad AFTER DELETE ON meetings BEGIN
                DELETE FROM relations WHERE src_kind = 'meeting' AND src_id = old.id;
                DELETE FROM relations WHERE dst_kind = 'meeting' AND dst_id = old.id;
            END;

            -- Names (aliases and glossary) by trigrams: "telef" finds "Telefónica".
            CREATE VIRTUAL TABLE names_fts USING fts5(text, tokenize = 'trigram remove_diacritics 1');
            CREATE TRIGGER aliases_ai AFTER INSERT ON aliases BEGIN
                INSERT INTO names_fts(rowid, text) VALUES (new.id * 2, new.alias);
            END;
            CREATE TRIGGER aliases_ad AFTER DELETE ON aliases BEGIN
                DELETE FROM names_fts WHERE rowid = old.id * 2;
            END;
            CREATE TRIGGER glossary_ai AFTER INSERT ON glossary BEGIN
                INSERT INTO names_fts(rowid, text) VALUES (new.id * 2 + 1, new.term);
            END;
            CREATE TRIGGER glossary_au AFTER UPDATE OF term ON glossary BEGIN
                DELETE FROM names_fts WHERE rowid = old.id * 2 + 1;
                INSERT INTO names_fts(rowid, text) VALUES (new.id * 2 + 1, new.term);
            END;
            CREATE TRIGGER glossary_ad AFTER DELETE ON glossary BEGIN
                DELETE FROM names_fts WHERE rowid = old.id * 2 + 1;
            END;

            -- Knowledge: decisions (1), tasks (2), notes (3), entity notes (4).
            CREATE VIRTUAL TABLE knowledge_fts USING fts5(text, tokenize = 'unicode61 remove_diacritics 2');
            CREATE TRIGGER decisions_ai AFTER INSERT ON decisions BEGIN
                INSERT INTO knowledge_fts(rowid, text) VALUES (new.id * 8 + 1, new.text);
            END;
            CREATE TRIGGER decisions_au AFTER UPDATE OF text ON decisions BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 1;
                INSERT INTO knowledge_fts(rowid, text) VALUES (new.id * 8 + 1, new.text);
            END;
            CREATE TRIGGER tasks_ai AFTER INSERT ON tasks BEGIN
                INSERT INTO knowledge_fts(rowid, text) VALUES (new.id * 8 + 2, new.text);
            END;
            CREATE TRIGGER tasks_au AFTER UPDATE OF text ON tasks BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 2;
                INSERT INTO knowledge_fts(rowid, text) VALUES (new.id * 8 + 2, new.text);
            END;
            CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN
                INSERT INTO knowledge_fts(rowid, text) VALUES (new.id * 8 + 3, new.text);
            END;
            CREATE TRIGGER notes_au AFTER UPDATE OF text ON notes BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 3;
                INSERT INTO knowledge_fts(rowid, text) VALUES (new.id * 8 + 3, new.text);
            END;
            CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 3;
            END;
            CREATE TRIGGER entities_note_ai AFTER INSERT ON entities WHEN new.note IS NOT NULL BEGIN
                INSERT INTO knowledge_fts(rowid, text) VALUES (new.id * 8 + 4, new.note);
            END;
            CREATE TRIGGER entities_note_au AFTER UPDATE OF note ON entities BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 4;
                INSERT INTO knowledge_fts(rowid, text) SELECT new.id * 8 + 4, new.note WHERE new.note IS NOT NULL;
            END;
            CREATE TRIGGER entities_note_ad AFTER DELETE ON entities BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 4;
            END;
            -- Notes created with schema 3.
            INSERT INTO knowledge_fts(rowid, text) SELECT id * 8 + 3, text FROM notes;
            """)),
        // Meeting card (summary and topics; decisions and tasks live in their own
        // tables). raw_purged_at supports the two-speed retention.
        Migration(5, .sql("""
            ALTER TABLE meetings ADD COLUMN card TEXT CHECK(card IS NULL OR json_valid(card));
            ALTER TABLE meetings ADD COLUMN card_version INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE meetings ADD COLUMN raw_purged_at REAL;
            CREATE TRIGGER meetings_card_au AFTER UPDATE OF card ON meetings BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 5;
                INSERT INTO knowledge_fts(rowid, text)
                    SELECT new.id * 8 + 5, json_extract(new.card, '$.resumen') || ' ' || coalesce((SELECT group_concat(value, ' ') FROM json_each(new.card, '$.temas')), '')
                    WHERE new.card IS NOT NULL;
            END;
            CREATE TRIGGER meetings_card_ad AFTER DELETE ON meetings BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 5;
            END;
            CREATE INDEX meetings_by_series ON meetings(series_id) WHERE series_id IS NOT NULL;
            """)),
        // Secure delete in the full-text indexes: a delete or an edit removes the
        // old terms from the index immediately, without waiting for 'optimize'.
        Migration(6, .sql("""
            INSERT INTO segments_fts(segments_fts, rank) VALUES ('secure-delete', 1);
            INSERT INTO names_fts(names_fts, rank) VALUES ('secure-delete', 1);
            INSERT INTO knowledge_fts(knowledge_fts, rank) VALUES ('secure-delete', 1);
            """)),
        // Model-server job queue (references, never text), live notes, chunks
        // with embeddings, and the origin of the card.
        Migration(7, .sql("""
            CREATE TABLE llm_jobs(
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                kind TEXT NOT NULL CHECK(kind IN ('acta','embed')),
                state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','done','failed')),
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                not_before REAL,
                created_at REAL NOT NULL,
                updated_at REAL
            );
            CREATE UNIQUE INDEX llm_jobs_pending ON llm_jobs(meeting_id, kind) WHERE state IN ('queued','running');
            CREATE TABLE live_notes(
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                t REAL NOT NULL,
                json TEXT NOT NULL CHECK(json_valid(json))
            );
            CREATE INDEX live_notes_by_meeting ON live_notes(meeting_id, t);
            CREATE TABLE chunks(
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                start REAL NOT NULL,
                end REAL NOT NULL,
                model TEXT NOT NULL,
                dims INTEGER NOT NULL,
                scale REAL NOT NULL,
                emb BLOB NOT NULL CHECK(length(emb) = dims)
            );
            CREATE INDEX chunks_by_meeting ON chunks(meeting_id, start);
            ALTER TABLE meetings ADD COLUMN card_source TEXT CHECK(card_source IN ('user','llm'));
            """)),
        // Multi-language and multi-app support:
        // - speaker labels become channel codes ('Yo' → 'me', 'Otros' → 'others');
        //   journals from 0.1.0 still insert the old labels, which is fine because
        //   they are replayed before this runs. `Channel(storedSpeaker:)` also
        //   maps the old labels, so a row missed here still reads correctly;
        // - the meeting's transcription locale and minutes output locale (BCP-47;
        //   NULL = legacy, es-ES and same as `locale`) and the app family it was
        //   captured from (NULL = legacy: Safari or all system audio);
        // - a stable error code for model-server jobs (`last_error` held localized
        //   text; NULL = legacy row).
        Migration(8, .sql("""
            UPDATE segments SET speaker = CASE speaker WHEN 'Yo' THEN 'me' ELSE 'others' END
                WHERE speaker IN ('Yo', 'Otros');
            ALTER TABLE meetings ADD COLUMN locale TEXT;
            ALTER TABLE meetings ADD COLUMN output_locale TEXT;
            ALTER TABLE meetings ADD COLUMN source_app TEXT;
            ALTER TABLE llm_jobs ADD COLUMN last_error_code TEXT;
            """)),
        // Name keys no longer depend on the locale and fold more letters
        // (ł ø æ œ đ ð þ ı, Arabic vowel marks and tatweel, Hebrew points):
        // `aliases.alias_norm` written by older versions is recomputed so those
        // aliases keep matching transcripts. Aliases of one entity that now share
        // a key are merged (see `recomputeAliasNormalization`).
        Migration(9, .code { db in try MeetingStore.recomputeAliasNormalization(db) }),
        // The minutes template a meeting is written with (`MinutesTemplate`
        // raw value; NULL = chosen before templates existed: general).
        Migration(10, .sql("ALTER TABLE meetings ADD COLUMN template TEXT;")),
        // Live Translation: the translated text of a segment, one row per target
        // language. It lives and dies with the segment (same retention, purge,
        // erase and backup): the cascade removes it when the segment goes.
        Migration(11, .sql("""
            CREATE TABLE segment_translations(
                segment_id INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
                lang TEXT NOT NULL,
                text TEXT NOT NULL,
                PRIMARY KEY(segment_id, lang)
            ) WITHOUT ROWID;
            """)),
        // Consent helper: when the user told the other participants that the
        // meeting is being transcribed (unix time; NULL = not recorded). It is a
        // column of the meeting, so it follows the meeting through retention,
        // erase, backup and export.
        Migration(12, .sql("ALTER TABLE meetings ADD COLUMN participants_informed_at REAL;")),
        // The topics of a meeting card are indexed separated by commas (they ran together in search
        // snippets: "Atlas launch Beta rollout"). Existing cards are indexed again.
        Migration(13, .sql("""
            DROP TRIGGER meetings_card_au;
            CREATE TRIGGER meetings_card_au AFTER UPDATE OF card ON meetings BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 5;
                INSERT INTO knowledge_fts(rowid, text)
                    SELECT new.id * 8 + 5, json_extract(new.card, '$.resumen') || ' ' || coalesce((SELECT group_concat(value, ', ') FROM json_each(new.card, '$.temas')), '')
                    WHERE new.card IS NOT NULL;
            END;
            DELETE FROM knowledge_fts WHERE rowid % 8 = 5;
            INSERT INTO knowledge_fts(rowid, text)
                SELECT id * 8 + 5, json_extract(card, '$.resumen') || ' ' || coalesce((SELECT group_concat(value, ', ') FROM json_each(card, '$.temas')), '')
                FROM meetings WHERE card IS NOT NULL;
            """)),
    ]
}
