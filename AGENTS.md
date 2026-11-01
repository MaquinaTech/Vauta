# AGENTS.md

Guidance for coding agents that work on Vauta's code or install Vauta on a user's Mac. Human contributors should read
[CONTRIBUTING.md](CONTRIBUTING.md); everything here is consistent with it.

Vauta is a macOS menu-bar app that transcribes meetings on the Mac and writes minutes with a model the user chooses.
It handles **confidential conversations**. The rules below protect the user's data and their trust in the app.

## Non-negotiable rules

1. **Never read, print, copy or summarize meeting content.** That includes transcripts, minutes, answers, the people
   and projects in Context, and the store itself in `~/Library/Containers/<bundle-id>/`. Never open, decrypt, copy or
   back up that container. Never run `transcribe-file --show-text` on a real recording, and never run `minutes-file` on anything but a public transcript (it is an evaluation command).
2. **Never handle secrets.** Don't ask the user to paste a model server key, a keychain password or a signing password
   into the conversation. The user types keys into Vauta (Settings › Models › Key) or into their own Terminal
   (`server-check --ask-key` reads the key without echo). Never put a key in a file, an argument, an environment
   variable or a log.
3. **No network beyond the allowed downloads.** Don't send anything to external services. The only downloads allowed
   are:
   - Apple's speech models and translation languages (through Vauta and macOS);
   - the model server software and the models the user chose;
   - the optional search model (EmbeddingGemma 2, 574 MB) from huggingface.co, only through Vauta's own Download
     button and only when the user asks. Agents never fetch it themselves, never run `hf cache prune`, and never put model
     files in the repository;
   - the optional integrated language model (Google's `google/gemma-4-E4B-it` at its pinned revision, a 15 GB transfer that
     Vauta quantises to about 4.2 GB on the Mac) from huggingface.co, under the same rules. The developer tools in
     `tools/language-model` read it once to derive the manifest, and only when the user has asked for that run.
4. **Never run the Vauta binary without a command.** With no arguments it starts a second menu-bar app with the user's
   permissions. Always pass a command (`doctor`, `status`, `languages`, `install-speech-assets`, `server-check`,
   `cert-pin`, `store-stats`, `version`…). Never build or run the diagnostics build (`-DVAUTA_DIAGNOSTICS`): it can
   capture audio. Never run anything that records audio.
