# Compatibility: meeting apps and browsers

Vauta records two channels. **Me** is your microphone. **Others** is the call audio, captured with a Core Audio *process tap* on the processes of the meeting app. Vauta never joins the call, so compatibility comes down to one question: does the app's audio play from the processes Vauta taps?

This page lists what Vauta knows about each app, what has been confirmed in real calls, and how you can help confirm the rest.

## Status

| Status | Meaning |
|---|---|
| **Verified** | Tested in real calls: "Others" is captured and transcribed. |
| **Expected — needs verification** | The bundle IDs and process layout are known and covered by unit tests, but nobody has confirmed it in a real call yet. |
| **Expected — bundle ID unconfirmed** | As above, and the bundle ID itself still needs confirming on a real install. |

Only Safari has been verified so far. An earlier version (0.1.0) captured Safari only, and the bundle IDs it tapped are unchanged. Everything else is new in 0.9.0.

## Search by meaning (the optional search model)

The search model (EmbeddingGemma 2) needs an **Apple silicon Mac (M1 or later)** with a GPU Metal supports. It is not offered on other Macs, and
keyword search keeps working. It uses about 360 MB of memory while loaded, up to about 1.1 GB while it indexes your library, and nothing
after it unloads (3 minutes idle, memory pressure, or delete); it needs about 843 MB of free disk space to install (574 MB on disk). Verified on an
M2 (see [SEARCH_MODEL.md](SEARCH_MODEL.md)); an M1 and an M5 (whose GPU uses different kernels) are checked with `Vauta mlx-selftest --model` before each release
and are not yet reported here.

## Audio sources

You choose where "Others" comes from in the menu-bar panel or in **Settings → Recording**:

| Source | What Vauta taps |
|---|---|
| **Auto** | The family of the app that is using the microphone when recording starts. If no known app is using it, Vauta falls back to all system audio. |
| **Chosen apps** | Only the processes of the families you select. |
| **All system audio** | Everything your Mac plays, except Vauta itself. Use it for apps not listed here. |

**Auto** is the default on a new install. If you upgrade from an earlier version (0.1, which captured Safari only) and never changed the setting, Vauta keeps capturing Safari only until you pick another source.

With **chosen apps** or **Auto**, the tap follows the family's processes while you record. When a matching process starts (for example a browser helper that opens when the call begins), Vauta adds it to the live tap.

## Browsers

Browsers are grouped by engine, because their media runs in helper processes shared by the whole engine. Web meetings such as Google Meet, Whereby or Jitsi, and installed web apps, are captured through the browser that runs them.

### Safari and WebKit browsers

Tapped processes: `com.apple.Safari`, `com.apple.WebKit.GPU`, `com.apple.WebKit.WebContent`. Installed Safari web apps (`com.apple.Safari.WebApp.*`) are recognised too.

| Browser | Bundle ID | Status |
|---|---|---|
| Safari | `com.apple.Safari` | **Verified** |
| Safari Technology Preview | `com.apple.SafariTechnologyPreview` | Expected — needs verification |
| Orion | `com.kagi.kagimacOS` | Expected — needs verification |
| DuckDuckGo | `com.duckduckgo.macos.browser` | Expected — needs verification |
| Safari web apps (Dock apps) | `com.apple.Safari.WebApp.*` | Expected — needs verification |

### Chrome, Edge and other Chromium browsers

Tapped processes: each browser's bundle ID and its `<bundle ID>.helper` processes, where Chromium plays audio. Installed web apps (`<bundle ID>.app.*`) are recognised for the browsers marked "web apps".

