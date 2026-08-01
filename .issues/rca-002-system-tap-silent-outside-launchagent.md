---
title: "System audio records digital silence unless quill runs as a LaunchAgent"
date: 2026-08-01
status: open
affects: "system audio capture and far-end speaker attribution"
---

## Context

Quill captures system playback with a Core Audio process tap
(`AudioHardwareCreateProcessTap`) feeding a private aggregate device. The tap is
subject to TCC: the capturing process needs system-audio-capture authorization,
which macOS surfaces in System Settings under Privacy & Security as two separate
lists — "Screen & System Audio Recording" and "System Audio Recording Only".

Because quill ships as a bare binary rather than an `.app`, `Package.swift`
embeds `Info.plist` into `__TEXT,__info_plist` via linker flags, carrying
`CFBundleIdentifier` and `NSAudioCaptureUsageDescription`. The stated purpose is
"so TCC can attribute permissions to quill itself when running as a
LaunchAgent".

The README's install recipe is `swift build -c release`, `sudo cp` to
`/usr/local/bin`, and `quill install --launch-at-login` marked **optional**.
"How to use" step 1 reads "Run it (`quill` in a terminal, or the LaunchAgent)",
presenting the two as equivalent.

They are not equivalent. Run from a terminal, the system track is digitally
silent, and nothing in quill reports a problem.

## Problem statement

Measured on macOS 26.5.2 (25F84), Apple Silicon, Swift 6.3.3, at `855869e`.
Each take played the same synthetic speech through the default output device
(MacBook Pro Speakers) while recording. Levels are computed by decoding the
resulting CAF to 16-bit PCM.

| # | launched by | signature | system peak | system non-zero | mic peak |
|---|---|---|---|---|---|
| 1 | shell | linker-signed | −∞ dB | 0.0% | −10.8 dB |
| 2 | shell | linker-signed, fresh process | −∞ dB | 0.0% | −13.1 dB |
| 3 | shell | re-signed, Info.plist bound | −∞ dB | 0.0% | −11.7 dB |
| 4 | **LaunchAgent** | re-signed, Info.plist bound | **−1.6 dB** | **50.9%** | −13.6 dB |

The mic track is healthy in every take, so the sessions themselves are sound.
Only the system track is affected.

The failure is entirely silent:

1. `AudioHardwareCreateProcessTap` returns `noErr`.
2. `kAudioTapPropertyFormat` reports a correct 2 ch / 48 kHz stream.
3. The aggregate device is created successfully and `AudioDeviceStart` succeeds.
4. The IO proc fires at the correct rate for the full session — take 1 delivered
   1,962 packets across 41.8 s at 1,024 frames per packet, matching wall clock.
5. Every sample in every buffer is zero.

A correctly clocked device delivering well-formed, all-zero buffers is the
signature of an unauthorized tap, not a broken audio graph. No error path in
`SystemAudioRecorder` can observe this, because at the API level nothing failed.

No TCC prompt appeared in takes 1–3. Quill never appeared in either permission
list. In take 4 macOS prompted with `"quill" would like access to record your
system audio` — naming quill itself — and capture worked immediately after
approval.

## RCA

Two independent defects compound. Only the second is load-bearing.

**1. `swift build` output does not bind the embedded Info.plist.**

The release binary is ad-hoc *linker-signed*:

```
CodeDirectory ... flags=0x20002(adhoc,linker-signed)
Identifier=quill
Info.plist=not bound
```

The linker writes the `__TEXT,__info_plist` section, but the signature it
generates seals no special slots, so the Info.plist is not covered by the code
directory. TCC will not read `CFBundleIdentifier` or
`NSAudioCaptureUsageDescription` from a section the signature does not bind, so
the embedded plist cannot do the job `Package.swift` added it for. Re-signing
fixes it:

```sh
codesign --force --sign - --identifier com.digimata.quill /usr/local/bin/quill
```

```
CodeDirectory ... flags=0x2(adhoc)
Identifier=com.digimata.quill
Info.plist entries=4
```

**2. A shell-launched process is not attributed to quill.**

This is the actual cause. TCC evaluates a request against the *responsible
process*, not necessarily the calling one. Launched from a terminal, quill's
responsible process is the terminal or host application, so the tap is
authorized against that subject. Quill has no identity of its own to grant, and
because the responsible process already carries its own TCC record, no prompt is
raised for the missing system-audio grant either. The result is an authorized-
looking, silent tap.

Take 3 is the decisive one: with the Info.plist correctly bound, a shell-launched
quill was still silent and still produced no prompt. Binding alone is not
sufficient. Under launchd the process is its own responsible process, TCC
evaluates quill's own identity, the prompt names quill, and capture works.

