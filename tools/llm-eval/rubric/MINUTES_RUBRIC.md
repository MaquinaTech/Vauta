# Blind rubric: meeting minutes (A/B, Apple on-device vs integrated Gemma 4 E4B)

You compare two sets of minutes, "A" and "B", for the SAME meeting. You do not know which system wrote which. Both are rendered
by one neutral renderer (same Markdown, segment ids hidden), so ignore style, length of wording and formatting. You see the
transcript (speaker-labelled, numbered), the rubric, and the two minutes. You never see timings, traces or system names.

Score each of A and B independently, 0 to 2 per criterion, total 0 to 12. Write one line of evidence per criterion.

| # | Criterion | 0 | 1 | 2 |
|---|---|---|---|---|
| C1 | Decisions: completeness | Misses most real decisions, or lists none where the meeting made some | Captures about half of the clear decisions | Captures nearly all clear decisions, none merged into vagueness |
| C2 | Tasks and owners: completeness and correctness | Misses most tasks, or owners are mostly wrong or invented | Some tasks missing, or about a quarter of owners/due dates wrong | Nearly all assigned tasks present with the right owner; due dates only when the speakers gave one |
| C3 | Faithfulness | Contains an invented fact (a number, name, date, decision or task nobody said) | Only wording that goes slightly beyond the text (over-strong verb, merged claims), no invented fact | Every statement is supported by the transcript |
| C4 | Summary and topics | Misleading, or misses the main thread of the meeting | Correct but generic, or misses one major topic | Accurately covers the main topics in proportion to the time spent on them |
| C5 | Open questions and follow-ups | Invents open questions, or ignores clear unresolved issues | Some real open items, some missed or weak | Real unresolved items, none invented |
| C6 | Usefulness | Someone who missed the meeting would be misled or lost | Usable with effort; noise or repetition | A reader could act on it without reading the transcript; concise, no filler |

Caps and rules
1. Fabricated-fact cap: any invented fact (C3 = 0) caps the TOTAL at 6 for that system. Say which statement is invented and why (quote the line).
2. Due dates: a due date that merely repeats the meeting date, or is computed from "today" without the speakers having said a date or weekday, counts as invented (C3 = 0) and also lowers C2 by one point (floor 0).
3. Owner labels: in AMI transcripts the speaker label ("Speaker 3 (remote)") is the only identity. An owner must match the speaker who accepted the task; naming the wrong speaker is a wrong owner.
4. Language: minutes in a language other than the transcript's are judged only on content; mention it, do not penalise.
5. Do not reward length. Two short correct items beat five items with one error.
6. Ties are allowed. Also give an overall preference: A, B, or tie, and a confidence 1 to 3.

Output (JSON, one object per case)
```json
{"case": "<id>", "A": {"C1":0,"C2":0,"C3":0,"C4":0,"C5":0,"C6":0,"invented":["quote"],"total":0},
 "B": {"C1":0,"C2":0,"C3":0,"C4":0,"C5":0,"C6":0,"invented":[],"total":0},
 "preference": "A|B|tie", "confidence": 1, "notes": "<=40 words"}
```

Reliability of judging
- LLM judge: 100% of cases, named with version in the report; never Gemma 4 and never Apple's model.
- Human (maintainer), planned and not yet done: stratified 25%, chosen before unblinding. Report quadratic-weighted kappa on the 0 to 12 totals; adjudicate gaps of more than 2 points.
- Position is randomised per case; the key is sealed and its sha256 committed before judging.
