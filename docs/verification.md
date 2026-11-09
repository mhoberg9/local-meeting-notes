# Verification record

Checked on November 9, 2026.

## Windows

[GitHub Actions run](https://github.com/mhoberg9/local-meeting-notes/actions/runs/42630431271) completed successfully for commit `cbf5c04`.

- Portable executable compiled with locked dependencies and bundled runtime/model/native engine.
- Live WAV checkpoint reading, interrupted-process recovery and original-file preservation passed.
- Deletion without completed transcripts was refused; completed-transcript cleanup preserved notes.
- Generated two-hour tracks retained their duration and ending audio.
- Private preview package publication completed.

The development Windows machine also passed an earlier system-loopback capture and reference-transcription test. CI itself does not have a user-session audio device test.

## Apple Silicon Mac

[GitHub Actions run](https://github.com/mhoberg9/local-meeting-notes/actions/runs/42630431339) completed successfully on the macOS 15 arm64 runner for commit `cbf5c04`.

- Swift storage tests compiled and passed, including active recording locks, readable live checkpoints, abrupt-exit recovery and preserving original audio.
- Guarded audio deletion and generated two-hour duration/ending-audio checks passed.
- Native Swift app and C++ Whisper helper compiled for arm64.
- The bundled framework was thinned to arm64, the app was locally signed, and signature verification passed.
- The bundled model initialized successfully.
- Private preview package publication completed.

A live microphone/system-audio recording, user permission prompts, actual speech-transcription quality and Gatekeeper behavior were not tested on this headless Mac runner. The preview is ad-hoc signed and not notarized. Perform a short live recording on your Mac before using it for an important meeting.

The two-hour checks use generated files and accelerated processing; they are not two hours of continuous live recording or full speech transcription.
