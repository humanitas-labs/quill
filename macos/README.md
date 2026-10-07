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
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `mic-002.caf`, `system-002.caf`, … | additional segments, present only if capture had to restart mid-session (see below) |
| `meta.json` | start/end timestamps, duration, per-track segments/offsets, and capture status (`complete`/`recovered`/`incomplete`) |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

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

## Transcription

By default, transcription runs on-device with **Parakeet TDT 0.6B v2**
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
`transcribe.log`, keep the session pending for retry, and never block later
jobs.

Three provider choices share the same recording queue and transcript format:

- `parakeet` (default): the built-in FluidAudio engine.
- `handy`: reuse an installed Handy runtime and its downloaded local models.
- `command`: call another local engine through a configurable executable or
  wrapper that implements the JSON contract below.

Unknown engines and invalid provider settings fail explicitly. Quill never
silently substitutes a different model.

### Handy

Install a [Handy](https://github.com/cjpais/Handy) build whose `--help` includes
`--transcribe-file`, `--list-models`, and `--json`. Older builds without these
headless commands are not supported. Download the desired model in Handy, then
copy its id from:

```sh
/Applications/Handy.app/Contents/MacOS/handy --list-models --json
```

Configure Quill:

```json
{
  "transcription": {
    "engine": "handy",
    "handy_model": "handy-computer/parakeet-unified-en-0.6b-gguf/parakeet-unified-en-0.6b-Q8_0.gguf"
  }
}
```

That model id is the default when `handy_model` is omitted; Quill passes it
explicitly, independently of the model selected in Handy's UI. Handy reuses
its existing local model cache and does not download during transcription.
`quill doctor` checks the headless CLI and that this model is downloaded.

Quill searches `/Applications/Handy.app`, `~/Applications/Handy.app`,
`/opt/homebrew/bin/handy`, and `/usr/local/bin/handy`. Set `handy_executable`
to an absolute path (or `~/...`) to override discovery.

Handy's file mode returns text without word timestamps. Quill records one
segment per nonempty chunk, using the chunk's actual audio duration. Chunks
are at most five minutes, with a ten-minute process timeout per chunk.
These coarse timestamps make overlapping conversation less precise than
Parakeet's word-based segments. Each chunk starts a new process and reloads
the model; words at chunk boundaries can lose context.

### Other local command providers

Use a local executable, or a wrapper around a CLI such as `whisper.cpp` that
converts its result to Quill's JSON contract. This does not require changing
Quill's source or adding an inference library dependency.

```json
{
  "transcription": {
    "engine": "command",
    "command": {
      "name": "my-local-engine",
      "executable": "~/.local/bin/my-transcription-adapter",
      "arguments": ["--audio", "{audio}", "--model", "{model}"],
      "model": "/absolute/path/to/local/model",
      "chunk_seconds": 300,
      "timeout_seconds": 600
    }
  }
}
```

- `executable`, `arguments`, and `model` are required. `name` defaults to
  `command`; the name and model are saved as transcript provenance.
- The executable path must be absolute or begin with `~/`. Arguments are
  passed directly, with no shell expansion. `{audio}` is required and becomes
  the temporary WAV path; `{model}` becomes the configured model string.
  Spaces and shell punctuation stay literal. Use absolute model paths; `~`
  in arguments or model strings is not expanded.
- Input is 16 kHz mono 16-bit PCM WAV. `chunk_seconds` defaults to 300 and
  accepts 1–300; `timeout_seconds` defaults to 600 and accepts 1–3600.
  The wrapper must use local inference to preserve Quill's local-only behavior.
- Exit zero and write **one JSON object to stdout** (maximum 16 MiB). Write
  logs/errors to stderr (maximum 4 MiB). Quill drains both streams while the
  process runs; the timeout also covers descendants keeping either stream open.
  Remaining descendants in the command's process group are terminated when it
  finishes. A nonzero exit, output overflow, or timeout fails the job, with a
  bounded stderr excerpt in `transcribe.log`.
- Temporary audio is removed after success or failure. Captured output stays
  in bounded memory buffers and is discarded after the command completes.
  `doctor` verifies the executable; a short test recording is needed to verify
  a custom provider's model and output protocol.

For precise timing, return segments with start/end **seconds relative to the
input chunk**, within its duration:

```json
{"segments": [{"start": 0.25, "end": 1.5, "text": "Hello."}]}
```

For engines without timestamps, return text covering the whole chunk:

```json
{"text": "Hello."}
```

An empty `segments` array or empty `text` means silence. If both are present,
`segments` takes precedence. Quill adds chunk and recording-segment offsets
itself, preserving silent chunks and capture gaps on the session clock.

Native providers implement `TranscriptionEngine`. CLI-specific integrations
implement `TranscriptionCommandAdapter` and register in `TranscriptionProvider`;
the shared host owns audio conversion, processes, validation, and timing.

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
- `transcription.engine` — `parakeet` (default), `handy`, or `command`; see the
  provider configuration above. Restart Quill after changing providers.
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

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v2 is English-only; language support depends on the selected
  provider. Native WhisperKit support is tracked separately in issue #69.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.

## Development checks

From the repository root:

```sh
swift test --package-path macos
swift build --package-path macos -c release
```

Adapter tests use temporary executables and synthetic audio, with no installed
models required. To also exercise an installed Handy runtime and its downloaded
default model, generate the smoke-test phrase and opt in:

```sh
say -o /tmp/quill-handy-test.aiff 'This is a local transcription test. The meeting starts at ten in the morning.'
QUILL_HANDY_TEST_AUDIO=/tmp/quill-handy-test.aiff swift test --package-path macos --filter testInstalledHandyWithSyntheticSpeech
```