| Browser | Bundle ID | Web apps | Status |
|---|---|---|---|
| Google Chrome | `com.google.Chrome` | yes | Expected — needs verification |
| Google Chrome Beta | `com.google.Chrome.beta` | yes | Expected — needs verification |
| Google Chrome Dev | `com.google.Chrome.dev` | yes | Expected — needs verification |
| Google Chrome Canary | `com.google.Chrome.canary` | yes | Expected — needs verification |
| Microsoft Edge | `com.microsoft.edgemac` | yes | Expected — needs verification |
| Microsoft Edge Beta | `com.microsoft.edgemac.Beta` | yes | Expected — needs verification |
| Microsoft Edge Dev | `com.microsoft.edgemac.Dev` | yes | Expected — needs verification |
| Microsoft Edge Canary | `com.microsoft.edgemac.Canary` | yes | Expected — needs verification |
| Brave | `com.brave.Browser` | yes | Expected — needs verification |
| Brave Beta | `com.brave.Browser.beta` | yes | Expected — needs verification |
| Brave Nightly | `com.brave.Browser.nightly` | yes | Expected — needs verification |
| Arc | `company.thebrowser.Browser` | no | Expected — needs verification |
| Dia | `company.thebrowser.dia` | no | Expected — needs verification |
| Vivaldi | `com.vivaldi.Vivaldi` | yes | Expected — needs verification |
| Opera | `com.operasoftware.Opera` | yes | Expected — needs verification |
| Opera GX | `com.operasoftware.OperaGX` | yes | Expected — needs verification |
| Chromium | `org.chromium.Chromium` | yes | Expected — needs verification |
| Comet | `ai.perplexity.comet` | no | Expected — bundle ID unconfirmed |
| Helium | `net.imput.helium` | no | Expected — bundle ID unconfirmed |

### Firefox and Gecko browsers

Tapped processes: each browser's bundle ID and `org.mozilla.plugincontainer`, the content process where Gecko plays audio. That content process is shared by every Gecko browser, so selecting this family can also capture another Gecko browser that is playing sound at the same time.

| Browser | Bundle ID | Status |
|---|---|---|
| Firefox | `org.mozilla.firefox` | Expected — needs verification |
| Firefox Developer Edition | `org.mozilla.firefoxdeveloperedition` | Expected — needs verification |
| Firefox Nightly | `org.mozilla.nightly` | Expected — needs verification |
| LibreWolf | `org.mozilla.librewolf`, `io.gitlab.librewolf-community` | Expected — bundle ID unconfirmed |
| Zen | `app.zen-browser.zen` | Expected — bundle ID unconfirmed |
| Floorp | `one.ablaze.floorp` | Expected — bundle ID unconfirmed |
| Waterfox | `net.waterfox.waterfox` | Expected — bundle ID unconfirmed |

## Meeting apps

Tapped processes: the app's bundle ID and its `<bundle ID>.helper` processes (Electron and similar apps play audio from helpers), except where noted.

| App | Bundle IDs | Notes | Status |
|---|---|---|---|
| Zoom | `us.zoom.xos` | | Expected — needs verification |
| Microsoft Teams | `com.microsoft.teams2` (new), `com.microsoft.teams` (classic) | Which helper carries the audio needs confirming. | Expected — needs verification |
| Slack (huddles) | `com.tinyspeck.slackmacgap` | | Expected — needs verification |
| Discord | `com.hnc.Discord`, `com.hnc.DiscordPTB`, `com.hnc.DiscordCanary` | | Expected — needs verification |
| Webex | `Cisco-Systems.Spark`, `com.webex.meetingmanager`, `com.cisco.webexmeetingsapp` | | Expected — needs verification |
| FaceTime | `com.apple.FaceTime`, `com.apple.avconferenced` | Call audio may run in the `avconferenced` system daemon, which may report no bundle ID. If "Others" stays silent, use **All system audio**. | Expected — needs verification |

Any other app works with **All system audio**. To have an app listed, open an issue with the results described below.

## Meeting links in your calendar

If you turn on **Settings → Calendar**, Vauta recognises meeting links in events to name the service and suggest recording. It knows links for Zoom (`zoom.us`, `zoomgov.com`), Microsoft Teams (`teams.microsoft.com`, `teams.live.com`), Google Meet (`meet.google.com`), Webex (`webex.com`), FaceTime (`facetime.apple.com`), Jitsi Meet (`meet.jit.si`), Whereby (`whereby.com`), Slack huddles (`app.slack.com`), Amazon Chime (`chime.aws`), Discord (`discord.com`, `discord.gg`) and GoTo Meeting (`meet.goto.com`, `gotomeeting.com`, `goto.com`). Recognising a link does not change what is captured; the audio source does.

## How to verify an app

You need Vauta installed and a real call, for example with a friend or a second device. Tell the other person that you are testing a transcription app.

The commands below use the installed app's binary, which `scripts/install.sh` puts in `~/Applications`. Both commands only read state: they never record audio or open your meetings.

1. **Check the app's processes during the call.** With the call running and the other person talking, run:

   ```sh
   ~/Applications/Vauta.app/Contents/MacOS/Vauta status
   ```

   It lists every process that Core Audio knows about, marking the ones that are playing (●) or using the microphone (🎙), with its bundle ID, its process ID and the family Vauta assigns to it. The last line says which meeting app is using the microphone. Check that:
   - the process that is **playing** the call audio (●) has the expected family, for example `— Chrome, Edge and other Chromium browsers`;
   - the meeting app is named on the last line while your microphone is on in the call.