5. **Don't weaken security or add dependencies.** Don't relax the App Sandbox, entitlements, hardened runtime, App
   Transport Security, TLS or certificate checks, or the model server address rules. Exactly one third-party package is
   allowed: the pinned MaquinaTech mlx-swift fork (it brings in Apple's swift-numerics). Never add another package, and never change the pin without the bump
   procedure in docs/SEARCH_MODEL.md. Never add entitlements (JIT, unsigned memory, library validation) to make MLX work:
   if `Vauta mlx-selftest` fails in the signed app, stop and report. If something doesn't work, explain the problem and
   propose options.
6. **The user decides**:
   - where the models run: Apple's on-device model, a server on this Mac, or a server on another computer;
   - the server software and the models;
   - the bundle ID;
   - the signing method.

   Ask with concrete options and a reasoned recommendation that fits the Mac's memory (`sysctl -n hw.memsize`).
7. **Commands that ask for passwords run in the user's own Terminal**, not in yours: `scripts/setup-signing.sh`,
   `scripts/install.sh` and `scripts/update.sh` with a local signing identity, and `server-check --ask-key`.

## Working on the code

| Task | Command |
|---|---|
| Build | `swift build` (add `-j 3` on machines with little memory) |
| Release build | `swift build -c release --arch arm64` |
| Test (Command Line Tools only) | `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` |
| Test (Xcode selected) | `swift test` |
| Translations check | `scripts/check-strings.sh` |
| License headers check | `scripts/check-headers.sh` |
| App bundle without a signing identity | `VAUTA_BUNDLE_ID=local.vauta.dev VAUTA_ALLOW_ADHOC=1 scripts/build-app.sh` (builds `build/Vauta.app` with its own bundle ID, so it never touches the installed app's data; don't open it unless the user asks) |
| Dependencies check | `scripts/check-dependencies.sh` (only the pinned mlx-swift fork and swift-numerics) |
| GPU kernels and the search model in the shipped binary | `build/Vauta.app/Contents/MacOS/Vauta mlx-selftest [--model]` (hidden command; exit 0 pass, 1 fail, 2 unsupported, 3 model missing) |

The first build compiles MLX's C++ and takes several minutes; `-j 3` still applies.

Conventions, in short (details in [CONTRIBUTING.md](CONTRIBUTING.md)):

- Swift 6 with strict concurrency; no new warnings.
- English for identifiers, comments, logs and source UI strings. User-facing text uses
  `String(localized: "…", comment: "…")` or SwiftUI string literals.
- Exactly one third-party package: the pinned MaquinaTech mlx-swift fork (MIT), which depends on Apple's swift-numerics. `import MLX` is allowed only in
  `Sources/VautaMLX`; a test enforces it. Everything else is Apple frameworks and the system SQLite.
- Every source file starts with the SPDX header (`Apache-2.0`, `2026 Nicolás López de Lerma López`).
- Files stay under about 600 lines. Logic goes in `VautaCore` with Swift Testing tests in `Tests/VautaCoreTests/`.
- Persisted formats are compatible forever: schema changes are new entries in `Schema.migrations`
  (never edit a published one), Keychain accounts, `UserDefaults` keys, stored enum raw values and stored JSON keys
  never change meaning.
- Tests never use the network, the user's store or audio devices. Never create, change or remove reminders or events on a real store: tests and the evaluation use `FakeActionWriter`, and only `Sources/Vauta/App/Actions/EventKitActionWriter.swift` may save or remove anything in Reminders or Calendar (a source-scan test enforces it).
- Network access goes through `AuditedSession` (`Sources/VautaCore/Network/`) only, with a `NetworkPurpose`, so it shows up
  in Network Activity. Never create a `URLSession`, a URL task, an `NWConnection` or a child process (such as `curl`)
  elsewhere: `NetworkAuditSourceScanTests` fails if you do. Never put content, headers, keys or query strings in the log.
- Don't commit, push or change Git configuration unless the user asks. Commits are signed off (`git commit -s`).

## Installing Vauta for a user

Vauta is distributed as source only: there are no signed or notarized downloads, no disk image and no Homebrew
package. It is built from source on the user's Mac with the steps below (the README's "Install from source" is the same). Talk to the user in their language.

### 1. Check the requirements

| Check | Command | Needed |
|---|---|---|
| macOS | `sw_vers` | 26 or later to run Vauta |
| Architecture | `uname -m` | `arm64` (Apple silicon) |
| Toolchain | `swift --version` | Swift 6.4 with the macOS 27 SDK (Command Line Tools for Xcode 27 or later) |
| Memory | `sysctl -n hw.memsize` | Decides which models fit (step 7) |
| Disk | `df -h ~` | A few GB for Apple's speech model and the build; more for local models |

If the Command Line Tools are missing, the user runs `xcode-select --install`. Xcode is not required. If a
requirement is not met, stop and explain it. `scripts/install.sh` and `scripts/update.sh` check the same before building
(`scripts/preflight.sh`, which also sets `VAUTA_JOBS` from the memory: 3 up to 24 GB, 2 with 8 GB) and stop with what to do;
`VAUTA_SKIP_PREFLIGHT=1` skips the checks.

### 2. Choose the bundle ID

Ask the user and suggest `com.<name>.vauta` or `local.<user>.vauta`. Save it in `scripts/local.env` (never committed):

```sh
VAUTA_BUNDLE_ID=com.example.vauta
```

