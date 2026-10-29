# Language-model A/B tools (developer-side, never shipped)

`Vauta llm-eval` compares Apple's on-device model with the integrated Gemma 4 E4B on minutes and live answers (a hidden command;
see docs/LANGUAGE_MODEL.md). This folder holds what runs around it. Nothing here reads a person's data: the sets are public or approved
transcripts, the audio and transcripts are never committed, and the model server is never contacted.

| File | What it does |
|---|---|
| `probe.py` | While a run goes, once a second: load averages, GPU "Device Utilization %", memory, thermal state, and for every process of the user the CPU time and energy deltas from `proc_pid_rusage` (public, sudo-less): the sum and top few of the OTHER processes (the shared-Mac context) and the watched pids. It only reads counters. `--ioreport` adds the chip-level watts below. |
| `ioreport_energy.py` | The IOReport "Energy Model" group (what `macmon` reads, no sudo): watts of CPU, GPU, ANE and DRAM per interval. Chip-level, so it includes every process (it is load-annotated: the probe says how much was foreign). Chip GPU energy is the primary figure for GPU work (the integrated model runs on the GPU, where `ri_energy_nj` sees nothing). **On macOS 27.0.1, as a non-root process, the CPU, DRAM and ANE channels never change (checked under a 4-core burn); only GPU Energy moves.** The sampler reports such channels as frozen instead of as 0 W. IOReport is a private framework: this is a developer tool, the app's source scan forbids the name in the language-model code. |
| `aggregate.py` | Summarises a `llm-eval` output folder (and a probe file): per task and load bucket the within-pair ratios (ABAB), JSON validity (with its 95% Wilson interval), retries, own-process CPU and energy, kept/dropped items, verified-claim and citation rates, chip-level energy when the probe has it. No quality judgement. |
| `stats.py` | The statistics of the gates (standard library only): Wilson intervals, the exact sign and McNemar tests, the meeting-cluster bootstrap (5,000 resamples, seed 1), Cohen's and quadratic-weighted kappa, the Jeffreys posterior of a rate with P(rate ≥ gate) (also with the meetings' design effect), paired TOST against a margin fixed before the run and its power, Holm and Benjamini-Hochberg adjustments, and the spread of an arm over repeated runs. The reports import it; a gate is published as the estimate, its interval and P(≥ gate). Tests: `python3 -I -m unittest discover -s eval/tests -p 'test_stats.py'`. |
| `rubric/` | The blind-judging rubrics (minutes, live answers). |
| `data/` | The scripts that built the evaluation sets: `build_ami_long.py` (AMI manual transcripts with speakers, 29.5 to 60 minutes), `dl_one.sh`, `fetch_es.py`, `make_es_windows.py` (cut, transcribe and diarize with Vauta's own CLI), `compile_questions.py` (validates and freezes the question file), `build_stress.py`, `count_tokens.py`, `make_blind_packets.py` (two providers' results rendered by one neutral renderer, A/B randomised, key sealed with a SHA-256 to commit before judging), `make_manifest.py`, `show.py`. They expect a working folder with `src/`, `data/`, `audio/` and `build/` next to `scripts/` (see below). |

## Minutes and live-answer flags

`Vauta llm-eval` takes three more options (hidden, evaluation only; the integrated model comes from `VAUTA_LLM_MODEL_DIR`):

| Option | What it does |
|---|---|
| `--arms a0\|a1\|a2\|a3` or a list of `streaming`, `recall`, `items` | Which parts of the integrated minutes are on. A0 is the original behaviour (standard layout, no recall wording, one call). A1 is the streaming layout plus the recall definitions. A2 is the streaming layout plus the second pass over each stretch of the meeting. A3 is all of them (the app). |
| `--guard none\|g1\|g2\|g1+g2` | Which guards of a live answer are on: the three-way `found` (G1) and the check of the quoted lines against the moment of the question (G2). |
| `--warm` (or `--replay-realtime`) | Replays each meeting as a recording: the integrated model reads the transcript as the segments arrive (a reading every ~600 characters, the way the app does), and the minutes or the question read only what came after. The traces carry `warmSeconds` and the prefix reuse. |

The minutes run stores the speakers of the transcript as speakers of the meeting (as after a real recording) instead of writing "Speaker 3 (remote):" in front of each line, so owners can be measured. Each call in `traces.jsonl` has a `breakdown` (`tokenizeSeconds`, `slotWaitSeconds`, `gateWaitSeconds`, `newPrefillTokens`, `prefillChunks`, `prefillSeconds`) next to the time to the first token.

## Live answers to questions heard in the meeting

`Vauta llm-eval --tasks live-questions` replays the final lines of the public transcripts through the same code the app runs while recording (cue scoring, the four-second settle, duplicates and rate limits, the evidence check, the model check, the answer and the card rules) on a **simulated clock**: lines arrive when they end, the model calls are real and their measured duration is added to the simulated time, one at a time as the lane runs them. The earlier meetings of a series (ES2004b before ES2004c; `cdm191218_a` before `_b`) are inserted as past meetings of the replayed one; documents are not part of the replay (the sets have no document corpus). It writes `traces.jsonl` like the other tasks and, per candidate sentence, `questions/questions.<provider>.jsonl`.

