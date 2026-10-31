// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Database schema version, stored in `PRAGMA user_version` inside the image.
/// Unrelated to the file envelope version (`EnvelopeVersion`).
typealias SchemaVersion = Int64

/// One schema migration. Each runs in its own transaction together with its
/// `user_version` update: it applies completely or not at all.
struct Migration: Sendable {
    enum Step: Sendable {
        /// One or more SQL statements.
        case sql(String)
        /// Swift code for data rewrites SQL cannot express (e.g. recomputing a
        /// normalized column). It runs inside the migration's transaction and
        /// must use `db` directly (nothing is journaled during migrations).
        case code(@Sendable (SQLiteDatabase) throws -> Void)
    }

    let version: SchemaVersion
    let steps: [Step]
    /// Runs with `PRAGMA foreign_keys = OFF` and checks `PRAGMA
    /// foreign_key_check` before committing. Needed to rebuild a table that
    /// other tables reference; see `rebuild(_:table:definition:columns:then:)`.
    let rebuildsTables: Bool

    init(_ version: SchemaVersion, _ steps: Step..., rebuildsTables: Bool = false) {
        self.version = version
        self.steps = steps
        self.rebuildsTables = rebuildsTables
    }

    /// A table rebuild, the only way to change a CHECK constraint (for
    /// example to widen `llm_jobs.kind` or `llm_jobs.state`) or a column type
    /// in SQLite. It follows SQLite's "12-step" procedure:
    ///
    /// 1. `PRAGMA foreign_keys = OFF`, set by the runner BEFORE `BEGIN` (the
    ///    pragma is a no-op inside a transaction), so dropping the old table
    ///    neither cascades nor fails on rows that reference it.
    /// 2. `CREATE TABLE <table>_new <definition>`.
    /// 3. `INSERT INTO <table>_new(<columns>) SELECT <columns> FROM <table>`.
    /// 4. `DROP TABLE <table>` (its indexes and triggers go with it).
    /// 5. `ALTER TABLE <table>_new RENAME TO <table>`.
    /// 6. `then`: recreate the table's indexes and triggers (and any view).
    /// 7. `PRAGMA foreign_key_check` must return no rows, then `COMMIT`, then
    ///    `PRAGMA foreign_keys = ON` again (also if anything failed).
    ///
    /// Caveat: if a trigger or view on ANOTHER table mentions `<table>`, step 5
    /// fails ("no such table") because SQLite re-parses the schema while the
    /// old table is gone. Drop such triggers/views first and recreate them in
    /// `then`. Tables with FTS triggers (meetings, segments, entities...) need
    /// their triggers recreated and, if rowids change, their index rebuilt.
    static func rebuild(_ version: SchemaVersion, table: String, definition: String, columns: String,
                        then followUp: String = "") -> Migration {
        Migration(version, .sql("""
            CREATE TABLE \(table)_new \(definition);
            INSERT INTO \(table)_new(\(columns)) SELECT \(columns) FROM \(table);
            DROP TABLE \(table);
            ALTER TABLE \(table)_new RENAME TO \(table);
            \(followUp)
            """), rebuildsTables: true)
    }
}

