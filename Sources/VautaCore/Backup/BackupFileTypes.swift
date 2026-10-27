// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

/// File extensions of an encrypted backup. The content format is identical for both
/// (its magic stays "ACTABK" forever); only the extension changed with the rename.
public enum BackupFileTypes {
    /// What Vauta writes.
    public static let current = "vautabackup"
    /// What the earlier version wrote. Still accepted when restoring.
    public static let legacy = "actabackup"
    /// Every extension restore accepts, current first.
    public static let accepted = [current, legacy]
}
