# quill for macOS

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

The macOS implementation is a single Swift binary with a menu-bar tray and no
app bundle.

## Install

```sh
cd quill
./scripts/build-macos
sudo ./scripts/install-macos
quill install --launch-at-login   # optional — runs in the background on login
```

For direct development inside this platform package:

```sh
cd macos
swift build -c release
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

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
| `mic.caf` | your side (default input device, 16-bit PCM) |
| `system.caf` | everything the Mac played — the other side of the call (16-bit PCM) |
| `mic-002.caf`, `system-002.caf`, … | additional segments, present only if capture had to restart mid-session (see below) |
| `in-progress.json` | temporary segment list while recording; removed after `meta.json` is written |
| `meta.json` | start/end timestamps, duration, per-track segments/offsets, and capture status (`complete`/`recovered`/`incomplete`) |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. Fixed-size PCM packets in CAF need no packet
table on clean close, so audio already written remains readable after a crash.
At 44.1 kHz mono mic and 48 kHz stereo system audio, allow roughly 1 GB per
hour for both tracks combined; usage varies with device sample rates.

## Capture recovery

macOS audio routes are not stable for the length of a meeting — connecting or
disconnecting AirPods, or changing the default device, can silently stop a
capture stream. Quill watches both tracks (a one-second watchdog over callback
progress, plus route-change notifications) and, if a track stalls, restarts it
on the current route into a new numbered segment (`mic-002.caf`, …). The
already-recorded segment is never modified.

What you see while recording:

- feather red, `● recording · 28:11` — both tracks healthy;
- feather orange, `◐ recovering microphone · 28:11` — a track stalled and is
  being restarted (up to three attempts);
- feather orange, `⚠ microphone capture lost · 28:14` — recovery failed; you
  get one notification, and the session will be marked incomplete;
- `△ system audio silent` — secondary diagnostic: the system track is running
  but delivering exact digital silence (may be legitimate — nothing playing).

At stop you get a notification if the session was anything other than
`complete`, and the transcript header carries the same status. Transcription
still runs — every segment that has audio is transcribed and merged on the
session clock, with the gap left visible in the timestamps.

After an incident, inspect `meta.json` in the session folder: each track lists
its `segments` (with session-clock start/end offsets and frame counts) and
`interruptions` (when the stall was detected, when capture resumed, how many
attempts it took). `status` tells you whether the track is `complete`,
`recovered` (usable, with a bounded gap), or `incomplete` (audio missing at
the tail or an unrecovered stall).

If Quill or the Mac stops before you click **Stop recording**, Quill reads
`in-progress.json` on its next launch and rebuilds `meta.json` from every
readable segment. It marks the session `incomplete`, records the interruption,
notifies you, and queues the surviving audio for transcription. A missing or
unreadable segment is listed as a warning in `meta.json`.

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
- **AVAudioFile** — streaming 16-bit PCM into CAF, readable after an unclean exit
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

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
