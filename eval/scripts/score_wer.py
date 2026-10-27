# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Word error rate: text normalisation and edit-distance alignment (standard library only).

  WER = (substitutions + deletions + insertions) / words in the normalised reference.

Normalisation, applied to both the reference and the recogniser output so that spelling conventions are not scored:
  - Unicode NFKC, lower case, typographic apostrophes to ', hyphens and other punctuation to spaces (apostrophes stay);
  - digits to English words ("3" -> "three", "25%" -> "twenty five percent", "3.5" -> "three point five"), "&" -> "and";
  - hesitations and back-channel sounds removed from both sides (um, uh, uhm, er, erm, ah, eh, hmm, hm, mm, mmm, mhm, huh);
  - "ok" -> "okay".
The reference additionally drops word fragments that AMI marks as truncated. Nothing else is mapped (no spelling
variants, compounds or contractions), so the figure is a little pessimistic.
"""
import re
import unicodedata

FILLERS = {"um", "umm", "uh", "uhm", "er", "erm", "ah", "eh", "hmm", "hm", "mm", "mmm", "mhm", "huh"}

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def number_words(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000:
        return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + number_words(n % 100))
    if n < 1_000_000:
        return number_words(n // 1000) + " thousand" + ("" if n % 1000 == 0 else " " + number_words(n % 1000))
    return " ".join(ONES[int(d)] for d in str(n))  # very large numbers: digit by digit


def normalize(text):
    t = unicodedata.normalize("NFKC", text).lower().replace("’", "'").replace("‘", "'")
    t = t.replace("%", " percent ").replace("&", " and ")
    t = re.sub(r"(\d),(\d{3})", r"\1\2", t)
    t = re.sub(r"(\d+)\.(\d+)", lambda m: f"{m.group(1)} point {' '.join(m.group(2))}", t)
    t = re.sub(r"[^a-z0-9']+", " ", t)
    out = []
    for w in t.split():
        w = w.strip("'")
        if not w or w in FILLERS:
            continue
        if w.isdigit():
            out.extend(number_words(int(w)).split())
        else:
            out.append("okay" if w == "ok" else w)
    return " ".join(out)


def align(ref, hyp):
    """Levenshtein alignment of two word lists -> (substitutions, deletions, insertions, reference length)."""
    n, m = len(ref), len(hyp)
    # Each cell keeps (cost, S, D, I) so the split of the errors comes out of the same optimal path.
    prev = [(j, 0, 0, j) for j in range(m + 1)]
    for i in range(1, n + 1):
        cur = [(i, 0, i, 0)]
        for j in range(1, m + 1):
            c, s, d, ins = prev[j - 1]
            best = (c, s, d, ins) if ref[i - 1] == hyp[j - 1] else (c + 1, s + 1, d, ins)
            c, s, d, ins = prev[j]
            if c + 1 < best[0]:
                best = (c + 1, s, d + 1, ins)
            c, s, d, ins = cur[j - 1]
            if c + 1 < best[0]:
                best = (c + 1, s, d, ins + 1)
            cur.append(best)
        prev = cur
    _, s, d, ins = prev[m]
    return s, d, ins, n


def wer(ref_text, hyp_text):
    r, h = normalize(ref_text).split(), normalize(hyp_text).split()
    s, d, i, n = align(r, h)
    return dict(sub=s, dele=d, ins=i, words=n, wer=100.0 * (s + d + i) / n if n else 0.0, hyp_words=len(h))
