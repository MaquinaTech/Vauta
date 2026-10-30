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


def hyp_correct(ref, hyp):
    """For each hypothesis word (a list), whether an optimal Levenshtein alignment matches it to an equal reference word.
    Ties prefer a match, then a substitution, a deletion and an insertion, walking back from the end."""
    n, m = len(ref), len(hyp)
    cost = [list(range(m + 1))] + [[i] + [0] * m for i in range(1, n + 1)]
    for i in range(1, n + 1):
        prev, row, r = cost[i - 1], cost[i], ref[i - 1]
        for j in range(1, m + 1):
            row[j] = min(prev[j - 1] + (r != hyp[j - 1]), prev[j] + 1, row[j - 1] + 1)
    ok = [False] * m
    i, j = n, m
    while i > 0 and j > 0:
        c = cost[i][j]
        if ref[i - 1] == hyp[j - 1] and c == cost[i - 1][j - 1]:
            ok[j - 1] = True
            i, j = i - 1, j - 1
        elif c == cost[i - 1][j - 1] + 1:
            i, j = i - 1, j - 1
        elif c == cost[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return ok


def scored_tokens(words):
    """[(text, confidence)] of recognised words -> [(normalised token, confidence)]: a word that normalises to several
    tokens ("25%") gives each its confidence, one that normalises to none (a filler) is dropped."""
    return [(t, c) for w, c in words for t in normalize(w).split()]


def reliability(pairs, bins=10):
    """How well confidences predict that a word is right. `pairs` = [(confidence 0..1, correct)].
    ECE: the gap between mean confidence and accuracy, averaged over equal-width bins weighted by their words.
    Brier: mean squared gap per word. AUROC: the chance that a right word is scored above a wrong one (0.5 = no signal)."""
    n = len(pairs)
    if n == 0:
        return dict(words=0)
    table = []
    for b in range(bins):
        lo, hi = b / bins, (b + 1) / bins
        inside = [(c, ok) for c, ok in pairs if lo <= c < hi or (b == bins - 1 and c == 1.0)]
        if inside:
            table.append(dict(lo=lo, hi=hi, words=len(inside), confidence=sum(c for c, _ in inside) / len(inside),
                              accuracy=sum(ok for _, ok in inside) / len(inside)))
    ece = sum(row["words"] / n * abs(row["confidence"] - row["accuracy"]) for row in table)
    brier = sum((c - ok) ** 2 for c, ok in pairs) / n
    # AUROC by ranks (ties count half).
    ranked = sorted(pairs, key=lambda p: p[0])
    rank_sum, i = 0.0, 0
    while i < n:
        j = i
        while j < n and ranked[j][0] == ranked[i][0]:
            j += 1
        mean_rank = (i + 1 + j) / 2
        rank_sum += mean_rank * sum(ok for _, ok in ranked[i:j])
        i = j
    right = sum(ok for _, ok in pairs)
    wrong = n - right
    auroc = (rank_sum - right * (right + 1) / 2) / (right * wrong) if right and wrong else None
    return dict(words=n, accuracy=right / n, mean_confidence=sum(c for c, _ in pairs) / n, ece=ece, brier=brier, auroc=auroc, bins=table)


def wer(ref_text, hyp_text):
    r, h = normalize(ref_text).split(), normalize(hyp_text).split()
    s, d, i, n = align(r, h)
    return dict(sub=s, dele=d, ins=i, words=n, wer=100.0 * (s + d + i) / n if n else 0.0, hyp_words=len(h))
