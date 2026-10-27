# Translating Vauta

Vauta's interface is written in English, and every string a user sees can be translated.
Translations are plain text files in the repository. You need a Mac with the Command Line
Tools (`xcode-select --install`); Xcode is not required.

Supported interface languages: English (`en`, the source), Spanish (`es`), French (`fr`),
German (`de`), Italian (`it`), Portuguese – Brazil (`pt-BR`), Japanese (`ja`),
Korean (`ko`) and Simplified Chinese (`zh-Hans`).

Before you start, read the [glossary](localization/GLOSSARY.md): canonical terms, words
that are never translated, and style rules.

## The files

Each language has a folder `Resources/<language>.lproj/` with three files:

| File | Contents |
|---|---|
| `Localizable.strings` | Almost every string of the app: `"English key" = "translation";` with a comment for translators above each one. |
| `Localizable.stringsdict` | Strings with a number that need plural forms ("1 meeting", "3 meetings"). |
| `InfoPlist.strings` | The permission prompts macOS shows on Vauta's behalf (microphone, system audio, calendars, local network). |

`Resources/en.lproj/` is the source. `Localizable.strings` there is extracted from the
code; `Localizable.stringsdict` and `InfoPlist.strings` are edited by hand.

Rules for every file:

- Change only the text on the **right** side (`= "…";`). Never change a key.
- Keep every placeholder: `%@` (text), `%lld` (number), `%%` (a percent sign). To change
  their order, number them all: `"%2$@ en %1$@"`.
- Escape double quotes inside a value as `\"`; prefer typographic quotes (“ ” « » „ “).
- Files are UTF-8. Keep the comments; they tell you where the string appears.

A few keys are not English sentences but context keys such as `state.recording`. They
exist because the same English word needs two translations (the Settings pane
"Recording" and the state "Recording"). Translate the English value shown next to them in
`en.lproj`, following the comment.

### Plurals

In `Localizable.stringsdict`, each key holds a format with one variable per number:

```xml
<key>%lld meetings</key>
<dict>
    <key>NSStringLocalizedFormatKey</key>
    <string>%#@count@</string>
    <key>count</key>
    <dict>
        <key>NSStringFormatSpecTypeKey</key>
        <string>NSStringPluralRuleType</string>
        <key>NSStringFormatValueTypeKey</key>
        <string>lld</string>
        <key>one</key>
        <string>%lld meeting</string>
        <key>other</key>
        <string>%lld meetings</string>
    </dict>
</dict>
```

Translate the `NSStringLocalizedFormatKey` text around the variables and each plural
form. Use the plural categories of your language (from the Unicode CLDR plural rules):

| Language | Categories |
|---|---|
| English, German | `one`, `other` |
| Spanish, Italian | `one`, `other` (`many`, for large round numbers such as a million, is optional) |
| French, Portuguese (Brazil) | `one` (0 and 1), `other` (`many` optional, as above) |
| Japanese, Korean, Chinese | `other` only (remove `one`) |

