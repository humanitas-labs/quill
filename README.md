<p align="center"><img src="docs/icon.png" width="96" alt="quill"></p>

# quill

A fully local meeting recorder and transcriber. Quill records your mic and the call's audio as separate tracks, transcribes them on-device, and writes a timestamped `me` / `them` transcript. Nothing leaves the machine.

## 1. Install

```sh
./scripts/build-macos
sudo ./scripts/install-macos
quill install --launch-at-login   # optional
```

Requires macOS 15+. Apple Silicon is recommended for transcription speed.

## 2. Usage

1. Click the feather in the menu bar and choose **Start recording**. First use asks for microphone and system audio permissions.
2. Choose **Stop recording** when the meeting ends. Transcription starts automatically.
3. The transcript lands in `~/Recordings/<yyyy.MM.dd-HHmm>/transcript.md`, next to the audio.

Already have a recording? AirDrop a Voice Memo from your iPhone to your Mac, then drag it from Downloads onto the feather (or choose **Transcribe audio file…**). It gets its own session folder and the same transcript.

See the [macOS documentation](macos/README.md) for configuration, the CLI, and troubleshooting.

## 3. Platforms

| Platform | Status | Documentation |
|---|---|---|
| macOS 15+ | Working | [macOS](macos/README.md) |
| Windows 11 | Capture probe planned | [Windows](windows/README.md) |
| Linux | Capture probe proposed | [Linux](linux/README.md) |

Each platform is a native, independent implementation. They share the session layout, transcript format, and test fixtures, not source code. See [docs/architecture.md](docs/architecture.md).

## 4. License

[MIT](LICENSE). Sibling of [parrot](https://github.com/humanitas-labs/parrot).