| Option | What it does |
|---|---|
| `--sensitivity low\|standard\|high` | The cue threshold (0.80, 0.50, 0.35). |
| `--no-check` | V0 of the design: no model check; the candidates that pass the evidence check go straight to the answer with their original words. |
| `--keep-answered-aloud` | Turns off the suppression of questions the next lines already answer. |
| `--sources this,past,docs` | Which sources the replay looks in (default `this,past`). |
| `--detect-only` | Cues and evidence check only: no model, no energy; outcomes `no_evidence` or `evidence`. |
| `--no-detection` | The lines are stored and the integrated model reads them as they come, but no detection stage runs (the arm "off" of the warm first-token comparison). |
| `--closing-probe` | After the last line, one question is asked of the meeting with the live rules and the kept prefix; the trace's `closingTTFTSeconds` is the time to its first token. Run it with and without `--no-detection`, same meetings, alternating the order, to see what detection costs a warm call. |
| `--sentences <file>` | Writes every sentence of every transcript with its cue score and the lines around it, then stops: the pool the labelling draws from. |

| File | What it does |
|---|---|
| `data/build_question_pool.py` | From the sentences file: every sentence with a question mark, every sentence with a score of 0.2 or more, a random 10% of the rest; meetings split 40% development and 60% test by a hash of their name; writes `pool.dev.jsonl`, `pool.test.jsonl` and a manifest with their SHA-256. It labels nothing. |
| `rubric/QUESTION_LABEL_RUBRIC.md` | What the labelling passes fill in (kind, answerable from where, answered aloud, gold answer and segments, language). |
| `questions_report.py` | Precision and recall of the cues against `kind == information`, what reaches the answer, coverage of the answerable questions, false cards per hour, latency and calls per hour, from the labels and the run files. Without labels it prints the counts that need none. |

The labelling passes (two blind passes and an adjudication, kappa on `kind` and `answerable`) were done, all by model passes with no human review; the 50-sentence sample (25 English, 25 Spanish) for a human spot check is prepared and not yet checked: see `docs/LANGUAGE_MODEL.md`, "Live answers".

## Pre-meeting brief

`Vauta llm-eval --tasks brief --sets <transcripts> --brief-fixtures <folder of *.brief.json> --out <dir>` builds the brief of the meeting
that follows the `earlier` ones of each fixture with the app's own brief code (docs/BRIEF.md), in a throwaway store, and writes
`briefs/briefs.jsonl`, one rendered text per series and arm (`briefs/<series>.<arm>.txt`, nothing that names the arm), `fixtures.sha256`
and the traces. Options: `--brief-arms K0,S0,KA,SA,KG,SG,BL[,BLG]` (S arms need `--search-model`, KG/SG need the integrated model),
`--brief-split dev|test`, `--brief-minutes-apple` and `--brief-minutes-integrated` (the `minutes_<provider>.jsonl` of the minutes runs;
the arms use the minutes of their own backend, and the arms without a model use the integrated ones). The fixtures are synthetic and
written blind to the briefed meeting's gold; the briefed meeting's transcript is never read. The blind judge's rubric and packets are
built outside this tool.

## Post-meeting actions