`other` is always required. Leave `NSStringFormatSpecTypeKey` and
`NSStringFormatValueTypeKey` unchanged. A form may drop the number when that reads better
("once" instead of "1 time"). Strings with several numbers (for example "Found %1$#@mentions@ …
in %4$#@meetings@") use numbered placeholders: keep each number with its variable.

## Add a language

1. Create the folder and copy the English files:

   ```
   mkdir Resources/fr.lproj
   cp Resources/en.lproj/*.strings Resources/en.lproj/*.stringsdict Resources/fr.lproj/
   ```

2. Translate the values in the three files (see the rules above). In `.stringsdict`,
   adjust the plural categories to your language.
3. If the language is not listed yet, add its code to `CFBundleLocalizations` in
   `Resources/Info.plist` and to `LocalizationTests.infoPlistDeclaresTheSupportedLanguages`.
4. Check the files:

   ```
   scripts/check-strings.sh
   ```

   It reports missing or extra keys and placeholders that don't match the English ones.
   CI runs the same check on every pull request.

5. Test in the app (see below) and open a pull request.

## Update a translation

When the code changes, regenerate the English source and compare:

```
scripts/extract-strings.sh   # rebuilds Resources/en.lproj/Localizable.strings from the code
scripts/check-strings.sh     # lists, per language, what is missing or no longer used
```

Add the missing keys (copy them from `en.lproj` with their comments), translate them, and
delete the keys reported as extra. If an English text changed, its key changed too: the old
key shows up as extra and the new one as missing.

## Test in the app

Build and install Vauta (`scripts/install.sh`, see the README), quit the running copy
(Vauta allows one instance at a time), then open it in your language:

```
open -n ~/Applications/Vauta.app --args -AppleLanguages '(fr)'
```

Use the code of the folder (`'(pt-BR)'`, `'(zh-Hans)'`). The language lasts for that
launch only. To keep it, choose it for Vauta in System Settings → General → Language &
Region → Applications.

The permission prompts appear only the first time Vauta asks for each permission. To see
them again, reset that permission for Vauta, for example
`tccutil reset Microphone <bundle-id>` (the bundle ID is in `scripts/config.sh` or your
`scripts/local.env`).

## Review checklist

- [ ] `scripts/check-strings.sh` passes.
- [ ] Terms follow the [glossary](localization/GLOSSARY.md); the same English term has
      the same translation everywhere.
- [ ] Product names and technical values are unchanged.
- [ ] Placeholders are all present; reordered ones are numbered.
- [ ] Plural forms are right for 0, 1, 2, 5, 21 and 100 in your language.
- [ ] Capitalization, quotation marks and ellipses follow your language's macOS style.
- [ ] macOS names (System Settings panes, Keychain, Login Items…) match Apple's
      translation.
- [ ] Nothing is cut off: check the menu-bar panel, the Settings window (all panes), the
      Meetings window (Meetings, Ask, Tasks, People), onboarding, alerts and notifications.
- [ ] Permission prompts read well and stay honest: they say what Vauta does and what it
      never does.

## What is not translated

- The command-line interface (`Vauta status`, `Vauta doctor`…) and diagnostic logs stay in
  English, so support requests and scripts read the same everywhere.
- Prompts sent to the model are English by design; minutes are written in the meeting's
  language or the one chosen in Settings → Models, and Ask answers in the language of the
  question, independently of the interface language.
- The names of the search model and where it comes from (EmbeddingGemma 2, Gemma, Hugging Face, Google, MLX), its revision (`914f7f8`) and its file names (`model.safetensors`, `tokenizer.json`) stay as written, in every language.
- Stored data is language-neutral: the app saves codes (for example the channel `me` or
  `others`), never labels, so changing the interface language never changes saved meetings.

## For developers: writing translatable code

- In SwiftUI, pass literals: `Text("Meetings")`, `Button("Copy Minutes")`,
  `.help("…")`, `.accessibilityLabel(Text("…"))`. Add `comment:` when the context isn't
  obvious: `Text("Open", comment: "Task status")`.
- Elsewhere, use `String(localized: "English text", comment: "Where it appears")`.
- Interpolate values instead of concatenating: `String(localized: "\(count) meetings")`
  becomes the key `%lld meetings` (`Int` → `%lld`, `String` → `%@`). For a number that
  needs plural forms, add the key to `Resources/en.lproj/Localizable.stringsdict`.
- Text that must not be translated (product names, identifiers, symbols, formatted
  numbers) goes through `Text(verbatim:)` or a plain `String`, never a `LocalizedStringKey`.
- When one English word needs two translations, give one of them a context key:
  `String(localized: "state.recording", defaultValue: "Recording", comment: "…")`.
- Strings resolve against the app bundle (`Bundle.main`), including those in `VautaCore`,
  which is linked into the same executable. Don't pass `bundle:` or `table:`.
- Run `scripts/extract-strings.sh` and commit the updated `en.lproj/Localizable.strings`.