The bundle ID is Vauta's identity for macOS: permissions, Keychain items, the sandbox container and the speech model
reservation. **It must not change after installing**; a new one starts from scratch. Without `local.env`, the default
is `local.vauta.app`. A build with any other bundle ID is a different app with its own data.
To move an existing install's data to another bundle ID, use **Settings → Privacy & Security → Back Up…** in the old
app and **Restore…** in the new one.

### 3. Build and test

```sh
swift build
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

All tests must pass; a failure stops the installation. The tests use temporary directories and in-memory keys, never
the network or the user's store. A few Keychain tests create items under a unique test service and delete them.

### 4. Signing

Ask which method the user prefers:

- **Recommended: a stable local identity.** macOS keeps permissions and Keychain access across updates. The script
  asks for passwords, so **the user runs it in their own Terminal**:

  ```sh
  cd <path to this folder> && ./scripts/setup-signing.sh
  ```

  It creates a dedicated signing keychain with its own password, and macOS asks for the Mac's password to trust the
  certificate for code signing only.

- **Ad-hoc**, for a quick trial. You may run it yourself, but macOS asks for permissions again after every update:

  ```sh
  VAUTA_ALLOW_ADHOC=1 ./scripts/install.sh
  ```

### 5. Install

With the local identity, the user runs this in their own Terminal too, because it asks for the signing keychain's
password:

```sh
./scripts/install.sh
```

It builds a release app, installs it as `~/Applications/Vauta.app` (no `sudo`) and opens it. This launch is the
intended one: it is the installed app, not the bare binary. If the same build is already installed, it does nothing.
When Vauta opens, macOS asks once for Keychain access for "Vauta": the user chooses **Always Allow**.

On first launch, Vauta's first-run setup guides the user through the transcription language, permissions, the speech
model download and the choice of model provider. Steps 6–9 cover the same ground from the command line, for when the
setup was skipped or something needs checking.

### 6. Speech model

Run these with the **installed** binary: the speech model is reserved for Vauta's bundle ID.

```sh
~/Applications/Vauta.app/Contents/MacOS/Vauta languages
~/Applications/Vauta.app/Contents/MacOS/Vauta install-speech-assets --locale es-ES
~/Applications/Vauta.app/Contents/MacOS/Vauta status --locale es-ES
```

`--locale` takes a BCP-47 language (`en-US`, `de-DE`, `ja-JP`…). Without it, Vauta uses the language chosen in its
settings, else the first supported language among the user's preferred languages. The model downloads once per
language. For custom vocabulary, `install-dictation-assets` downloads the dictation model for a language.

### 7. Choose the model provider

Vauta writes minutes, live notes and answers with one of four providers. The user picks it in Settings › Models
("Write minutes with"):

| Provider | Setup | Notes |
|---|---|---|
| Apple Intelligence on this Mac (Quick start · Basic quality) | None | Requires Apple Intelligence to be turned on. Small context window (about 4K tokens on macOS 26). |
| Integrated model (Gemma 4 E4B, Google) | Settings › Models › Download (a 15 GB transfer from Hugging Face that Vauta converts to 4.2 GB; the user clicks it, agents never start it) | Only on Macs with 16 GB of memory or more (`sysctl -n hw.memsize`); optional and never the default. Apple Intelligence and the model servers keep working. |
| A model server on this Mac | Install LM Studio, Ollama or another OpenAI-compatible server; Settings › Models › Set Up… guides the user through LM Studio or Ollama and the model that fits the Mac's memory | Loopback only (`127.0.0.1`, `::1`, `localhost`). Vauta detects servers on their usual ports. |
| A model server on your network | A server on another computer, over HTTPS | Private addresses only; see below. |

Searching by meaning ("Search by meaning" in the same pane) can use the server's embedding model, the optional downloaded
search model or none (keyword search only). Without a saved choice or a server configuration it defaults to none; saved
choices and installs with a server configuration are not changed.

A server needs `GET /v1/models` and `POST /v1/chat/completions` with streaming, plus `POST /v1/embeddings` when
embeddings come from the server. LM Studio and Ollama provide all three. The embedding model name is required only when search by meaning runs
on the server; otherwise a server configuration does not need one.

Models have three roles:

| Role | Used for | Recommendation |
|---|---|---|
| Fast | Live notes while recording | A 4–9B instruct model without reasoning |
| Main | Final minutes and Ask with citations | The best model that fits comfortably in memory |
| Embedding | Finding the passages Ask needs | A multilingual embedding model with at least 256 dimensions, for example Qwen3-Embedding-0.6B, bge-m3 or multilingual-e5 |

The fast and main models can be the same model. Rough guidance for 4-bit quantized models by unified memory:

| Memory | Fast | Main | Context |
|---|---|---|---|
| 16 GB | ~8B | Same as fast | 16–32K |
| 24–32 GB | ~8B | 14–32B | 32K |
| 48 GB or more | ~8B | 27–32B or larger | 32–64K |

Check which models the server's catalog offers at install time. Set Vauta's context size to the **real** context the
server loads the models with.

#### A) A server on this Mac

The server must listen **only on 127.0.0.1**. Vauta refuses any other address in this mode.

**LM Studio**

1. Download the models (`lms get …`, or in the app).
2. Start the server on port 1234: `lms server start`. Leave **Serve on Local Network** off.
3. Load the models with the chosen context: `lms load <model> --context-length 32768`.
4. Base URL: `http://127.0.0.1:1234/v1`. Exact model names come from `lms ls` or `/v1/models`.