`Vauta llm-eval --tasks actions --sets <transcripts> --out <dir>` runs Part A of the post-meeting actions over public transcripts, in a throwaway
store, and never touches EventKit (every write goes to `FakeActionWriter`). Options: `--actions-arms ET1,ETO,EBL,FD,FDX,FBL,RP`,
`--actions-minutes-apple` and `--actions-minutes-integrated` (the `minutes_<provider>.jsonl` of the minutes runs; the email arms and the replay need
them), `--actions-fixtures <folder of <meeting>.actions.json>` (invented attendees at `example.org`, who "Speaker 2" is, closing lines that name the
next meeting, reminders already in the list; hashed into `fixtures.sha256`; written blind to the detector's word lists). Arms: `ET1` one email and
`ETO` one per owner, from the stored minutes; `EBL` the same backend writing the email with no template and no verifier; `FD` the follow-up detector as
the app runs it (last tenth of the transcript, plus tasks), `FDX` the detector reading every segment, `FBL` the backend extracting the next meeting;
`RP` the replay of the duplicate, due-day, crash and undo scenarios (counts in `replay.jsonl`; a failed check is an error in the trace). Outputs carry
blind labels: `emails/<meeting>.<label>.txt`, `followups/<meeting>.<label>.json`, `sealed/key.json` (labels to arms) and its SHA-256. The model arms
(`EBL`, `FBL`) run on Apple's model and the integrated model only, never on a model server.

## Method on a shared Mac

Another session may be using the CPU, GPU and RAM. For every speed, latency, resource or energy figure: record the context with it
(`probe.py`); prefer a quiet window (`llm-eval --quiet-wait`: load1 < 4, no other process of the user above 50% of a core, GPU below
10%, bounded wait, each trace says whether it was met); run the two providers interleaved item by item (ABAB); take GPU energy from the
chip-level IOReport figure (primary for GPU work, with the foreign load next to it) and CPU time and CPU energy per process
(`ri_energy_nj`, CPU only: the secondary figure); and say which absolute numbers were taken under foreign load.
Quality counts are unaffected by load.

## The sets (2026-10-12)

- **English**: 22 AMI meetings of 29.5 to 60 minutes (AMI manual transcripts 1.6.2, CC BY 4.0; 13 of the pinned `test` list, 9 of `dev`),
  6.6k to 18.1k Gemma tokens. Use `dev` only for a pilot (sampler, context, quote constraint).
- **Spanish (real meetings)**: 17 windows of 41 to 45 minutes cut from 10 sessions of the Concejo Deliberante de Capilla del Monte
  (Cordoba, Argentina), recordings published on archive.org. **Licences**: each item page declares a Creative Commons
  licence, recorded with the URL, the page, the size, the SHA-256 and the archive.org SHA-1 in the manifest: CC BY 4.0 for six items
  (`sesionextraordinaria…18diciembre2019`, `concejodeliberante211119`, `sesiondelconcejodeliberante241019`, `SesinDelConcejo…120619…`,
  `AudioConcejoDeliberante251018`, `comisionconcejodeliberantetemavillacielo`) and CC BY-SA 4.0 for four (`concejodeliberante290819`,
  `concejo-deliberante-capilla-del-monte-sesion-25-06-20`, `concejo-deliberante-03-09-20`, `debate-concejo-deliberante-emergencia-economica`),
  uploaded by the municipality's news account. BY needs attribution; BY-SA would also need the cuts and transcripts to be shared under
  BY-SA if they were ever distributed. They are used internally only and are not committed. The design asked for Madrid assembly
  committees; no downloadable recording with verified reuse terms was found, so this set is a **deviation from the design**: Argentine Spanish (River Plate accent), one municipality, a formal-political register, two meeting types. The transcripts
  contain names of councillors and of private people (a petition, an employee questioned in the session); questions were written with
  roles wherever possible.
- **Live-answer questions**: 158 (plus 37 for the 135-minute concatenation), each asked right after a segment (only earlier segments are
  visible), 17.7% unanswerable. Frozen with a SHA-256 before any run. Written by one author and validated mechanically (gold segments
  exist and precede the question; a quoted evidence string appears in the cited segment); the design's two-author adjudication is not done.

## Gaps

The sets above were not judged when they were built: the blind packets exist (sealed keys), and the judge must be neither of the compared
models. Judged results, where they exist, are in docs/LANGUAGE_MODEL.md and docs/BENCHMARKS.md. The pilot (greedy against card sampling, one pass against forced map-reduce, the quote constraint) needs those scores.
Windows of one session are not independent: use sessions (10) as the unit for Spanish and meetings (22) for English. Nothing reaches 60k
tokens; only the concatenated stress file reaches 30k.

## `--tasks links`

`Vauta llm-eval --tasks links --sets <transcripts> --links-series <series.json> --out <dir> [--links-arms LK0,LS0,LKA,LSA,LKG,LSG,LBL,LS0R,POOL,RP] [--links-minutes-apple <minutes_apple.jsonl>] [--links-minutes-integrated <minutes_integrated.jsonl>] [--links-fixtures <folder of *.links.json>] [--links-split dev|test] [--search-model <install dir>] --providers apple,integrated`
 `LS0R` is development only: the run refuses it when the split is `test` or a chosen cluster is a test cluster. Every arm, the model baseline included, writes the same blind columns; method and score go to `links/sealed/`. The baseline loads the integrated model only when `--providers` includes `integrated`.
Hidden, evaluation only. `series.json`: `{"clusters":[{"id","language","split","attendees":[..],"meetings":[{"name","date"}]}]}` (meetings in order, names are files of `--sets`; a missing date is a week after the previous one). Produce the minutes with `--tasks minutes --extraction release --summary release --harness release --open-questions release`, earlier meetings first. Each cluster and arm runs in a throwaway store through the real job queue; outputs: `links/<cluster>.<label>.tsv` (shown pairs: relation, both texts, evidence; no method or score, so a grader cannot tell the arm family) and `links/sealed/<cluster>.<label>.tsv` (the same pairs with method and score, not for graders), `pool/<cluster>.<provider>.tsv` (every same-series pair with cosine and keyword bands, no arm names), `traces.jsonl` (timings, pass counts, model calls), `replay.jsonl` (RP), `fixtures.sha256`, `sealed/key.json` and its hash. LS arms need `--search-model`; LS0R is development only; there is no server arm.
