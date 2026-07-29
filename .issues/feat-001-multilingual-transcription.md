---
title: "Multilingual transcription via Parakeet TDT v3"
date: 2026-07-28
status: implemented
affects: "transcription — model and language selection"
---

## Summary

Quill records audio in any language correctly, but it does not **transcribe**
it: the engine is pinned to Parakeet TDT 0.6B **v2**, which is English-only.
The failure is silent — v2 does not reject Spanish audio, it forces it through
English phonetics and writes a `transcript.md` full of plausible nonsense.

Multilingual capability is **already installed** in the dependency tree.
FluidAudio 0.15.5 (pinned in `Package.resolved`) exposes `AsrModelVersion.v3`
= `parakeet-tdt-0.6b-v3-coreml`, multilingual across 25 European languages,
Spanish among them. This is configuration work, not integration work.

---

## Context: current architecture

A single Swift binary (SPM, no `.app` bundle) running as an `.accessory`
menu-bar daemon. One click records two independent tracks; on stop they are
transcribed on-device and merged.

```
Quill.swift ── AppController (@MainActor)
                 ├─ MenuBarController        NSStatusItem, inline SVG
                 │
                 ├─ START ─► RecordingSession  →  ~/Recordings/<yyyy.MM.dd-HHmm>/
                 │              ├─ SystemAudioRecorder → system.caf  (Core Audio process tap)
                 │              └─ MicRecorder         → mic.caf     (AVAudioEngine)
                 │
                 └─ STOP  ─► meta.json (timestamps + per-track start_offset_ms)
                               │
                               └─► TranscriptionCoordinator (actor, serial queue)
                                      ├─ ParakeetEngine.transcribe(mic.caf)    → "me"
                                      ├─ ParakeetEngine.transcribe(system.caf) → "them"
                                      ├─ shift by offset, sort by time
                                      ├─ transcript.json + transcript.md (atomic)
                                      └─ on_stop hook + notification
```

Design decisions that matter for this work:

- **Two tracks = free diarization.** mic = `me`, system = `them`, with no
  speaker-identification model.
- **The filesystem is the queue.** A session with `meta.json` but no
  `transcript.json` is pending. `resumePending()` rescans on launch.
- **The engine lives behind a protocol.** `TranscriptionEngine`
  (`Sources/quill/Transcription/TranscriptionEngine.swift:14`) exposes
  `prepare()` / `transcribe()` / `release()` plus `name` and `model` as
  provenance. Nothing outside that protocol knows which language is being
  spoken — the blast radius of this change is one file and a half.
- **The engine loads lazily and is released when the queue drains**
  (`TranscriptionCoordinator.swift:91`), so ~600 MB of weights don't sit idle.
- **CAF, not m4a.** No finalization pass needed: a crash mid-meeting doesn't
  lose what was already written.

---

## Verified finding

`Sources/quill/Transcription/ParakeetEngine.swift:31` asks for `version: .v2`.

Verified by cloning `FluidInference/FluidAudio` at tag **v0.15.5**, the exact
revision pinned in `Package.resolved`:

| Check | Result |
|---|---|
| `AsrModelVersion` (`Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift:5`) | `.v2`, `.v3`, `.tdtCtc110m`, `.tdtJa` |
| v3 in its own docs (`Documentation/Models.md:14`) | *"Batch speech-to-text, 25 European languages (0.6B params). **Default ASR model**"* |
| `downloadAndLoad` default | `version: AsrModelVersion = .v3` — quill asks for `.v2` explicitly |
| Signature quill already calls | `transcribe(_ url:decoderState:language:)` — the third argument is optional, so **the current code compiles unchanged against v3** |
| `buildWordTimings` (used at `ParakeetEngine.swift:56`) | global function in `AsrTypes.swift:182`, model-agnostic |
| `AsrManager.loadModels(_ models: AsrModels)` | takes the struct that already carries the version — the manager is untouched |
| `Language` (`Sources/FluidAudio/Shared/TokenLanguageFilter.swift:4`) | includes `case spanish = "es"` |

There are no traps in the v2 → v3 migration.

### Important nuance: the `language` hint does less than it looks

From the documentation on the signature itself:

> *"Optional language hint for **script-aware token filtering** (v3 only). When
> set, top-K tokens that don't match the language's **script** are skipped."*

And in `TokenLanguageFilter.swift:41`, Spanish and English sit in the same
group: `.latin`. So **the hint does not condition the model on Spanish**, it
only discards candidates from another alphabet. That is genuinely useful for
Russian or Greek; for Spanish its effect is close to nil. v3 does the real work
on its own.

Design consequence: **don't build UI or configuration that promises a
fine-grained "Spanish mode"**, because the engine doesn't deliver one.

---

