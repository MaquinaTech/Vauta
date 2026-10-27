# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Spanish WER: normalisation and scoring (reuses the Levenshtein alignment of the repo's score_wer.py).

Normalisation (both sides): NFKC, lower case, punctuation (including inverted marks) to spaces, apostrophes dropped,
digits to Spanish cardinal words ("1.234" thousands separator, "3,5" -> "tres coma cinco", "%" -> "por ciento",
"€" -> "euros"), hesitations removed (eh, em, ehm, mm, mmm, hm, ah, uh, um). Accents are kept in the strict figure;
the "folded" figure also strips diacritics (n with tilde stays n) because the MLS texts use pre-reform spellings
(e.g. "á" for "a", "ó"/"ò") that a recogniser rightly writes the modern way. Nothing else is mapped.
"""
import re, unicodedata, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score_wer import align

U = "cero uno dos tres cuatro cinco seis siete ocho nueve diez once doce trece catorce quince dieciséis diecisiete dieciocho diecinueve veinte veintiuno veintidós veintitrés veinticuatro veinticinco veintiséis veintisiete veintiocho veintinueve".split()
T = "_ _ _ treinta cuarenta cincuenta sesenta setenta ochenta noventa".split()
H = "_ ciento doscientos trescientos cuatrocientos quinientos seiscientos setecientos ochocientos novecientos".split()

def num(n):
    if n < 30: return U[n]
    if n < 100: return T[n // 10] + ("" if n % 10 == 0 else " y " + U[n % 10])
    if n == 100: return "cien"
    if n < 1000: return H[n // 100] + ("" if n % 100 == 0 else " " + num(n % 100))
    if n < 1_000_000:
        k, r = divmod(n, 1000)
        return ("mil" if k == 1 else num(k) + " mil") + ("" if r == 0 else " " + num(r))
    if n < 10**12:
        k, r = divmod(n, 10**6)
        return ("un millón" if k == 1 else num(k) + " millones") + ("" if r == 0 else " " + num(r))
    return " ".join(U[int(d)] for d in str(n))

FILL = {"eh", "em", "ehm", "mm", "mmm", "hm", "hmm", "ah", "uh", "um", "mhm"}

def normalize(text, fold=False):
    t = unicodedata.normalize("NFKC", text).lower().replace("’", "").replace("'", "")
    t = t.replace("%", " por ciento ").replace("€", " euros ").replace("&", " y ")
    t = re.sub(r"(?<=\d)\.(?=\d{3}(\D|$))", "", t)
    t = re.sub(r"(\d+),(\d+)", lambda m: f"{m.group(1)} coma {' '.join(m.group(2))}", t)
    t = re.sub(r"(\d+)\.(\d+)", lambda m: f"{m.group(1)} coma {' '.join(m.group(2))}", t)
    if fold:
        t = t.replace("ñ", "\0")
        t = "".join(c for c in unicodedata.normalize("NFD", t) if unicodedata.category(c) != "Mn").replace("\0", "ñ")
    t = re.sub(r"[^a-z0-9ñáéíóúü\0]+", " ", t)
    out = []
    for w in t.split():
        if w in FILL: continue
        out.extend(num(int(w)).split() if w.isdigit() else [w])
    s = " ".join(out)
    return s.replace("á", "a").replace("é", "e").replace("í", "i").replace("ó", "o").replace("ú", "u").replace("ü", "u") if fold else s

def wer(ref, hyp, fold=False):
    r, h = normalize(ref, fold).split(), normalize(hyp, fold).split()
    s, d, i, n = align(r, h)
    return dict(sub=s, dele=d, ins=i, words=n, wer=100.0 * (s + d + i) / n if n else 0.0, hyp_words=len(h))

if __name__ == "__main__":
    assert normalize("Hay 1.234 personas, el 25% y 3,5 años") == "hay mil doscientos treinta y cuatro personas el veinticinco por ciento y tres coma cinco años", normalize("Hay 1.234 personas, el 25% y 3,5 años")
    assert normalize("¿Qué tal? 2023") == "qué tal dos mil veintitrés"
    assert normalize("Á los niños", fold=True) == "a los niños"
    print("ok")
