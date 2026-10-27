# Labelling rubric: questions heard in a meeting

You see one sentence of a meeting transcript, the lines around it (3 before, 2 after), the meeting's name and, for series, the earlier
meetings' names. You label the sentence. Two passes label independently (different seeds and order, no access to each other or to any
system's output); a third pass adjudicates the differences. A person spot-checks a sample of 50 sentences (25 per language); this check is pending.

Fill the `label` object of the pool line:

- `kind`:
  - `information`: it asks for a fact, a figure, a date, a name, a decision, or what was said or agreed, that notes, an earlier meeting
    or a document could hold.
  - `opinion`: it asks what people think or prefer. `request`: it asks someone to do something. `rhetorical`: the speaker does not expect
    an answer, or answers it in the next lines. `social`: greetings, checks of audio or screen, small talk. `not_question`: anything else
    (a statement, a tag, an exclamation, a fragment).
- `answerable` (only for `information`):
  - `so_far`: the answer is in this meeting before the sentence (give the segment ids in `gold_segments`);
  - `later`: it is only said after the sentence in this meeting;
  - `past_meeting`: it is in an earlier meeting of the series (give "meeting:segment" ids);
  - `document`: it is in a document of the set (give the file and place);
  - `none`: nowhere in the material.
- `answered_aloud`: true when one of the next two lines already gives the answer.
- `gold_answer`: one or two sentences, in the language of the question, written from the gold segments only, for every answerable one.
- `language`: the language code of the sentence itself (`en`, `es`, ...), so a question in a language other than the meeting's can be
  counted apart.

Rules: judge the sentence as a person in the meeting would; the transcript's punctuation is not evidence (a missing mark does not make a
sentence a statement, and a mark does not make it a question); a question rewritten by the next speaker counts once, on the first
phrasing that asks for the fact; when in doubt between `information` and `opinion`, choose `opinion`; never use information that is not in
the lines, the series meetings or the documents given. Do not look at any model output.

Agreement is reported as Cohen's kappa on `kind` and on `answerable` before the adjudication.