## Project guidelines (extracted from history)

There is no `CLAUDE.md` or `CONTRIBUTING.md`. The guidelines live in the
decisions, and they are consistent:

**1. UI gets trimmed, not extended.**

- `60c1571 revert: drop the floating recording overlay` — deleted 158 lines and
  all of `UI/RecordingOverlay.swift`. Reason: *"macOS already shows a mic
  indicator… drawing our own pill over the desktop was noise."*
- `d33beb3 fix: keep the menu bar to just the feather — no elapsed counter`

The menu has five items and **none of them is a preference**: three actions
(record, open folder, quit) and two disabled status labels.

**2. Every option lives in `config.json`.** The pattern was set in `7b76df8`
and `8ab6ebb`, identical each time: a new key, an opinionated default, and a
README paragraph explaining the trade-off. The entire diff of `8ab6ebb`
(flipping the echo-cancellation default) was **10 lines across 2 files**, none
of them UI.

**3. `Config` is read-only and uncached.** It reads from disk on every query
and never writes. That's what keeps there from being any state to synchronize.

**4. Opinionated defaults, documented with their cost.** Each one carries the
"why" in its doc comment and in the commit body.

**5. Doc comments explain the why and the failure they prevent**, not the what.

**6. Single binary, no external resources.** Even the icon is an inline SVG
(`MenuBarController.swift:92`).

**7. Conventional commits with a body explaining the reason.**

### Rejected: a visual language picker

A submenu listing the 25 languages with a checkmark on the active one was
considered. **Rejected**, for three reasons:

- It contradicts guideline 1, with two precedents of UI deleted as noise.
- It would require `Config` to write, breaking guideline 3 and introducing the
  first source of persistent state written by the app.
- **A meeting's language doesn't change between sessions** — it's a property of
  the user, not of the meeting. A picker optimizes for frequent switching.
  Compare `mic_voice_processing`, which genuinely is context-dependent
  (headphones vs. speakers) and still lives in JSON.

---

## Design

A single knob, inside the `transcription` block that already exists:

```json
{
  "transcription": { "enabled": true, "engine": "parakeet", "language": "en" }
}
```

Language → model mapping, internal:

| `language` | Model | Reason |
|---|---|---|
| `"en"` (default) | Parakeet v2 | better WER on English; preserves current behaviour |
| any of the other 25 | Parakeet v3 + hint | multilingual |
| `"auto"` | Parakeet v3, no hint | autodetection |

**Default `"en"`.** It preserves today's behaviour exactly, doesn't force a
600 MB download on existing users, and makes other languages opt-in — the same
reasoning that made echo cancellation opt-in in `8ab6ebb`.

One knob (language) is preferred over two (model + language): users think in
languages, not in model versions, and every value changes something real.

### Plan by file

| File | Change |
|---|---|
| `Sources/quill/Config.swift` | `transcriptionLanguage() -> String` alongside the other `transcription` accessors, same doc-comment style |
| `Sources/quill/Transcription/ParakeetEngine.swift` | language → (`AsrModelVersion`, `Language?`) mapping; take it in `init`; pass `language:` to `transcribe`; make `model` dynamic provenance (hardcoded today at `:25`) |
| `Sources/quill/Transcription/TranscriptionCoordinator.swift` | `preparedEngine()` (`:143`) builds the engine — read the config there |
| `Sources/quill/Doctor.swift` | `checkTranscription()` (`:81`) parameterizes the version instead of pinning `.v2` at `:89-90` |
| `README.md` | a paragraph with the trade-off, in the style of the `mic_voice_processing` one |

Expected size: the size of `8ab6ebb` — dozens of lines across 4 files plus the
README.

### What the architecture gives for free

Two problems that showed up under the UI approach simply **disappear**:

- *Invalidating the cached engine when the model changes*: because `Config`
  reads from disk on every query and the coordinator releases the engine when
  the queue drains, editing the JSON already takes effect on the next drain.
  All that's needed is to **document** that a change mid-queue doesn't affect
  the batch in flight — which is the desirable behaviour anyway (consistency
  within a batch).