This also explains an observation that initially looked contradictory: the host
application *did* hold "Screen & System Audio Recording", yet the tap was still
silent. Process taps are gated on the system-audio-capture service — the
"System Audio Recording Only" list — which was empty on the test machine. A
Screen Recording grant does not confer it.

**Ruled out during diagnosis.** The aggregate device was suspected of lacking a
clock source, since `createAggregateDevice` passes an empty
`kAudioAggregateDeviceSubDeviceListKey` and no main sub-device. Adding the
default output device as `kAudioAggregateDeviceMainSubDeviceKey` and as the sole
sub-device changed nothing (take 3 was run with that variant). The aggregate
configuration is fine; the change was reverted.

## Proposed fix

**Documentation, and it is the minimum.** The LaunchAgent is not optional for
system audio. "How to use" should not offer running from a terminal as an
equivalent option, and the Gotchas entry pointing at Screen Recording is
misleading — the user will find quill absent from that list with no way to add
it, because a bare binary cannot be added through the `+` picker.

**Detect the silence in code.** This is the highest-value change, because the
failure is otherwise invisible: the user records a meeting, believes both sides
were captured, and discovers at transcription time that the far end is gone.

`MicRecorder` already establishes the pattern — it tracks signal peak over the
first second of the voice-processing path and falls back when the route delivers
digital zeros (rca-001). `SystemAudioRecorder` should do the same: accumulate
peak over the first second of tap callbacks, and if it is exactly zero, log and
notify. Unlike the mic case there is no fallback to switch to, so the correct
action is to tell the user loudly rather than to recover silently.

**Make `doctor` say something useful.** `checkSystemAudio` currently reports
"state unknowable until first use", which is true of the TCC state but not of
the configuration that determines it. A process launched by launchd has `PPID`
1; when quill is running any other way, doctor can warn that system audio will
not be captured regardless of granted permissions.

**Do not add a re-signing step.** It was the obvious candidate fix and it turns
out to be unnecessary — see below. Binding the Info.plist is still arguably
worth doing so `CFBundleIdentifier` survives into the signature, but it fixes
nothing on its own and should not be sold as the remedy for silent capture.

## Is re-signing required? No.

Tested directly. A stock `swift build -c release` binary — `linker-signed`,
`Identifier=quill`, `Info.plist=not bound`, no modification of any kind — was
installed to `/usr/local/bin/quill` and the LaunchAgent restarted so the new
image was actually loaded. A permission prompt was approved, and the next
recording captured system audio at −0.6 dB peak across 54.6% non-zero samples.

| binary | launched by | system peak |
|---|---|---|
| re-signed, Info.plist bound | LaunchAgent | −1.6 dB |
| **stock, linker-signed, not bound** | **LaunchAgent** | **−0.6 dB** |

So defect 1 is real but not load-bearing. The LaunchAgent is the necessary and
sufficient condition, and **the install recipe needs no `codesign` step**. This
is the more useful outcome: it means the fix is documentation plus a liveness
check, with no change to how the binary is produced.

Note that `tccutil reset AudioCapture com.digimata.quill` cannot be used to get
a clean slate here — `tccutil` resolves bundle identifiers through
LaunchServices, which does not know a bare binary, and returns OSStatus -10814.
Only a service-wide reset works, which revokes every other app's grant too.

**Residual uncertainty.** The grant used by the stock binary was approved while
that path had already been overwritten with the stock binary, but while the
previously-granted signed image was still the running process. Whether TCC keyed
that grant to the code signature or to the executable path was therefore not
isolated, and this machine had prior quill grant history at the same path. On a
machine that has never granted quill, the prompt may behave differently. What is
demonstrated is the practical claim: a stock binary under launchd obtains and
uses a working system-audio grant.

## Relevant files

**Fix targets:**

- `README.md` — presents terminal and LaunchAgent as equivalent; the Gotchas
  entry sends users to the wrong permission list.
- `Sources/quill/Audio/SystemAudioRecorder.swift` — no liveness check; every
  error path passes because nothing returns an error.
- `Sources/quill/Doctor.swift` — `checkSystemAudio` cannot report the one thing
  it could actually determine.
- `Package.swift` — embeds the Info.plist that the resulting signature does not
  bind.

**Flow:**

- `Sources/quill/RecordingSession.swift` — starts the system recorder first; a
  silent tap does not fail, so the session proceeds normally.
- `Sources/quill/Transcription/TranscriptionCoordinator.swift` — transcribes a
  silent track without complaint, yielding a transcript with no `them` segments.

**Precedent:**

- `.issues/rca-001-voice-processing-silent-mic.md` — same failure shape on the
  mic track, and the liveness check added there is the model for the fix
  proposed here.
