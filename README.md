# Local Meeting Notes

Private desktop meeting recorder and offline transcription app for Windows and Apple Silicon macOS, powered by whisper.cpp.

## What it does

- Records system audio and an optional microphone.
- Transcribes locally after **Stop and transcribe**; no cloud transcription account or API key.
- Offers German and English, using a shared multilingual small Q5_1 model.
- Saves timestamped subtitles and plain text, with recording checkpoints and interrupted-session recovery.
- Keeps audio by default. After a complete transcript is saved, **Delete audio** can remove the current meeting's WAV files after confirmation.

## Downloads and current status

Download the platform package from [Releases](../../releases). Build workflows publish a private preview release only after their compilation and checks succeed.

| Platform | Package | Verification |
| --- | --- | --- |
| Windows 10/11, Intel/AMD x64 | Portable EXE inside a ZIP; runtime, engine and model bundled | Recording and offline transcription tested locally; CI checks storage/recovery and packaging |
| macOS 15+, Apple Silicon | Native `.app` inside a ZIP; framework, helper and model bundled | Compiled and storage/model checks passed on an arm64 Mac runner; live microphone/system-audio capture still needs a user-session test |

Preview builds are unsigned on Windows and ad-hoc signed on Mac. macOS builds are not notarized. A managed device may require its normal IT approval. This repository does not disable system security protections.

## Build Windows

Install the .NET 10 SDK (the packaged app targets and bundles .NET 8.0.33), then run PowerShell from the repository root:

```powershell
./scripts/Build-Windows.ps1
```

The first build downloads checksum-pinned Whisper/model files, verifies Microsoft's signed native runtime package, and restores locked NuGet dependencies. The redistributable installer is not executed; the required libraries are bundled locally. The output is `dist/LocalMeetingNotes-Portable-Windows-x64.zip`. No runtime installation or internet connection is needed by the resulting app.

## Build Apple Silicon macOS

On macOS 15+ with Xcode 16+ or compatible Command Line Tools containing the macOS 15 SDK:

```bash
bash macos/Build.command --long-tests
```

The first build fetches verified model/framework files. It runs storage/recovery checks, builds the arm64 app and helper, signs the bundle locally, and checks model initialization. Outputs are `macos/dist/Local Meeting Notes.app` and `macos/dist/LocalMeetingNotes-macOS-AppleSilicon.zip`.

Move the app to Applications before first opening it. Grant microphone and **Screen & System Audio Recording** permissions yourself, and make a short test recording of system playback and your voice. No video or screenshots are saved. A successful headless CI build cannot test these permissions or real capture.

See the [verification record](docs/verification.md), [Mac instructions](macos/Read%20me.txt), [Windows instructions](docs/windows.txt), and [portable Windows instructions](docs/windows-portable.txt).

## Source layout

- `windows/Source`: C# Windows Forms app, WASAPI capture, recovery and checks.
- `macos/Source`: native Swift interface/capture/storage and a C++ Whisper helper.
- `macos/Tests`: runnable storage/recovery and generated two-hour audio checks.
- `scripts`: dependency verification and Windows portable-package builders.
- `.github/workflows`: platform builds, checks and preview release publication.
- `licenses`: third-party notices.

Large models, native downloads, compiled applications and installers are not stored in Git. Builders fetch verified dependencies and include them in the offline packages. The model is approximately 190 MB; removing language menu choices alone does not shrink its shared weights.

## Recordings, recovery and deletion

Windows portable data lives in `LocalMeetingNotes-data/Meetings` beside the executable. Mac data lives in `~/Library/Application Support/LocalMeetingNotes/Meetings`. **Open meeting folder** shows the current recording's files.

Recording writes continuously to disk and requests durable checkpoints about every five seconds. The app asks the OS to stay awake and checks available space. Two hours with system audio and microphone uses about 690 MB across the original tracks and combined WAV. Recovery works on copies, retaining originals. Forced sleep, device failure, sudden power loss or damaged storage can still lose recent or unavailable audio; there is no zero-loss guarantee.

Deletion is optional and permanent for the current meeting's WAV files; transcripts, subtitles and logs stay. Imported originals and original interrupted-recording folders stay. Deletion is not secure disk erasure and does not remove external backups.

No recordings or transcripts are part of this repository or its releases. `.gitignore` excludes meeting folders, common audio/subtitle files, caches and credentials. Review your own commits before sharing additional data.

## Dependencies and licensing

Whisper is pinned to the official b5454 / 1.9.5 release, and the model to a pinned Hugging Face revision with SHA-256 verification. Windows uses NAudio 2.2.1 and bundles .NET plus Microsoft's app-local C++ runtime. Mac uses Apple's system frameworks and the official Whisper Mac framework; Apple SDKs are not redistributed.

Third-party license notices are in `licenses` and in the platform packages. No public license has been assigned to this private application's own source code.

