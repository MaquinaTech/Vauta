# Task owners with and without speakers: offline evaluation

What this page measures, how, and what it does not prove. The numbers come from
`Tests/VautaCoreTests/OwnerAccuracyEvalTests.swift`, which fails if they change without this page changing.

## What it is

Fifteen invented meetings in nine languages (English, Spanish, French, German, Italian, Brazilian Portuguese, Japanese,
Korean, Chinese; English three times, Spanish, French, German and Japanese twice) with 56 tasks whose owner is known. Each meeting is run
three times through the real minutes pipeline (prompt, validation, owner rules, verification, storage):

- **Me / Others.** No speaker data. The prompt labels lines "Me" and "Others". The meeting is run through the
  **current** pipeline and the **current** system prompt, not through the code of a version from before speakers existed.
  The recorded answers are what a model plausibly says when it only sees "Me" and "Others": it often names an
  attendee for an "Others" commitment that the words do not name (15 wrong owners, for example "I'll chase legal"
  given to Ana). **That contradicts the current system prompt**, which tells the model to leave the owner empty when
  neither a label without "?" nor the segment itself names it. So this arm is a model that ignores that instruction.
- **Me / Others, careful.** The same prompt, with the answers of a model that follows the instruction: the recorded answers
  of the arm above, with every owner removed that is neither "Me" on a line the prompt labels "Me" nor named in the words of
  the line (derived mechanically in the test, from the label the prompt shows and nothing else). A model that sees only
  "Me" and "Others" cannot tell an unnamed second voice on the user's microphone from the user, so it keeps "Me" there
  too: that is the one wrong owner of this arm. It is the lower bound of what a careful model does without labels.
- **With speakers.** Every line carries its speaker label (`Ana (remote)`, `Speaker 2 (remote)`, `Me 2 (in the room)`,
  a `?` after a label the diarizer is unsure about), and the owner rules and checks below are active.

The owner check of the minutes (an owner who is not the user on their own channel, not a confidently labeled speaker and
not named in the words is marked "not confirmed") runs in every arm, with or without speaker data.

## What it is not

**No language model runs.** The model's answers are recorded in the fixtures, written by hand to be what a model would
plausibly answer to each prompt. The percentage points between the arms that come from those recorded answers are
therefore an assumption built into the fixtures, **not a measurement of any model**. The assertions
`speakers.accuracy > baseline.accuracy` and `speakers.wrong < baseline.wrong` are consistency checks of the fixtures
with the code, not evidence: the gap in the first arm is inflated by design, and the careful arm shows how much of it
disappears when the model does what its prompt says. What the evaluation does measure is the code: that the labels reach
the prompt, that Swift fixes, refuses or marks owners the way the rules say, and that nothing breaks across scripts and
languages. Do not quote these numbers as the accuracy of Vauta. A real measurement needs real model answers on
consented meetings, and that is a separate, later evaluation.

## Result

| Arm | Owner correct | Wrong person | No owner | Owners marked "not confirmed" |
|---|---|---|---|---|
| Me / Others (recorded answers that ignore the prompt) | 25/56 | 15 wrong | 16 | 15 (14 of them wrong) |
| Me / Others, careful (unsure = no owner) | 26/56 | 1 wrong | 29 | 0 |
| With speakers, recorded answers as written | 47/56 | not applicable | not applicable | not applicable |
| With speakers, after the rules of Swift | 48/56 | 5 wrong | 3 | 3 (all 3 wrong) |

Effect of the rules of Swift on the speakers arm, line by line: **+3 fixed, -2 withheld**, net +1; 2 more wrong
owners became "no owner".

- **+3 fixed.** Two come from the rule "a confident speaker who says what they will do owns the task the model left
  open" (one line in each of the two German meetings, where the model gave no owner). One comes from the room-voice rule: a second voice on
  the user's microphone that nobody named is not "Me".
