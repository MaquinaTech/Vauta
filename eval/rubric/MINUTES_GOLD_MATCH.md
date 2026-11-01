# Blind matching: minutes against human summaries

How a judge matches the decisions and tasks of minutes with the decisions and actions of AMI's human summaries, for
[`score_minutes_gold.py`](../scripts/score_minutes_gold.py) `--matches`. The packets come from
[`gold_match_packets.py`](../scripts/gold_match_packets.py); this text is copied into them as `INSTRUCTIONS.md`.

`human.tsv` lists, per meeting, the decisions and actions that a human annotator wrote in the summary of an AMI meeting (a public
corpus of design meetings in English). `items.tsv` lists, per meeting, decisions and tasks that automatic minutes systems wrote for
the same meetings, mixed and shuffled; you are not told which system wrote which item and must not try to find out. Never open the
folder `sealed` next to this one.

For each row of `items.tsv`, read the item and the human sentences of the same meeting, and fill `states` with:

- the `human_id` of each human sentence whose content the item states, followed by `=full` or `=part`, separated by `;`
  (for example `ES2004b:decision.2=full;ES2004b:action.1=part`):
  - `full`: the item says what the sentence decides or assigns (the wording may differ);
  - `part`: the item states one of several decisions or actions the sentence lists, or the same decision or action with an
    important part missing;
- `none` when the item states no human sentence of its meeting.

Judge the content only:

- a topic, a point to discuss or a presentation that happened is not a decision or an action;
- an item that contradicts a sentence, or changes who does it or what was chosen, does not state it;
- a decision item may state a human action and a task item may state a human decision: mark what it states, whatever its kind.

Write the result as `items_graded.tsv` in this folder: the same rows and columns as `items.tsv`, in the same order, with `states`
filled for every row. Then write the SHA-256 of `items_graded.tsv` into `grades.sha256`.
