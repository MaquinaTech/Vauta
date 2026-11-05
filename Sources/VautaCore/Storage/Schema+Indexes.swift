// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

extension Schema {
    /// Migration 39, indexes only: every foreign key column leads an index (`StorageForeignKeyIndexTests`). Deleting a parent
    /// looks its children up by that column; without one, each deleted line or meeting scanned the whole child table (deletes,
    /// retention, edits). Published once merged: never edit it (`SchemaFreezeTests`).
    static let foreignKeyIndexes = """
            CREATE INDEX decisions_by_segment ON decisions(segment_id) WHERE segment_id IS NOT NULL;
            CREATE INDEX tasks_by_segment ON tasks(segment_id) WHERE segment_id IS NOT NULL;
            CREATE INDEX tasks_by_owner ON tasks(owner_id) WHERE owner_id IS NOT NULL;
            CREATE INDEX tasks_by_owner_speaker ON tasks(owner_speaker_id) WHERE owner_speaker_id IS NOT NULL;
            CREATE INDEX suggestions_by_meeting ON suggestions(meeting_id);
            CREATE INDEX suggestions_by_segment ON suggestions(segment_id) WHERE segment_id IS NOT NULL;
            CREATE INDEX detected_questions_by_segment ON detected_questions(segment_id) WHERE segment_id IS NOT NULL;
            CREATE INDEX follow_ups_by_segment ON follow_ups(segment_id) WHERE segment_id IS NOT NULL;
            CREATE INDEX meeting_speakers_by_suggested_segment ON meeting_speakers(suggested_by_segment) WHERE suggested_by_segment IS NOT NULL;
            CREATE INDEX entities_by_merged_into ON entities(merged_into) WHERE merged_into IS NOT NULL;
            CREATE INDEX glossary_by_entity ON glossary(entity_id) WHERE entity_id IS NOT NULL;
            CREATE INDEX relations_by_meeting ON relations(meeting_id) WHERE meeting_id IS NOT NULL;
            CREATE INDEX llm_jobs_by_meeting ON llm_jobs(meeting_id);
            CREATE INDEX item_link_dismissals_by_src_meeting ON item_link_dismissals(src_meeting_id);
            CREATE INDEX item_link_dismissals_by_dst_meeting ON item_link_dismissals(dst_meeting_id);
            CREATE INDEX meeting_materials_by_source ON meeting_materials(source_id);
            CREATE INDEX speaker_suggestion_rejections_by_entity ON speaker_suggestion_rejections(entity_id);
            """
}