- *A progress-bar UI for the download*: `quill doctor` already exists for
  exactly this (*"Never discover a missing model after an important
  meeting"*). It only needs to look at the selected model's cache.

---

## Risks and unknowns

1. **v3's real-world quality is still unmeasured.** v3 traded some English
   accuracy for multilingual coverage. The test below uses clean TTS, which
   says nothing about noise, overlapping speech or accents. **This remains the
   one serious unknown**, and it is why this issue stays open rather than
   closing.
2. ~~**v3 download size: unverified.**~~ Resolved: 470 MB (v2 is 452 MB).
   Separate caches, they coexist without clobbering each other.
3. ~~**None of this has been compiled.**~~ Resolved: it builds and runs.
4. **Segmentation: verified, with a new nuance.** Breaking on a `.` / `?` / `!`
   suffix survives, but not for the predicted reason. On Spanish audio v3 emits
   **no `¿` or `¡` at all** and closes questions with `.` rather than `?`.
   Segments break on the period; the result is right, the premise was wrong.
5. **Three languages FluidAudio knows and v3 doesn't cover.** The `Language`
   enum has 28 cases because it partitions *scripts*, not model coverage: it
   includes `bs`, `be` and `sr`, which NVIDIA doesn't list among the 25. They
   are transcribed anyway — they sit close to covered neighbours — but never
   silently: a warning goes to stderr.

---

## Verification

Tested without recording a meeting: a fabricated session (`meta.json` +
`mic.caf`) under a custom root, which `resumePending()` picks up on its own via
`quill run --out <dir>`. Audio: 12.4 s of Spanish synthesized with
`say -v "Mónica"` (es_ES), the same file down both paths.

**`transcription.language: "es"` → v3**

> Buenos días a todos, como veis la migración del pipeline de transcripción.
> Creo que deberíamos añadir suporte multilingüe cuanto antes, porque el modelo
> actual solo entiende inglés, y eso es un problema serio para nuestras
> reuniones en español.

Two errors in ~40 words (`como` missing its accent, `suporte` for `soporte`).
Accents, ñ and diaeresis all correct.

**`transcription.language: "en"` → v2, the same audio**

> How is the migration of the people in transcription?
> I think that we have a support of multilingual […] because the model actual
> zoning and less, and that is a problem for our union in Spanish.

`transcribe.log` recorded `done — 2 segments`. No error, no warning, a
well-formed `transcript.md`. The silent failure from the summary, reproduced —
including an obscenity invented out of "cuanto antes".

Also verified:

- **Language → model mapping** across all 29 possible values: 25 pass with no
  warning (English via v2, the other 24 via v3), `auto` passes, `bs`/`be`/`sr`
  warn and run, an unknown code warns and falls back to English.
- **Provenance**: `transcript.md` records the model that actually ran.
- **Effective version**: v3 loads an 8192-token vocabulary; v2 loads 1024.

---

## Code observations (independent of this feature)

Found while reviewing; none of them blocks the work above.

1. **`Package.swift:9` asks for FluidAudio `from: "0.7.0"` while
   `Package.resolved` pins 0.15.5.** In SwiftPM, `from:` on a 0.x version
   resolves up to `<1.0.0`, and within 0.x SemVer offers no protection against
   breaking changes: a clean `swift package update` can pull an incompatible
   API. Suggested: `.upToNextMinor(from: "0.15.0")`. *(That very version jump is
   what brought multilingual support.)*
2. **`MicRecorder` is `@unchecked Sendable` over genuinely shared state.**
   `firstBufferAt`, `livenessPeak` and `livenessFrames` are written from the tap
   callback and read from main (`RecordingSession.swift:57`). Same in
   `SystemAudioRecorder.swift:141`. Benign in practice, but a real data race the
   compiler isn't checking.
3. **`Config.load()` reparses the JSON on every query**, several times per
   session. Trivial cost, but it lets the config change mid-session
   inconsistently. *(Note: this same property is what makes a language change
   apply on its own — see above. Don't "fix" it without weighing that.)*
4. **Input-device changes during recording are unhandled.** Unplugging
   headphones mid-meeting can stop `AVAudioEngine` and truncate the mic track
   with no warning. The liveness check only covers the first second.
5. **`AVAudioFile.write` inside the audio IOProc**
   (`SystemAudioRecorder.swift:148`) — disk I/O in a latency-sensitive
   callback. It runs on its own `DispatchQueue`, so it's defensible, but it's
   the likely cause if glitches ever show up.
6. **No tests and no CI.** For a project whose costliest bug was a silent
   framework failure (rca-001), a test over `MicRecorder`'s format and liveness
   would have the highest return — though the hard part is inherently untestable
   without hardware.
7. **Transcript-level echo suppression is still unimplemented** (proposed at
   `rca-001:96`). It's the safety net for paths where AEC doesn't work.

---

## References

- `.issues/rca-001-voice-processing-silent-mic.md` — RCA of the silent mic;
  context for why `mic_voice_processing` is opt-in.
- FluidAudio v0.15.5 — `Documentation/Models.md`, `AsrModels.swift`,
  `TokenLanguageFilter.swift`, `AsrManager.swift`.
- v3 model: `FluidInference/parakeet-tdt-0.6b-v3-coreml` (HuggingFace).
- Alternatives in the same enum, not evaluated: `.tdtCtc110m` (110M, smaller
  and faster, English), `.tdtJa` (Japanese).