2. **Record a short test.** In the menu-bar panel, set the audio source to the app's family (or **Auto**), start recording, and let the other person talk for a minute. Check that:
   - the **Others** level meter moves when they speak;
   - their words appear as "Others" in the transcript.

   Then try muting and unmuting, leaving and rejoining the call, and switching headphones, which restarts some apps' audio processes.

   If the app holds the microphone but **Others** carries no sound for 60 seconds, the panel shows an alert once per silent stretch ("… is in a call, but Vauta hears nothing from it") with what to check: the app's sound is muted or plays through a device chosen only inside the app, or Vauta lacks the system-audio permission. **Others** can then be fixed by choosing **All system audio** as the source. Note in your report whether the alert appeared.

3. **If something is wrong**, run the doctor as well:

   ```sh
   ~/Applications/Vauta.app/Contents/MacOS/Vauta doctor
   ```

## Per-app verification checklist (maintainer)

The maintainer runs this once per app before 0.9.0, and again when an app changes how it plays audio. It goes further than
[How to verify an app](#how-to-verify-an-app): it also checks speaker separation, captions and the capture alert. Each run
needs a real call with a second person (tell them you are testing a transcription app), a second device or account is fine.
Nothing here needs meeting content: do not copy transcripts into the results.

### Before you start (once)

- Vauta installed with `scripts/install.sh` signed with your local identity (`scripts/setup-signing.sh`), not an ad-hoc build (ad-hoc builds
  ask for permissions again every time). Note the version: `Vauta --version`.
- **Settings → Speakers → Separate speakers** is on. **Settings → Translation**: Live Translation on, a target language that
  differs from the meeting language, and its language download done.
- Microphone and system-audio permissions granted. Audio source: **Auto**.
- Terminal open with `~/Applications/Vauta.app/Contents/MacOS/Vauta status` ready.

### Steps for each app

1. Join a call with the other person. Make sure you hear them and they hear you. If the app has its own speaker or
   microphone selector, leave it on the same devices as macOS.
2. In the call, ask the other person to say a few sentences, ideally with a second person in the room or on a third device
   so that **two different voices** reach Others for at least a minute (a recording played aloud on their side also works).
3. Start recording in the menu-bar panel (**⌃⌥R**). Speak a few sentences yourself.
4. Run `Vauta status` while the other person talks. Write down the **bundle ID of the process playing the call audio** (the
   process marked ●), the family Vauta assigns, and the app named on the last line as using the microphone.
5. Check, with the panel open:
   - **Me**: the Me meter moves when you speak and your words appear as Me.
   - **Others**: the Others meter moves when they speak and their words appear as Others.
   - **Speakers**: after a minute or so, the two voices show as different speakers (Speaker 1, Speaker 2) in the panel or
     the transcript, and they do not swap when they alternate.
   - **Captions**: press **⌃⌥T**; the captions panel appears over the call (also when the call is full screen), shows their
     speech translated and does not take focus. Share your screen and note whether the panel shows in the share: Vauta asks
     macOS to keep it out, which is not guaranteed for every sharing app.
6. Stress it: mute and unmute yourself, mute the other person, have them leave and rejoin, switch headphones or speakers during
   the call, and share a screen if the app allows. Check that Others keeps arriving and note what broke.
7. **Capture alert.** While still in the call with the microphone held by the app, make Others silent for just over a minute:
   mute the app's sound output (not the other person; or play the call through a device chosen only inside the app, if it
   has such a setting). Vauta cannot tell a fault from a far side that is simply silent, so a far side silent for a minute
   also raises the alert: its wording is a list of things to check, not a claim of a fault. After about 60 seconds the
   panel must show "<app> is in a call, but Vauta hears nothing from it" with **Open Sound Settings**. Dismiss it and
   check that it does not come back while the silence lasts. Restore the sound and let Others be heard for about ten
   seconds: Others must resume and the alert is armed again, so a new silent minute may raise it a second time (that is
   correct, not a failure). Note whether the alert named the right app. With VoiceOver on, the alert is also spoken
   when it appears.
8. Stop recording. Open the meeting: Me and Others both have text, speakers are separated, and no audio file exists
   anywhere (nothing to check on disk; Vauta never writes audio).
