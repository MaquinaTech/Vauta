// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Which parts of the post-meeting actions are on in this release. The code for each part stays and is tested; a part is switched on
/// here only when its judged evaluation meets the gate in docs/ACTIONS.md.
public enum ActionsRelease {
    /// The email draft section of the Follow-up sheet. Held on both backends: judged with default settings, no email on Apple's model
    /// and 3 of 27 on the integrated model were free of factual errors before the extraction fix, and after it every judged arm still had
    /// errors (one email: Apple 15 of 15 meetings, integrated 11 of 15), so the first gate (0 factual errors) fails.
    public static let emailDraft = false

    /// Automatic detection of follow-up meetings in a transcript. On: with the cap of 2 candidates per meeting the judged detector met all
    /// three gates (precision 1.00, capped recall 0.867, day accuracy 1.00), all on mentions inserted into the test transcripts (natural recall 0 of 2; precision's lower
    /// bound 0.87). **Those figures were measured on the stored minutes of the new extraction**, while the app runs the ranked one on Apple's model
    /// and the old one on the servers (`MinutesRelease.extraction(integrated:)`). Rules version 2 was run on Apple's ranked minutes on 2026-10-24 (no judge,
    /// 14 meetings: precision 1.00, capped recall 0.857, day accuracy 1.00; docs/LANGUAGE_MODEL.md); the servers' minutes were not measured. With them the
    /// detector reads the same transcript lines (the cited segments and the last tenth); its task path ignores a task with an implausible day, because a
    /// day the old extraction kept may be one the model worked out, and counts a task marked "to be confirmed" only when its cited clause states the day. The sheet therefore never says that no follow-up was mentioned, only that Vauta found none. **New Event…** (by hand) is always available.
    public static let followUpDetection = true

    /// The email's summary, by backend: none has been measured accurate, so none offers it (`FollowUpEmailSummary`).
    public static let emailSummaryBackends: Set<String> = FollowUpEmailSummary.measuredAccurateBackends
}
