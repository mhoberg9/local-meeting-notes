Native Apple Silicon preview for macOS 15+. The ZIP contains the app, Whisper framework, helper and offline model. Move the app to Applications before first opening it.

This package passed compilation, generated storage/recovery checks and model initialization on a Mac runner. It has NOT passed a live user-session microphone/system-audio capture test in CI. Grant the app's permissions yourself and verify both audio sources with a short recording before a real meeting. It is ad-hoc signed, not notarized. No existing recordings are included.

Read the repository README for the data folder, optional permanent audio deletion and recovery limits.
