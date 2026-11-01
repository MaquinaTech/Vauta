# Blind grading: does the transcript support each item?

How a judge grades the decisions and tasks of minutes against the transcript around the passage each one cites, for
[`item_support.py`](../scripts/item_support.py) `score`. The packets come from `item_support.py packets`; this text is copied
into them as `INSTRUCTIONS.md`.

`items.md` lists, per meeting, decisions and tasks that automatic minutes systems wrote, mixed and shuffled under neutral ids;
you are not told which system wrote which item and must not try to find out. Never open a folder named `sealed`. Under each item
are the passages of the transcript around the one it cites, numbered as in the meeting; the cited passage is marked `►`. The
transcripts are public meetings (AMI, in English).

For each row of `grades.tsv`, fill `support` with one word:

- `yes`: the passages say it. For a decision, the group settled the point: agreed, chose, approved, rejected, postponed or
  assigned it. For a task, someone will do it after this point of the meeting. A stated owner or due date must be the one said.
- `weak`: the passages say something like it, but the item goes beyond them: a proposal, an opinion or a question written as a
  decision; a wish or a suggestion written as a task; a wrong owner, date or figure; two points merged into one.
- `no`: the passages do not say it, say the opposite, or it is not a decision or a task at all (a topic, a presentation that
  happened, a fact someone reported).

Judge only what the passages show; do not reward or punish wording or length. When the passages are not enough to tell, choose
`weak`, and say why in `note` (at most 15 words). A `note` is optional otherwise.

Write the result as `grades.tsv` in this folder (the same rows and columns, in the same order, `support` filled for every row),
then write the SHA-256 of `grades.tsv` into `grades.sha256`.
