# Getting help with Vauta

Vauta is a free, open-source project maintained by one person. There is no paid support, but questions get an answer when time allows.

## Where to ask

| You want to… | Go to |
|---|---|
| Ask how to do something, or get help with your setup | [GitHub Discussions, Q&A](https://github.com/MaquinaTech/Vauta/discussions/categories/q-a) |
| Share an idea or discuss a direction before it is a request | [GitHub Discussions, Ideas](https://github.com/MaquinaTech/Vauta/discussions/categories/ideas) |
| Report something that doesn't work | [A bug report](https://github.com/MaquinaTech/Vauta/issues/new/choose), or **Settings → Status → Report a Problem…**, which copies the diagnostics and opens one with your versions filled in |
| Say whether a meeting app or browser worked with Vauta | [A compatibility report](https://github.com/MaquinaTech/Vauta/issues/new?template=compatibility.yml) |
| Suggest an improvement | [A feature request](https://github.com/MaquinaTech/Vauta/issues/new/choose) |
| Report a wrong or missing translation | [A translation issue](https://github.com/MaquinaTech/Vauta/issues/new/choose) |
| Report a security vulnerability | [Private vulnerability reporting](https://github.com/MaquinaTech/Vauta/security/advisories/new), **never** a public issue |
| Report a Code of Conduct violation | A private report titled "Code of Conduct" through [private vulnerability reporting](https://github.com/MaquinaTech/Vauta/security/advisories/new); see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) |

Before asking, please search existing issues and discussions, and read the documentation in [`docs/`](docs/).

## What to include

Good details get faster answers:

- **Vauta version**: Settings › About.
- **macOS version and Mac model**: Apple menu › About This Mac.
- **The meeting app or browser** that held the call, with its version, if the problem is about capture.
- **Transcription language** and **model provider** (Apple Intelligence, LM Studio, Ollama…), with the model name if
  you use a model server.
- **What you did, what you expected and what happened.**
- **Diagnostics**: Settings › Status › **Copy Diagnostics** copies versions and the setup checklist, without meeting
  content. From Terminal, this read-only check gives a similar report:

  ```sh
  /Applications/Vauta.app/Contents/MacOS/Vauta doctor
  ```

  (For a build from source, use `~/Applications/Vauta.app/Contents/MacOS/Vauta`.) For capture problems, also run
  `Vauta status` the same way while the call is playing audio. It lists the processes playing or recording audio,
  without any audio or text.

## Keep your meetings private

**Never post meeting content**: no transcripts, minutes, answers, names of participants, screenshots of meetings or
audio. Describe what happened instead. If you need to show a problem with text, make up a short example.

Don't post keys, certificates, private CA files or server addresses that you'd rather keep private. Nobody from the
project will ever ask you for them.

## Recording other people

Vauta is meant for conversations where everyone knows they are being transcribed. Many places require the consent of
every participant before a conversation is recorded or transcribed, and the rules differ by country, state and
workplace. You are responsible for following the law and your organization's policies.

We don't provide help with recording or transcribing people without their consent, or with hiding that Vauta is
running. Requests like that will be closed.

## Response times

Issues and discussions are read regularly, but there is no guaranteed response time. Security reports are handled
first. If you can, help others in Discussions too: that keeps the project healthy.
