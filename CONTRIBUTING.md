# Contributing to quill

Thanks for helping improve quill. Small, focused pull requests are easiest to
review, especially around audio capture and permissions where macOS behavior
can be subtle.

## Before you start

- Search existing issues before opening a new one.
- For a substantial feature or behavior change, open an issue first so the
  approach can be agreed before a large patch is written.
- Never upload a real meeting recording, transcript, config file containing
  secrets, or another person's voice. Create a short synthetic audio sample
  when a reproduction needs audio.

## Development setup

You need:

- macOS 15 Sequoia or later
- Xcode 16 or later, or matching Command Line Tools
- Swift 6
- A microphone for capture testing; headphones are useful when testing the
  separate mic and system tracks

Fork the repository, then clone your fork:

```sh
git clone https://github.com/YOUR-NAME/quill.git
cd quill
git remote add upstream https://github.com/digimata/quill.git
swift package resolve
swift build
```

Check the CLI without starting the menu-bar daemon:

```sh
.build/debug/quill --version
.build/debug/quill doctor
```

Running `.build/debug/quill` starts the daemon. macOS will request microphone
and System Audio Recording permissions on first use. Development and release
binaries may be treated as distinct permission identities after a rebuild, so
recheck System Settings → Privacy & Security when capture unexpectedly becomes
silent.

## Project layout

| Path | Purpose |
|---|---|
| `Sources/quill/Audio` | Microphone and Core Audio process-tap capture |
| `Sources/quill/Transcription` | On-device transcription and job coordination |
| `Sources/quill/UI` | Menu-bar UI |
| `Sources/quill/RecordingSession.swift` | Session lifecycle and on-disk metadata |
| `Sources/quill/Config.swift` | User config parsing and path resolution |
| `scripts` | Release packaging and Homebrew formula generation |
| `.github/workflows` | Intel/Apple Silicon CI and tagged releases |

The filesystem is also the transcription queue: a session with `meta.json`
and no `transcript.json` is pending. Preserve that recovery behavior when
changing session or transcription code.

## Making a change

1. Create a branch from the latest `master`.
2. Keep the change focused and explain behavior changes in the commit or PR.
3. Add or update documentation for user-visible CLI, config, file-format, or
   permission changes.
4. Build the production configuration before opening a PR:

   ```sh
   swift build --configuration release
   "$(swift build --configuration release --show-bin-path)/quill" --version
   ```

5. For audio changes, test start, stop, and process termination. Confirm the
   two CAF files remain readable and that a later recording can still start.

CI performs a release build on native Apple Silicon and Intel macOS runners.
The project does not yet have a complete automated audio test suite, so include
the exact manual scenarios you ran in the PR description.

## Pull requests

A useful PR description answers:

- What user problem does this solve?
- What changed, and what intentionally did not change?
- How was it tested, including Mac architecture and macOS version?
- Does it change permissions, config, metadata, transcript output, or recovery
  after a crash?

Do not include generated `.build` content, downloaded transcription models, or
recordings in commits.

## Maintainer release process

quill uses semantic versions and starts at `0.1.0` while interfaces are still
settling.

1. Update `QuillVersion.current` in `Sources/quill/Version.swift` and
   `CFBundleShortVersionString` in `Sources/quill/Info.plist` to the same value.
2. Move the release notes in `CHANGELOG.md` under the new version and date.
3. Run a release build and package the current Mac architecture:

   ```sh
   swift build --configuration release
   ./scripts/package-release.sh 0.1.0 "$(uname -m)"
   ```

4. Commit the version bump, create an annotated tag, and push it:

   ```sh
   git tag -a v0.1.0 -m "quill 0.1.0"
   git push origin master v0.1.0
   ```

The release workflow verifies that the tag, Swift version, and Info.plist
version agree. It builds `arm64` and `x86_64` archives, creates a GitHub release
with checksums, renders `Formula/quill.rb`, and commits the updated formula to
the default branch. Repository Actions must have permission to write contents;
branch protection must allow the release workflow's formula update.
