# Quill architecture

Last updated: `2026.08.04`

Quill is one product with separate native implementations for each supported
desktop platform. Platform code does not share a runtime or source language.
Compatibility is maintained through shared behavioral contracts and fixtures.

## Repository boundaries

```text
Quill product
├── shared behavior and formats
├── macOS implementation
│   ├── Swift and AppKit lifecycle
│   ├── Core Audio capture
│   └── Core ML transcription through FluidAudio
├── Windows implementation
    ├── native Windows lifecycle
    ├── WASAPI microphone and process-loopback capture
    └── local ONNX transcription
└── Linux implementation
    ├── native Linux lifecycle
    ├── PipeWire microphone and playback capture
    └── local ONNX transcription
```

| Path | Responsibility |
|---|---|
| `macos/` | Complete native macOS implementation and Swift package |
| `windows/` | Native Windows implementation and platform documentation |
| `linux/` | Native Linux implementation boundary and platform documentation |
| `docs/` | Current architecture and historical decisions |
| `.plan/` | Product roadmap and active implementation plans |
| `fixtures/` | Future cross-platform session and transcript compatibility fixtures |
| `scripts/` | Stable repository-level developer entry points |

## Shared contract

The platforms share these concepts even when their audio containers differ:

- one timestamped directory per recording session;
- independent microphone (`me`) and playback (`them`) tracks;
- `meta.json` describing session times, per-track segment files, offsets, and
  capture completeness (schema v2 below);
- canonical, timed, speaker-tagged `transcript.json`;
- readable `transcript.md` generated from the canonical transcript;
- a recoverable filesystem-backed transcription queue; and
- local-only recording and inference.

### Session metadata v2

Audio routes are not stable for the length of a meeting (rca-006), so a track
is a sequence of one or more segment files rather than one file. `meta.json`
schema v2 is the shared contract for that:

- `schema_version: 2`, session `started`/`ended` (ISO 8601, human-readable
  only), `duration_seconds`, and a session `status`;
- `tracks[]`, each with `kind` (`mic`/`system`, or `memo` for an imported
  file), `speaker` (`me`/`them`/`memo`), a final `status`, `segments[]`,
  `interruptions[]`, and `warnings[]`;
- optional `source`: the original file name of imported audio, absent for
  live recordings;
- each segment records `file`, `start_offset_ms`, `end_offset_ms`,
  `frames_written`, `sample_rate_hz`, and `channels`;
- each interruption records `detected_offset_ms`, `recovered_offset_ms`
  (absent when unrecovered), `reason`, `attempts`, and an optional `error`.

Rules the schema encodes:

- **Monotonic alignment.** Every offset is milliseconds on one monotonic
  session clock captured at session start. Wall-clock adjustments can never
  move segments relative to one another; `started`/`ended` are display values.
- **Segment naming.** The first segment is `mic.caf`/`system.caf` (`.wav` on
  Windows); recovery restarts append a counter: `mic-002.caf`, `mic-003.caf`.
  A segment already on disk is never reopened, truncated, or overwritten.
- **Final status.** `complete` (ran through stop without a detected
  interruption), `recovered` (capture resumed; the interruption and its
  bounded gap are preserved), or `incomplete` (capture could not be restored
  or was stale at stop). Session status is the worst track status. A recovered
  session is usable but never represented as uninterrupted.
- **Backward reads.** Transcription readers accept both v2 and the original v1
  shape (`files` + `start_offset_ms`, absent offsets defaulting to 0), so
  sessions recorded before v2 remain transcribable unchanged. Writers emit v2
  only, atomically, after capture teardown finishes.
- **Merging.** Each segment transcribes independently and is shifted by its
  `start_offset_ms`; capture gaps stay visible as timestamp gaps in the merged
  transcript.

**Imported audio.** An existing recording (e.g. an AirDropped Voice Memo) is
staged as a v2 session with one complete `memo` track whose single segment
starts at offset 0. The source is copied, never moved; meta.json is written
last so a partial import is never picked up by the transcription queue.

Formal JSON schemas and compatibility fixtures will be extracted before the
Windows capture probe becomes a full application. Until then, the macOS output
implemented in `macos/Sources/quill/SessionMeta.swift`,
`macos/Sources/quill/RecordingSession.swift`, and
`macos/Sources/quill/Transcription/TranscriptionCoordinator.swift` is the
reference behavior, with schema tests in `macos/Tests/QuillTests/`.

## Build and release boundaries

Each platform owns its build graph, dependencies, tests, packaging, and release
artifact. Repository-level scripts provide stable entry points. A platform
failure must not prevent the other platform from building independently.

Release artifacts will be platform-qualified rather than presented as one
portable executable.

## Decision log

| Decision | Status | Summary |
|---|---|---|
| [ADR-001](decisions/001-multiplatform-repository.md) | Active | Keep native platform implementations in one repository under symmetric platform roots. |