**Ollama**

1. Download the models: `ollama pull <model>`. Ollama listens on `127.0.0.1:11434` by default.
2. **Don't set `OLLAMA_HOST` to `0.0.0.0`.**
3. Raise the default context: `launchctl setenv OLLAMA_CONTEXT_LENGTH 32768`, then restart Ollama.
4. Base URL: `http://127.0.0.1:11434/v1`. Model names include the tag, for example `qwen3:8b`.

A server on this Mac needs no key. In Settings › Models, **Find Servers on This Mac** finds running servers and **Use**
fills in the address, the suggested models and the server type.

#### B) A server on another computer

Vauta requires **HTTPS** and a local network address:

- `10.x`, `172.16–31.x`, `192.168.x`;
- `100.64–127.x` (Tailscale), link-local `169.254.x`, or IPv6 unique local (`fc00::/7`) and link-local (`fe80::/10`)
  addresses;
- host names ending in `.local`, `.lan`, `.home.arpa`, `.internal` or `.ts.net`.

A host given by name also needs a private CA or a certificate pin, because the name could resolve anywhere.

1. **Fixed address.** Give the server a fixed IP, for example with a DHCP reservation on the router.
2. **Certificate.** If the server has no valid certificate, run this on the Mac, from this folder:

   ```sh
   ./scripts/make-server-cert.sh <IP> [name.local]
   ```

   It writes to `./vauta-server-tls/` (or `$VAUTA_TLS_DIR`):
   - `ca.key`, the private CA key: keep it off the server and out of cloud backups;
   - `ca.crt`, which the user imports into Vauta as the private certificate authority;
   - `server.crt` and `server.key`, valid for 800 days, which the user copies to the server;

   and prints the server's pin. Running it again with the same arguments renews the certificate and keeps the pin.
   If the server already has a publicly trusted certificate (for example from `tailscale cert`), no CA is needed;
   a pin is optional but recommended.
3. **TLS.** If the model server can't serve HTTPS itself, put a TLS proxy in front of it that listens on the network
   address and forwards to `127.0.0.1`. For example, with Caddy (which forwards streamed responses without
   buffering):

   ```text
   https://192.168.1.50:8443 {
       tls /path/server.crt /path/server.key
       @nokey not header Authorization "Bearer {$VAUTA_KEY}"
       respond @nokey 401
       reverse_proxy 127.0.0.1:11434
   }
   ```

