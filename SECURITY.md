# Security policy

## Supported versions

Vauta is distributed as source code only (no signed or notarized downloads): you build it from a tagged commit, see [Verifying what you run](#verifying-what-you-run).

| Version | Security fixes |
|---|---|
| Latest tagged release (0.9.x) | Yes |
| Older tags | No. Please update |
| Builds from `main` | Fixed on `main`; no backports |

## Reporting a vulnerability

Please report vulnerabilities **privately**, through GitHub's private vulnerability reporting:
[github.com/MaquinaTech/Vauta/security/advisories/new](https://github.com/MaquinaTech/Vauta/security/advisories/new).
Do not open a public issue, discussion or pull request for a security problem.

Include what you can: the Vauta version (Settings → About), the macOS version, the steps to reproduce, what you expected
and what happened, and the impact you see. Do not include real meeting content.

Vauta is maintained by one person, so these are targets, not guarantees:

| Step | Target |
|---|---|
| Acknowledge your report | 7 days |
| First assessment (confirmed or not, severity) | 14 days |
| Fix or mitigation for critical issues | as fast as possible, within 60 days at most |
| Fix or mitigation for high and medium issues | 60 days |
| Low issues | the next regular release |

These targets meet the [OpenSSF Best Practices](https://www.bestpractices.dev/) criterion that no medium or higher
vulnerability stays unpatched more than 60 days after it is publicly known; ours count from your report, which is stricter. If a fix needs longer (for example a change to a persisted
format that must stay compatible), we tell you why and publish a mitigation in the meantime.

Vauta has **not been independently audited** (see [Audit status](#audit-status)).

We coordinate the disclosure date with you, publish a GitHub security advisory with the fix, and credit you unless
you prefer otherwise.

**In scope:** the Vauta app and command-line tool, the scripts in `scripts/`, and the release workflow.
**Out of scope:** vulnerabilities in model servers (LM Studio, Ollama and others), in macOS or Apple frameworks, and
findings that require the attacker to already control your user account while Vauta is running (see the threat model).

## Threat model

Vauta handles meeting transcripts and, for speaker separation and the optional saved voices, **voice-derived data**
(speaker embeddings and voice fingerprints, which are biometric data). Both can be very sensitive. Vauta is designed for one
person on their own Mac. Audio itself is never written to disk. The voice data rules are in
[Speaker separation and voice data](#speaker-separation-and-voice-data).

### What Vauta protects against

| Threat | Protection |
|---|---|
| Someone reads the store from the disk, a stolen backup or a copied file | The store is encrypted with AES-256-GCM; the key is in the login keychain, not next to the file. Audio is never written to disk |
| Another app on the Mac reads Vauta's data | The store is in Vauta's sandbox container and is ciphertext. The database key's Keychain access is bound to Vauta's code signature: another app asking for it triggers a macOS prompt |
| Someone on the network reads or changes what Vauta sends to a model server | Network servers are reached only over HTTPS with TLS 1.3, with your private CA as the only trust anchor when you set one (otherwise the system's, for a publicly trusted certificate) and optional certificate pins. Vauta refuses non-private addresses, proxies and redirects |
| A misconfiguration sends meetings to the internet | Destinations are validated in code: loopback, or private network addresses and local names only |
| Meeting text leaks through other channels | No telemetry, no logs, no window restoration, notifications without meeting text, optional copy protection |
| Someone gets a backup file | AES-256-GCM with a PBKDF2-derived key (1,000,000 iterations); only as strong as the password you chose |
| Voice data (speaker embeddings, saved voice fingerprints) leaks from disk, backups, exports or the network | Kept only in the encrypted store and in password-encrypted backups (the same protection as the transcript); never in exports, logs, prompts, the search index or on the network; fingerprints are opt-in, deletable per person and removed by Erase Everything |
| A malicious document (a crafted PDF, Office file, archive or image) attacks the parser | The Office formats are read with Vauta's own strict reader, never a general one: ZIP and XML limits (central directory only, no ZIP64, no encryption, 200:1 ratio, 64 MB per entry, 200 MB per file, CRC checked, no DOCTYPE or entity so no XXE or entity expansion, depth, size and time limits); HTML is stripped as text and never loaded in a web view, so nothing remote is fetched; PDF, images and text recognition use Apple's frameworks **in the app's process** with size, page and time limits and a crash guard (`vauta.docs.extracting`: a file that crashed Vauta is skipped on the next launch). Opening and drawing a PDF page (also for text recognition) runs on a thread of its own inside a deadline, and a file that passes it is finished as partial and not tried again at every launch. Apple's parsers (PDFKit, the RTF and Word readers) never look at a clock, so a crafted file can keep its abandoned thread busy until you quit: Vauta counts those threads and, with two stuck, starts no further PDF, Word, RTF or image read until one ends (residual risk: up to two busy threads and the memory of their files). Reading never happens while a meeting records. Fuzz tests run in CI. A separate, isolated reader process is planned |
| Text in a document tries to steer the model (prompt injection) | Document text is cleaned, delimited, defanged and labelled as data; one rule in the system prompt says never to follow it; Ask has no tools and fetches nothing; the answer is plain text; a claim is verified only by a verbatim quote in a passage that was sent; document text never reaches the minutes, notes or live notes |
| A tampered or substituted search model (a malicious mirror, CDN or file) | Only Google's original file at one pinned revision is fetched, and every 32 MiB block, each of the 413 tensors and the assembled file are checked against SHA-256 values built into Vauta before anything is installed; a mismatch deletes everything. The weights are data: the parsers are bounded and fuzzed, there is no pickle and no remote code, and the model cannot run anything. A malicious CDN can only make the download fail. See [The search model](#the-search-model-optional-download) |
| Old copies of the store stay readable after "Erase Everything" | The key is deleted and replaced (crypto-shred). See the caveat about keychain backups below |

### Speaker separation and voice data

Separating the speakers of a meeting produces voice-derived data (embeddings). The rules:

- They are computed on this Mac by two models bundled in the app. Each model folder is checked against a pinned
  SHA-256 (a hash over every file name and content) before Core ML loads it; a changed, missing or extra file, or a
  symbolic link, refuses to load and the recording continues without speakers. The check guards a damaged or tampered
  copy; an attacker who can rewrite the signed app bundle is out of scope, as for the rest of the app. Core ML also
  compiles the verified files for the Neural Engine into its own cache in the app's Caches folder; that derived copy
  holds no meeting data and is not hashed (tampering with it needs write access as your user, which is out of scope below).
- Window embeddings are written only to the encrypted store (`diarization_windows`, in the encrypted journal and
  snapshot), are deleted when the speakers are finalized (or, if that fails or the recording crashed, when the meeting
  ends or at the next launch, whichever comes first; or with their meeting), are deleted when a backup that holds an
  unfinished recording is restored, and are never logged, exported, indexed, put in a prompt or sent. `WindowRecord` prints no embedding.
- Malware running as your user while Vauta is open can read them from memory like the rest of the store; that is
  already out of scope (below).
- The models add no code and no network path (`NetworkAuditSourceScanTests` covers the sources).

#### Saved voices (voice profiles)

Suggesting who is speaking across meetings stores voice fingerprints (`voice_profiles`, up to 10 per person) and, while the
setting is on, a voice summary per speaker with each meeting (`speaker_voices`). They are biometric data, so:

- Off by default; saved only by an explicit action per person, behind a consent attestation whose time is stored. The user
  records who agreed; Vauta cannot verify it. The paid legal review was not done: the docs say consent is the recording
  user's responsibility and recommend a DPIA note for organisations.
- They live only in the encrypted store (journal and snapshot), are included in encrypted backups and in Erase Everything,
  and are not in exports, logs, prompts, the search index, the vector cache or on the network. `VoiceProfileEmbedding`,
  `SpeakerVoiceDraft` and `SpeakerCentroid` print no vector. A source scan test (`VoiceRecognitionTests`) fails if a file
  other than the store and the matcher touches the voice tables.
- Deleting them (per person, which includes the summaries of the speakers named after them, all, with the person or with the
  meeting, by turning the setting off for the summaries, when a summary is 14 days old, and when a meeting's summaries are
  replaced) saves a snapshot at once, so neither the journal nor the previous snapshot keeps them (`secure_delete` zeroes the pages).
- A fingerprint of another embedding model is never compared, and the thresholds belong to one model.
- The shipped app has no command that writes voice vectors to a file: the calibration command `speaker-centroids` exists only
  in the diagnostics build, which is never distributed (and a source-scan test fails if code other than the store, the
  matcher and the diarization calls `SpeakerCentroids.compute`).
- Exfiltration of the fingerprints by malware running as the same user while Vauta is open is **out of scope**, like the
  rest of the decrypted store (below). A fingerprint cannot be turned back into audio, but it could be used to recognize that
  person's voice elsewhere, which is why it is opt-in.

### What Vauta does not protect against

- **Malware or another process running as your user while Vauta is open.** The decrypted database is in Vauta's
  memory, and the login keychain is unlocked for your whole session, including while the screen is locked. The
  Meetings lock (Touch ID or password) protects the interface, not memory.
- **A key item planted before Vauta creates its store.** When no store exists yet, Vauta uses a `database-key-v1` item
  that is already in the login keychain (so a store restored next to it still opens). A process running as you that
  created that item beforehand, with an access list open to it, could read the key. Such a process is already in the
  threat above; "Erase Everything" and a restore replace the item with one only Vauta can read.
- **Other accounts on this Mac, with a server on this Mac.** In **This Mac** mode Vauta talks plain HTTP to
  `127.0.0.1`, which is shared by every account on the Mac. While your server is stopped, a process of another
  account can listen on its port and receive Vauta's requests (meeting text and the server key). On a Mac shared
  with people you don't trust, keep the server running while Vauta uses it, or run it on another computer
  (**Network** mode, HTTPS).
- **Someone using your unlocked login session.** Vauta asks for Touch ID or your password before showing Meetings,
  but whatever is already on screen is visible, and your keychain is unlocked for any app they run.
- **Rollback.** Replacing `vauta.db.enc` and `vauta.journal.enc` with an older pair encrypted with the same key, or
  dropping whole records from the end of the journal, is not detected: it authenticates and brings back an earlier
  state. "Erase Everything" changes the key, so copies older than an erase never open.
- **A compromised or untrusted model server.** The server reads everything Vauta sends it (transcript text, notes,
  names). Use a server you control.
- **Old keychain backups.** Time Machine backs up the login keychain, encrypted with your login password, so an older
  backup may still contain a key that "Erase Everything" has since replaced. The store itself is excluded from
  backups, but someone with a copy of an old store file (for example one copied by hand), that keychain backup and
  the login password of that time can decrypt that copy. Erase Everything removes the key and data from this Mac; it
  cannot change old backups.
- **Screenshots and screen sharing.** Copy protection prevents accidental copying, not someone who can see the screen.
- **Ad-hoc signed builds.** Without a stable signature, the Keychain cannot bind the key to Vauta's identity.

## Encryption

### Key

- A random 256-bit key (CryptoKit), stored as a generic-password item in the login keychain: service = the app's
  bundle ID, account `database-key-v1`. Never synchronizable.
- Created only when no store exists. If the store exists and its key is missing, Vauta refuses to create a new key
  (that would make the store unreadable) and reports the problem. A locked keychain or a cancelled prompt never leads
  to a new key.
- A new store uses an item that is already there, so a store file put back next to it still opens (see the limit
  below). "Erase Everything" never does: it deletes the item, checks it is gone and adds a new one, and an item that
  appears in between makes the add fail instead of being adopted.
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is set, but the classic login keychain ignores it (it needs the Data
  Protection keychain, which requires a provisioning profile). In practice the item is readable while the login
  keychain is unlocked.

### Snapshot (`vauta.db.enc`), envelope v2

The database is an in-memory SQLite database. To save it, Vauta serializes it with `sqlite3_serialize`, compresses it
with LZ4 (or stores it as is when that is not smaller) and seals it:

```
file      = "ACTA" | 0x02 | nonce (12) | ciphertext | tag (16)
plaintext = size (UInt64 LE) | method (0 = stored, 1 = LZ4) | payload
cipher    = AES-256-GCM, random nonce, AAD = "ACTA" | 0x02
```

The magic `ACTA` is a legacy format identifier from the working name. Like `ACTJ` (journal), `ACTABK` (backup) and the
HKDF label `acta-journal-v1`, it is part of the encrypted formats and of the authenticated data, so it never changes.
Stores written before the rename open without conversion.

The header is authenticated, so a tampered file or a file of another version does not decrypt. Envelope v1 (Vauta
0.1, LZFSE) is still read and is rewritten as v2 on the next save. The envelope version is independent of the
database schema version.

### Journal (`vauta.journal.enc`)

Between snapshots, only new writes are appended (every 10 seconds while recording):

```
header = "ACTJ" | 0x01 | generation (16 random bytes)
record = length (UInt32 LE) | AES-256-GCM(statements), AAD = header | seq (UInt64 LE)
key    = HKDF-SHA256(database key, info: "acta-journal-v1", 32 bytes)
```

- The journal key is derived with its own label: the snapshot and the journal never share a key.
- The snapshot stores the generation, so a journal from another snapshot is never replayed.
- The sequence number in the AAD prevents reordering, repeating or removing records in the middle. A truncated last
  record (power cut mid-write) does not authenticate and replay stops there.

### Documents index (`vauta.docs.enc`)

The index of the files you add as document sources uses the snapshot's envelope with its own key,
`HKDF-SHA256(database key, info: "vauta.documents.v1", 32 bytes)`. It is derived data: never in the journal or in backups,
rebuilt from your files when it does not open, and deleted by Erase Everything and by a restore. While a file is being
read, a small plaintext marker, `vauta.docs.extracting`, holds the source number, the file's size and date, and the first
8 bytes of an HMAC-SHA256 of its relative path (key derived from the documents key with `vauta.documents.marker.v1`),
never its name, so a file that crashes the reader is skipped on the next launch.

### Durability

- Snapshots are written to a new `0600` temporary file, flushed with `F_FULLFSYNC`, renamed over the old file, and the
  directory is flushed with `F_FULLFSYNC` so the rename survives a power cut.
- Journal appends use `F_BARRIERFSYNC` (ordered, cheap). A power cut can lose the last few seconds of a recording,
  never the order of what was written.
- A snapshot is taken a few seconds after edits, when the journal exceeds 8 MB, and when a recording ends.

### Plaintext hygiene

- Plaintext buffers that Vauta controls are zeroed when released (best effort: copies made inside Foundation or
  CryptoKit cannot be reached).
- SQLite runs with `secure_delete = ON` and `temp_store = MEMORY`. Deleting a meeting also merges the full-text
  indexes and runs `VACUUM`.
- The process runs with `umask 077`. Window restoration is off. A file lock (`vauta.lock`, and `acta.lock` too while
  it exists) prevents two instances from writing the same store.
- **Migrating from an earlier version.** On open, a store with the old file names is verified with the Keychain key (read-only) and
  only then renamed in place, one atomic `rename(2)` per file, snapshot first and journal second. An interruption
  between the two is finished on the next open; any failure after the renames puts the old names back. Files are
  never deleted by the migration.

### Encrypted backups

Format of a backup file (`.vautabackup`; backups from an earlier version are still accepted), implemented in `Sources/VautaCore/Backup/`:

    "ACTABK" | version (1) | KDF id (1 = PBKDF2-HMAC-SHA256) | iterations (UInt32, big endian) | salt (16 bytes)
    | AES-256-GCM sealed box (12-byte nonce | ciphertext | 16-byte tag)

- The 28-byte header is the GCM additional authenticated data, so changing the version, the iteration count or the salt makes decryption fail.
- Key: PBKDF2-HMAC-SHA256 (CommonCrypto `CCKeyDerivationPBKDF`) over the NFC-normalized UTF-8 password, 1,000,000 iterations
  (readers accept 600,000 to 2,000,000), 16 random bytes of salt, 32-byte output. Apple's frameworks have no
  memory-hard KDF (scrypt, Argon2) and Vauta takes no third-party cryptography code, so a long password is the real protection;
  the app requires at least 12 characters.
- Plaintext inside the sealed box: manifest length (UInt32) | manifest (JSON: format, app version, schema version,
  creation time, meeting count, settings length) | the settings (format 2 only) | the database image in the same
  packed form as the snapshot (size | LZ4 | bytes). The image is taken from the open store in one step on the store's
  actor, so it is consistent.
- Settings (`BackupPreferences`): a binary property list of an explicit allow-list of UserDefaults keys (languages,
  templates, shortcuts, privacy and recording switches, the choice of where models run), each with the type it must
  have. No Keychain item is ever read: the server address, models, key, certificate authority and pins stay out, as
  does everything specific to one Mac (frames, markers, calendar identifiers). On restore a key that is unknown, of
  another type or too large is skipped, a payload that can't be read is ignored (the meetings still restore), and
  nothing outside the allow-list is ever written. Format 1 (no settings) is still read and leaves the settings alone;
  a reader that only knows format 1 refuses a format 2 file by its manifest. The archive version byte stays 1.
- Plaintext buffers that Vauta controls are zeroed after use; nothing unencrypted is written to disk.
- A backup is treated as untrusted even though it is authenticated (whoever knows the password can author one). Every
  database connection runs with `trusted_schema = OFF` and `cell_size_check = ON`; a declared image size is capped
  (1 GiB, and LZ4 payloads cannot declare more than 256 times their length).
- Restore decrypts and validates in memory (authentication, manifest, schema no newer than the app's, the image's
  schema compared object by object with Vauta's own DDL for that version, so a backup carrying any extra or changed
  table, index, trigger, view or virtual table is refused before anything runs; SQLite `integrity_check`;
  migrations for older schemas) before touching the store. Then, with no suspension point: a new random key is
  stored in a second Keychain item (`database-key-v1.staged`); the backup is written as the new snapshot, sealed with
  the new key, atomically over the old one (`F_FULLFSYNC`, rename, directory sync); the database key item is deleted
  and added again with the new key and Vauta's own access list; the staged item is deleted; the journal is removed.
  If writing fails, the staged key is deleted and the old store is untouched. If the process stops at any step, the
  next launch opens the store with whichever of the two keys authenticates the snapshot and finishes the change, so
  the store opens with either the old data or the restored data. After success the old key no longer exists, which
  is the same crypto-shred as Erase Everything.
- A wrong password, a changed header or payload, and a truncated file are indistinguishable by design (GCM
  authentication fails); a file without the header, or cut inside it, is reported as not being a backup.
- Not protected: a backup is only as strong as its password; an attacker with the file can guess offline. A backup also
  carries no freshness: restoring an older backup is allowed (that is its purpose).

### Erase Everything

Deletes the snapshot and the journal, deletes the key from the Keychain, verifies it is gone, creates a new key and
writes an empty store. A marker file completes the key rotation on the next launch if Vauta is interrupted.
The search model (public weights, no personal data) is not part of the store and is kept; **Settings → Models → Delete…** removes it.

## Network policy

Vauta's only network client is `LLMClient`, which talks to the model server you configured. The rules are enforced in
code (`LLMServerConfig`, `ServerAddress`, `ServerTrust`, `LLMClient`). Every request, from `LLMClient` and from
discovery, goes through one choke point, `AuditedSession` (see [Network audit](#network-audit)):

| Rule | Detail |
|---|---|
| Two modes | **This Mac**: loopback only (`127.0.0.0/8`, `::1`, `localhost`); plain HTTP allowed. **Network**: HTTPS only, never loopback |
| Private addresses only | `10/8`, `172.16/12`, `192.168/16`, `100.64/10` (CGNAT, Tailscale), `169.254/16`, `fc00::/7`, `fe80::/10`, IPv4-mapped forms, and names ending in `.local`, `.lan`, `.home.arpa`, `.internal` or `.ts.net`. IP literals are parsed into bytes (no leading zeros or textual tricks) |
| TLS 1.3 only | `tlsMinimumSupportedProtocolVersion = .TLSv13` |
| Private CA | When set, the certificates in your CA bundle are the **only** trust anchors. Without one, the system anchors are used (for a publicly trusted certificate, such as one from `tailscale cert`). Either way, evaluation makes no network fetches (no OCSP, CRL or missing intermediates), so a publicly trusted server must send its full chain. The host name must match the certificate |
| Certificate pins | SHA-256 of the leaf certificate's SubjectPublicKeyInfo (base64). Several are allowed for rotation. EC P-256/P-384/P-521 and RSA keys |
| Names need trust | A host given by name (not an IP address) needs a private CA or a pin. Configurations saved by an earlier version without either keep working and show a warning |
| Peer check | For hosts given by name, the address actually connected to must be private (or, for IPv6 only, on a subnet this Mac is directly attached to; an IPv4 peer must always be private); otherwise further requests are refused until the configuration is applied again. Before the first request of a session to such a host, Vauta sends a probe with no body and no key (`GET …/models`) and waits for its connection metrics: nothing else is sent until the connected address is known to be allowed, and nothing is sent if the metrics don't arrive within 10 seconds. Every completed request is checked again. What remains: the system may open another connection later (a second one in parallel, or a new one after the idle one closed) and resolve the name again; a request on that connection is checked only once it completes, and stops the ones after it. TLS runs first on that connection too, which is why new configurations need a private CA or a pin for names |
| No proxies, no redirects | HTTP, HTTPS, SOCKS, PAC and proxy auto-discovery are disabled; redirects are refused |
| Fixed destinations | URLs are built only from the configured base URL (plus a few read-only identification paths of the chosen server type on the same origin) and checked again on every response |
| No state | Ephemeral session: no cache, cookies or credential storage. Response sizes are capped |
| The key | Read from the Keychain for each request, printable ASCII only, never logged. "Test Connection" sends the saved key only to the exact saved destination and trust settings. The key and the configuration are saved as a new Keychain item each time (any item already there is deleted first), so they never take on an access list another app set |

**Discovery** ("Find Servers") uses a separate session that only reaches `http://127.0.0.1` on ports 1234, 11434, 8080,
8000 and 1337, with short timeouts, no proxies and no redirects. It runs when you click the button, and, while the
**Set up a model server** guide is open, every few seconds on ports 1234 and 11434 only (it stops when the guide closes).

Speech models and on-device language assets are downloaded by macOS from Apple, not by Vauta. Vauta never listens on
the network.

### The search model (optional download)

The one other outgoing connection is the optional search model, only after you click **Download** (see
[PRIVACY.md](PRIVACY.md#the-search-model)). It has its own session and its own rules, in `SearchModelDestinations`
and `SearchModelDownloader`, and also goes through `AuditedSession` with the purpose `modelDownload`:

| Rule | Detail |
|---|---|
| Nothing unless you click | Constructing the controller, launching the app and every background task make no request (a test counts zero log entries). A recording pauses a running download and it continues by itself afterwards |
| Exact destinations | `https`, port 443, no user information. `huggingface.co` with exactly `/google/embeddinggemma-2/resolve/914f7f89142e33e77833254d9c9b90c3cef7303b/model.safetensors` or `…/tokenizer.json`; the redirect target must be on an exact host list (currently `us.aws.cdn.hf.co`; no wildcards, any path because CDN paths are opaque), one hop at most. Anything else is a **Blocked** row and nothing is sent. Hosts seen from other regions are added by exact name at release time |
| Redirects are not followed | The 302 comes back as a response and the downloader validates its `Location`. If it carries `X-Repo-Commit`, `X-Linked-Etag` or `X-Linked-Size`, they must equal the pinned revision, hash and size |
| Ranges, exactly | Each weights request must be answered `206` with `Content-Range: bytes a-b/1488915288` and exactly the requested length; a `200` is cancelled before its body is read. The tokenizer is capped at its pinned size |
| Integrity from hashes | Default TLS trust with no pinning (Hugging Face rotates certificates), so the guarantee is the checksums: per block (as it arrives), per tensor and for the assembled file. A block that differs is fetched once more; a second difference deletes the partial file. No self-hosted conversion exists |
| Ephemeral and anonymous | No cache, cookies or credential storage; no `Authorization` header and no token (the model is not gated); default User-Agent. System proxies are honoured (unlike the model-server session), because the destination is on the internet. The signed CDN address is kept in memory only and its query string never reaches the log, the export or a file |
| Import | Files you choose are identified by size and checked with the same hashes before they are used; symbolic links are followed, as in the Hugging Face cache |

Running the model adds no entitlement: Vauta compiles MLX's GPU kernels from embedded source on the first use, which runs in
Apple's Metal compiler service. If `Vauta mlx-selftest` ever fails in a signed build, the answer is to stop and report, never to
add JIT, unsigned-memory or library-validation entitlements. The procedure is in
[docs/SEARCH_MODEL.md](docs/SEARCH_MODEL.md#the-self-test).

**Third-party code.** MLX is the only third-party package: a fork of mlx-swift (MIT) pinned by revision, built from source.
`scripts/check-dependencies.sh` and a test fail on any other package or revision. Bumping it follows the checklist in
docs/SEARCH_MODEL.md (re-apply the patches, regenerate the kernel source, run the self-test on signed builds). Its licences
are in [NOTICE](NOTICE) and `THIRD_PARTY_LICENSES.txt`. The pin is transitive: the fork's own submodule `Source/Cmlx/mlx` points to a second
repository, `MaquinaTech/mlx` at commit `d1dfda2` (branch `vauta-clt`), which carries the C++ part of the runtime-compilation patch; both
repositories are ours and both commits are tagged (`vauta-0.9.0`, signed with the release key) and rulesets on both repositories block deleting or
moving those tags and deleting or force-pushing `vauta-clt`, so the pin cannot become unfetchable.

### Network audit

Settings → Privacy & Security → **Network Activity…** lists every connection Vauta makes, so the rules above can be
checked on a running app and not only read in the source.

| Property | Detail |
|---|---|
| One choke point | `Sources/VautaCore/Network/AuditedSession.swift` is the only file that creates a `URLSession`, starts a URL task or opens a socket. It wraps each request (`bytes(for:purpose:)`, `data(for:purpose:)`) and records it in `NetworkActivityLog` |
| A test keeps it that way | `NetworkAuditSourceScanTests` scans every Swift file under `Sources/` and fails if any other file uses `URLSession(…)`, `URLSession.shared`, URL tasks, `NWConnection` and the other Network framework types, legacy URL loading, web views, raw sockets, an XPC connection to a Mach service, child processes (which could run `curl`: `Process`, `popen`, `posix_spawn`, `fork`, the `exec` family), or an initializer that loads whatever URL it is given (`Data(contentsOf:)`, `String(contentsOf:)`, `NSImage(contentsOf:)`, `PDFDocument(url:)`, `AVURLAsset(url:)`, `NSAttributedString(contentsOf:)`/`(url:)`, `XMLParser(contentsOf:)`). The calls that only read a file on the Mac are listed one by one in the test, with the reason each URL is local and how many each file has. New code that needs the network must go through `AuditedSession` |
| Metadata only | Time, purpose, scheme, host, port, method, path (no query), approximate body bytes sent and received (headers and overhead are not counted), duration, status or error kind, and, for coalesced probes, a count and the time of the last one. Never content, prompts, headers, keys, query strings or user information in URLs. Tests send secrets through the choke point and check that none is stored or exported |
| Coalescing | Identical read-only discovery probes of this Mac (same destination, path and result, less than 60 s apart) merge into one row with a count, so the guided setup's polling cannot push other entries out of the 1,000-entry buffer. Requests of every other purpose are never merged |
| Blocked requests | A request refused by the destination rules before anything is sent (a URL that is not the configured server, a name that resolved outside the allowed network, a path the server type does not use) is listed as **Blocked** with a reason category, with no bytes sent. It is not counted as a connection in the destination summary |
| Purposes | Improved live translations are requested with the `translation` purpose, so they show as such (`ServerTranslator` → `ChatOptions.purpose`); a test follows one through the live translator into the log |
| In memory | An actor with a ring buffer of the last 1,000 entries for this run of the app. Nothing is persisted; the only file is the JSON the user chooses to export |
| Classification | Destinations are labelled *on this Mac*, *on your local network* or *outside your local network*, using the same address rules as `ServerAddress`. The last one should never appear: the destination checks refuse such requests before anything is sent, and the label exists so a violation could not hide |
| Search model download | Listed with the purpose "Search model download": one `huggingface.co` row per file lookup (302) and one row per range from the download host (206). A redirect to a host outside the list is a Blocked row. These destinations are labelled "A download you started" and the summary does not warn about them; the "outside your local network" warning stays for anything else, which should never appear |
| Limits | It records Vauta's own requests. Downloads that macOS makes (speech and translation languages, Apple Intelligence model files) are outside the app and are not listed. An independent network monitor such as Little Snitch or LuLu covers those. The log is evidence for the user, not a security boundary: code that bypassed `AuditedSession` would not be listed, which is why the source scan test exists |

## App Sandbox, hardened runtime and entitlements

Vauta runs in the App Sandbox with the hardened runtime and **no** runtime exception entitlements (no JIT, no
unsigned executable memory, no disabled library validation). The entitlements, from
[`Resources/Vauta.entitlements`](Resources/Vauta.entitlements):

| Entitlement | Why |
|---|---|
| `com.apple.security.app-sandbox` | Confines Vauta to its container; nothing else on disk is reachable without you |
| `com.apple.security.device.audio-input` | The microphone, transcribed on device as "Me". Meeting-app audio is captured with a Core Audio process tap, which needs no entitlement; macOS asks for your permission |
| `com.apple.security.personal-information.calendars` | Optional, off by default: reads the calendars you choose to name the meeting and its attendees. The same access lets Vauta, only when you press Add for one item, add that reminder or event and read the titles of the one list (or day) it adds to, so it does not add it twice, and remove only what it created. One source file does the writing and a test enforces it; Vauta never edits, completes or deletes anything it did not create |
| `com.apple.security.network.client` | Outgoing connections to your model server and, only when you click Download, to Hugging Face for the search model, as enforced above. There is no `network.server` |
| `com.apple.security.files.user-selected.read-write` | Only files you pick: a recording to import (read), your server's CA certificate (read), an export (write) |
| `com.apple.security.files.bookmarks.app-scope` | Remembers, read-only, the folders and files you added as document sources, so they work after a restart. Revocable: removing a source deletes its bookmark |

`Info.plist` allows local networking in App Transport Security (`NSAllowsLocalNetworking`) so that loopback servers
work over HTTP; it does not allow arbitrary loads.

## Code signing

macOS ties your permissions (microphone, audio capture, calendar) and the Keychain key to Vauta's **signature and
bundle ID**. Keep both stable.

- **Your builds** (the only kind there is: Vauta is source-only): run `scripts/setup-signing.sh` once. It creates a local signing identity in a dedicated
  keychain with its own password that locks after 10 minutes, so no process running as you can sign code as Vauta
  without that password. `scripts/build-app.sh` uses it automatically. (A fork with an Apple Developer account can
  set `VAUTA_SIGN_IDENTITY` to a Developer ID identity; Vauta itself publishes no such builds.)
- **Ad-hoc signing** (`VAUTA_ALLOW_ADHOC=1`) is for CI and quick tests. Each build has a different identity, so
  macOS asks for permissions again and the Keychain cannot tell Vauta from another app.
- **Do not change the bundle ID** after installing (`VAUTA_BUNDLE_ID` in `scripts/local.env`). Keychain items, the
  sandbox container and permissions belong to it; a new ID starts from scratch.

Check a build with:

```sh
codesign --verify --strict --verbose=2 Vauta.app
codesign -d --entitlements - Vauta.app
codesign -dvv Vauta.app 2>&1 | grep -E 'Authority|Timestamp|flags'
```

## Verifying what you run

Vauta publishes source, not binaries, so what you run is what you built. To check it:

1. Build from a tagged release, not from a moving branch: `git clone https://github.com/MaquinaTech/Vauta.git`, then
   `git checkout v<version>`.
2. Verify the tag. Release tags are signed with the maintainer's SSH key (ED25519, fingerprint
   `SHA256:exvRtcRtqxp/AHhadgXr7PAHe9itjHFPqVVCoGaOrU4`), which is published as a signing key on the
   MaquinaTech GitHub account ([its signing keys](https://api.github.com/users/MaquinaTech/ssh_signing_keys)), so GitHub shows the tag as "Verified". The public key is
   also committed in the repository as [`.github/allowed_signers`](.github/allowed_signers) (principal `maintainer@vauta`). To check
   the tag locally, first confirm that the file holds the key above, independently of the checkout (the fingerprint printed here must
   match the one in this document as read on GitHub, and the key must be listed at the signing-keys address above):

   ```sh
   ssh-keygen -lf <(cut -d' ' -f3- .github/allowed_signers)   # must print SHA256:exvRtcRtqxp/AHhadgXr7PAHe9itjHFPqVVCoGaOrU4
   ```

   Then verify the tag:

   ```sh
   git -c gpg.ssh.allowedSignersFile=.github/allowed_signers tag -v v<version>
   ```

   It must print `Good "git" signature … with ED25519 key SHA256:exvRtcRtqxp/AHhadgXr7PAHe9itjHFPqVVCoGaOrU4`. Compare `git rev-parse v<version>^{commit}` with the
   commit shown on the release page. Release notes are the matching section of `CHANGELOG.md`.
3. Read what you build. The code is small enough to audit: [docs/CLAIMS.md](docs/CLAIMS.md) links every claim to a
   test or command, and `scripts/check-dependencies.sh` verifies the pinned dependencies.
4. Check the result with the `codesign` commands above and the Network Activity list in the app.

## Audit status

Vauta has **not been independently audited**. Its security properties are backed by public tests and source code, listed
claim by claim in [docs/CLAIMS.md](docs/CLAIMS.md), and by your own checks (Network Activity, an outside network
monitor, `codesign`). That is evidence, not an assurance from a third party. If you rely on Vauta for confidential
work, read the code and the threat model above, and report what you find as described in
[Reporting a vulnerability](#reporting-a-vulnerability).

The cryptography actually used, with its parameters and its known weaknesses, is reviewed in
[docs/CRYPTO_REVIEW.md](docs/CRYPTO_REVIEW.md). That review is internal, written by the project, and is not an audit.

## Related

- [PRIVACY.md](PRIVACY.md): what is stored, where, and what is sent.
- [docs/MODEL_SERVERS.md](docs/MODEL_SERVERS.md): setting up a server on your network with TLS.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the pieces fit together.