9. If Others stayed silent, repeat with **All system audio**, and note that this is the fallback that works.
10. Record the result in the table below: status, bundle ID of the audio process, app and macOS and Vauta versions, date,
    and one line of notes. For a failure: fix `MeetingAppCatalog` with a test, or document the app as unsupported and say
    which source works.

### App-specific notes

| App | Set up | Watch for |
|---|---|---|
| Zoom | Desktop app, a meeting with two participants (a second Zoom account on another device) | Audio from `us.zoom.xos` or a helper; screen sharing with computer sound; Zoom's own "Original sound" setting |
| Microsoft Teams | New Teams (`com.microsoft.teams2`) with a second account; also classic if installed | Which helper plays the audio (note the bundle ID); joining the meeting from the browser instead is a Chrome test |
| Google Meet in Chrome | `meet.google.com` in Google Chrome, signed-in second account | Audio from `com.google.Chrome` helpers; other tabs playing sound at the same time are captured too (say so in the notes); also try a Meet installed as a Dock web app |
| Slack huddle | A huddle in a channel or DM | `com.tinyspeck.slackmacgap` helpers; huddle audio when the Slack window is in the background |
| FaceTime | FaceTime audio and video call with a second Apple ID | Whether Others is silent in **Auto** and works with **All system audio** (`avconferenced` has no bundle ID); the capture alert is expected to fire if it is silent |
| Webex | Webex app, a meeting started from the second account | Which of the three bundle IDs plays the audio |
| Discord | A voice channel with a second account | `com.hnc.Discord` helpers; Discord's "noise suppression" and "Krisp" may change the audio, note the setting |

### Results

Replace "not yet verified" with the outcome. Do not delete a row: add a new dated row when a later run differs.

| App | Status | Audio process (bundle ID) | Others captured | Speakers separated | Captions | Capture alert | App, macOS and Vauta versions | Date | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Zoom | not yet verified | | | | | | | | |
| Microsoft Teams (new) | not yet verified | | | | | | | | |
| Google Meet in Chrome | not yet verified | | | | | | | | |
| Slack huddle | not yet verified | | | | | | | | |
| FaceTime | not yet verified | | | | | | | | |
| Webex | not yet verified | | | | | | | | |
| Discord | not yet verified | | | | | | | | |

## How to report

Open a [bug report](https://github.com/MaquinaTech/Vauta/issues/new/choose), whether it worked or not, and include:

- the app or browser and its version, and the meeting service for web calls (for example "Chrome 141, Google Meet");
- your Vauta version (`Vauta --version`), macOS version and Mac model;
- the audio source you used (Automatic, chosen apps or All system audio);
- the lines of `Vauta status` for the meeting app's processes. You can leave out unrelated processes;
- whether the Others meter moved and whether Others was transcribed;
- anything that changed it, such as muting, rejoining or headphones.

Please **do not paste transcripts, minutes or any meeting content**. `Vauta status` and `Vauta doctor` print none.

When a report confirms that an app works, its status here changes to **Verified**. If an app needs a different bundle ID or helper, the fix goes into `Sources/VautaCore/Capture/MeetingAppCatalog.swift`; see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Live Translation

Live Translation uses Apple's Translation framework, which is a different list from speech recognition:

- **Transcription** (speech recognition) supports the languages `Vauta languages` prints. Live Translation can only translate a meeting whose transcription language is also a Translation language.
- **Translation** supports about 20 languages, some with regional variants (for example Portuguese from Portugal, traditional Chinese). Vauta's pickers show one entry per language and keep the variants that read differently. Not every pair is offered: an unsupported pair shows "Spanish → Korean isn’t available" (the pair in question) in the captions panel, with a menu to choose another language.
- The meeting language and the target must differ. By default the target is the first of your Mac's preferred languages that differs from the meeting's.
- Each pair is downloaded once from Apple (the system asks for consent) and runs on this Mac afterwards. Vauta never downloads anything silently and cannot remove a language: use System Settings › General › Language & Region › Translation Languages.
- macOS 26.4 and later offer a faster, smaller model family (low latency); Vauta uses it when it is installed and otherwise the high-fidelity family every macOS 26 has.
- The captions panel appears over full-screen meeting apps in other Spaces. Vauta asks macOS to keep it out of screen sharing, which is not guaranteed for every sharing app. Verified here: the pipeline, the panel layout and the storage. The system download sheet and the panel over a full-screen call still need confirmation on real calls.