4. **Key.** The user generates a key for Vauta only, **on the server** (`openssl rand -hex 32`), and later types it
   into Settings › Models › Key. You never see it.
5. **Firewall.** The port should accept only the Mac running Vauta.

### 8. Check the server without touching the app

Create `vauta-server.json` (it is git-ignored). It may contain the address, CA and pins, but **never the key**:

```json
{
  "mode": "local",
  "baseURL": "http://127.0.0.1:11434/v1",
  "fastModel": "<exact name>",
  "deepModel": "<exact name>",
  "embeddingModel": "<exact name>",
  "contextTokens": 32768,
  "profile": { "kind": "ollama" }
}
```

- For another computer, `mode` is `"remote"` and the URL starts with `https://`. Add `"caPEM"` (the contents of
  `ca.crt`, with line breaks written as `\n`) and/or `"pins": ["<pin>"]`.
- `profile.kind` is one of `lmStudio`, `ollama`, `llamaCpp`, `mlx`, `vllm`, `jan`, `localAI` or `openAICompatible`;
  the other profile fields take that kind's defaults. A configuration without `profile` uses the legacy request
  dialect (`ServerProfile.legacy`); a host given by name still needs `caPEM` or `pins` (only a configuration saved by
  0.1.x keeps working without them, with a warning).
- `contextTokens` must be between 8192 and 262144.

Test it with the binary built in step 3, not the installed one (the installed app is sandboxed and can't read files
in this folder):

```sh
.build/debug/Vauta server-check vauta-server.json
```

It lists the server's models, sends a short test prompt to each chat model and one embedding request, and must end
with `OK`. Nothing from meetings is sent. If the server needs a key, the user runs the command in their own Terminal
with `--ask-key` and types the key without echo. For a remote server, macOS may ask to allow Terminal on the local
network.

To compute a pin from a certificate, without network access:

```sh
.build/debug/Vauta cert-pin vauta-server-tls/server.crt
```

### 9. Load the configuration into Vauta

```sh
pbcopy < vauta-server.json
```

The user opens Vauta › Settings › **Models**, chooses one of the server providers so the server settings appear, opens
**Advanced** and clicks **Paste Configuration** (it switches to the matching provider and saves nothing yet), reviews
the settings and clicks **Apply**. If the server needs a key, the user types it in the **Key** field. **Test Connection** checks the
server.

The configuration is stored in the Keychain, bound to Vauta's signature. Afterwards, delete `vauta-server.json` if it
contains the CA or pins and the user doesn't want to keep it. In remote mode, macOS asks to allow Vauta on the local
network: the user must allow it.

### 10. Final check

Run the read-only doctor with the **installed** binary, so it checks the app's own settings:

```sh
~/Applications/Vauta.app/Contents/MacOS/Vauta doctor
```

It reports macOS, the speech model for the recording language, whether a store exists (without opening it), whether
the model server is reachable and lists the configured models, and the microphone and calendar permissions. It exits
with status 1 when it finds a problem.

Then the user checks Settings › **Status** (every item should be green or explained) and makes a 1–2 minute test
recording with **⌃⌥R** (press again to stop). If the first-run setup was skipped, microphone and system audio
permissions are requested at the first recording. Afterwards, the meeting should have minutes in Meetings, and Ask should answer with citations. Settings ›
Status › **Copy Diagnostics** copies versions and the checklist, with no meeting content, for a support request; **Report a Problem…**
copies them too and opens a GitHub bug report with only the Vauta and macOS versions filled in.

## Updating Vauta for a user

```sh
./scripts/update.sh                       # local signing identity: the user runs it in their own Terminal
VAUTA_ALLOW_ADHOC=1 ./scripts/update.sh   # ad-hoc: you may run it
```

