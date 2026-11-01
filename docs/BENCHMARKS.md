# Benchmarks

What was measured, how, on what, and what the numbers do **not** say. Everything here is reproducible with the
committed [evaluation harness](../eval/README.md), except the [long recordings](#long-recordings), which were an ad-hoc check, and the minutes row of the harness phase (2026-10-24), whose test set is sealed and not in this repository; the datasets are downloaded at pinned, hash-verified revisions and
are never committed. This is the only place the README takes accuracy figures from.

| | |
|---|---|
| Measured on | 2026-10-11 |
| Machine | Apple M2, 24 GB, macOS 27.0.1 (26A434) |
| App | release build (`swift build -c release --arch arm64`) of branch `gold-w7`: main at `9cdb74c` plus the speaker-separation change described under [What the 2026-10-11 change did](#what-the-2026-10-11-change-did); `Vauta diarize` and `Vauta transcribe-file` |
| Tools | ffmpeg 9.0.2 (libopus), Python 3.12.15, numpy 2.5.3 |
| Language | English (human-annotated meetings). Spanish only as read and parliament speech (WER) and as **synthetic** conversations (speaker separation); no real Spanish meeting |
| Audio | public corpora made to resemble one side of a call, some with simulated call impairments; **not real calls** |

## Summary

| Measure | Result | Reference point |
|---|---|---|
| Speaker separation, diarization error rate (DER), 18 recordings of the tuning set, 0.25 s collar | **9.4 %** (15.1 % with no collar); 11.0 % before the 2026-10-11 change | 41.1 % if all remote speech were one speaker |
| Same, **19 held-out English recordings** (8 AMI dev meetings, 11 VoxConverse files; settings not chosen on them, though their figures were seen during the sweeps) | **9.5 %** (15.8 % with no collar); 10.8 % before the change | 54.9 % / 52.9 % (AMI / VoxConverse) if all speech were one speaker |
| Same, 12 **synthetic** Spanish conversations of 2 to 6 speakers | **7.2 %** (12.3 % with no collar); 9.4 % before | 58.5 %. Synthetic, easier than real meetings: [Spanish](#spanish) |
| Same, 24 call-impaired files (noise, packet loss, narrowband, AGC) | **16.3 %** (22.6 % with no collar); 16.8 % before | 54.6 % |
| Speaker count (speakers with at least 10 s of speech), tuning set / held-out English | exact in 9 of 18, within one in 18 / exact in 9 of 19, within one in 18; on held-out English the count is now slightly too high (+0.58 on average); on the AMI files of both sets the extra speaker is the participant left out of the mix, heard as cross-talk ([Results](#results)) | |
| Speed of speaker separation | about 158 times faster than real time (25,288 s of audio in 160 s) | |
| Word error rate (WER), AMI, close-talk headset, reference turns only | **10.8 %** (6,537 words, 10 meetings x 10 min); **11.7 %** on 8 other meetings (4,777 words) | |
| WER, AMI, simulated remote mix of 3 speakers (Opus-coded), reference turns only | **20.3 %** (8,664 words) / **16.4 %** on 8 other meetings (7,083 words); 1,096 of the 1,757 errors in the first set are deletions | |
| WER, Spanish, 35.6 min of parliament speech and audiobooks, Apple's `es-ES` model | **7.6 %** (7.4 % ignoring accents): 9.2 % parliament, 5.4 % audiobooks | Read and parliament speech, not conversation |
| Minutes, Apple's on-device model with the parts the app sends to it, 10 AMI meetings x 3 min of manual transcript: decisions and tasks kept by the app's checks (2026-11-01) | 12 of the 22 the model proposed (7 dropped by the citation check); every kept item has a citation that exists and holds its figures; none marked Unconfirmed | Only one model and a small sample: [Minutes](#minutes-citations) |
| Same, 10 min windows | 29 of the 59 proposed in 9 meetings (26 dropped), every kept item with a valid citation, 1 marked Unconfirmed; the tenth meeting failed once and wrote its minutes when run again | |
| Minutes, Apple's model and the integrated model, 20 sealed public meetings, harness phase, measured 2026-10-24 (blind, one LLM judge with no human review, **every switch on**): firm decisions and tasks covered, firm list length | Apple 100 of 167 in a list of 185 items (before: 99 in 518); integrated 51 (before: 42), the request the app runs on the integrated model since 2026-10-24 (items first, outcome rule, recall wording, expected counts with the item floor, greedy decoding); on the development meetings it listed 5.3 items per meeting at recall 0.32 and precision 0.61 (old: 0.22 to 0.25 and 0.66) with a median +14 s and p90 +53 s per meeting on the pairs. Apple's figures are for the ranked extraction with the outcome-first digest switched on, which the app does not ship | Not reproducible from the repository: the test set is sealed. Apple ships a subset that was not judged as such. Date, build, tables, limits and commands: [LANGUAGE_MODEL.md](LANGUAGE_MODEL.md#harness-phase-what-ships-blind-test-2026-10-24) |
| Minutes against **AMI's human summaries**, 13 whole meetings (manual transcripts): human decisions found / decisions citing near one (a random passage: 9 %) | Apple 25 % / 22 %; integrated model 20 % / 28 %. By content (one blind LLM judge): 20 % and 21 % of the 70 human decisions found; 31 % and 49 % of the decisions state one. No task has the owner the annotators named | One run per model; content matched by one blind LLM judge, no human review; not held out: [Minutes against AMI's human summaries](#minutes-against-amis-human-summaries) |

The DER figure for AMI uses the "no-bleed" scoring region explained below. With the plain scoring region it is 38.1 %
for AMI (26.3 % for all 18 recordings), almost all of it false alarm caused by an artifact of how the test audio is
built, not by the diarizer. Read that section before quoting any number.

## Diarization error rate

### Method

*DER* is the share of reference speech time that is wrong: missed speech + false alarm + speaker confusion. Overlapped
speech is scored. A **0.25 s collar** ignores 0.25 s on each side of every reference turn boundary (the NIST and
VoxConverse convention); the figures with no collar are given too, and are stricter.

**Sets of the tuning set (the 18 recordings the settings were chosen on).**

- **AMI "others"** (10 meetings of the official AMI test split: ES2004a, ES2004c, IS1009a, IS1009c, IS1009d, TS3003a, TS3003b,
  TS3003c, EN2002a, EN2002b; four participants each; 14 to 43 minutes). The app diarizes only the **Others** channel (the remote
  participants; **Me** is your own microphone), so the test audio imitates that: one participant is taken out as "me", the
  other three headsets are level-normalised, summed and passed through the Opus codec (libopus, voip mode, alternating 24 kbps and
  16 kbps) to simulate a conferencing codec. The reference is AMI's turns for the three remote speakers. Recipe at the top of
  [`eval/scripts/build_sets.py`](../eval/scripts/build_sets.py).
- **VoxConverse test** (8 recordings of 14 to 15 minutes with 2 to 9 speakers; selection rule: for each speaker count from 2 to 9, the
  largest file under 30 MB), original audio, no simulation.

**Held-out sets** (not used to choose any setting; built and pinned like the above, see [`eval/heldout/README.md`](../eval/heldout/README.md)):

- **AMI dev "others"**: 8 meetings of the AMI dev split (ES2011a and c, IS1008a, c and d, TS3004a, c and d; 16 to 50 minutes), built exactly like the AMI set above.
- **VoxConverse held-out**: 11 test recordings listed in `eval/manifests/heldout/vox_selected.txt` (2 to 12 speakers, 4.6 to 12 minutes).
- **Spanish conversations**: 12 synthetic conversations (see [Spanish](#spanish)).
- **Call-impaired**: 8 of the clean files above (3 AMI, 3 Spanish, 2 VoxConverse) put through 3 call profiles ([Spanish](#spanish), last table).

#### The "no-bleed" scoring region

Headset microphones also pick up their neighbours. In the AMI remote mix, "me" is not
supposed to be present, but their voice leaks faintly into the other participants' headsets and the level normalisation
raises it. A diarizer correctly hears that voice; the remote-only reference does not contain it, so it is counted as false alarm
(30.4 points of the 39.3 % below). That would not happen in a real call, where the remote side does not contain your own voice.
The headline AMI figure therefore scores only the time that is **not** speech of someone outside the remote reference (the
"no-bleed" UEM, built from AMI's own turns). Both are reported; neither is hidden.

**Scorer.** [`eval/scripts/score_der.py`](../eval/scripts/score_der.py), independent of the app and of pyannote (standard library and numpy;
10 ms frames, NIST form, Hungarian one-to-one speaker mapping). On 10 October 2026 it was checked once against
pyannote.metrics 4.1 on the same engine output and agreed to the printed precision, per file and in total (AMI 12.0 / 17.9, VoxConverse
9.6 / 14.3, AMI plain region 39.3 / 41.0, collar 0.25 and none; these figures belong to the engine before the 2026-10-11 change), and against a second frame-based scorer (purity, coverage, speaker count).
Those two cross-check scripts are not in the repository, so that check is a one-time statement, not something this harness reruns. The scorer has unit tests (`eval/tests`).

### Results

Tuning set (the engine as it is now; the change is compared under [What the 2026-10-11 change did](#what-the-2026-10-11-change-did)):

| Set | Files | Speech | DER (collar 0.25) | Miss | False alarm | Confusion | DER (no collar) | One-speaker baseline |
|---|---|---|---|---|---|---|---|---|
| AMI others, no-bleed region | 10 | 11,631 s | **10.5** | 5.4 | 3.2 | 1.9 | 16.5 | 47.1 |
| VoxConverse | 8 | 6,792 s | **7.6** | 2.6 | 2.5 | 2.5 | 12.7 | 31.6 |
| **All 18** | 18 | 18,423 s | **9.4** | | | | 15.1 | 41.1 |
| AMI others, plain region (includes the "me" bleed as false alarm) | 10 | 11,631 s | 38.1 | 5.4 | 30.8 | 1.9 | 39.9 | 47.1 |

Held-out English (settings never chosen on these files):

| Set | Files | Speech | DER (collar 0.25) | Miss | False alarm | Confusion | DER (no collar) | One-speaker baseline |
|---|---|---|---|---|---|---|---|---|
| AMI dev others, no-bleed region | 8 | 8,616 s | **11.5** | 4.6 | 3.8 | 3.2 | 18.3 | 54.9 |
| VoxConverse held-out | 11 | 4,493 s | **5.9** | 0.9 | 1.9 | 3.2 | 10.9 | 52.9 |
| **Both** | 19 | 13,109 s | **9.5** | 3.2 | 3.1 | 3.2 | 15.8 | |
| AMI dev others, plain region | 8 | 8,616 s | 32.1 | 4.6 | 24.3 | 3.2 | 36.0 | 54.9 |

All values are percent of reference speech time. The **All 18** and **Both** rows divide the pooled errors by the pooled reference time scored with the collar, which is a little less than the "Speech" column (that column is the time with no collar); so a pooled row is not the average of the rows above it weighted by that column (for **Both** it would be 9.6, 0.1 above). The comparisons below pool the same way. The "one-speaker baseline" scores the same reference speech with a single
label (perfect speech detection, no separation), which is what the app did before it separated speakers.

The 18 files of the tuning set split into two fixed halves, listed by name in [`eval/pins.json`](../eval/pins.json) (`diarization_halves`: file ids sorted by plain name, even positions in half A, odd positions in half B). `run_diarization.py` prints each half's DER and writes it to `summary.json`:

| Half | Files | DER (collar 0.25) | DER (no collar) |
|---|---|---|---|
| Half A | 9 | 10.7 | 16.8 |
| Half B | 9 | 8.3 | 13.5 |

The halves show how much the figure moves from one group of files to another (about 2.4 points with nine files each); treat the whole-set figure as the headline. They are **not** a held-out test: the diarization threshold and the settings changed on 2026-10-11 were chosen while developing on this same set, so no part of it is untouched by those choices. The held-out sets above are the out-of-sample figures.

AMI, per file (no-bleed region):

| File | Ref speech (s) | Ref speakers | Found | DER 0.25 | Miss | FA | Conf | DER no collar |
|---|---|---|---|---|---|---|---|---|
| EN2002a | 2003 | 3 | 4 | 14.3 | 10.6 | 1.2 | 2.5 | 18.7 |
| EN2002b | 1653 | 3 | 3 | 12.4 | 7.2 | 1.6 | 3.7 | 17.3 |
| ES2004a | 534 | 3 | 3 | 13.0 | 9.6 | 2.3 | 1.1 | 20.1 |
| ES2004c | 1643 | 3 | 3 | 4.8 | 1.8 | 2.6 | 0.4 | 9.7 |
| IS1009a | 625 | 3 | 4 | 13.3 | 5.4 | 3.4 | 4.5 | 19.7 |
| IS1009c | 1350 | 3 | 4 | 5.4 | 1.6 | 2.9 | 1.0 | 11.7 |
| IS1009d | 1028 | 3 | 4 | 14.3 | 4.8 | 5.9 | 3.6 | 25.6 |
| TS3003a | 176 | 3 | 3 | 46.3 | 16.2 | 17.3 | 12.8 | 54.5 |
| TS3003b | 1241 | 3 | 4 | 9.8 | 3.2 | 5.9 | 0.7 | 14.6 |
| TS3003c | 1379 | 3 | 4 | 8.7 | 5.3 | 3.1 | 0.3 | 12.5 |

VoxConverse, per file:

| File | Ref speech (s) | Ref speakers | Found | DER 0.25 | Miss | FA | Conf | DER no collar |
|---|---|---|---|---|---|---|---|---|
| crorm | 872 | 2 | 1 | 4.5 | 4.5 | 0.0 | 0.0 | 5.1 |
| fijfi | 827 | 4 | 4 | 5.5 | 1.0 | 1.5 | 3.0 | 11.3 |
| ikhje | 868 | 6 | 6 | 6.5 | 1.8 | 2.0 | 2.7 | 12.3 |
| lpola | 811 | 2 | 2 | 10.7 | 5.1 | 1.7 | 3.9 | 14.7 |
| poucc | 944 | 6 | 5 | 11.8 | 2.5 | 3.3 | 6.1 | 19.4 |
| sexgc | 838 | 3 | 3 | 7.9 | 1.7 | 4.8 | 1.4 | 13.1 |
| uhfrw | 851 | 4 | 4 | 8.2 | 2.6 | 3.4 | 2.2 | 14.8 |
| yzvon | 781 | 2 | 3 | 6.4 | 1.0 | 4.1 | 1.3 | 10.2 |

"Ref speakers" and "Found" count only speakers with at least 10 s of speech inside the scored region, on both sides. Exact count:
9 of 18 files; within one: 18 of 18. On AMI the app usually finds one speaker too many (+0.6 on average); on VoxConverse the
count is now close (-0.1 on average; before the change it merged speakers, -0.6).

The extra speaker on AMI is a real voice, not a split one. `eval/scripts/left_out_voice.py` checked a rerun of the tuning set on
30 October 2026, with the same speakers found in every file. In each of the 6 files with one too many, the extra speaker is the
participant `build_sets.py` left out of the mix ("me"): 78 % to 97 % of its time falls where only that participant speaks. The
remote headsets hear that voice faintly across the room, and the reference of the remote side does not have it. Without it the
count is exact in 9 of the 10 files (mean signed error -0.10). The tenth, TS3003a, finds the left-out participant and two of
the three remote speakers. The held-out AMI set, built the same way and rerun the same day (DER as published, 11.5 % in
the no-bleed region), says the same. All 8 files have that participant as a separated speaker, with 79 % to 94 % of its time.
Without it, the count is exact in 7 of the 8 files (mean signed error -0.12 instead of +0.75); ES2011a then finds two of
its three remote speakers. A real call's Others channel carries the user's voice only when the far side sends it back.

**What this says.** On English meeting audio, the app labels the right speaker for most speech, and most of the remaining error is
missed speech (the diarizer does not call some quiet or short speech speech) rather than mixing people up (confusion 1.9 to
3.2 points). It does **not** say how it performs on real calls, real Spanish meetings, or noisy rooms.

### Speed

`Vauta diarize` over the 18 files of the tuning set took 160.0 s for 25,288 s of audio (real-time factor 0.0063, about 158 times faster than real
time); the longest file (TS3003c, 43 min) took 15.6 s. Over the 55 held-out and augmented files it took 313 s for 47,510 s (152 times). This is wall time of the whole command, including loading and verifying the
models, on the machine above.

### What the 2026-10-11 change did

Three settings of the offline (end of meeting) speaker separation changed; the live labels shown while recording did not.

1. Speech of one speaker separated by less than **0.5 s** is one turn (was 0.1 s).
2. Every analysis window votes with the same weight when turns are rebuilt (was a Hamming weight centred on the window).
3. The fold that merges tiny voices into the nearest large one **scales with the meeting**: a voice needs at least 1.5 % of the recording as speech, between 12 s and **30 s** (was a fixed 20 s). The 30 s ceiling only takes effect above 33 minutes.

"Before" is the engine of main, run with the real `Vauta diarize` command on the same audio and scored by the same scorer: the tuning-set baseline is the run behind main's published figures (build `a670db8`, 11.0 % and 16.6 %, summary in [`eval/heldout/results/before_tuning_set`](../eval/heldout/results/before_tuning_set)), and the held-out baseline is a build of `9eb516e` ([`results/before`](../eval/heldout/results/before)). The speaker-separation code (`Sources/VautaCore/Diarization`) is identical in `a670db8`, `9eb516e` and `9cdb74c`. DER is the pooled error over the pooled reference time scored with the collar (see the note under the results tables), collar 0.25 s unless stated. "Better" and "worse" count files whose DER moved by more than 0.05 points; the interval is a 95 % bootstrap over files of the mean per-file change.

| Set | Files | DER before | DER after | No collar, before to after | Files better / worse | Mean change per file [95 % interval] | Speaker count exact, before to after |
|---|---|---|---|---|---|---|---|
| Tuning set | 18 | 11.0 | **9.4** | 16.6 to 15.1 | 17 / 1 | -1.6 [-2.1, -1.1] | 6 to 9 of 18 |
| **Held-out English** | 19 | 10.8 | **9.5** | 16.7 to 15.8 | 13 / 5 | -1.8 [-3.7, -0.5] | 9 to 9 of 19 |
| - AMI dev | 8 | 12.5 | 11.5 | 18.8 to 18.3 | 7 / 1 | -0.8 [-1.4, -0.2] | 1 to 2 of 8 |
| - VoxConverse held-out | 11 | 8.0 | 5.9 | 12.6 to 10.9 | 6 / 4 | -2.4 [-5.5, -0.3] | 8 to 7 of 11 |
| Synthetic Spanish | 12 | 9.4 | **7.2** | 13.5 to 12.3 | 12 / 0 | -2.2 [-4.6, -0.6] | 9 to 10 of 12 |
| Call-impaired | 24 | 16.8 | **16.3** | 22.8 to 22.6 | 18 / 1 | -0.4 [-0.7, -0.2] | 18 to 18 of 24 |

Where it is not an improvement:

- **The count of speakers on held-out English is slightly too high** after the change: +0.58 on average (it was 0.00 before). Exact in 9 of 19 files both before and after; within one in 18 of 19 both times. The gain is in DER, not in counting.
- One tuning file got worse (TS3003a, 46.0 to 46.3, the shortest and hardest file). Five held-out files got worse: ES2011a (14.3 to 15.1) and four VoxConverse files by 0.3 to 0.6 points (bjruf, eddje, gmmwm, vtzqw). On the AMI dev set the gain is the smallest of the three English groups (-1.0 point pooled, 12.5 to 11.5; -0.8 as a mean per file).
- The improvement comes with less missed speech (held-out English 3.9 to 3.2) and less confusion (4.2 to 3.2), and slightly more false alarm (2.8 to 3.1), as expected from merging more pauses.
- The gain does not depend on the collar: with no collar every group improves as well.

**How independent the held-out figures are.** The 19 English files and the Spanish and call-impaired sets were not in the tuning set, and the shipped values follow the tuning set: a gap of 0.8 s scored lower still with the 0.25 s collar (tuning set 9.0, Spanish 6.8) but not without it, and 0.5 s, which lowers DER on every set with and without the collar, was kept; the fold share was taken from a plateau. But the sweeps that led to these values (about 50 variants) printed the held-out figures next to the tuning ones, so the held-out sets are **not blind**. The models themselves were trained by others on AMI (train) and VoxConverse (dev); whether AMI dev was used for their validation is unverified. The tuning figure (-1.6 pooled: 11.0 to 9.4) and the held-out one (-1.4 pooled: 10.8 to 9.5) are close, which suggests little over-fitting, but 19 files are few: the interval above reaches -0.5.

**Reproducing the table.** Every row of [`eval/heldout/results/before_after.jsonl`](../eval/heldout/results/before_after.jsonl) is one line of `compare_runs.py` (`eval/.venv/bin/python -I eval/scripts/compare_runs.py --sets-dir <sets> --before <run> --after <run>`, run directories as `run_diarization.py` and `run_diar_sets.py` write them). The held-out, Spanish and call-impaired rows use `--sets-dir eval/heldout/sets` (committed text), `--before` a run of the `9eb516e` build and `--after` a run of this branch. The tuning-set row needs the sets the main harness built (`<VAUTA_EVAL_WORK>/sets`, which holds `ami_others` and `voxconverse`) and takes the run behind main's published figures (the `before_tuning_set` summary above) as `--before`. The summaries of the after runs are in `results/after` and `results/after_tuning_set`.

**Effect on the voice-recognition gate.** Voice recognition only uses a speaker whose turns share at most 40 % of their time with another speaker's (`VoiceProfileThresholds.maximumOverlapShare`), and merging pauses lengthens turns. [`eval/scripts/overlap_shares.py`](../eval/scripts/overlap_shares.py) computes that share from a run's RTTMs (the app's own definition) for speakers with at least 30 s of turn speech:

| Held-out run | Speakers with 30 s | Share of the others' time: mean / median / 90th percentile | Within the 40 % gate |
|---|---|---|---|
| English (AMI dev + VoxConverse), before | 67 | 10.0 % / 7.8 % / 19.7 % | 66 |
| English, after | 66 | 10.2 % / 8.4 % / 19.7 % | 65 |
| Plus 12 Spanish conversations, before | 113 | 10.1 % / 9.8 % / 18.1 % | 112 |
| Plus 12 Spanish conversations, after | 113 | 10.4 % / 10.0 % / 19.0 % | 112 |

The share rises by about 0.3 points and the same one speaker per set fails the gate before and after. **Not re-measured:** the 0.70 cosine threshold for a match and the spread gate depend on the speaker embeddings, which the RTTMs do not hold and which only the diagnostics build can write out; the scaled fold changes which small clusters survive, so those two gates were calibrated on the engine before this change.

### Long recordings

**This section is an ad-hoc check, outside the harness:** the joined recordings, their reference and the scoring commands are not committed, so the figures here cannot be reproduced from the repository, and the Summary does not quote them. The fold ceiling and the clustering were not exercised above 50 minutes before this change. Two recordings were made by joining AMI dev "others" files of the same four-person team (TS3004: sessions a and c, then a, c and d), because no single recording that long is in the sets. They are not real single meetings: the joins are abrupt and the same people appear again after a cut.

| Recording | Length | Wall time of `Vauta diarize` | Peak memory (max resident / peak footprint) | Result |
|---|---|---|---|---|
| TS3004 a + c | 72 min | 26.3 s (164 times real time) | 89 MB / 72 MB | 4 speakers, 919 turns; DER 11.4 % (collar 0.25, no-bleed region), the reference has 4 speakers |
| TS3004 a + c + d | 117 min | 43.8 s (161 times real time) | 134 MB / 114 MB | 4 speakers, 1,686 turns; not scored (no reference was built) |

The time is the whole command (analysis of every window plus the final clustering); the final clustering alone is a small part of it (the earlier estimate is 33 to 66 ms for 43 to 60 minutes). Memory was read with `/usr/bin/time -l` and does not include the models' weights mapped by Core ML on every run (a 5-minute file shows 274 MB resident), so read it as "does not grow with length", not as the app's memory use. A unit test (`theFoldCeilingKeepsAGuestInALongMeeting`) pins the reason for the 30 s ceiling: with a ceiling above the guest's speech time, a voice with 32 s of speech in a long meeting is merged into another speaker. **Not tested on real data:** such a guest in a real hour-long meeting.

### Tried and not changed: calling more frames speech

Most of the error left is missed speech, so on 1 November 2026 one build swept a bias against "nobody speaks". The segmentation
network decides each frame by its most likely class, one of which is "nobody speaks"; `DiarizationConfig.noneLogBias` lowers that
class's log-probability first, so a positive bias calls more frames speech and a negative one fewer (`Vauta diarize --none-bias <n>`,
and `--none-bias` in `run_diarization.py` and `run_diar_sets.py`). At 0, the network's own decision, the run reproduces the published
figures exactly. The tuning set and the 19 held-out English files, pooled as above; the last two columns compare each value with 0 on
the held-out files:

| Bias | Tuning set: DER (miss / false alarm) | No collar | Held-out English: DER (miss / false alarm) | No collar | Held-out files better / worse | Mean change per held-out file [95 % interval] |
|---|---|---|---|---|---|---|
| -0.5 | 9.93 (5.47 / 2.40) | 15.46 | 9.58 (3.88 / 2.53) | 15.60 | 8 / 7 | -0.03 [-0.22, +0.17] |
| -0.25 | 9.64 (4.90 / 2.63) | 15.23 | 9.47 (3.53 / 2.74) | 15.61 | 9 / 3 | -0.04 [-0.13, +0.05] |
| **0 (shipped)** | **9.53 (4.36 / 3.01)** | 15.22 | **9.46 (3.20 / 3.08)** | 15.78 | | |
| 0.25 | 9.43 (3.92 / 3.32) | 15.25 | 9.43 (2.93 / 3.44) | 15.88 | 4 / 8 | -0.04 [-0.29, +0.14] |
| 0.5 | 9.55 (3.53 / 3.76) | 15.51 | 9.72 (2.67 / 3.83) | 16.34 | 4 / 14 | +0.26 [-0.02, +0.60] |
| 1 | 10.18 (2.95 / 4.77) | 16.48 | 10.44 (2.22 / 4.93) | 17.45 | 1 / 16 | +0.96 [+0.44, +1.66] |
| 1.5 | 11.16 (2.51 / 5.97) | 17.74 | 11.73 (1.77 / 6.52) | 19.07 | 0 / 18 | +2.08 [+1.05, +3.46] |
| 2 | 12.68 (2.21 / 7.48) | 19.55 | 13.63 (1.48 / 8.59) | 21.16 | 0 / 18 | +3.70 [+2.09, +5.79] |

- **Missed speech becomes false alarm.** Each step towards speech trades missed speech for as much false alarm or more: from 0 to 0.5
  the held-out miss falls by 0.53 points and the false alarm rises by 0.75. A negative bias does the opposite.
- **The best value is within noise.** The best value on the tuning set, 0.25, is 0.10 point lower there and 0.03 lower on the held-out
  files. Its interval spans zero there, 8 held-out files get worse against 4 better, and the figure with no collar is worse on both
  sets. So the setting stays at 0.
- **The speaker count does not move it either.** It is exact in 10 of the 19 held-out files at 0.25, against 9 at 0, and within one
  in all 19 against 18.
- **Not measured:** the call-impaired and Spanish sets, whose audio was not built for this sweep. The option stays so that they can be.

`eval/heldout/results/none_bias.jsonl` holds the `compare_runs.py` lines behind the table, each with its `none_bias`: every value
against 0, for the tuning set and the held-out groups.

## Word error rate

### Method

*WER* = (substitutions + deletions + insertions) / words in the reference. It is measured on `Vauta transcribe-file --locale en-US`,
Apple's on-device speech recognizer, as the app uses it, against AMI's **manual word transcripts** (`words/*.words.xml` of the
pinned annotations 1.6.2). The first 600 s of each of the 10 AMI test-split meetings is used (a longer window only slows the pure-Python
edit-distance scorer).

Two conditions, per meeting:

- **Headset.** The raw close-talk headset (no gain, no codec) of the speaker who talks most in the window. The best case for the
  recognizer.
- **Others.** The simulated remote mix of the three remote speakers (the same audio as the DER set). The recognizer sees one stream
  with overlapping speakers.

**Reference text.** The words (no punctuation tokens, vocal sounds such as laughs and coughs, or truncated fragments) of the
scored speakers that start in the window, in time order. **Normalisation** (both sides, [`score_wer.py`](../eval/scripts/score_wer.py)):
lower case; punctuation to spaces except apostrophes; digits spelled out ("3" to "three", "25%" to "twenty five percent"); hesitations and
back-channels removed (um, uh, uhm, er, erm, ah, eh, hmm, hm, mm, mmm, mhm, huh); "ok" to "okay". Nothing else is mapped (no spelling
variants or compounds), so the figure is slightly pessimistic.

**Oracle masking.** A headset also records its neighbours, and the remote mix contains the faint "me" voice. A recognizer rightly
transcribes them and the scorer would count them as insertions (63.4 % and 53.5 % WER without masking). To measure recognition and
not that artifact, the audio is muted outside the scored speakers' reference turns (0.25 s of padding) before it is transcribed. This
uses the reference segmentation, which a real app does not have; it removes the effect of speech detection from the number.

### Results

| Condition | Meetings | Reference words | Substitutions | Deletions | Insertions | WER (oracle-masked) | WER (unmasked) |
|---|---|---|---|---|---|---|---|
| Headset | 10 | 6,537 | 374 | 244 | 88 | **10.8 %** | 63.4 % |
| Others (simulated remote mix) | 10 | 8,664 | 576 | 1,096 | 85 | **20.3 %** | 53.5 % |

| Meeting | Headset: words | Headset WER % | Others: words | Others WER % |
|---|---|---|---|---|
| ES2004a | 425 | 10.1 | 622 | 20.6 |
| ES2004c | 406 | 8.1 | 889 | 14.6 |
| IS1009a | 711 | 12.4 | 1089 | 19.9 |
| IS1009c | 488 | 4.7 | 1122 | 9.0 |
| IS1009d | 581 | 6.5 | 515 | 13.0 |
| TS3003a | 1079 | 13.3 | 50 | 40.0 |
| TS3003b | 767 | 8.5 | 356 | 14.3 |
| TS3003c | 428 | 7.5 | 716 | 9.2 |
| EN2002a | 990 | 9.5 | 1841 | 25.5 |
| EN2002b | 662 | 22.2 | 1464 | 34.7 |

**What this says.** On clean, close-talk English speech the recognizer is wrong on about one word in ten. On the remote mix the
error roughly doubles, and 62 % of it is **deletions**; the likely reason is that when several people talk at once a single recognizer follows one of them (the harness counts deletions in total, not by overlap). The
two meetings with the most overlapped speech (EN2002a and EN2002b) are the worst. The small file TS3003a "others" has only 50 reference
words (the remote speakers say little in its first 10 minutes), so its percentage means little; the pooled figure is weighted by words.
WER on a quiet speakerphone, with accents, jargon or other languages, will differ; **none of those was measured**.

#### Held-out meetings

The same method on the first 600 s of the 8 AMI dev meetings (not part of the set above; transcription does not depend on the speaker-separation change, and the figures are the same before and after it):

| Condition | Meetings | Reference words | Substitutions | Deletions | Insertions | WER (oracle-masked) | WER (unmasked) |
|---|---|---|---|---|---|---|---|
| Headset | 8 | 4,777 | 262 | 211 | 86 | **11.7 %** | 77.6 % |
| Others (simulated remote mix) | 8 | 7,083 | 460 | 606 | 99 | **16.4 %** | 37.4 % |

Per meeting, from 6.7 % (IS1008d, headset) to 17.3 % (TS3004a, headset) and from 7.6 % (IS1008a) to 24.4 % (TS3004d) on the remote mix. The two sets differ by about one point on the headset and four on the remote mix, which shows how much WER moves between groups of meetings; no single figure here is "the" WER of English meetings.

### Speed

Transcription took about 54 s per condition for 6,000 s of audio (about 110 times faster than real time, including start-up of the
command for each file), on the machine above.

### Word confidence

The app does not ask the recognizer how sure it is of each word. `run_wer.py --confidence` measures, on 30 October 2026, what
asking would cost and what it would tell. It runs one more oracle-masked pass of the 10 meetings that asks for it
(`transcribe-file --out`), alternating which pass goes first. Words without a confidence are left out. Run
`wer-confidence-1`; the plain passes reproduce the table above (10.8 % and 20.2 %).

| Condition | WER plain | WER asking | Time ratio | Scored words | Right | Mean confidence | ECE | Brier | AUROC |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Headset | 10.8 % | 10.8 % | 0.98 | 6,379 | 92.8 % | 0.858 | 0.079 | 0.082 | 0.785 |
| Others (simulated remote mix) | 20.2 % | 20.2 % | 1.00 | 7,655 | 91.4 % | 0.833 | 0.088 | 0.097 | 0.773 |

Reliability: the share of right words in each confidence band, both conditions together.

| Confidence | Words | Right |
|---|---:|---:|
| below 0.3 | 408 | 65.9 % |
| 0.3–0.5 | 818 | 75.1 % |
| 0.5–0.7 | 1,701 | 86.5 % |
| 0.7–0.9 | 2,798 | 88.8 % |
| 0.9–1.0 | 8,309 | 97.2 % |

**What this says.** Asking changes no word and takes no longer. The confidence does tell right words from wrong ones (AUROC 0.77
to 0.79), and it is lower than the share of right words below 0.9: a word at 0.5 to 0.7 is right 86.5 % of the time. A threshold
or a calibration made from these numbers would be fitted on the same 10 meetings; the held-out sets would have to confirm it.
"Right" is a word aligned to the same reference word, after the normalisation of `score_wer.py`; a scored word is a recognised
word that has a confidence (insertions included).

## Whether the microphone heard the others

While recording, `EchoCoupling` decides from the loudness of the two channels (10 ms energies) whether the microphone hears the
Others channel. Over speakers it does, and the echo marks of the Me lines run. A recording in which it never does in a minute of
the others speaking ("never heard") is taken as headphones, and nothing is marked. A microphone that hears them in two of the
last six windows of 10 s suggests headphones in the panel ("heard lately"). Its thresholds were set on simulated energies;
`eval/scripts/run_echo_coupling.py` (`Vauta echo-coupling`) measures them on real speech, 30 October 2026, the first 600 s of
the 10 AMI meetings above. The Others file is the remote mix of `build_sets.py`, and the Me file is, by condition:

- **room**: the left-out participant's raw headset. The four sat in one room, so the headset hears the others faintly, as a
  microphone hears speakers turned low. The hardest case to hear.
- **speakers**: the same headset with the remote mix added 20 dB lower and 150 ms later. Where the room's cross-talk is the
  stronger, it gives the delay (about 0 s).
- **headphones**: the left-out participant's headset of the next meeting, whose room never heard this mix.

| Condition | Expected | Windows | Heard | Never heard | Heard lately | Median delay |
|---|---|---:|---:|---:|---:|---:|
| room | heard | 452 | 76.1 % | 0 of 10 | 8 of 10 | 0.01 s |
| speakers | heard | 452 | 92.0 % | 0 of 10 | 10 of 10 | 0.15 s |
| headphones | never heard | 452 | 0.0 % | 10 of 10 | 0 of 10 | - |

No meeting is taken for headphones when the microphone hears the others, even faintly, and none recorded "over headphones"
hears them. The panel's suggestion would not come up in two of the ten faint-room meetings. These are headsets in one room
with a simulated codec, not a laptop microphone and real speakers: they test the measure on real speech, not every room.

## Spanish

Spanish is measured in two ways, and neither is a real Spanish meeting. **No claim is made about real Spanish calls.**

### Word error rate

`Vauta transcribe-file --locale es-ES` (Apple's on-device recognizer) on 35.6 minutes of read and parliament speech: four 5-minute files of European Parliament speech (VoxPopuli, Spanish test split, CC0) and three of audiobook readings (Multilingual LibriSpeech, CC BY 4.0), each made of whole source utterances joined with 0.5 s gaps, with their exact reference texts. Normalisation ([`score_wer_es.py`](../eval/scripts/score_wer_es.py)): lower case, punctuation removed, digits spelled out in Spanish, hesitations removed; the "ignoring accents" figure also strips diacritics (the audiobook texts use pre-reform spellings such as "a" with an accent, which a recognizer rightly writes the modern way). No oracle masking is needed: there is one speaker at a time.

| Source | Reference words | Substitutions | Deletions | Insertions | WER | WER ignoring accents |
|---|---|---|---|---|---|---|
| Parliament speech (4 x 5 min) | 3,213 | 126 | 104 | 66 | **9.2 %** | 9.1 % |
| Audiobooks (3 x 5 min) | 2,254 | 86 | 10 | 26 | **5.4 %** | 5.0 % |
| **All** | 5,467 | 212 | 114 | 92 | **7.6 %** | 7.4 % |

Per file between 4.5 % and 6.4 % (audiobooks) and 7.1 % and 10.3 % (parliament). Parliament speech is spontaneous-sounding but prepared, with proper names and numbers, and has more deletions. This says how well Apple's model reads clean Spanish speech; it does not say how it does with conversation, overlapping speakers, accents of the Americas or a laptop microphone.

### Speaker separation on synthetic Spanish conversations

12 conversations of 2 to 6 speakers (9 to 15 minutes), built from the same sources: speakers' utterances are cut at pauses and placed by a turn-taking model with overlaps and short interjections, each speaker with their own level, band limit, noise floor and sometimes a small synthetic room; the tracks are summed and Opus-coded as in the English sets. The reference is exact for the construction (the voice-activity interval of every placed chunk), not human-annotated. Six conversations use audiobook voices and six parliament voices; they are never mixed.

DER 7.2 % (collar 0.25; 9.4 % before the change), 12.3 % with no collar; miss 2.9, false alarm 0.4, confusion 3.9; the one-speaker baseline is 58.5 %. Speaker count exact in 10 of 12 files and within one in 12 of 12. The two weakest files are es_conv08 (5 speakers, 4 found, 21.9 %) and es_conv03 (3 speakers found, 15.4 %, 11 points of it missed speech).

**Why this is probably easier than a real Spanish meeting.** Read and parliament speech has no conversational prosody; turn-taking comes from a Markov model; the overlap is 3 to 13 % of speech (AMI has about 10 to 20 %); there are no backchannels; each speaker comes from a different recording room, which helps to tell them apart. So the figure shows that the separation does not break on Spanish voices and that the change helps there, not what a user will see.

### Call-impaired audio

Eight clean files (three AMI, three Spanish, two VoxConverse) were put through three simulated call profiles: wideband VoIP (noise 20 dB below speech, 2 % packet loss), PSTN narrowband (12 dB, 300 to 3,400 Hz, mu-law, 4 % loss) and a poor mobile call (8 dB, Opus at 12 kbps, 8 % bursty loss, a muted gap about every 45 s). The recipe is in [`eval/scripts/build_aug.py`](../eval/scripts/build_aug.py). Muted regions are excluded from the scoring ("no-drop" region). 24 files:

| Profile | DER before (mean per file) | DER after (mean per file) |
|---|---|---|
| Wideband VoIP | 14.2 | 13.7 |
| PSTN narrowband | 16.7 | 16.3 |
| Poor mobile | 17.9 | 17.5 |
| **All 24 (pooled)** | 16.8 | **16.3** (22.6 with no collar) |

Worst after the change: ES2011a on the poor mobile profile (60.5 %: its three speakers are found as one), then es_conv06 PSTN (37.9 %) and TS3004a PSTN and VoIP (33.4 % and 36.6 %). The clean versions of the eight source files scored 7.9 % on average before the change, so impairments roughly double the error. These are simulations (crude packet-loss concealment, synthetic noise), not recordings of real calls.

## Minutes citations

### Method

The app writes minutes with a model the user chooses. What can be measured without choosing for anyone is the **citation
discipline**: whether each decision and task the app keeps cites a passage of the transcript that exists and that holds every
figure the item states, and how many the app itself marks *Unconfirmed*. `Vauta minutes-file` (an evaluation command, in the
shipping binary; see `eval/README.md`) runs the app's own minutes code on a public transcript: the prompts, block summaries
when the transcript does not fit the model's window, the validation that drops an item without a real citation or without a
quote that is word for word in the cited passage, and the `MinutesVerifier` checks that mark Unconfirmed. It uses a
throwaway encrypted store in a temporary folder and contacts no model server. `eval/scripts/run_minutes.py` feeds it the AMI
**manual** word transcripts (so the figures measure the minutes writer, not the recogniser) of the 10 meetings of the WER
set, all four participants, cut into passages (a speaker's words, pauses under one second, three words or more), then
`score_minutes.py` counts, over the items kept:

- **cited**: items with a citation (the app drops the rest, so this is 100 % by construction);
- **valid citation**: the cited passage exists and contains every digit figure of the item;
- **Unconfirmed**: the share the app marked itself;
- **proposed / dropped**: what the model proposed in its final answer and how many the app dropped before any of the above.

The model is **Apple's on-device language model** (`SystemLanguageModel.default`, macOS 27.2 (26B123), context window 4,096
tokens), the model people get with no setup, with the parts of the minutes the app sends to it: `minutes-file` forces none, and
the JSON it writes says which ran (`choices`). No model server was used, so nothing here says how a larger model does.

### Results

Measured on 1 November 2026 with a release build of `main` at `f484493` (runs `minutes-rel-180` and `minutes-rel-600`).
"Not kept" is what passed the citation check but is not in the minutes: the app's later steps on Apple's model left it out (such
as the ranking that keeps only the best decisions and tasks firm, or a repeat merged); this run does not break it down.

3-minute windows (5 to 27 passages each, one request per meeting: 10 model calls):

| Measure | Result |
|---|---|
| Decisions and tasks proposed / dropped / not kept / kept | 22 / 7 / 3 / 12 (7 of 22 dropped: no real passage cited, or a quote that is not word for word in it) |
| Kept items with a citation | 12 of 12 (by construction) |
| Kept items whose citation is valid (exists, holds the item's figures) | **12 of 12 (100 %)**; none was invalid and left unmarked |
| Kept items marked Unconfirmed by the app | **0 of 12** |
| Meetings with no decision or task kept | 2 of 10 (the model proposed none that passed, or the app dropped them all) |

10-minute windows (26 to 108 passages; 12 model calls for 9 meetings):

| Measure | Result |
|---|---|
| Proposed / dropped / not kept / kept | 59 / 26 / 4 / **29** (26 of 59 dropped) |
| Kept items whose citation is valid | **29 of 29 (100 %)**; none was invalid and left unmarked |
| Kept items marked Unconfirmed by the app | 1 of 29 (3 %) |
| Meetings with minutes written | 9 of 10, each with at least one decision or task kept. EN2002b (104 passages) failed, and the command did not print the job's message (it does now); run again alone twice, it wrote its minutes both times (11 and 8 items kept), so the failure was not seen again |

The figures published before (18 / 13 / 5 and 3 of 13 Unconfirmed on 3-minute windows; 42 / **0** / 42 on 10-minute windows)
were measured before #26, when `minutes-file` ran parts of the minutes that the app does not send to Apple's model.

### What this says, and what it does not

The valid-citation rate is high because the app checks before it keeps: an item whose quote is not in the cited passage never
reaches the minutes, and the rate counts only what the figure check can see (a digit that is not in the cited passage). It does
**not** say that a decision is correctly summarised or that the owner is right: that needs the human or judge rubric in
[`eval/rubric/MINUTES_RUBRIC.md`](../eval/rubric/MINUTES_RUBRIC.md), which has not been scored. What it does show is how much the
checks cost with this model: on 10-minute windows 26 of the 59 decisions and tasks Apple's 4,096-token model proposed (44 %)
cited no real passage or quoted it not word for word, and the app dropped them; on 3-minute windows, 7 of 22 (the summary and
topics are not checked by this measure). A model server with a larger window is the better choice for long meetings. Samples are
small (12 and 29 kept items), the model is not deterministic (a rerun gives other counts), and the manual transcript is cleaner
than a recogniser's output on a real call. The command uses Apple's on-device model only; a model server is not measured.

## Minutes against AMI's human summaries

### Method

AMI's annotators wrote an abstractive summary of each scenario meeting, with sections for its decisions, actions and problems,
and linked each sentence to the dialogue acts it rests on (the summary links of the AMI manual annotations 1.6.2, CC BY 4.0,
the zip already pinned in `eval/pins.json`). It is a reference for the minutes that no model wrote. `eval/scripts/build_ami_gold.py`
takes those sentences for the 13 meetings of the `llm-eval` AMI set that have one (ES2004 b to d, ES2011d, IS1009 b to d,
TS3003 b to d and TS3004 b to d: whole meetings of 30 to 45 minutes, manual transcripts, all four participants; 9 of them in the
set's test split), with the linked dialogue acts as passages of the transcript the minutes are written from: 70 decision
sentences (60 with a link) and 18 action sentences (17 with a link), over 3,869 passages.

`llm-eval --tasks minutes` wrote the minutes with what the app sends (`--extraction release --summary release --harness release
--open-questions release`), with Apple's on-device model (macOS 27.2 (26B123)) and with the integrated Gemma 4 E4B, one run
each. It used a release build of `f484493`, whose minutes code is the same at `c8db768` (run `gold-minutes-1`, 1 November 2026).
Each decision or task cites one passage. `score_minutes_gold.py` counts an item as *grounded* in a human sentence when that
passage is within one passage of a passage linked to the sentence, and reports:

- **found**: the human decisions (or actions) that some decision (or task) of the minutes is grounded in;
- **supported**: the decisions (or tasks) grounded in a human decision (or action);
- **in the human summary**: the items grounded in any sentence of the summary, its abstract and problems included;
- **at random**: what a citation drawn at random scores on the last two, from the share of passages near a linked one;
- **right owner**: of the tasks grounded in an action whose subject names roles ("The industrial designer will ..."), those
  whose owner is one of those speakers.

An AMI sentence often holds several decisions at once, so a sentence counts as found once and an item as supported by any
sentence: there is no one-to-one matching. The items the ranking leaves in "Other possible items" are not counted as items;
the column "with other items" adds them to what is found.

What the items say was judged blind as well. Packets mixed the 204 decisions and tasks the two models showed under neutral ids,
next to the 88 human decisions and actions of the 13 meetings (with a link or not), with the key sealed before any judging
(SHA-256 `0dbfa4da…`); `eval/scripts/gold_match_packets.py` writes the same packets again, and the same key in its own layout
(`dbe10430…`). One LLM judge, of another model family than the two measured and not told
which model wrote what, marked the human sentences each item states, in full or in part
([rubric](../eval/rubric/MINUTES_GOLD_MATCH.md); its grades have SHA-256 `0b427b46…`). `score_minutes_gold.py --matches` then
counts the human sentences found by content, the items that state one, and whether such an item cites where it was said
(within one passage of a linked passage).

### Results

| Model | Kind | Human sentences | Found | With other items | Items | Supported | At random | In the human summary | At random | Right owner |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Apple | decisions | 60 | **25 %** [12 %, 40 %] | 28 % | 58 | **22 %** [12 %, 35 %] | 9 % | 78 % | 63 % | – |
| Apple | tasks | 17 | **71 %** [36 %, 91 %] | 71 % | 67 | **24 %** [8 %, 44 %] | 2 % | 72 % | 63 % | 0 of 11 |
| Integrated | decisions | 60 | **20 %** [10 %, 33 %] | 20 % | 43 | **28 %** [17 %, 38 %] | 9 % | 88 % | 63 % | – |
| Integrated | tasks | 17 | **59 %** [17 %, 86 %] | 59 % | 36 | **31 %** [5 %, 59 %] | 2 % | 75 % | 63 % | 0 of 9 |

By content (one blind judge, every human sentence):

| Model | Kind | Human sentences | Found by content | In full | Items | Stating one | Cited where it was said |
|---|---|---:|---:|---:|---:|---:|---:|
| Apple | decisions | 70 | **20 %** [12 %, 28 %] | 7 % | 58 | **31 %** [18 %, 44 %] | 7 of 17 |
| Apple | tasks | 18 | **50 %** [25 %, 68 %] | 17 % | 67 | **15 %** [5 %, 28 %] | 9 of 10 |
| Integrated | decisions | 70 | **21 %** [12 %, 33 %] | 9 % | 43 | **49 %** [29 %, 68 %] | 9 of 19 |
| Integrated | tasks | 18 | **39 %** [17 %, 60 %] | 22 % | 36 | **31 %** [8 %, 60 %] | 10 of 11 |

95 % intervals: meeting-cluster bootstrap. On the 9 test meetings alone, Apple's minutes find 27 % of the decisions and 77 % of
the actions, the integrated model's 14 % and 69 % (`gold_scores.json`). With no tolerance (the cited passage itself must be a
linked one), Apple's decisions fall to 13 % found and 12 % supported and the integrated model's to 17 % and 26 %: Apple's
citations land next to the linked passage more often than on it. With two passages of tolerance, the rates rise by at most 7 points.

### What this says, and what it does not

- **The minutes find about a fifth of the human decisions, by either measure.** By content, 20 % (Apple) and 21 % (integrated)
  of the 70 human decisions, and few of them in full (7 and 9 %); by where they point, 25 and 20 % of the 60 with a link. The
  annotators wrote down design decisions (materials, buttons, colours, the battery) that the minutes leave out.
- **The integrated model's decisions are more often real decisions.** 49 % of them state a human decision, against 31 % of
  Apple's, and both cite near a human decision 2.4 to 3.1 times as often as a random passage would; most items (72 to 88 %) cite
  something the human summary covers.
- **Tasks: few human actions, many tasks.** Half of the 18 human actions are stated by one of Apple's 67 tasks and 39 % by one
  of the integrated model's 36, but only 15 % of Apple's tasks and 31 % of the integrated model's state a human action. Many of
  the others read as points to discuss rather than tasks ("Evaluate color options").
- **Said right, cited elsewhere.** A task that states a human action cites where it was said 19 times out of 21; a decision that
  states a human decision, 16 times out of 36. The measure by place misses the other 20: said right, but cited more than one
  passage away from where the annotator linked it.
- **No task has the owner the annotators named.** AMI's participants play roles and call each other by them, and the minutes
  never take a role as an owner (a role is not a person). On this corpus 8 of Apple's 98 tasks (counting those ranked out) and 2
  of the integrated model's 36 have an owner at all. This measures the corpus as much as the minutes: an owner needs a named
  person (an attendee, someone in Context).
- **One annotator, one judge, one run.** One annotator wrote each summary; one LLM judge matched the items, with no human
  review of its matches; each model ran once, on 13 meetings: the intervals are wide.
- **Not held out.** These meetings are in the `llm-eval` sets the minutes were developed on. The 11 scenario meetings that no
  evaluation had used are sealed for the check before a release ([`eval/heldout/README.md`](../eval/heldout/README.md)).

## Search by meaning (held-out check)

The optional search model (EmbeddingGemma 2, [SEARCH_MODEL.md](SEARCH_MODEL.md)) was chosen after two spikes, not yet reproduced from this repository. Passage
recall at 3 (R@3) against keyword search (BM25 alone, what Ask used before) with the pinned model, 256-dimension int8 vectors, Gemma alone, paired
bootstrap 95% intervals:

| Set | Queries | R@3 BM25 | R@3 model | Difference |
|---|---|---|---|---|
| MIRACL, 7 languages (es, en, ja, zh, ko, de, fr) | 213 to 300 each | 0.31 to 0.50 | 0.55 to 0.77 | +0.13 to +0.33, every interval above zero |
| MLQA, question and passage in different languages (es to en, en to es) | 420 and 478 | 0.40 and 0.38 | 0.71 and 0.75 | +0.30 and +0.37 |
| Written by the project (60 passages, 86 questions, es, en, ja, cross-language) | 86 | 0.709 | 0.965 | +0.26 [+0.15, +0.36]; across languages 0.93 against 0.14 |

Also measured: Matryoshka 256 dimensions costs 0 to 0.04 R@3 against 768 and int8 storage at most 0.005; Apple's contextual embeddings (removed in 0.9.0)
were worse than keyword search on every set (about -0.2 R@3); fusing the model with BM25 at equal weight gives back much of the gain, so Vauta ranks with the model and uses keywords
only to boost exact names, numbers and codes (that boost was tuned on synthetic data: 80 codes and 60 names on an English background).

**Limits, in plain words.** MIRACL (Wikipedia) and MLQA are public and are referenced, never copied, so you can fetch them; the project's own set is small and is not published, so
the third row cannot be reproduced from this repository and is not quoted in the README. Italian, Portuguese (Brazil) and speech-recognition-noisy transcripts were not measured. An M1 and an M5 were not measured. Speed
was about 20 ms per passage on an M2 in a release build.

**Held-out check before release (pending).** The boost values (+0.30 for a code, +0.15 for a name) are frozen. They are checked once, on a new set of real, self-authored, ASR-noisy
transcripts (es, en, it, pt-BR) with code and name questions, with these gates: R@3 of the final rule against the model alone, lower 95% bound at least -0.02; bare-code hit at 1 at least 0.95; no regression on "what did X say"
questions. If the name part fails, `SemanticRanker.nameBoost` becomes 0 and only the code boost ships. Results and reproduction steps are added here when the check is run; until then this section is the only claim about search quality
and the README quotes none.

## Post-meeting actions

`llm-eval --tasks actions` (see `tools/llm-eval/README.md`) ran over 15 public test meetings (11 AMI series and 4 Concejo sessions; English and
Spanish only) with the stored minutes of Apple's model and of the integrated Gemma 4 E4B, on a Mac14,3 (Apple M2, 24 GB), macOS 27, 19 October 2026.
Fixtures and gold were written without seeing the detector's word lists. One blind LLM judge graded 84 emails, 55 pairs and 71 follow-up candidates (single rater, no human review; the fixtures and
the gold labels were also model-assisted, and the judge was of the same model family that wrote the gold labels, so judge bias cannot be ruled out). A human spot-check of about 50 gold labels has not been done. Rates are per email; the Wilson intervals do not account for clustering by series (n = 12 to 15 per arm).

**The email, default settings (no summary).** Template arms: one email (`ET1`), one per owner (`ETO`); `EBL` is the same backend writing it unaided.

| Arm / backend | n | errors per email | emails with 0 errors | would send after light edits |
|---|---|---|---|---|
| `ET1` / Apple | 14 | 15.9 | 0 of 14 | 0 of 14 |
| `ETO` / Apple | 14 | 22.8 | 0 of 14 | 0 of 14 |
| `EBL` / Apple | 14 | 14.0 | 0 of 14 | 0 of 14 |
| `ET1` / integrated | 15 | 2.5 | 2 of 15 | 2 of 15 |
| `ETO` / integrated | 12 | 2.5 | 1 of 12 | 1 of 12 |
| `EBL` / integrated | 15 | 2.7 | 1 of 15 | 1 of 15 |

Pooled template arms: Apple 0 of 28 error-free (Wilson 0 to 0.121); integrated 3 of 27 (0.039 to 0.281). Gates: zero factual errors fails on both
backends; "would send after light edits" at 80% fails (Apple 0%, integrated 11%); non-inferiority to `EBL` by sign test over series is **not
demonstrated** (template ahead in three of four comparisons, never behind, sign p 0.18 to 1.0), and on Apple the template states more errors than
`EBL` (+1.9 and +8.8 per email, sign p 0.022 and 0.003) because it copies every stored line while `EBL` drops some. The cause is upstream: the
template copies the stored tasks, owners and decisions faithfully, and those are often wrong (Apple lists non-decisions and lines that contradict the
transcript; the integrated minutes name the speaker who asked instead of the person addressed, in 13 of 15 meetings; 8 due days were all in 2005).
The tracer (every line is a stored field) found 0 violations in 80 drafts: a build check, not an accuracy figure. The summary toggle was not
measured because no backend offers it.

**The follow-up detector (`FD`, `FDX` identical), 15 meetings, 103 expected meetings (101 inserted, 2 natural).**

| Arm | candidates | precision | recall, full list | recall, at most 2 per meeting | day correct | time correct |
|---|---|---|---|---|---|---|
| `FD` | 27 | 0.926 (0.766 to 0.979) | 25 of 103 = 0.243 (0.170 to 0.334) | 25 of 30 = 0.833 | 25 of 25 (0.867 to 1.00) | 21 of 25 |
| `FBL` / Apple | 15 | 1.00 (0.796 to 1.00) | 15 of 103 = 0.146 | 0.50 | 6 of 15 | 0.80 |
| `FBL` / integrated | 2 (13 of 15 meetings returned none) | 0.50 | 1 of 103 = 0.010 | 0.033 | 1 of 1 | 1 of 1 |

The two natural mentions (committee Mondays in `cdm200903_a`) were found by no arm. The detector shows at most 2 candidates per meeting while each
fixture holds 6 to 8 conflicting proposals, so the recall gate as written (0.60 against all expected) cannot be reached; the capped figure is shown
beside it. Errors the judge found: two past references read as future dates ("last time we
spoke on the 3rd", "la última vez, el 30 de agosto"), and four wrong times (three carried over from the neighbouring line, one "10 o'clock" not read).

**Deterministic gates (no judge).** Duplicates created: 0 over 29 replays (217 tasks pressed twice at once, reopened and rewritten). Undo removed
217 of 217 created items and nothing else. Nothing is detected during a recording (tests; 0 model calls in the template and detector arms).
The due day written equalled the minutes' day in 8 of 8, **but none of the 8 matched the transcript** (all were days in January 2005, years before
the meeting): the check passed as defined while the day was wrong. See "What changed after the judge" below.

**Release decision (the first judge's, applied).** Hold the email draft, the email summary and automatic follow-up detection; reminders and
**New Event…** stay. Superseded for detection by the second judged run below.

### Second judged run after the extraction fix (15 test meetings, one blind judge)

One blind LLM judge (one rater, no human review; the fixtures and the gold labels were also model-assisted, and the judge was of the same model family that wrote the gold labels, so judge bias cannot be ruled out) graded
858 minutes items (60 packets), 83 emails (53 pairs) and 121 follow-up candidates on 20 October 2026. The gold was sealed before the grading
(17 of 17 hashes) and the keys were opened only after it. The packets show neither summary, topics nor the citation check, so those were not judged.

**Which build, and what is spent.** The figures below describe the build judged on 20 October 2026. The extraction was changed afterwards
(the later fixes, listed in [LANGUAGE_MODEL.md](LANGUAGE_MODEL.md#release-state): recap scope, procedure rules, role words in the duplicate rule, named assignees, agreement voids,
hedged commitments marked "to be confirmed", the speaker-owner mark, and the later refusal and answerer checks), so the judged build no longer exists and these numbers are not the new
extraction's today. The 15 test meetings informed those changes: they are **spent**, and a new measurement on them is not held-out.

**Tasks, decisions and owners (old extraction, new extraction).** "Email-grade" is the items not marked "to be confirmed", the ones the default
email may use.

| Metric | Apple old | Apple new | Integrated old | Integrated new |
|---|---|---|---|---|
| Items stored | 359 | 381 | 58 | 60 |
| Precision, all items | 0.223 | 0.223 | 0.759 | 0.683 |
| Task / decision precision | 0.277 / 0.153 | 0.283 / 0.158 | 0.872 / 0.526 | 0.909 / 0.407 |
| Email-grade items, of which real | 355, 80 | 97, 55 | 51, 37 | 38, 33 |
| Email-grade precision | 0.225 | 0.567 | 0.725 | 0.868 |
| False items reaching the default email | 275 | 42 | 14 | 5 |
| Real items hidden as "to be confirmed" | 0 | 30 (10 tasks) | 7 | 8 |
| Owner right / wrong / missing | 36 / 1 / 18 | 37 / 3 / 11 | 6 / 19 / 9 | 21 / 2 / 7 |
| Meetings with at least one wrong owner | 1 | 3 | 11 of 15 | 2 of 15 |
| Missed gold tasks / decisions | 5 / 33 | 9 / 31 | 14 / 50 | 18 / 48 |
| Recall (real / (real + missed)) | 0.678 | 0.680 | 0.407 | 0.383 |

Paired sign tests over the 15 meetings: integrated wrong owners 11-1-3 in favour of the new extraction (p 0.006) and real tasks with the right owner
10-0-5 (p 0.002); its precision, missed tasks and email-grade precision do not change significantly (p 0.34 to 0.75), and its decision precision
falls from 0.53 to 0.41 with 6 more invented or wrong decisions, mostly marked "to be confirmed" (two reach the email). On Apple's model the
only significant effect is on what reaches the email: false items 15-0-0 (p 0.0001), email-grade precision 14-1-0 (p 0.001); list precision,
recall, owners and missed tasks are unchanged (p 0.38 to 1.0). Apple still lists about 25 items per meeting, about 6 of them real.

**The email on the new minutes (default settings, no summary).** The harness seeded a task owned by a speaker label with the person the fixture says that speaker is, so these emails name owners that the app's default email would leave unnamed unless the user had named every speaker (the harness now seeds them unnamed unless asked with `--actions-name-speakers`; the judged emails were not regenerated). `ET1` one email, `ETO` one per owner, `EBL` the same backend writing it unaided.

| Arm / backend | n | factual errors (emails with any) | would send after light edits | tone (1 to 5) |
|---|---|---|---|---|
| `ET1` / Apple | 15 | 56 (15 of 15) | 0.00 | 1.9 |
| `ETO` / Apple | 14 | 10 (8 of 14) | 0.43 | 3.1 |
| `EBL` / Apple | 15 | 273 (15 of 15) | 0.00 | 1.1 |
| `ET1` / integrated | 15 | 15 (11 of 15) | 0.20 | 3.0 |
| `ETO` / integrated | 9 | 1 (1 of 9) | 0.89 | 3.8 |
| `EBL` / integrated | 15 | 28 (12 of 15) | 0.20 | 2.9 |

Gates of the design (section 17.6): zero factual errors with default settings fails on every arm. At least 80% would send passes only for `ETO` /
integrated (0.89 on 9 meetings; every per-owner packet omits at least one addressee). Non-inferiority to `EBL`: both Apple arms are clearly
better (15-0-0 and 14-0-0, p 0.0001), but the baseline is unusable (18 errors per email); the integrated arms are ahead without significance
(8-5-2, p 0.58, and 6-3-0, p 0.51). Half of the integrated `ET1` errors (7 of 15) are in the open-question lines or in a proposed meeting stated as
scheduled. **Verdict: the email draft stays off on both backends.**

**The follow-up detector, capped at 2 candidates per meeting** (`FD` and `FDX` gave identical candidates on both backends; counted once).

| Arm | candidates | precision | recall, full list | recall, at most 2 per meeting | day correct | time correct |
|---|---|---|---|---|---|---|
| `FD` / `FDX` | 26 | 1.00 (26 of 26; Wilson 0.87 to 1.00) | 26 of 103 = 0.25 | 26 of 30 = 0.867 (about 0.70 to 0.95) | 26 of 26 | 0.92 |
| `FBL` / Apple | 15 | 0.87 | 13 of 103 = 0.13 | 0.43 | 0.38 | 0.69 |
| `FBL` / integrated | 2 | 0.50 | 1 of 103 = 0.01 | 0.03 | 1 of 1 | 1 of 1 |

Both detector arms read the stored minutes of the **new extraction** (its cited segments and tasks, with a due day stored only when the words say it). The app
runs the new extraction on the integrated model, the ranked extraction on Apple's model (since the harness phase) and the old one on the servers. Since then the detector's task path ignores
a day outside a year after the meeting (the old extraction could keep a day the model worked out) and, since rules version 2, counts a task marked "to be confirmed" only when the clause of
its cited passage that says the day neither asks nor hedges. Rules version 2 was run on 2026-10-24 on these 15 meetings with minutes made by what the app ships on each backend, scored by
day match to this phase's gold and with no judge ([LANGUAGE_MODEL.md](LANGUAGE_MODEL.md), "DEV check of the shipped combinations"): on Apple's ranked minutes (14 meetings: its model
declined to write one) 24 candidates, 24 correct, 24 of 28 with the cap of 2 (0.857) and day accuracy 1.00; on the integrated model's, the figures above again. The servers' minutes of the
old extraction were never run through the detector, so no figure is shown for them; the sentences inserted in the test transcripts sat in the last tenth, which the detector always reads
(`FD` equals `FDX`), so the gap is expected to be small, but it is not measured.

Gates: precision at least 0.90, capped recall at least 0.60 and day accuracy at least 0.90 all pass, so the detector is on. The two time misses are
"the 18th around one o'clock" offered without a time. In the 4 Concejo meetings it offers one candidate, which caps recall there at 1 of 2. The only
natural follow-ups in the set, the two committee Mondays in `cdm200903_a`, were both missed (natural recall 0 of 2), so every match was an inserted
mention. No past meeting, dinner or appointment was offered.

**Not in this judge's packets, reported afterwards.** Summary, topics and the citation-verification rate were not in the packets. In the traces read after unblinding, the
drops for a quote not found in the transcript went from 78 to 82 on Apple's model and from 5 to 10 on the integrated model, and the share of
proposed items kept on the integrated model from 0.92 to 0.53 (the new filter drops items, which is not the gate metric).
Citation-verification rate on the 15 test meetings, from the stored traces (items that passed the quote, segment and entity checks over items checked): Apple 0.571 old to 0.611 new
(+0.041, 95% clustered bootstrap CI -0.035 to +0.115); integrated 0.921 to 0.912 (-0.008, CI -0.073 to +0.058). No drop is detectable; non-inferiority within 0.05 is not shown at this sample size.
Blind pairwise comparison of the summary and open questions (one LLM judge, 15 meetings per backend): integrated, summary errors 6 old and 7 new, coverage 49 and 52 of 75, clarity 60 and 57,
preferred new in 9 meetings and old in 6 (sign test on per-meeting summary errors, p 0.73); Apple, summary errors 18 old and 23 new (new worse in 7 meetings, better in 3, p 0.34), coverage 35 and 35, preferred new in 8 and old in 7.
Apple's trend is unfavourable and its invented or wrong item count rose (10 to 16), hence the app then ran the new extraction on the integrated model only; the harness phase's blind test later moved Apple's model to the ranked extraction ([LANGUAGE_MODEL.md](LANGUAGE_MODEL.md), "Harness phase: what ships"). The servers were not measured and keep the old one.

**What changed after the first judge.** Fixes for the causes it named, each with a unit test and the deterministic checks re-run (the second judged run is above): a due day before the meeting or more than a year after it is dropped when the
minutes are read, and again before a reminder or an email uses it (the re-run wrote none of the 8 and the replay checks that); a date after a look-back
phrase ("last time", "la última vez", "la dernière fois", "letztes Mal", "l'ultima volta", 前回, 上次, 지난번) is not a meeting; a time belongs only to
the day it is next to; "10 o'clock" is read; per-owner drafts no longer repeat the decision and open-question lists; a due day after a sentence end is
joined with a dash. Not fixed (needs better stored minutes, then a new judged run): non-decisions in Apple's lists, and the owner taken from the
speaker who asked.

Limits: one LLM judge and no human review (the gold labels were also model-assisted, and the judge was of the same model family that wrote the gold labels and the fixtures, so judge bias cannot be ruled out); error counts depend on counting rules fixed before unblinding, a stricter or
looser judge would move totals but not the verdicts; AMI "d" meetings hold few real agreements, so most tasks and follow-ups are inserted lines;
`FD` ran without minutes, so the detector's task-due path was not tested; TS3005d has no Apple arms (Apple's model declined to write its minutes);
no model server, no M1 8 GB, and the seven languages other than English and Spanish are covered by string, render and detector tests only.

## Reproduce

```sh
python3 -m venv eval/.venv && eval/.venv/bin/pip install --only-binary=:all: --require-hashes -r eval/requirements.txt
brew install ffmpeg
swift build -c release --arch arm64
.build/release/Vauta install-speech-assets --locale en-US
eval/run_all.sh          # about 2.8 GB of downloads for the tuning set; about 25 minutes plus the downloads
```

`eval/run_all.sh` also builds and scores the held-out sets (about 4 GB more to download and about 8 GB more on disk with the built audio, on top of the tuning set's about 3 GB and 5 GB; estimates, as the sizes of the remote sources can change; needs the extra Python wheels of `eval/requirements-heldout.txt` and Apple's `es-ES` speech model; skip with `--skip-heldout`). The reference texts, scored regions and the results quoted here are committed in `eval/heldout/`, so the numbers can be checked without the audio. To compare two runs of the same sets: `eval/scripts/compare_runs.py`.

The minutes tables alone: `eval/.venv/bin/python -I eval/scripts/run_minutes.py --bin .build/release/Vauta --seconds 180` for the
3-minute windows and `--seconds 600` for the 10-minute ones (`run_all.sh` runs both, tagged `<tag>-minutes180` and `<tag>-minutes600`).

The human gold of the minutes: `python3 -I eval/scripts/build_ami_gold.py --sets <the llm-eval AMI sets> --out <gold>`, then
`Vauta llm-eval --tasks minutes --sets <the same sets> --providers apple,integrated --extraction release --summary release --harness release
--open-questions release --out <run>` and `python3 -I eval/scripts/score_minutes_gold.py --gold <gold> --minutes apple=<run>/minutes/minutes.apple.jsonl
--minutes integrated=<run>/minutes/minutes.integrated.jsonl`.

`eval/run_all.sh` verifies every download against `eval/manifests/*.sha256.txt` (`eval/manifests/heldout/` for the held-out sets) and `eval/pins.json`, checks the generated reference
files against `eval/manifests/REFERENCES.sha256.txt`, and writes `environment.json`, per-file tables and `summary.json` / `wer.json`
under `eval/work/runs/<tag>/`. The audio built here is regenerated, not stored, and is not byte-identical to earlier internal builds of the same
recipe (the Opus encode and the rounding differ), so figures can move by a few tenths of a point between regenerations.

## Limits, in plain words

- **No real Spanish meeting, and nothing in other languages.** The Spanish figures are read and parliament speech (WER) and synthetic conversations (speaker separation). No suitably licensed public multi-speaker Spanish meeting corpus was found
  (CALLHOME Spanish, the MLC-SLM Spanish data and Albayzin diarization data need licence checks or requests). The synthetic conversations are probably easier than real ones ([Spanish](#spanish)). No other language was measured.
- **Simulated codec, not real calls.** The English sets have no packet loss, jitter, automatic gain control, echo, speakerphone or room acoustics (the call-impaired set adds crude simulations of some of them, [Spanish](#spanish)). Headsets are
  close-talk, easier than a laptop microphone in a room.
- **Small sets.** 18 tuning and 19 held-out English recordings for DER (the intervals above are wide: the held-out gain is between 0.5 and 3.7 points per file), 10 + 8 ten-minute windows for WER. One file (TS3003a, 176 s of remote speech) is an outlier at 46 % DER. Every AMI file has exactly three remote speakers, and the AMI dev meetings share the recording protocol of the tuning set.
- **No recording over 50 minutes with a real reference.** The two long runs are joined recordings of one team ([Long recordings](#long-recordings)).
- **The tuning set is in-sample.** The diarization threshold and the settings changed on 2026-10-11 were selected on this set, so its figures are in-sample. The held-out sets are out-of-sample for the app but not blind (the sweeps printed their figures), and not unseen by the models' own training ([What the change did](#what-the-2026-10-11-change-did)). The two halves above only show the spread between groups of files.
- **Live labels were not changed or re-measured.** The provisional speaker labels shown while recording follow other settings; the figures here are for the final result after the meeting.
- **Minutes quality, search and translation quality.** Minutes, Ask and Live Translation quality depend on the model you choose.
  For minutes this page reports only the mechanical citation checks of one model, Apple's on-device model, on 10 public AMI
  windows ([Minutes citations](#minutes-citations)), and where the minutes of Apple's model and the integrated model point against
  AMI's human summaries of 13 meetings ([Minutes against AMI's human summaries](#minutes-against-amis-human-summaries)), which
  scores the place an item cites, not its wording; the rubric scores (faithfulness, decisions, owners, coverage) have not been
  given. Search and translation quality are not benchmarked here.
- **Voice recognition across meetings** has its own calibration, written in [ARCHITECTURE.md](ARCHITECTURE.md) (search for
  "Calibration"); it was not re-run here and its data are not in the repository.

## Attribution

AMI Meeting Corpus (Carletta et al.) and VoxConverse (Chung et al.), both CC BY 4.0; Multilingual LibriSpeech (Pratap et al., Meta AI, CC BY 4.0) and VoxPopuli (Wang et al., Meta AI, CC0) for the Spanish sets (see [`eval/heldout/README.md`](../eval/heldout/README.md)); reference annotations from
`pyannote/AMI-diarization-setup` and `joonson/voxconverse` at the commits in [`eval/pins.json`](../eval/pins.json). Derived audio is not
redistributed; the VoxConverse audio is never redistributable (its copyright stays with the video owners).

## Post-meeting actions, Part B (links)

Method, series and gates: docs/ACTIONS.md. The tool is `llm-eval --tasks links`; the test series are fresh AMI clusters and Spanish council sessions not used before, the development series are the spent ones; gold and judge are independent sessions, sealed before unblinding; test is reported once. **Judged once on the test series (2026-10-25); no arm passed.** One independent model judge graded all 644 pooled pairs (38 same, 12 changes, 66 related, 528 none) from the transcripts, blind to the arms, and its grades were hashed before the key was opened. It agreed with the gold on 612 of 644 labels and on valid against not valid on 640 of 644 (kappa 0.96); the four disagreements are seeded pairs and none changes a shown pair. Series: 14; target meetings: 38 per backend. Intervals are 95% Wilson and **do not account for clustering by series or meeting**.

| Arm | G1 precision, natural (≥0.85) | G2 false links per target (≤0.3) | G3 natural recall (≥0.50) | G4 "changes" false positives (≤0.10) | G5 near-miss shown (≤10% of series) |
|---|---|---|---|---|---|
| Apple, model baseline (LBL) | 1/73 = 0.014 FAIL | 2.68 FAIL | 0.25 FAIL | 7/7 FAIL | 4/14 FAIL |
| Apple, keyword (LK0) | 0/1 FAIL | 0.053 pass | 0.00 FAIL | none shown | 1/14 pass |
| Apple, vector (LS0) | 0/1 FAIL | 0.053 pass | 0.00 FAIL | none shown | 0/14 pass |
| Apple, vector + check (LSA) | 0/1 FAIL | 0.026 pass | 0.00 FAIL | none shown | 0/14 pass |
| Integrated, model baseline (LBL) | 4/33 = 0.12 FAIL | 0.87 FAIL | 0.497 FAIL | 20/22 FAIL | 2/14 FAIL |
| Integrated, keyword (LK0) | 1/2 FAIL | 0.053 pass | 0.12 FAIL | none shown | 1/14 pass |
| Integrated, vector (LS0) | 1/1 (n=1, not evidence) | 0.026 pass | 0.12 FAIL | none shown | 0/14 pass |
| Integrated, vector + check (LSG) | none shown | 0 pass | 0.00 FAIL | none shown | 0/14 pass |

G1 and G3 fail for every arm on both backends, so **links are off for both**. Two things hold recall down: the minutes extracted both items of a seeded carry-over for only 24 of 76 pairs (Apple) and 14 of 76 (integrated), and the arms show very few links (1 to 11 per arm over 38 targets, 0 to 2 natural). Comparisons: vector against keyword (G7) is not significant (Apple seeded F1 0.51 against 0.07, p=0.0625; natural 0.00 against 0.00; integrated seeded 0.13 against 0.00, p=0.75), so the vector method is a direction, not a result. The model check (G8) did not help: Apple's LSA cut the seeded valid links from 9 to 1 and added a wrong "changes"; integrated LSG dropped its only natural true link and labelled a carry-over as a change; **LKA and LKG are not a measurement of the check** (it never ran after the keyword pass in that run; the app now runs it there, unmeasured). "Changes" suggestions: of the product arms' 6, 2 had the right relation and 1 stated a real difference (checked after unblinding), and none was natural, so G4 has n=0 for them; they are not shown on either backend.

Not measured: follow-up precision, recall and day accuracy (G9; no arm emits follow-up records), cross-language pairs (development only), a model server. Pass latency p90 (largest cluster) was 173 to 190 ms for the keyword pass on Apple and 93 to 98 ms on the integrated model's minutes; vector pass with check 2.4 to 3.9 s; the model baseline's call p90 was 9.6 s (Apple, 3 of 36 replies invalid JSON) and 9.1 s (integrated). Energy: the integrated check used 0.028 Wh over 52 meetings (3 calls), which is not a per-meeting figure. Timings of several runs overlapped other work on the shared Mac and are flagged in the run's `deterministic.json`. Replay checks passed (deterministic 28 of 28, ranked-out never linked 28 of 28, nothing while recording 4 of 4, dismissal and confirmation survive a rewrite on 2 clusters per backend); that dismissal check rewrites the items with the same words, and a rewrite that rewords them is reported apart (it can bring a pair back).

Limits: one LLM judge with no human review, and the gold labels were also model-assisted, and the judge was of the same model family that wrote the gold labels and the fixtures, so judge bias cannot be ruled out. A human spot-check of about 50 gold labels is pending. Recall is measured only against pairs of items the minutes extracted, and in the heavy low-cosine cells a per-cell upper bound allows far more hidden links than were estimated (about 246 on Apple against about 4 estimated, 72 against about 8 on the integrated model), so true recall could be well below the figures above.