/// The single, ordered registry of schema migrations and their runner.
///
/// Rules: versions are strictly increasing and contiguous (a test checks it);
/// never edit a published migration, add a new one. Journal replay runs BEFORE
/// migrations (the journal was written with the schema of its snapshot), so
/// every migration must also be correct on data replayed from older versions'
/// SQL.
enum Schema {
    static let migrations: [Migration] = migrationsThrough13 + [
        // Speaker recognition. `meeting_speakers` holds the speakers of one meeting (a channel
        // plus an ordinal: "Speaker <ordinal>"), `segments.speaker_id` says who said each
        // segment. `segments.speaker` keeps its frozen 'me'/'others' values, and the 'others'
        // role of `meeting_entities` stays the fallback for meetings without speaker data, so
        // no CHECK is rebuilt. `source` records who named the speaker: 'user' is ground truth
        // and is never overwritten; 'suggested' keeps a candidate that is not shown as a name.
        // `voice_profiles` (opt-in, off by default) holds the voice fingerprints a person
        // consented to; `model_id` names the embedding model, and a different one is unusable.
        // A voice profile dies with its person (a speaker only loses the name); the profiles
        // also go with the encrypted store, its backups and Erase Everything. No audio is stored anywhere.
        Migration(14, .sql("""
            -- AUTOINCREMENT: an ID is never reused, so an undo record can never meet another
            -- meeting's speaker under the ID of one that was deleted.
            CREATE TABLE meeting_speakers(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                channel TEXT NOT NULL CHECK(channel IN ('me','others')),
                ordinal INTEGER NOT NULL CHECK(ordinal >= 1),
                entity_id INTEGER REFERENCES entities(id) ON DELETE SET NULL,
                source TEXT NOT NULL DEFAULT 'auto' CHECK(source IN ('auto','user','profile','suggested')),
                confidence REAL CHECK(confidence IS NULL OR confidence BETWEEN 0 AND 1),
                talk_seconds REAL NOT NULL DEFAULT 0,
                UNIQUE(meeting_id, channel, ordinal)
            );
            CREATE INDEX meeting_speakers_by_entity ON meeting_speakers(entity_id) WHERE entity_id IS NOT NULL;
            -- A speaker never keeps a name source without a person: when the person goes, the
            -- foreign key clears entity_id and this returns the speaker to 'auto'.
            CREATE TRIGGER entities_speakers_bd BEFORE DELETE ON entities BEGIN
                UPDATE meeting_speakers SET source = 'auto' WHERE entity_id = old.id;
            END;
            -- 1 when the user turned off separating speakers for this meeting: finalization leaves
            -- it without speaker data, which renders exactly like a meeting from before this feature.
            ALTER TABLE meetings ADD COLUMN speakers_off INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE segments ADD COLUMN speaker_id INTEGER REFERENCES meeting_speakers(id) ON DELETE SET NULL;
            ALTER TABLE segments ADD COLUMN speaker_confidence REAL;
            ALTER TABLE segments ADD COLUMN overlap INTEGER NOT NULL DEFAULT 0;
            -- 1 once the user decided who said the segment (reassigned, split or merged by hand):
            -- a later diarization never overwrites it.
            ALTER TABLE segments ADD COLUMN speaker_locked INTEGER NOT NULL DEFAULT 0;
            CREATE INDEX segments_by_speaker ON segments(speaker_id) WHERE speaker_id IS NOT NULL;
            CREATE TABLE voice_profiles(
                id INTEGER PRIMARY KEY,
                entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                model_id TEXT NOT NULL CHECK(length(model_id) > 0),
                embedding BLOB NOT NULL CHECK(length(embedding) > 0),
                created_at REAL NOT NULL,
                source_meeting_id INTEGER REFERENCES meetings(id) ON DELETE SET NULL,
                consent_recorded_at REAL NOT NULL,
                last_matched_at REAL
            );
            CREATE INDEX voice_profiles_by_entity ON voice_profiles(entity_id, model_id);
            CREATE INDEX voice_profiles_by_model ON voice_profiles(model_id, entity_id);
            CREATE INDEX voice_profiles_by_meeting ON voice_profiles(source_meeting_id) WHERE source_meeting_id IS NOT NULL;
            """)),
        // Speaker separation while recording. Each analysed window of the other participants' audio leaves its
        // speaker embeddings here (a few KB per window), so a recording that crashes can still have its speakers
        // finalized at the next launch. They are voice data: they live only in the encrypted store and its
        // journal, never reach an export, a prompt, the search index or the network, and the rows are deleted
        // when the speakers are finalized (secure_delete zeroes them) or with the meeting. No audio is stored.
        Migration(15, .sql("""
            CREATE TABLE diarization_windows(
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                seq INTEGER NOT NULL,
                data BLOB NOT NULL,
                PRIMARY KEY(meeting_id, seq)
            ) WITHOUT ROWID;
            """)),
        // Deterministic checks on the minutes. A decision or task the model proposed whose owner, date or figures
        // do not appear in the segment it cites is kept but marked `unconfirmed`; a task whose owner the cited
        // segment does not back (neither a confident speaker label nor the owner's name in the words) has
        // `owner_uncertain`. Both are 0 for every row written before, and for everything the user writes.
        Migration(16, .sql("""
            ALTER TABLE decisions ADD COLUMN unconfirmed INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE tasks ADD COLUMN unconfirmed INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE tasks ADD COLUMN owner_uncertain INTEGER NOT NULL DEFAULT 0;
            """)),
        // Chunk text names who spoke, so a question about a person finds what they said. `text_key` fingerprints the
        // text a chunk was embedded from (empty for chunks written before): a meeting whose speakers were named,
        // renamed or re-separated since then is embedded again, like after a change of embedding model. It is a
        // hash, never the text, and carries no voice data.
        Migration(17, .sql("""
            ALTER TABLE chunks ADD COLUMN text_key TEXT NOT NULL DEFAULT '';
            """)),
        // Recognizing voices across meetings (opt-in, off by default). While the setting is on, a finalized meeting
        // keeps a numeric summary of each speaker who talked long enough (`speaker_voices`), only so the user can
        // choose "Remember this voice" afterwards; it is voice data like a profile: it lives only in the encrypted
        // store, goes with its speaker (so with its meeting), is deleted once it becomes a profile, when the setting
        // is turned off and with "Delete All Saved Voices", and is never exported, logged, indexed or sent anywhere.
        // `speaker_suggestion_rejections` remembers, for one meeting, a person the user said a speaker is not, so
        // finalizing again never offers that person for that meeting. It holds IDs only.
        Migration(18, .sql("""
            CREATE TABLE speaker_voices(
                speaker_id INTEGER PRIMARY KEY REFERENCES meeting_speakers(id) ON DELETE CASCADE,
                model_id TEXT NOT NULL CHECK(length(model_id) > 0),
                embedding BLOB NOT NULL CHECK(length(embedding) > 0),
                created_at REAL NOT NULL
            );
            CREATE TABLE speaker_suggestion_rejections(
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                PRIMARY KEY(meeting_id, entity_id)
            ) WITHOUT ROWID;
            """)),
        // Imported recordings. `imported` is 1 for a meeting made from a file: it has one audio channel, so "This is my
        // voice" may be offered there (in a recording the user is the Me channel, and a remote speaker must never be
        // saved as the user). 0 for every meeting written before.
        Migration(19, .sql("ALTER TABLE meetings ADD COLUMN imported INTEGER NOT NULL DEFAULT 0;")),
        // A saved voice only suggests ("Is this Ana?"), it never names a speaker: a speaker once named by a voice
        // ('profile') becomes a suggestion until the user accepts it. The CHECK of 14 still allows 'profile'; nothing writes it.
        // The same rules as `planVoices` and `dropOrphanSuggestions` apply: a person the user already gave to another
        // speaker of the meeting, or whose saved voice is gone, is not suggested; that speaker is unnamed again.
        Migration(20, .sql("""
            UPDATE meeting_speakers SET entity_id = NULL, source = 'auto'
            WHERE source = 'profile' AND (
                entity_id IS NULL
                OR coalesce((SELECT merged_into FROM entities WHERE id = entity_id), entity_id)
                   NOT IN (SELECT entity_id FROM voice_profiles)
                OR coalesce((SELECT merged_into FROM entities WHERE id = entity_id), entity_id) IN (
                    SELECT coalesce((SELECT merged_into FROM entities WHERE id = u.entity_id), u.entity_id)
                    FROM meeting_speakers u
                    WHERE u.meeting_id = meeting_speakers.meeting_id AND u.source = 'user' AND u.entity_id IS NOT NULL));
            UPDATE meeting_speakers SET source = 'suggested' WHERE source = 'profile';
            """)),
        // Finding a saved voice in earlier meetings (opt-in with "Recognize voices across meetings", offered, never
        // automatic). `speaker_voices` is deleted when it becomes a profile, so it cannot serve a search after the user
        // confirms a voice; this table keeps the same numeric summary of each clean Others speaker for the SAME 14 days
        // (never longer: the people in a meeting did not agree to anything), only so a voice the user confirms can be looked
        // for in the meetings of that window (the result is a suggestion, never a name). Voice data like a profile:
        // encrypted store only, dies with its speaker (so with its meeting), after 14 days, with the person's voices, with
        // "Delete All Saved Voices" and when recognition is turned off; never exported, logged, indexed, put in a prompt or
        // sent anywhere.
        Migration(21, .sql("""
            CREATE TABLE speaker_centroids(
                speaker_id INTEGER PRIMARY KEY REFERENCES meeting_speakers(id) ON DELETE CASCADE,
                model_id TEXT NOT NULL CHECK(length(model_id) > 0),
                embedding BLOB NOT NULL CHECK(length(embedding) > 0),
                created_at REAL NOT NULL
            );
            """)),
        // The user's shorthand notes are expanded by the model. `notes.text` stays exactly what the user typed: no
        // model code writes it. The expansion lives in its own row (one per note) so the user's words are structurally
        // never rewritten. `sentences` holds the verified sentences with the segments they cite (stored JSON keys never
        // change meaning: text, cites[{seg, t}], quote, unconfirmed, differs); `source_key` is the normalized note text
        // it was written from, so a note edited since shows as out of date; `previous` keeps one level of undo. Search
        // uses kind 6 of `knowledge_fts`. The row goes with its note and its meeting; retention keeps it (it is the
        // distilled meeting, like decisions). No table is rebuilt.
        Migration(22, .sql("""
            ALTER TABLE notes ADD COLUMN added_after INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE notes ADD COLUMN edited_at REAL;
            CREATE TABLE note_expansions(
                note_id INTEGER PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                state TEXT NOT NULL CHECK(state IN ('pending','done','not_found','failed','dismissed')),
                pass TEXT NOT NULL CHECK(pass IN ('live','final','manual')),
                sentences TEXT CHECK(sentences IS NULL OR json_valid(sentences)),
                plain TEXT NOT NULL DEFAULT '',
                source_key TEXT NOT NULL,
                upto_segment INTEGER NOT NULL DEFAULT 0,
                user_edited INTEGER NOT NULL DEFAULT 0,
                previous TEXT CHECK(previous IS NULL OR json_valid(previous)),
                error_code TEXT,
                updated_at REAL NOT NULL
            );
            CREATE INDEX note_expansions_by_meeting ON note_expansions(meeting_id);
            CREATE TRIGGER note_expansions_ai AFTER INSERT ON note_expansions WHEN new.plain <> '' BEGIN
                INSERT INTO knowledge_fts(rowid, text) VALUES (new.note_id * 8 + 6, new.plain);
            END;
            CREATE TRIGGER note_expansions_au AFTER UPDATE OF plain ON note_expansions BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.note_id * 8 + 6;
                INSERT INTO knowledge_fts(rowid, text) SELECT new.note_id * 8 + 6, new.plain WHERE new.plain <> '';
            END;
            CREATE TRIGGER note_expansions_ad AFTER DELETE ON note_expansions BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.note_id * 8 + 6;
            END;
            """)),
        // Document knowledge sources: the folders and files the user added so Ask can answer from them. Only what the
        // user chose lives here (and so in backups): the app-scoped, read-only security-scoped bookmark of each source, its
        // last known path (for display and "Locate…"), its pause state, and which meeting it was attached to. The index of the
        // documents' text is NOT in this database: it is derived data in its own encrypted image (`vauta.docs.enc`, see
        // `DocumentIndex`), rebuilt from the sources. `attached_meeting_id` makes a single file a meeting's material;
        // `meeting_materials` links a file of a library source to a meeting without indexing it twice. Both go with their meeting.
        Migration(23, .sql("""
            CREATE TABLE doc_sources(
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL CHECK(kind IN ('folder','file')),
                display_name TEXT NOT NULL,
                path TEXT NOT NULL,
                bookmark BLOB NOT NULL,
                volume_uuid TEXT,
                paused INTEGER NOT NULL DEFAULT 0,
                attached_meeting_id INTEGER REFERENCES meetings(id) ON DELETE CASCADE,
                added_at REAL NOT NULL
            );
            CREATE INDEX doc_sources_by_meeting ON doc_sources(attached_meeting_id);
            CREATE TABLE meeting_materials(
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                source_id INTEGER NOT NULL REFERENCES doc_sources(id) ON DELETE CASCADE,
                rel_path TEXT NOT NULL,
                PRIMARY KEY(meeting_id, source_id, rel_path)
            );
            """)),
        // Apple's on-device embeddings (NLContextualEmbedding, model ids "apple-nl:*") were removed: they ranked below keyword
        // search in every benchmark. Their chunk vectors are useless now. Data only; the schema does not change. (The same
        // vectors in the documents image are dropped when it is opened: `DocumentIndex.dropRetiredVectors`.)
        Migration(24, .sql("""
            DELETE FROM chunks WHERE model LIKE 'apple-nl:%';
            """)),
        // A task whose owner is a speaker nobody has named yet ("Speaker 2"): the speaker row, so that naming the speaker later shows
        // the name (and the owner becomes the person). Null for every task written before and for every task with an owner who is a
        // person.
        Migration(25, .sql("""
            ALTER TABLE tasks ADD COLUMN owner_speaker_id INTEGER REFERENCES meeting_speakers(id) ON DELETE SET NULL;
            """)),
        // Live answers: the questions Vauta heard in a meeting and confirmed with the model, and what became of each (an
        // answer card shown, no answer, a rate limit, a newer question...). Stored with the meeting, encrypted like everything else,
        // and deleted with it (also by retention and by "Erase"). `text` is what the transcriber wrote, `rewrite` the standalone
        // question; `answer` is the verified answer with its citations (`AutoAnswerContent`, whose JSON keys never change meaning).
        // Only what the person kept (`kept`) reaches search (kind 7 of `knowledge_fts`) and export; the rest is shown on the meeting's
        // page only. A cited meeting or document that is deleted later is dropped when the row is read ("Source removed").
        Migration(26, .sql("""
            CREATE TABLE detected_questions(
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                segment_id INTEGER REFERENCES segments(id) ON DELETE SET NULL,
                t REAL NOT NULL,
                channel TEXT NOT NULL CHECK(channel IN ('me','others')),
                text TEXT NOT NULL,
                rewrite TEXT NOT NULL DEFAULT '',
                outcome TEXT NOT NULL CHECK(outcome IN ('answered','no_answer','rate_limited','stale','failed','superseded','stopped')),
                answer TEXT CHECK(answer IS NULL OR json_valid(answer)),
                shown INTEGER NOT NULL DEFAULT 0,
                dismissed INTEGER NOT NULL DEFAULT 0,
                kept INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX detected_questions_by_meeting ON detected_questions(meeting_id, t);
            CREATE TRIGGER detected_questions_ai AFTER INSERT ON detected_questions WHEN new.kept = 1 BEGIN
                INSERT INTO knowledge_fts(rowid, text)
                    VALUES (new.id * 8 + 7, new.text || ' ' || coalesce(json_extract(new.answer, '$.answer'), ''));
            END;
            CREATE TRIGGER detected_questions_kept AFTER UPDATE OF kept ON detected_questions BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 7;
                INSERT INTO knowledge_fts(rowid, text)
                    SELECT new.id * 8 + 7, new.text || ' ' || coalesce(json_extract(new.answer, '$.answer'), '') WHERE new.kept = 1;
            END;
            CREATE TRIGGER detected_questions_ad AFTER DELETE ON detected_questions BEGIN
                DELETE FROM knowledge_fts WHERE rowid = old.id * 8 + 7;
            END;
            """)),
        // The pre-meeting brief. `doc_sources.is_notes_export` marks a documents folder that holds notes exported from Notes (the brief
        // labels its passages "Note"); nothing else changes for a source. `meeting_briefs` keeps, with a recorded meeting, the
        // brief the person walked in with: references to the items it showed (a decision, a task, a meeting, a person, a file) and
        // the agenda lines that passed the checks, as JSON (`BriefStoredReferences`; its keys never change meaning). It holds no
        // reminder text and no invitation notes. It goes with its meeting (retention, delete and Erase).
        Migration(27, .sql("""
            ALTER TABLE doc_sources ADD COLUMN is_notes_export INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE meeting_briefs(
                meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
                created_at REAL NOT NULL,
                version INTEGER NOT NULL,
                json TEXT NOT NULL CHECK(json_valid(json))
            );
            """)),
        // Post-meeting actions (Part A). `tasks.due_day` is the calendar day of a due date, fixed when it is set ('YYYY-MM-DD', no time
        // zone), so it never shifts when the person travels; older rows get it from `due` in the time zone of this Mac at migration time
        // (a task written in another zone can still be one day off, which the architecture notes say). `meetings.time_zone` is the zone
        // of the Mac when the meeting was recorded (NULL for older ones). `follow_ups` are the next meetings found in a meeting (or added
        // by the person), so they can be dismissed and created once. `created_actions` is the ledger of what Vauta created or linked in
        // Reminders and Calendar: identifiers and a hash of the title only, never the text. A deleted task or follow-up keeps its ledger
        // row as 'orphaned' (the reminder still exists and still counts against duplicates); a deleted meeting removes it.
        Migration(28, .sql("""
            ALTER TABLE tasks ADD COLUMN due_day TEXT CHECK(due_day IS NULL OR due_day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]');
            ALTER TABLE meetings ADD COLUMN time_zone TEXT;
            ALTER TABLE meetings ADD COLUMN follow_ups_recipe INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE follow_ups(
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                segment_id INTEGER REFERENCES segments(id) ON DELETE SET NULL,
                t REAL,
                title TEXT NOT NULL,
                day TEXT CHECK(day IS NULL OR day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
                day_inferred INTEGER NOT NULL DEFAULT 0,
                minute_of_day INTEGER CHECK(minute_of_day IS NULL OR (minute_of_day >= 0 AND minute_of_day < 1440)),
                duration_min INTEGER,
                source TEXT NOT NULL CHECK(source IN ('detected','user')),
                state TEXT NOT NULL DEFAULT 'suggested' CHECK(state IN ('suggested','dismissed','done')),
                recipe INTEGER NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE INDEX follow_ups_by_meeting ON follow_ups(meeting_id);
            CREATE TABLE created_actions(
                id INTEGER PRIMARY KEY,
                target TEXT NOT NULL CHECK(target IN ('reminder','event','ics')),
                src_kind TEXT NOT NULL CHECK(src_kind IN ('task','follow_up')),
                src_id INTEGER NOT NULL,
                meeting_id INTEGER REFERENCES meetings(id) ON DELETE CASCADE,
                ek_id TEXT,
                ek_external_id TEXT,
                container_id TEXT,
                title_hash TEXT NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('writing','created','linked','handed_off','orphaned','removed','missing')),
                written_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                due_basis TEXT
            );
            CREATE UNIQUE INDEX created_actions_live ON created_actions(target, src_kind, src_id)
                WHERE state IN ('writing','created','linked','handed_off');
            CREATE INDEX created_actions_by_meeting ON created_actions(meeting_id);
            CREATE TRIGGER created_actions_tasks_ad AFTER DELETE ON tasks BEGIN
                UPDATE created_actions SET state = 'orphaned', updated_at = (julianday('now') - 2440587.5) * 86400.0
                 WHERE src_kind = 'task' AND src_id = old.id AND state IN ('writing','created','linked','handed_off');
            END;
            CREATE TRIGGER created_actions_follow_ups_ad AFTER DELETE ON follow_ups BEGIN
                UPDATE created_actions SET state = 'orphaned', updated_at = (julianday('now') - 2440587.5) * 86400.0
                 WHERE src_kind = 'follow_up' AND src_id = old.id AND state IN ('writing','created','handed_off');
            END;
            """), .code { db in
            // Backfill: the day of each existing due date in this Mac's time zone (best effort).
            let zone = TimeZone.current
            for row in try db.query("SELECT id, due FROM tasks WHERE due IS NOT NULL AND due_day IS NULL") {
                let day = DueDay.containing(Date(timeIntervalSince1970: row.double(1)), in: zone).string
                try db.query("UPDATE tasks SET due_day = ? WHERE id = ?", [.text(day), .integer(row.int(0))])
            }
        }),
        // Why a model-proposed item is "unconfirmed": `unconfirmed_reason` is a short internal code, never text from the meeting
        // ('rank' = the item did not make the ranked list, anything else = a check on the item's words doubted it: 'figures',
        // 'question', 'tentative', 'noAgreement'…). NULL for every row written before and for items that are not unconfirmed, which
        // keep today's look (an old unconfirmed item is shown as doubted). `unconfirmed` itself keeps its meaning everywhere.
        Migration(29, .sql("""
            ALTER TABLE decisions ADD COLUMN unconfirmed_reason TEXT;
            ALTER TABLE tasks ADD COLUMN unconfirmed_reason TEXT;
            """)),
        // Post-meeting actions (Part B): links from the tasks and decisions of a meeting to earlier ones. `item_vectors` are the search model's
        // vectors of the items' words (int8, one space per model), `item_links` the suggestions and what the person decided about them
        // ('suggested', 'confirmed', 'dismissed'; `src_id` is the newer item). Scores, methods and evidence are diagnostics: no text of a
        // meeting is stored here except the differing words in `evidence`, which are copied from the two items. `meetings.links_recipe` is
        // the recipe of the pass that last ran on a meeting. A deleted or re-worded item takes its vector and its suggestions with it
        // (triggers); confirmed and dismissed links go only when an item is deleted. `item_link_dismissals` keeps a dismissal by content
        // (a hash of the normalized words of both items, never the words), because rewriting the minutes gives the model's items new ids.
        Migration(30, .sql("""
            CREATE TABLE item_vectors(
                kind TEXT NOT NULL CHECK(kind IN ('task','decision')),
                item_id INTEGER NOT NULL,
                model TEXT NOT NULL,
                dims INTEGER NOT NULL,
                scale REAL NOT NULL,
                recipe INTEGER NOT NULL,
                emb BLOB NOT NULL CHECK(length(emb) = dims),
                PRIMARY KEY(kind, item_id, model)
            ) WITHOUT ROWID;
            CREATE TABLE item_links(
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL CHECK(kind IN ('task','decision')),
                src_id INTEGER NOT NULL,
                dst_id INTEGER NOT NULL,
                rel TEXT NOT NULL CHECK(rel IN ('same','changes')),
                state TEXT NOT NULL DEFAULT 'suggested' CHECK(state IN ('suggested','confirmed','dismissed')),
                method TEXT NOT NULL CHECK(method IN ('vector','keyword','model','user')),
                score REAL,
                evidence TEXT CHECK(evidence IS NULL OR json_valid(evidence)),
                recipe INTEGER NOT NULL,
                created_at REAL NOT NULL,
                decided_at REAL,
                -- What the two items were before a confirmation made them the person's (source, text key, doubted), so Undo can give it back.
                prior TEXT CHECK(prior IS NULL OR json_valid(prior)),
                CHECK(src_id <> dst_id),
                CHECK(rel = 'same' OR kind = 'decision')
            );
            CREATE UNIQUE INDEX item_links_pair ON item_links(kind, src_id, dst_id);
            CREATE INDEX item_links_dst ON item_links(kind, dst_id);
            CREATE INDEX item_links_pending ON item_links(kind, src_id) WHERE state = 'suggested';
            CREATE TABLE item_link_dismissals(
                kind TEXT NOT NULL CHECK(kind IN ('task','decision')),
                src_meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                src_key TEXT NOT NULL,
                dst_meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                dst_key TEXT NOT NULL,
                decided_at REAL NOT NULL,
                PRIMARY KEY(kind, src_meeting_id, src_key, dst_meeting_id, dst_key)
            ) WITHOUT ROWID;
            ALTER TABLE meetings ADD COLUMN links_recipe INTEGER NOT NULL DEFAULT 0;

            CREATE TRIGGER item_cleanup_tasks_ad AFTER DELETE ON tasks BEGIN
                DELETE FROM item_vectors WHERE kind = 'task' AND item_id = old.id;
                DELETE FROM item_links WHERE kind = 'task' AND (src_id = old.id OR dst_id = old.id);
            END;
            CREATE TRIGGER item_cleanup_decisions_ad AFTER DELETE ON decisions BEGIN
                DELETE FROM item_vectors WHERE kind = 'decision' AND item_id = old.id;
                DELETE FROM item_links WHERE kind = 'decision' AND (src_id = old.id OR dst_id = old.id);
            END;
            CREATE TRIGGER item_vectors_tasks_au AFTER UPDATE OF text ON tasks WHEN new.text IS NOT old.text BEGIN
                DELETE FROM item_vectors WHERE kind = 'task' AND item_id = old.id;
                DELETE FROM item_links WHERE kind = 'task' AND state = 'suggested' AND (src_id = old.id OR dst_id = old.id);
            END;
            CREATE TRIGGER item_vectors_decisions_au AFTER UPDATE OF text ON decisions WHEN new.text IS NOT old.text BEGIN
                DELETE FROM item_vectors WHERE kind = 'decision' AND item_id = old.id;
                DELETE FROM item_links WHERE kind = 'decision' AND state = 'suggested' AND (src_id = old.id OR dst_id = old.id);
            END;
            """)),
        // The speakers' sound picked up by the microphone: Me lines that are the other participants' words (`EchoDetection`, run
        // when the recording ends). 0 = not marked; 1 = an echo: shown dimmed, left out of the minutes, answers, owners, search and
        // exports, never deleted; 2 = the person said the line is theirs, so it is never marked again.
        Migration(31, .sql("""
            ALTER TABLE segments ADD COLUMN echo INTEGER NOT NULL DEFAULT 0 CHECK(echo IN (0, 1, 2));
            """)),
        // How tight a speaker's voice cluster is: the mean cosine of its window embeddings to their centroid (`SpeakerCentroid.spread`),
        // written by the diarization that found the speaker. One number, not a voice: it cannot be matched with anybody. Low means the
        // cluster probably holds two voices, so its lines do not back a task owner on their own (`SpeakerTag.mixesVoices`). NULL for
        // the speakers written before, the user's microphone, and speakers the user added.
        Migration(32, .sql("""
            ALTER TABLE meeting_speakers ADD COLUMN voice_spread REAL CHECK(voice_spread IS NULL OR voice_spread BETWEEN -1 AND 1);
            """)),
        // The meetings whose Me lines were never checked for the speakers' echo: those recorded before it was marked (migration 31)
        // and, added when the store opens, those a crash left open, which never reached `endMeeting`. `markPendingEchoes` checks
        // each once and takes it off the list. A meeting with a line already marked, or said to be the person's, was checked.
        Migration(33, .sql("""
            CREATE TABLE echo_pending (meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE);
            INSERT INTO echo_pending (meeting_id) SELECT id FROM meetings WHERE ended_at IS NOT NULL AND raw_purged_at IS NULL
                AND NOT EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id AND echo <> 0);
            """)),
        // A speaker who said who they are ("Hi, I'm Ana"): the line that said it, for a suggestion that came from it (`source` stays
        // 'suggested', so it is only "Is this Ana?" until the person accepts it). Gone with the line; and when the speaker's person or
        // source changes any other way (a voice, the person's answer), the line no longer explains it and is forgotten.
        Migration(34, .sql("""
            ALTER TABLE meeting_speakers ADD COLUMN suggested_by_segment INTEGER REFERENCES segments(id) ON DELETE SET NULL;
            CREATE TRIGGER meeting_speakers_suggestion_reason AFTER UPDATE OF entity_id, source ON meeting_speakers
            WHEN new.suggested_by_segment IS NOT NULL AND new.suggested_by_segment IS old.suggested_by_segment
                 AND (new.entity_id IS NOT old.entity_id OR new.source <> 'suggested')
            BEGIN
                UPDATE meeting_speakers SET suggested_by_segment = NULL WHERE id = new.id;
            END;
            """)),
    ]

