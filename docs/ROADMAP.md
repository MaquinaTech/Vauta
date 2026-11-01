# Roadmap

This is where Vauta is heading next. It is a direction, not a promise: plans change with what users need and what macOS makes possible. Every item has to keep Vauta's principles:

- **Local first.** Meeting audio and text stay on your Mac, or go only to a server you run on your local network.
- **No telemetry**, no account, no cloud service of our own.
- **Minimal dependencies.** One third-party package, a pinned fork of MLX (MIT), which brings in Apple's swift-numerics; otherwise Apple frameworks and the system SQLite.
- **Your existing data keeps working.** Every change to a stored format comes with a migration and a test.

Want to help with one of these, or propose something else? Open a [feature request](https://github.com/MaquinaTech/Vauta/issues/new/choose) first, so we can agree on the approach before you write code. See [CONTRIBUTING.md](../CONTRIBUTING.md).

## Next

### Verified compatibility for more apps

Vauta knows the processes of the major meeting apps and browsers, but only Safari has been confirmed in real calls. The first goal after 0.9.0 is to move the rest of [COMPATIBILITY.md](COMPATIBILITY.md) to "Verified" with reports from users, and fix the bundle IDs or helper processes that turn out to be different.

### Signed builds and Homebrew (possible future, not planned)

Vauta is source-only: users build it on their own Mac. Signed and notarized downloads, and a Homebrew cask built from them, would need an Apple Developer Program membership. They are not planned; the maintainer may revisit this later. `scripts/package.sh` and `scripts/notarize.sh` and the appendix of [RELEASING.md](RELEASING.md) are kept for that case.

### Voice recognition beyond English

Vauta tells the other participants apart on this Mac, shows and names them in the transcript and the minutes, and, if you
turn it on, suggests who is speaking from saved voices across meetings (opt-in, one person at a time, with their agreement; a
suggestion never becomes a name until the user accepts it). The threshold (0.70) was calibrated on English headset recordings only. What remains:

- Calibrating and testing other languages, laptop microphones, phone audio and different devices for the same person, and
  adjusting the threshold where the numbers say so; if the numbers ever support it, revisit whether a very close match may name a speaker (today it never does).
- Saving a voice from a live meeting's own microphone, so enrolling yourself does not need an imported recording.
- Exporting speaker turns as RTTM.

### After a meeting: the follow-up email and links to earlier meetings

**Follow Up…** already turns a meeting's tasks into reminders and agreed follow-up meetings into Calendar events ([ACTIONS.md](ACTIONS.md)). Two parts are built but off in this release because they did not pass their judged evaluation ([BENCHMARKS.md](BENCHMARKS.md#post-meeting-actions)):

- The follow-up email draft, for your own mail app (no draft met the gate of zero factual errors). Whether to switch it on, or the automatic follow-up detection, is a pending decision that needs a fresh held-out set.
- Linking a task or decision to the same one in an earlier meeting (it did not reach its precision and recall gates). After that: a decision History view, search grouping, links in exports, Ask with links, links across languages, a model-server check of link pairs (it needs a measured server arm and a Network Activity purpose), and the email's de-duplication of linked tasks.

A model-based follow-up extraction is a candidate, measured as an experiment arm only.

Before a release, the maintainer checks the signed build on macOS 26 and macOS 27 (permission prompts and the compatibility table in [COMPATIBILITY.md](COMPATIBILITY.md)).

### Vauta for local agents (MCP)

An optional [Model Context Protocol](https://modelcontextprotocol.io) server, so agents and tools running on your Mac can search your meetings, read minutes and list tasks, with your permission.

- Off by default, and read-only to start with.
- Local only: no network listener, and access only for the clients you allow.
- It would respect the same lock as the Meetings window.

## Later

- **More languages for the interface**: see [TRANSLATING.md](TRANSLATING.md) to add one.

## Considered, not planned

- **An iOS or iPadOS companion.** iOS does not let one app capture another app's call audio, so it could not record both sides of a call the way Vauta does on the Mac. A read-only companion for your minutes would need your meetings on a second device, which means syncing, and that conflicts with keeping them on one Mac. We will look at this again if Apple adds a way to do it that keeps meetings private.
- **A general-purpose model engine or helper app.** Besides the optional integrated model (one pinned model, see [LANGUAGE_MODEL.md](LANGUAGE_MODEL.md)), Vauta guides you to LM Studio or Ollama (**Set Up a Model Server**) for other models instead of embedding a general inference engine: it would be no faster on the same MLX core and would add dependencies, network destinations and ongoing maintenance.
- **A cloud service or hosted models.** Vauta works with servers you run yourself. It will not send meetings to a service we or anyone else hosts.
- **A bot that joins calls.** Vauta stays invisible to the call by design.
