#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
# shellcheck disable=SC1111 # the curly quotes in this file are the text being checked, not shell quoting
#
# Checks that every localization matches the English source (en.lproj):
#   - the same Localizable.strings, Localizable.stringsdict and InfoPlist.strings files;
#   - the same keys (plural categories in .stringsdict may differ by language, but "other"
#     is required);
#   - the same format specifiers by position and type (%@, %lld, %1$@, %#@var@, …), so a
#     translation can reorder arguments but never drop, add or change one. A plural variant
#     may omit a specifier present in the English "other" form ("One meeting").
#   - no key defined twice in a .strings file (the last one would silently win);
#   - French: a no-break space before : ; ? ! and inside « »; arrows in paths with U+00A0;
#     German: the "du" register.
#
#   scripts/check-strings.sh [resources-dir ...]   (default: Resources and Sources/*/Resources)
#
# Exits 0 when everything matches or there are no localizations yet, 1 on any mismatch.
# Uses only plutil and JavaScript for Automation, both part of macOS.
set -euo pipefail
cd "$(dirname "$0")/.."

FILES=(Localizable.strings Localizable.stringsdict InfoPlist.strings)

# Prints one line per problem; prints nothing when the translation matches.
read -r -d '' COMPARE <<'JS' || true
function run(argv) {
  const [kind, enPath, trPath] = argv;
  const read = (p) => JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null)));
  const en = read(enPath), tr = read(trPath);
  const problems = [];
  const plural = new Set(["zero", "one", "two", "few", "many", "other"]);
  const literalKeys = new Set(["NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"]);
  // %[n$] then either a .stringsdict variable (#@name@) or flags, width, precision, length, conversion.
  const specRe = /%(?:(\d+)\$)?(?:#@([^@\s]+)@|[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp%]))/g;

  // Maps each argument position to its normalized type.
  function specs(text) {
    const map = {};
    let next = 1, m;
    specRe.lastIndex = 0;
    while ((m = specRe.exec(text)) !== null) {
      if (m[4] === "%") continue;
      const conv = ({ i: "d", D: "d", U: "u", O: "o", X: "x", E: "e", F: "f", G: "g", A: "a" })[m[4]] || m[4];
      // A variable consumes an argument like any other specifier.
      map[m[1] ? Number(m[1]) : next++] = m[2] !== undefined ? "#@" + m[2] + "@" : (m[3] || "") + conv;
    }
    return map;
  }
  const show = (map) => Object.keys(map).sort().map((k) => k + ":" + map[k]).join(" ") || "none";
  const same = (a, b) => show(a) === show(b);
  const subset = (a, b) => Object.keys(a).every((k) => b[k] === a[k]);

  function flatten(value, path, out) {
    if (value !== null && typeof value === "object") {
      for (const k of Object.keys(value)) flatten(value[k], path.concat(k), out);
    } else {
      out[JSON.stringify(path)] = String(value);
    }
    return out;
  }
  const label = (key) => JSON.parse(key).join(" > ");

  // A translation that moves an argument must number its placeholders (%2$@). Unnumbered ones take the arguments in order, so a
  // reordered sentence names the wrong thing. Only the quoted placeholder can be told apart from the text alone: if the English
  // quotes the n-th unnumbered placeholder and the translation quotes another one, the translation reordered without numbering.
  function unnumberedOrder(text) {
    const re = /(.)[ \u00a0\u202f]*%(\d+\$)?[-+ #0']*(?:\d+)?(?:ll|l)?[@dDiuUxXfFsS][ \u00a0\u202f]*(.?)/gu;
    const open = "\u201c\u00ab\u201e\u300c\u2018\u2039\"", close = "\u201d\u00bb\u201c\u300d\u2019\u203a\"";
    let n = 0, m, quoted = -1, numbered = false;
    const plain = text.replace(/%%/g, "");
    while ((m = re.exec(plain)) !== null) {
      if (m[2]) numbered = true;
      if (open.includes(m[1]) && close.includes(m[3])) quoted = n;
      n++;
    }
    return { count: n, quoted, numbered };
  }
  function reorderedWithoutNumbers(enText, trText) {
    const e = unnumberedOrder(enText), t = unnumberedOrder(trText);
    return e.count >= 2 && !e.numbered && !t.numbered && e.quoted >= 0 && t.quoted >= 0 && e.quoted !== t.quoted;
  }

  if (kind.endsWith(".stringsdict")) {
    const e = flatten(en, [], {}), t = flatten(tr, [], {});
    const isPlural = (key) => plural.has(JSON.parse(key).slice(-1)[0]);
    const otherOf = (key) => JSON.stringify(JSON.parse(key).slice(0, -1).concat("other"));
    for (const key of Object.keys(e)) {
      if (isPlural(key)) {
        if (JSON.parse(key).slice(-1)[0] === "other" && !(key in t)) problems.push("missing plural form: " + label(key));
      } else if (!(key in t)) {
        problems.push("missing key: " + label(key));
      }
    }
    for (const key of Object.keys(t)) {
      const leaf = JSON.parse(key).slice(-1)[0];
      if (isPlural(key)) {
        const source = e[otherOf(key)];
        if (source === undefined) { problems.push("plural form without an English 'other': " + label(key)); continue; }
        if (!subset(specs(t[key]), specs(source)))
          problems.push("format mismatch in " + label(key) + ": " + show(specs(t[key])) + " (English 'other': " + show(specs(source)) + ")");
      } else if (!(key in e)) {
        problems.push("extra key: " + label(key));
      } else if (literalKeys.has(leaf)) {
        if (t[key] !== e[key]) problems.push(label(key) + " must stay '" + e[key] + "' (found '" + t[key] + "')");
      } else if (!same(specs(t[key]), specs(e[key]))) {
        problems.push("format mismatch in " + label(key) + ": " + show(specs(t[key])) + " (English: " + show(specs(e[key])) + ")");
      }
    }
  } else {
    for (const key of Object.keys(en)) if (!(key in tr)) problems.push("missing key: " + key);
    for (const key of Object.keys(tr)) {
      if (!(key in en)) { problems.push("extra key: " + key); continue; }
      if (!same(specs(String(tr[key])), specs(String(en[key]))))
        problems.push("format mismatch in " + JSON.stringify(key) + ": " + show(specs(String(tr[key]))) + " (English: " + show(specs(String(en[key]))) + ")");
      if (reorderedWithoutNumbers(String(en[key]), String(tr[key])))
        problems.push("reordered arguments need numbered placeholders (%1$@, %2$@) in " + JSON.stringify(key));
      // A forced line break the English source does not have goes wrong at other widths and font sizes: let the layout wrap.
      const breaks = (text) => (String(text).match(/\n/g) || []).length;
      if (breaks(tr[key]) > breaks(en[key]))
        problems.push("line break (\\n) the English source does not have in " + JSON.stringify(key));
    }
  }
  return problems.join("\n");
}
JS

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
CHECKED=0
report() { echo "ERROR: $*" >&2; FAILED=1; }
to_json() { plutil -convert json -o "$2" "$1" 2>/dev/null || { report "$1 is not a valid strings/plist file"; return 1; }; }

DIRS=("$@")
if [[ ${#DIRS[@]} -eq 0 ]]; then
  DIRS=(Resources)
  for d in Sources/*/Resources; do [[ -d "$d" ]] && DIRS+=("$d"); done
fi

for dir in "${DIRS[@]}"; do
  shopt -s nullglob
  LPROJS=("$dir"/*.lproj)
  shopt -u nullglob
  [[ ${#LPROJS[@]} -gt 0 ]] || continue
  BASE="$dir/en.lproj"
  if [[ ! -d "$BASE" ]]; then
    report "$dir has localizations but no en.lproj"
    continue
  fi
  for name in "${FILES[@]}"; do
    [[ -f "$BASE/$name" ]] && { to_json "$BASE/$name" "$WORK/en.json" || true; }
  done
  for lproj in "${LPROJS[@]}"; do
    [[ "$lproj" == "$BASE" || "$(basename "$lproj")" == "Base.lproj" ]] && continue
    for name in "${FILES[@]}"; do
      if [[ ! -f "$BASE/$name" ]]; then
        [[ -f "$lproj/$name" ]] && report "$lproj/$name has no English source ($BASE/$name)"
        continue
      fi
      [[ -f "$lproj/$name" ]] || { report "missing $lproj/$name"; continue; }
      to_json "$BASE/$name" "$WORK/en.json" || continue
      to_json "$lproj/$name" "$WORK/tr.json" || continue
      CHECKED=$((CHECKED + 1))
      # Settings paths ("Settings → Models") keep a no-break space (U+00A0) on both sides of the arrow.
      if [[ "$name" == *.strings ]]; then
        while IFS= read -r line; do
          [[ -n "$line" ]] && report "$lproj/$name: plain space next to '→' (use U+00A0): $line"
        done < <(perl -Mutf8 -CSD -ne 'if (/^"(?:[^"\\]|\\.)*" = "((?:[^"\\]|\\.)*)";/) { my $v = $1; print substr($v, 0, 90), "\n" if $v =~ /(?: →|→ )/ }' "$lproj/$name")
      fi
      # Widows: in es, fr, de, it and pt-BR the last two words of a sentence of 7+ words are joined with U+00A0,
      # so a banner or alert never ends on a one-word line.
      if [[ "$name" == *.strings ]]; then
        case "$(basename "$lproj")" in
          es.lproj|fr.lproj|de.lproj|it.lproj|pt-BR.lproj)
            while IFS= read -r line; do
              [[ -n "$line" ]] && report "$lproj/$name: join the last two words with U+00A0: $line"
            done < <(perl -Mutf8 -CSD -ne 'if (/^"(?:[^"\\]|\\.)*" = "((?:[^"\\]|\\.)*)";/) { my $v = $1; my $s = (split(/\\n/, $v, -1))[-1]; print substr($v, 0, 90), "\n" if $s =~ /[.?]$/ && $s =~ /^(?:\S+ ){6,}[^\s\\\x{a0}\x{2060}]+$/ }' "$lproj/$name")
            ;;
        esac
      fi
      # A key defined twice: the last definition wins at runtime, so a stale value could silently replace the right one.
      if [[ "$name" == *.strings ]]; then
        while IFS= read -r line; do
          [[ -n "$line" ]] && report "$lproj/$name: duplicate key: $line"
        done < <(perl -Mutf8 -CSD -ne 'if (/^"((?:[^"\\]|\\.)*)"\s*=\s*"/) { my $k = $1; if ($seen{$k}) { print "line $. repeats line $seen{$k}: ", substr($k, 0, 80), "\n" } else { $seen{$k} = $. } }' "$lproj/$name")
      fi
      PROBLEMS="$(osascript -l JavaScript -e "$COMPARE" "$name" "$WORK/en.json" "$WORK/tr.json")" \
        || { report "could not compare $lproj/$name"; continue; }
      while IFS= read -r line; do
        [[ -n "$line" ]] && report "$lproj/$name: $line"
      done <<< "$PROBLEMS"
    done
  done
done

# A localized value that says the same sentence twice (a translation pasted over itself) is a defect: the check flags a stretch of
# 16+ characters repeated right after itself (optionally separated by spaces or punctuation) and a sentence of 12+ characters that
# appears twice in one value. Every language is checked, English included.
for dir in "${DIRS[@]}"; do
  for f in "$dir"/*.lproj/Localizable.strings; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      [[ -n "$line" ]] && report "$f: a sentence is repeated in one value: ${line:0:140}"
    done < <(perl -Mutf8 -CSD -ne '
      next unless /^"(?:[^"\\]|\\.)*" = "((?:[^"\\]|\\.)*)";/;
      my $v = $1;
      my $hit = $v =~ /(.{16,}?)[\s.!?\x{3002}\x{ff01}\x{ff1f}]*\1/;
      my %seen;
      for my $s (split /[.!?\x{3002}\x{ff01}\x{ff1f}\n]+/, $v) { $s =~ s/^\s+|\s+$//g; next if length($s) < 12; $hit = 1 if $seen{$s}++ }
      print "$.: $v\n" if $hit' "$f" || true)
  done
done

# Paths in Settings and System Settings use "→" with a non-breaking space (U+00A0) on both sides,
# so a line never breaks before the arrow; "›" is not used. The source is checked: translators copy it.
for dir in "${DIRS[@]}"; do
  f="$dir/en.lproj/Localizable.strings"
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    [[ -n "$line" ]] && report "$f: path separator needs U+00A0 around → (and never ›): ${line:0:120}"
  done < <(grep -nE '^"[^"]*( [→›] |[→›] | [→›])[^"]*" =' "$f" || true)
done

# French puts a no-break space (U+00A0 or U+202F) before : ; ? ! and inside « »: a plain space lets a line
# break before the punctuation or inside the quotes ("::1" and "a:b" are not French punctuation).
for dir in "${DIRS[@]}"; do
  for f in "$dir"/fr.lproj/*.strings "$dir"/fr.lproj/*.stringsdict; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      [[ -n "$line" ]] && report "$f: French needs a no-break space (U+00A0) before : ; ? ! and inside « »: ${line:0:120}"
    done < <(perl -Mutf8 -CSD -ne 'next if /^\s*\/?\*/ || /^\s*<key>/; print "$.: $_" if /« |(?<=[^\s\x{a0}\x{202f}]) »|(?<![\x{a0}\x{202f}:]) [:;?!](?=[\s"<]|$)/ && !/::1/' "$f" || true)
  done
done

# French "compte(s) rendu(s)" (the main term for minutes) never splits across lines: U+00A0 between its words.
for dir in "${DIRS[@]}"; do
  for f in "$dir"/fr.lproj/*.strings "$dir"/fr.lproj/*.stringsdict; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      [[ -n "$line" ]] && report "$f: French 'compte(s) rendu(s)' needs U+00A0 between its words: ${line:0:120}"
    done < <(grep -nEi 'comptes? rendus?' "$f" | grep -v '^[0-9]*:[[:space:]]*/\*' || true)
  done
done

# German addresses the user as "du" (docs/localization/GLOSSARY.md): flag the formal "Sie/Ihr".
for dir in "${DIRS[@]}"; do
  for f in "$dir"/de.lproj/*.strings "$dir"/de.lproj/*.stringsdict; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      [[ -n "$line" ]] && report "$f: formal German address (use \"du\"): ${line:0:120}"
    done < <(grep -nE '\b(Ihr|Ihre|Ihren|Ihrem|Ihrer|Ihres|Ihnen)\b|en Sie\b|\bSie (können|haben|sind|müssen|möchten|wollen)\b' "$f" | grep -v '^[0-9]*:[[:space:]]*/\*' || true)
  done
done

# German puts U+00A0 (not a plain space) before "…"; Brazilian Portuguese never puts an article before Vauta or Acta;
# Japanese and Korean quote every Settings path that a particle follows (「設定」 → 「モデル」で, “설정 → 모델”에서).
for dir in "${DIRS[@]}"; do
  f="$dir/de.lproj/Localizable.strings"
  [[ -f "$f" ]] && while IFS= read -r line; do
    [[ -n "$line" ]] && report "$f: German needs U+00A0 before '…', not a plain space: ${line:0:120}"
  done < <(perl -Mutf8 -CSD -ne 'print "$.: $_" if /^"(?:[^"\\]|\\.)*" = ".* \x{2026}/' "$f" || true)
  f="$dir/de.lproj/Localizable.stringsdict"
  [[ -f "$f" ]] && while IFS= read -r line; do
    [[ -n "$line" ]] && report "$f: German needs U+00A0 before '…' in plural forms: ${line:0:120}"
  done < <(perl -Mutf8 -CSD -ne 'print "$.: $_" if /<string>.*[^\x{a0}\s]\x{2026}/' "$f" || true)
  f="$dir/ko.lproj/Localizable.strings"
  [[ -f "$f" ]] && while IFS= read -r line; do
    [[ -n "$line" ]] && report "$f: Korean says 회의, never 미팅: ${line:0:120}"
  done < <(perl -Mutf8 -CSD -ne 'print "$.: $_" if /^"/ && / = ".*\x{bbf8}\x{d305}/' "$f" || true)
  f="$dir/pt-BR.lproj/Localizable.strings"
  [[ -f "$f" ]] && while IFS= read -r line; do
    [[ -n "$line" ]] && report "$f: pt-BR puts no article before Vauta or Acta: ${line:0:120}"
  done < <(perl -Mutf8 -CSD -ne 'print "$.: $_" if /^"/ && / = ".*\b(?:[oO]|d[oO]|a[oO]|n[oO]|pel[oO]) (?:próprio )?(?:Vauta|Acta)\b/ && !/^"[^"]*" = "[^"]*\bn[oO] Acta/' "$f" || true)
  f="$dir/ja.lproj/Localizable.strings"
  [[ -f "$f" ]] && while IFS= read -r line; do
    [[ -n "$line" ]] && report "$f: Japanese quotes every Settings path (「設定」 → 「モデル」で): ${line:0:120}"
  done < <(perl -Mutf8 -CSD -ne 'next unless /^"(?:[^"\\]|\\.)*" = "(.*)";/; $v = $1; print "$.: $v\n" if $v =~ /(?<!」)\x{a0}\x{2192}\x{a0}/ && $v !~ /^%@.\x{2192}.%@$/' "$f" || true)
  f="$dir/ko.lproj/Localizable.strings"
  [[ -f "$f" ]] && while IFS= read -r line; do
    [[ -n "$line" ]] && report "$f: Korean quotes every Settings path (“설정 → 모델”에서): ${line:0:120}"
  done < <(perl -Mutf8 -CSD -ne 'next unless /^"(?:[^"\\]|\\.)*" = "(.*)";/; $v = $1; print "$.: $v\n" if $v =~ /\x{a0}\x{2192}\x{a0}/ && $v !~ /^%@.\x{2192}.%@$/ && $v !~ /\x{201c}[^\x{201d}]*\x{a0}\x{2192}\x{a0}[^\x{201d}]*\x{201d}/' "$f" || true)
done

# Glossary terms that must not come back (docs/localization/GLOSSARY.md): the waveform icon has one name per
# language, Italian quotes with “ ” (never « »), Korean never uses single quotes.
BANNED_RULES=(
  "de|Wellensymbol|the menu-bar icon is \"Wellenform-Symbol\""
  "it|icona a onda|the menu-bar icon is \"icona della forma d’onda\""
  "pt-BR|ícone de onda|the menu-bar icon is \"ícone de forma de onda\""
  "it|[«»]|Italian quotes with “ ”"
  "ko|[‘’]|Korean quotes with “ ”, never single quotes"
  # The user is 自分 or no pronoun, never あなた (ja); a full stop between two Korean sentences is followed by a space
  # (the sentence splitter needs ". ", and "마이크가 없습니다.마이크를" reads as a typo). The patterns are escapes: the arguments are bytes.
  "ja|\x{3042}\x{306a}\x{305f}|the user is 自分 or no pronoun, never あなた"
  "ko|[\x{ac00}-\x{d7a3}]\.[\x{ac00}-\x{d7a3}A-Z]|a full stop between two sentences is followed by a space"
  # One translation per glossary term: context length (fr "longueur de contexte", pt-BR "comprimento de contexto"), download (de "herunterladen",
  # never a bare "lädst"), import (ja 読み込む, never インポート), voice recognition (pt-BR "de vozes", never the speech wording "de voz").
  "fr|[Ll]ongueur du contexte|context length is \"longueur de contexte\" everywhere"
  "pt-BR|[Cc]omprimento do contexto|context length is \"comprimento de contexto\" everywhere"
  "de|(?<!herunter)l\x{e4}dst|download is \"herunterladen\", never a bare \"lädst\""
  "ja|\x{30a4}\x{30f3}\x{30dd}\x{30fc}\x{30c8}|import is 読み込む, never インポート"
  "ja|\x{201c}|Japanese quotes with 「 」, never “ ”"
  "pt-BR|[Rr]econhecimento de voz(?!es)|voice recognition (who is speaking) is \"reconhecimento de vozes\""
  # The Return key has one name per language: it "A capo" (never "Invio"). The speech model is always the recognition wording:
  # de "Spracherkennungsmodell" (a bare "Sprachmodell" reads as an LLM), es/pt-BR never "El modelo de %@" / "O modelo de %@".
  # Privacy scope: meeting text can leave this Mac through a model server on another computer, Reminders, Calendar or an email, so a line
  # must say what it is about ("A server on this Mac keeps meeting text on this Mac") and the consent notice only promises the internet.
  "en|never leaves? this Mac|an absolute \"never leaves this Mac\" is wider than the privacy promise: scope it to its subject"
  "en|nothing leaves it|an absolute \"nothing leaves it\" is wider than the privacy promise: scope it to its subject"
  "en|runs only on my Mac|the consent notice cannot say the app runs only on this Mac (the model server may be another computer): say nothing is sent to the internet"
  "it|\bInvio\b|the Return key is \"A capo\" in Italian"
  "de|Sprachmodell|the speech model is \"Spracherkennungsmodell\"; \"Sprachmodell\" reads as a language model"
  "es|[Ee]l modelo de %@|the speech model is \"modelo de reconocimiento de voz\""
  "pt-BR|[Oo] modelo de %@|the speech model is \"modelo de reconhecimento de fala\""
  # A shortcut has one word per language (GLOSSARY): de "Tastaturkurzbefehl" (never "Kürzel", "Tastenkürzel"), it "abbreviazione" (never
  # "scorciatoia"). Dismissing a person is "descartar" in pt-BR, never "ignorar" (next to a permission problem "ignore" sounds dangerous).
  "de|[Kk]\x{fc}rzel|a shortcut is \"Tastaturkurzbefehl\" in German, never \"Kürzel\" or \"Tastenkürzel\""
  "it|[Ss]corciatoi|a shortcut is \"abbreviazione\" in Italian, never \"scorciatoia\""
  "it|dal vivo|live notes and Live Translation are \"in diretta\" in Italian, never \"dal vivo\""
  "pt-BR|ignorar [a-z]+ pessoa|dismissing a person is \"descartar\" in pt-BR, never \"ignorar\""
)
for dir in "${DIRS[@]}"; do
  for rule in "${BANNED_RULES[@]}"; do
    IFS='|' read -r lang pattern why <<<"$rule"
    f="$dir/$lang.lproj/Localizable.strings"
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      [[ -n "$line" ]] && report "$f: $why: ${line:0:120}"
    done < <(perl -Mutf8 -CSD -ne 'BEGIN { $p = shift } next if /^\s*\/?\*/; print "$.: $_" if /^"(?:[^"\\]|\\.)*" = ".*(?:$p)/' "$pattern" "$f" || true)
  done
done

# The privacy promise keeps the English condition ("only through a model server on another computer, or in what you choose to add to
# Reminders, Calendar or an email"): a translation that says only where the text goes reads as if it leaves the Mac, and one that drops
# the user's own exports (Reminders, Calendar, email) promises more than the app does. Each rule is language~patterns, every pattern
# is one regular expression: the "only" condition, the model server and the three exports, in order.
PRIVACY_KEYS=(
  "Meeting text leaves this Mac only through a model server on another computer, or in what you choose to add to Reminders, Calendar or an email."
  "Audio is never saved to disk. Meetings and context are encrypted (AES-256) on this Mac. Meeting text leaves this Mac only through a model server on another computer, or in what you choose to add to Reminders, Calendar or an email."
)
PRIVACY_CONDITION=(
  "de~nur\süber\seinen\sModellserver.*Erinnerungen,\sKalender\soder\seiner\sE-Mail"
  "es~solo\ssale\sde\seste\sMac\sa\stravés\sde\sun\sservidor\sde\smodelos.*Recordatorios,\sCalendario\so\sun\scorreo"
  "fr~ne\squitte\sce\sMac\sque\spar\sun\sserveur\sde\smodèles.*Rappels,\sà\sCalendrier\sou\sà\sun\se.mail"
  "it~solo\stramite\sun\sserver\sdi\smodelli.*Promemoria,\sCalendario\so\sa\sun’email"
  "pt-BR~só\ssai\sdeste\sMac\spor\sum\sservidor\sde\smodelos.*Lembretes,\sCalendário\sou\sa\sum\se.mail"
  "ja~モデルサーバ.*リマインダー、カレンダー、メール.*だけ"
  "ko~모델\s서버.*미리\s알림,\s캘린더,\s이메일.*경우에만"
  "zh-Hans~只有通过.*模型服务器.*提醒事项、日历或邮件"
)
for dir in "${DIRS[@]}"; do
  for rule in "${PRIVACY_CONDITION[@]}"; do
    IFS='~' read -r lang pattern <<<"$rule"
    f="$dir/$lang.lproj/Localizable.strings"
    [[ -f "$f" ]] || continue
    for key in "${PRIVACY_KEYS[@]}"; do
      perl -Mutf8 -CSD -e 'BEGIN { ($k, $p) = splice(@ARGV, 0, 2); utf8::decode($k); utf8::decode($p) } while (<>) { next unless index($_, "\"$k\" = \"") == 0; exit(/$p/ ? 0 : 1) } exit 0' "$key" "$pattern" "$f" \
        || report "$f: the privacy promise must keep the English condition (only through a model server on another computer, or what you add to Reminders, Calendar or an email): ${key:0:60}"
    done
  done
done

# The follow-up email's words live in Swift, not in a .strings file: the same ja pronoun rule applies there.
if [[ -f Sources/VautaCore/Actions/FollowUpEmailWords.swift ]] && perl -Mutf8 -CSD -ne 'exit 1 if /\x{3042}\x{306a}\x{305f}/' Sources/VautaCore/Actions/FollowUpEmailWords.swift; then :; else
  report "Sources/VautaCore/Actions/FollowUpEmailWords.swift: the user is 自分 or no pronoun, never あなた (ja)"
fi

if [[ $FAILED -ne 0 ]]; then
  echo "Strings check failed." >&2
  exit 1
fi
if [[ $CHECKED -eq 0 ]]; then
  echo "No translations to check yet."
else
  echo "OK: $CHECKED localized files match English."
fi
