# Governance

This document describes how decisions are made in the Vauta project and how people can take on more responsibility.
It will change as the project grows.

## Roles

| Role | Who | Responsibilities |
|---|---|---|
| **Users** | Anyone who uses Vauta | Report problems, suggest improvements, help others. |
| **Contributors** | Anyone who opens an issue, a discussion or a pull request | Improve Vauta following [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). |
| **Maintainers** | Listed below | Review and merge pull requests, triage issues, make releases, enforce the Code of Conduct and handle security reports. |

## Maintainers

| Name | GitHub | Areas |
|---|---|---|
| Nicolás López de Lerma López | [@MaquinaTech](https://github.com/MaquinaTech) | Project lead; all areas |

The project lead created Vauta and holds final responsibility for its direction and its releases. Vauta is distributed as
source code only (no signed or notarized binaries).

## How decisions are made

Most decisions happen in the open, in issues, [GitHub Discussions](https://github.com/MaquinaTech/Vauta/discussions) (Q&A and Ideas) and pull request reviews.

- **Everyday changes** (bug fixes, small improvements, translations, documentation) are merged once a maintainer has
  reviewed and approved them and CI passes.
- **Significant changes** (new features, changes to persisted data formats, new permissions or entitlements, changes
  to how Vauta talks to model servers, new supported platforms) start with an issue or discussion describing the
  problem and the proposed approach. Maintainers aim for consensus with the people involved.
- **When consensus isn't reached**, the project lead decides and explains the reasoning in the issue.

Some principles are not up for a vote, because they are the reason Vauta exists:

- meeting audio is never written to disk and meeting content stays on the user's devices, encrypted;
- no telemetry, no accounts and no cloud services; the only network traffic is the model server the user chose and
  Apple's model downloads;
- no third-party dependencies beyond the two the build already uses: a pinned fork of MLX (MIT) and its dependency swift-numerics, checked by `scripts/check-dependencies.sh`; adding another needs the agreement of the project lead;
- existing users' data keeps opening after every update.

Changing one of these requires a public discussion and the explicit agreement of the project lead, and would be
announced in the release notes.

## Repository controls

What the project requires of its GitHub repository and of the people who can change it. The rulesets below are in force on the
public repository (Settings → Rules); two-factor authentication is an account setting, so for it this section is the standard
maintainers are held to.

- **Two-factor authentication** is required for every maintainer and for anyone with write access. Prefer a passkey or a
  hardware security key to SMS.
- **A ruleset on `main`**: pull requests only (no direct pushes; a repository administrator can bypass the rules only when
  merging a pull request), the CI build and tests (`Build and test`, which also runs the string and header checks) and CodeQL
  (`Analyze (Swift)`) must pass, conversations must be resolved, commits must be signed, and force pushes and branch deletion
  are blocked. At least one approving review from someone other than the author will be required once there is a second
  maintainer. Until then the project lead reviews their own pull requests and CI is the independent check; this is stated
  openly, not hidden.
- **Signed commits** are required on `main` by that ruleset: every commit must show as Verified, signed with a key of its
  author's GitHub account (merges made on GitHub are signed by GitHub). Contributions also carry a DCO sign-off
  ([CONTRIBUTING.md](CONTRIBUTING.md#developer-certificate-of-origin)), which the project lead checks before merging.
- **Signed tags**: every release tag is signed with the maintainer's SSH key, ED25519 `SHA256:exvRtcRtqxp/AHhadgXr7PAHe9itjHFPqVVCoGaOrU4`, published as a
  signing key on the MaquinaTech GitHub account and committed as [`.github/allowed_signers`](.github/allowed_signers) ([verify a tag](SECURITY.md#verifying-what-you-run)). Verifiers should confirm the key file against the fingerprint above or the GitHub account's signing keys, not trust the checkout alone. A second ruleset lets only a repository administrator create, move or delete `v*` tags.
- **Releases** are source-only: a tag on `main` and a draft GitHub release created by the release workflow, which the
  project lead publishes by hand ([docs/RELEASING.md](docs/RELEASING.md)). No binaries are published.
- **Actions** are pinned by full commit SHA and updated through Dependabot pull requests that are reviewed like any other.
- **Secrets**: the project holds no signing certificate, notarization key or other release secret; the release workflow
  uses only the repository's own `GITHUB_TOKEN`.

### Continuity

Vauta currently has one maintainer. If that person cannot continue, the source remains Apache-2.0 and anyone can fork
and build it. The project publishes no signed binaries, but one key matters: `update.sh` installs only releases whose
tag is signed with the maintainer's SSH key (above), so that key is a single point of failure for updates. If it is lost,
or if someone else continues the project, users have to check the new key by hand once before `update.sh` accepts it
([SECURITY.md](SECURITY.md#if-the-release-key-changes)). A second maintainer with admin rights on the repository is the
way to remove these single points of failure, and inviting one is a project goal.

## Security reports

Vulnerabilities are reported privately through
[GitHub private vulnerability reporting](https://github.com/MaquinaTech/Vauta/security/advisories/new). Maintainers
handle them privately until a fix is released, as described in [SECURITY.md](SECURITY.md).

## Becoming a maintainer

Maintainers are invited, not elected. The project lead invites contributors who have shown, over several months:

- a sustained record of good contributions: code, reviews, triage, documentation or translations;
- sound judgment about privacy, security and backward compatibility;
- helpful, respectful communication, in line with the Code of Conduct.

New maintainers usually start with responsibility for one area (for example capture, model servers or a
localization) and get write access to the repository. If you'd like to take on more, say so in a discussion or
contact the project lead.

Maintainers who are no longer active, or who no longer wish to serve, can step down at any time and are listed as
emeritus maintainers. A maintainer who seriously or repeatedly violates the Code of Conduct can have their role
removed by the project lead.

## Changes to this document

Changes to this document are made through pull requests and approved by the project lead.