- **When the model names somebody else, the rules do not replace it.** A line can hold two actions ("You handle the
  invoices and I'll send the deck"), so when the model's owner differs from the confident speaker of a commitment and the
  words do not name that owner, the owner stays and is marked. Two recorded answers that name the wrong person for a
  confident speaker's commitment are kept for that reason: they count as wrong, and the interface marks them.
- **The doubtful-label rule fired on 3 lines**: it withheld 2 correct owners (-2 withheld; labels of 0.45 and in
  crosstalk) and prevented 1 wrong owner (the Spanish line the diarizer put on the wrong person at 0.40). Within these
  fixtures it is a net loss of one owner. It is kept because it is a requirement of the design (a label the system
  is unsure about never gives a task to anyone), not because the evaluation shows a gain. The other wrong owner that
  became "no owner" comes from a different rule (a person the meeting does not have).

The 5 wrong owners with speakers: **3 are marked** in the interface (two are the model's owner against a confident
speaker's commitment, one is an owner the transcript does not support), and **2 are confidently wrong labels**: in two
meetings (English and Spanish) the diarizer attributes a commitment to the wrong person with a confidence of 0.85 and
0.88, above the threshold. The model follows the label it is shown, Swift trusts a confident label, and the owner is
wrong and not marked. Without speakers the model leaves those two tasks open, so on those lines the speakers arm is
worse than the baseline.

A change of 2026-10-14 moved one number of the first arm: the owner "Me" now needs a line of the user's own voice behind the task (rule
`task.ownerMeUnbacked`), so one recorded "Me" owner on a line nobody in the room spoke became "no owner" (16 wrong to 15, 15
without an owner to 16). The speakers arm and the careful arm did not move.

## The extraction of the development phase (owner from the transcript)

The same recorded answers, played through the extraction of the phase "fix tasks, decisions and owners" (`MinutesExtraction.shipped`,
`OwnerInference`, `ItemEvidence`; method in [LANGUAGE_MODEL.md](LANGUAGE_MODEL.md#tasks-decisions-and-owners-in-the-minutes-development-phase)).
The model's label is a hint and no longer the answer: the owner comes from the clause that holds the quote and the lines around it
(self-commitment, the person asked who accepts, a volunteer, a name used as the addressee), and a speaker label that is doubtful,
a role ("the Industrial Designer will…") or a group ("we should…") gives nobody. `OwnerAccuracyEvalTests` runs both extractions;
the first table above is the old one and is unchanged.

| Arm | Owner correct | Wrong person | No owner | Owners marked "not confirmed" | Gold tasks marked "to be confirmed" |
|---|---|---|---|---|---|
| Me / Others (recorded answers that ignore the prompt) | 26/56 | 1 wrong | 29 | 2 (0 of them wrong) | 1 of 56 |
| With speakers | 51/56 | 2 wrong | 3 | 1 (0 of them wrong) | 1 of 56 |

With speakers: against the old rules **48/56 → 51/56** correct and **5 → 2 wrong**; against the model's recorded answer the rules
changed 8 owners: 6 fixed, 2 withheld, none broken. On the Me / Others arm the 15 wrong owners the recorded answers had became 1 (an unnamed second voice
on the user's microphone is still the user's channel). The one gold task marked "to be confirmed" is "We should also run the customer
survey": a group suggestion with nobody charged, which is the intended reading. Verification still catches 4/4 planted errors.
The fixtures are invented, the cues were tuned on them (a regression check, not an accuracy figure for real speech), and they were written before the rules: before the last round of cues, 17 of the 56 gold tasks were marked, mostly
requests to a person by name ("Ana, can you…?") with no answer in the fixture and first-person statements without a "will"
("Yo preparo el informe", "Io organizzo la riunione"); the cues for those were added from this page, so these 56 are no longer an
unseen test of the cue lists. The development meetings of LANGUAGE_MODEL.md are the measurement.

## What the 0 became

An earlier version of this page reported 0 wrong owners. That was true by construction: every label at or above the
threshold named the true speaker. Real diarization is not perfect (its error rate on a real room is worse than on
benchmarks), and nothing in the code can recover from a wrong label of high confidence. The fixtures now include such
lines, and the wrong owners are reported. Lines at or above the threshold are still assumed correct in 71 of 73
confident, non-overlapping lines in the fixtures; real errors at high confidence would become wrong owners exactly as
the two here did. A request ("Ana, send the deck and I'll review it") is never taken as the speaker's own commitment
when the words name another person of the meeting, whether the model named them or left the owner empty.

## Verification

Four tasks that look right but plant a wrong figure (5,000 written as 50,000; 12 as 120), a date (Monday for
"Friday") or a name (Hugo for Camille) were mixed in: **4/4 are marked "unconfirmed"**, with **0/56** false alarms among
the 56 faithful tasks (all 56 were stored; a task the pipeline dropped would be counted on its own, not as "no false alarm").
The check compares digits, calendar dates and names literally against the cited segment; it
does not read meaning, so a paraphrase that changes a number into words is marked too. Marked items stay in the
minutes: the user decides, and can clear a mark with "Mark as Checked".

The checks are meant to be strict about what the segment says and lenient about how it is said, and the 56 tasks above
are not enough to show that, so `FaithfulPhrasingTests` runs further faithful tasks through the same validation: "next
Friday" and its equivalents in five languages (ten days from a Tuesday), "in two weeks" in three, names that are also
everyday words ("mark the invoices", Spanish "al", "will", "may"), and figures written in kanji or digits. None is marked.
A name counts as written in a task only with its own capitals, so the everyday word is not taken for a person. The limit
that remains: a task that starts with a word equal to a known person's name ("Mark the invoices as paid") and whose
segment does not contain that word is still marked "unconfirmed"; the user clears it with one click.

## Links: the spot-check of the gold

When the links gold is sealed, a stratified packet of about 50 labels (same, changes, none; both languages) is prepared for a human reviewer (about 30 minutes). Agreement under 85% means the gold is redone. The Part B ship decision waits for this check.
