# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Speaker-attributed word error rates of a meeting transcript (standard library only).

A word is (speaker, start, end, text). Both sides are normalised as in score_wer.py (a word can become several tokens,
which keep its times). With R reference speakers and H hypothesis speakers (a hypothesis word with no speaker is the
speaker None, one stream like any other):

  cpWER   concatenated minimum-permutation WER (CHiME-6). Each reference speaker's tokens, in time order, against those of
          the hypothesis speaker assigned to them, with the assignment that gives the fewest errors in total (Hungarian,
          over max(R, H) slots padded with empty speakers): a hypothesis speaker left without a reference speaker counts
          its tokens as insertions, a reference speaker left without one as deletions.
  tcpWER  time-constrained cpWER (MeetEval): the same, except that a hypothesis token can only match or substitute a
          reference token when their intervals overlap once the hypothesis one is widened by the collar (5 s) on each
          side. A word recognised in the right stream but at another moment is then a deletion and an insertion.
  WDER    word diarization error rate (Shafey et al., 2019). The tokens of all speakers, in time order on each side, are
          aligned once, speaker blind; of the reference tokens that were recognised (correct or substituted), the share
          whose hypothesis speaker is not the one mapped to their reference speaker (the mapping that keeps the most
          pairs, Hungarian). Also gives the speaker-blind WER of that alignment.

All three divide by the number of reference tokens, so a perfect transcript with perfect speakers scores 0.
"""
from array import array

import score_wer as sw


def tokens(words):
    """[(speaker, start, end, text)] -> {speaker: [(start, end, token)]}, each speaker's tokens in time order."""
    out = {}
    for speaker, start, end, text in words:
        for token in sw.normalize(text).split():
            out.setdefault(speaker, []).append((start, end, token))
    for stream in out.values():
        stream.sort(key=lambda t: (t[0], t[1]))
    return out


def _allowed(r, h, collar):
    return h[0] - collar < r[1] and r[0] < h[1] + collar


def distance(ref, hyp, collar=None):
    """Fewest edits that turn the tokens `hyp` into `ref` ([(start, end, token)] each). With `collar`, a match or a
    substitution needs the time overlap described above."""
    n, m = len(ref), len(hyp)
    prev = list(range(m + 1))
    for i in range(1, n + 1):
        r = ref[i - 1]
        cur = [i] + [0] * m
        for j in range(1, m + 1):
            h = hyp[j - 1]
            best = prev[j] + 1 if prev[j] < cur[j - 1] else cur[j - 1] + 1
            if collar is None or _allowed(r, h, collar):
                diagonal = prev[j - 1] + (r[2] != h[2])
                if diagonal < best:
                    best = diagonal
            cur[j] = best
        prev = cur
    return prev[m]


def hungarian(cost):
    """Assignment of each row to a distinct column with the lowest total cost, for a square matrix -> [column of row]."""
    size = len(cost)
    inf = float("inf")
    u, v, p, way = [0] * (size + 1), [0] * (size + 1), [0] * (size + 1), [0] * (size + 1)
    for i in range(1, size + 1):
        p[0], j0 = i, 0
        minv, used = [inf] * (size + 1), [False] * (size + 1)
        while True:
            used[j0] = True
            i0, delta, j1 = p[j0], inf, 0
            for j in range(1, size + 1):
                if not used[j]:
                    cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j]:
                        minv[j], way[j] = cur, j0
                    if minv[j] < delta:
                        delta, j1 = minv[j], j
            for j in range(size + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minv[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while j0:
            j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
    column = [0] * size
    for j in range(1, size + 1):
        if p[j]:
            column[p[j] - 1] = j - 1
    return column


def cp_wer(ref, hyp, collar=None):
    """ref, hyp: {speaker: [(start, end, token)]} -> dict(wer, errors, words, pairs). `pairs` maps each reference
    speaker to its hypothesis speaker (None when it got an empty slot); with `collar`, the time-constrained figure."""
    refs, hyps = sorted(ref, key=str), sorted(hyp, key=str)
    size = max(len(refs), len(hyps))
    rows = [ref[s] for s in refs] + [[]] * (size - len(refs))
    cols = [hyp[s] for s in hyps] + [[]] * (size - len(hyps))
    cost = [[len(c) if not r else len(r) if not c else distance(r, c, collar) for c in cols] for r in rows]
    column = hungarian(cost) if size else []
    errors = sum(cost[i][column[i]] for i in range(size))
    words = sum(len(r) for r in rows)
    pairs = {refs[i]: (hyps[column[i]] if column[i] < len(hyps) else None) for i in range(len(refs))}
    return dict(wer=errors / words if words else 0.0, errors=errors, words=words, pairs=pairs)


def _merged(streams):
    out = [(start, end, token, speaker) for speaker, stream in streams.items() for start, end, token in stream]
    out.sort(key=lambda t: (t[0], t[1], str(t[3])))
    return out


def wder(ref, hyp):
    """ref, hyp: {speaker: [(start, end, token)]} -> dict(wder, wer, recognised, wrong_speaker, words, mapping)."""
    r, h = _merged(ref), _merged(hyp)
    n, m = len(r), len(h)
    # Cost rows and the move into each cell (0 diagonal, 1 deletion, 2 insertion), for the walk back.
    moves = [bytearray([2]) * (m + 1) for _ in range(n + 1)]
    prev = array("i", range(m + 1))
    for i in range(1, n + 1):
        cur = array("i", [i]) + array("i", [0]) * m
        moves[i][0] = 1
        token, row = r[i - 1][2], moves[i]
        for j in range(1, m + 1):
            best, move = prev[j - 1] + (token != h[j - 1][2]), 0
            if prev[j] + 1 < best:
                best, move = prev[j] + 1, 1
            if cur[j - 1] + 1 < best:
                best, move = cur[j - 1] + 1, 2
            cur[j], row[j] = best, move
        prev = cur
    errors = prev[m]
    pairs = []
    i, j = n, m
    while i > 0 and j > 0:
        move = moves[i][j]
        if move == 0:
            pairs.append((r[i - 1][3], h[j - 1][3]))
            i, j = i - 1, j - 1
        elif move == 1:
            i -= 1
        else:
            j -= 1
    refs = sorted({s for s, _ in pairs} | set(ref), key=str)
    hyps = sorted({s for _, s in pairs} | set(hyp), key=str)
    size = max(len(refs), len(hyps))
    count = {}
    for pair in pairs:
        count[pair] = count.get(pair, 0) + 1
    # The mapping that keeps the most pairs: the lowest cost of (most kept - kept).
    top = max(count.values(), default=0)
    cost = [[top - count.get((refs[a], hyps[b]), 0) if a < len(refs) and b < len(hyps) else top for b in range(size)] for a in range(size)]
    column = hungarian(cost) if size else []
    mapping = {refs[a]: hyps[column[a]] for a in range(len(refs)) if column[a] < len(hyps)}
    wrong = sum(1 for a, b in pairs if mapping.get(a) != b)
    return dict(wder=wrong / len(pairs) if pairs else 0.0, wer=errors / n if n else 0.0, recognised=len(pairs),
                wrong_speaker=wrong, words=n, mapping=mapping)
