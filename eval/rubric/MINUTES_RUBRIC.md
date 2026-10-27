# Minutes rubric

How minutes are judged in the evaluation. Scores are given per meeting by a human or by a judge model (named in the report);
the citation checks are mechanical and need no judge ([`score_minutes.py`](../scripts/score_minutes.py)). Use only public
transcripts (the AMI meetings of [`pins.json`](../pins.json)); never real meetings.

## Scored 0, 1 or 2 per criterion

| Criterion | 0 | 1 | 2 |
|---|---|---|---|
| **Faithfulness** | States something the transcript does not say, or reverses it | Everything is in the transcript, with small distortions (wrong emphasis, merged speakers) | Every statement is supported by the transcript as said |
| **Decisions** | Invents a decision, or misses most of the real ones | Finds the main decisions, misses or blurs some | Every clear decision, none invented |
| **Tasks and owners** | Tasks invented or the owner is wrong in most | Most tasks right; some owners missing or wrong | Tasks right, owner named only when the transcript says who |
| **Dates and figures** | A date or number that is not in the transcript | Right, but vague where the transcript was exact | Every date and number as said |
| **Coverage** | Most of the meeting's topics are missing | The main topics, not the secondary ones | Every topic that took real time |
| **Brevity** | Reads like the transcript, or too thin to use | Some padding | Short enough to read in a minute, nothing lost |

A fabricated fact caps the whole meeting at 0 for Faithfulness whatever the other items look like.

## Counted mechanically (no judge)

For every item of the minutes that cites a passage (`citations`, passage ids into the transcript):

- **Citation validity**: the cited passage exists and contains every figure (digits) the item states.
- **Unconfirmed share**: the part of the items the app marks "Unconfirmed" (it does so when its own checks fail).
- **Uncited share**: items with no citation at all.

## What a report must say

The model (name and exact revision), the number of meetings, the transcript source (manual or Apple's recogniser), the date,
the commit, each criterion's mean and the mechanical rates, and which meetings were judged by whom.
