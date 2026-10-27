# Blind rubric: live answers (A/B)

For each case you see: the meeting transcript UP TO the question moment only (segments numbered, speaker-labelled), the question,
the gold answer and gold supporting segment ids (written by the authors), and two answers "A" and "B" rendered by one neutral
renderer (citations shown as the cited transcript text, not ids). You do not know which system wrote which.

1. Label each answer with exactly one:
   - correct: states what the gold answer states (extra correct detail is fine; paraphrase is fine; numbers and names must match).
   - partial: right in part, or right but missing a key element of the gold answer.
   - wrong: answers the question but with a wrong fact.
   - hallucinated: asserts specific content that the visible transcript does not support (invented name, number, decision) when the gold says there is none, or adds invented specifics to an otherwise right answer.
   - false_refusal: says the information is not available when the gold shows it is.
   - correct_refusal: (unanswerable cases only) says the transcript so far does not contain it, without inventing.
   For unanswerable cases, any confident specific answer is hallucinated. A refusal that adds a speculative guess presented as fact is hallucinated; a refusal with a clearly marked hedge ("not stated; possibly...") is correct_refusal.
2. Citations: list for each answer the cited transcript segments (shown as text). Mark each cited segment as supporting, partly supporting, or not supporting the claim it is attached to.
   Mechanical metrics are computed afterwards from the gold ids and from a substring check against the transcript: citation precision (supporting / cited), recall (gold segments cited / gold segments), and the app's verified-claim rate.
3. Information visible after the question moment must not be rewarded: if an answer states something that is only said later in the meeting, label it hallucinated and flag "leak".
4. Cross-language cases: the answer language should follow the question; judge content only, note if the language was wrong.
5. Preference A, B or tie, confidence 1 to 3.

Output (JSON): {"case": "<qid>", "A": {"label": "...", "cites": [{"seg_text": "...", "support": "yes|part|no"}], "leak": false},
"B": {...}, "preference": "A|B|tie", "confidence": 1, "notes": "<=40 words"}

Aggregation (done by the harness, not the judge): correct rate, correct+partial rate, hallucination rate overall and on unanswerables,
false-refusal rate, citation precision and recall, paired bootstrap over meetings for the Gemma-minus-Apple difference.
