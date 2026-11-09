#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd -P)"
cd "$ROOT"
mkdir -p Models Vendor .build/downloads
MODEL="$ROOT/Models/ggml-small-q5_1.bin"
MODEL_SHA="ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
ARCHIVE="$ROOT/.build/downloads/whisper-b5454-xcframework.zip"
ARCHIVE_SHA="e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
verified() { [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$2" ]]; }
fetch() {
  local url="$1" path="$2" expected="$3"
  if verified "$path" "$expected"; then return; fi
  curl --fail --location --retry 3 "$url" -o "$path.download"
  verified "$path.download" "$expected" || { echo "Checksum mismatch: $path"; exit 1; }
  mv "$path.download" "$path"
}
fetch "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin" "$MODEL" "$MODEL_SHA"
fetch "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip" "$ARCHIVE" "$ARCHIVE_SHA"
EXTRACTED="$(mktemp -d "$ROOT/.build/vendor.XXXXXX")"
ditto -x -k "$ARCHIVE" "$EXTRACTED"
FRAMEWORK="$EXTRACTED/build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
[[ -d "$FRAMEWORK" ]] || { echo "The macOS framework is missing from the verified archive."; exit 1; }
if [[ -f "$ROOT/Vendor/whisper-macos.zip" ]]; then
  mv "$ROOT/Vendor/whisper-macos.zip" "$EXTRACTED/previous-macos-framework.zip"
fi
ditto -c -k --keepParent "$FRAMEWORK" "$ROOT/Vendor/whisper-macos.zip"
{
  printf '%s  %s\n' "$MODEL_SHA" 'Models/ggml-small-q5_1.bin'
  printf '%s  %s\n' "$(shasum -a 256 "$ROOT/Vendor/whisper-macos.zip" | awk '{print $1}')" 'Vendor/whisper-macos.zip'
} > "$ROOT/COMPONENT-SHA256.txt"
echo "Verified offline model and macOS framework are ready."
