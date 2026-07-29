# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](../parrot/), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

**Download (recommended).** Grab the latest `.dmg` from the
[Releases](https://github.com/digimata/quill/releases) page, open it, and drag
**quill.app** to Applications. Launch it and the feather appears in the menu
bar.

The app is signed with a Developer ID and notarized by Apple, so it opens
without Gatekeeper warnings.

To also use the CLI (`quill doctor`, `quill run`, …), symlink the bundled
binary onto your `PATH`:

```sh
sudo ln -sf /Applications/quill.app/Contents/MacOS/quill /usr/local/bin/quill
quill doctor                      # check permissions & models
quill install --launch-at-login   # optional — run in the background on login
```

**Build from source.**

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

To produce a signed, notarized `.dmg` yourself, see
[`scripts/build-release.sh`](scripts/build-release.sh) and
[Releasing](#releasing).

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon (the release binary is
`arm64`; build from source for Intel).

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2**
(English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Core ML port — roughly 20 seconds per hour of audio on Apple Silicon. Models
(~600 MB) download once on first transcription; `quill doctor` tells you
whether they're already cached so you're never downloading after an important
meeting.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

## Releasing

Distribution artifacts are Developer ID-signed and Apple-notarized so they run
without Gatekeeper prompts. quill ships as a menu-bar `quill.app` inside a
`.dmg`; everything signs with a single **Developer ID Application**
certificate — no Developer ID Installer cert required.

- **Locally:** `scripts/build-release.sh` builds the release binary, wraps it
  in `quill.app` (Info.plist from `packaging/Info.plist`), codesigns it
  (hardened runtime + `packaging/quill.entitlements`), notarizes and staples
  the app, then packages and notarizes a `.dmg`. It reads its config from the
  environment:

  ```sh
  APP_IDENTITY="Developer ID Application: NAME (TEAMID)" \
  NOTARY_PROFILE=quill-notary \
  VERSION=0.1.0 \
  ./scripts/build-release.sh
  ```

  `NOTARY_PROFILE` is a `notarytool` keychain profile
  (`xcrun notarytool store-credentials`). Set `SKIP_NOTARIZE=1` to sign without
  notarizing (local testing only).

- **CI:** push a `v*` tag and `.github/workflows/release.yml` builds, signs,
  notarizes, and attaches the `.dmg` to the GitHub release. It expects the
  certificate and App Store Connect notary secrets documented at the top of
  that workflow.

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v2 is English-only. Other languages will come with the Whisper
  engine.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