It installs the newest release tag only if it is signed by the maintainer's key (checked against the
`.github/allowed_signers` already in the checkout and the fingerprint in SECURITY.md), never an older version than the
installed one, and only after the tests pass. It stops on local changes. If it says the key does not match, stop and
tell the user: never edit `.github/allowed_signers` or the script to make it pass. A checkout of 0.9.3 or earlier needs
`git checkout main && git pull` once first: versions before 0.9.3 have no script, and the one in 0.9.3 can stop with
"unbound variable" when a newer release is there. That pull is not covered by the signature check (SECURITY.md,
"Supported versions").

## Troubleshooting

| Symptom | What to check |
|---|---|
| Can't reach the model server | The server is running and the URL matches the one that passed `server-check`. For a remote server: System Settings › Privacy & Security › Local Network › Vauta. |
| The server doesn't list the models | Names must match `/v1/models` exactly, including the tag (`:8b`). |
| Certificate rejected | The IP or name in the URL isn't in the certificate's SAN; the CA isn't the one that signed the certificate; the pin doesn't match (`Vauta cert-pin server.crt`); or the certificate is valid for more than 825 days, or it has expired (Status warns 30 days before; `doctor` prints the date; run `make-server-cert.sh` again with the same arguments to renew it and keep the pin). |
| A name-based host is refused | Add the private CA or a pin, or use the IP address. |
| Slow minutes | Normal with large models on modest machines. Use a smaller main model, or raise the context only if memory allows. |
| The model answers with text instead of JSON | Use a more capable instruct model, or set the server type in Settings › Models › Advanced so Vauta can request structured output. Vauta strips leading `<think>…</think>` reasoning blocks. |
| Speech model missing | `Vauta languages`, then `Vauta install-speech-assets --locale <id>` with the installed binary. |

## Moving an existing install to another bundle ID

Builds from source default to the bundle ID `local.vauta.app`. A different bundle ID is a different app, with its own container, Keychain items and permissions, and it cannot read the old data. Builds of an earlier version used the bundle ID `local.acta.app`: to keep that container, build Vauta with `VAUTA_BUNDLE_ID=local.acta.app` (it opens the same container and moves the earlier version's files to their current names on first launch), then follow the steps below to Back Up and Restore into the build you want to keep. Never copy or decrypt the old container by hand. To move meetings:

1. Update the **old** install first, **keeping its bundle ID**: build the current source with `VAUTA_BUNDLE_ID` set to the old value (in `scripts/local.env`) and run `./scripts/install.sh`. Only builds with the backup feature (0.9.0 and later) have **Settings › Privacy & Security › Back Up…**.
2. Ask the user to open Back Up…, choose a password of at least 12 characters, and save the file somewhere they control. The user types the password; never ask for it, store it or put it in a command.
3. Build and install with the new `VAUTA_BUNDLE_ID` (or the default) and open it once so the setup finishes.
4. Ask the user to open **Settings › Privacy & Security › Restore…**, choose the file and confirm the replacement.
5. The model server settings and its key are not in the backup (the preferences are, and are restored with it): repeat sections 7 to 9 for the model server of the new install.
6. Only after the user confirms the meetings are in the new install, offer to uninstall the old one (see Uninstalling). Leave the backup file to the user.

## Uninstalling

1. Quit Vauta.
2. Delete `~/Applications/Vauta.app` and `~/Library/Containers/<bundle-id>/` (this deletes all meetings). The optional
   search model and the integrated language model (the `gemma-4-e4b-it` folder) live inside that container, in
   `Data/Library/Application Support/Vauta Models`; they hold no meeting content, so the user can also remove it first with Settings → Models → Delete. You still must not open the container:
   tell the user the path.
3. In Keychain Access, delete the items whose service is `<bundle-id>`.
4. Optional: delete the signing keychain `~/Library/Keychains/vauta-signing.keychain-db` and
   `scripts/signing-identity.txt`.