    /// The schema version this build writes.
    static var currentVersion: SchemaVersion { migrations.last!.version }

    static func version(of db: SQLiteDatabase) throws -> SchemaVersion {
        try db.query("PRAGMA user_version")[0].int(0)
    }

    /// Applies the pending migrations up to `target` (default: the latest).
    /// Returns true if anything changed. A database from a newer version of
    /// Vauta is refused untouched (its content is unknown; rewriting it would
    /// lose data).
    @discardableResult
    static func migrate(_ db: SQLiteDatabase, upTo target: SchemaVersion? = nil,
                        using migrations: [Migration] = Schema.migrations) throws -> Bool {
        let latest = migrations.last?.version ?? 0
        let version = try version(of: db)
        guard version <= latest else {
            throw StoreError(.newerSchema, detail: "schema \(version) > \(latest)")
        }
        var changed = false
        for migration in migrations where migration.version > version && migration.version <= (target ?? latest) {
            try apply(migration, to: db)
            changed = true
        }
        return changed
    }

    private static func apply(_ migration: Migration, to db: SQLiteDatabase) throws {
        if migration.rebuildsTables { try db.execute("PRAGMA foreign_keys = OFF") }
        defer { if migration.rebuildsTables { try? db.execute("PRAGMA foreign_keys = ON") } }
        try db.execute("BEGIN")
        do {
            for step in migration.steps {
                switch step {
                case .sql(let sql): try db.execute(sql)
                case .code(let body): try body(db)
                }
            }
            if migration.rebuildsTables, try !db.query("PRAGMA foreign_key_check").isEmpty {
                throw StoreError(.migrationFailed, detail: "foreign key violations after rebuild")
            }
            try db.execute("PRAGMA user_version = \(migration.version)")
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw StoreError(.migrationFailed, detail: "version \(migration.version): \(error)")
        }
    }
}
