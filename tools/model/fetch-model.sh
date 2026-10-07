#!/usr/bin/env bash
# Downloads the exact Ozen-v1 files the apps ship, pinned to one Hugging Face
# revision and checked against SHA-256, into a cache. Pass a directory to also
# copy them there (the iOS build copies them into the app bundle this way).
#
#   tools/model/fetch-model.sh                 # just fill the cache
#   tools/model/fetch-model.sh ios/Ozen/Model  # and copy into a target dir
set -euo pipefail

REPO="itayinbar/Ozen-v1"
REV="82aae03decb5592029922ea15e19ed96d1e8ece3"
CACHE="${OZEN_MODEL_CACHE:-$HOME/.cache/ozen/models/${REV:0:8}}"

# path  sha256
FILES=(
  "onnx/encoder_model_fp16.onnx ec63a2dab9fe408baab3d7f16bf8316e7988c8982ba86f427354fb4a3b8b613b"
  "onnx/decoder_model_merged.onnx e490fa4dd2f15b859ad5b7c94c3fdbe819262bebd18680a7742fed1ec863386b"
  "tokenizer.json 050f0aff338e5779ebe80f25c760da76857e009dc17c2caef8424d613ee7dbfa"
)

mkdir -p "$CACHE/onnx"
for entry in "${FILES[@]}"; do
  read -r path sum <<<"$entry"
  dest="$CACHE/$path"
  if [[ -f "$dest" ]] && echo "$sum  $dest" | shasum -a 256 -c --status; then
    continue
  fi
  echo "fetching $path"
  curl -fL --retry 3 -o "$dest.part" "https://huggingface.co/$REPO/resolve/$REV/$path"
  echo "$sum  $dest.part" | shasum -a 256 -c --status || { echo "checksum mismatch: $path" >&2; rm -f "$dest.part"; exit 1; }
  mv "$dest.part" "$dest"
done

if [[ $# -ge 1 ]]; then
  mkdir -p "$1"
  for entry in "${FILES[@]}"; do
    read -r path _ <<<"$entry"
    cp -c "$CACHE/$path" "$1/$(basename "$path")" 2>/dev/null || cp "$CACHE/$path" "$1/$(basename "$path")"
  done
fi
echo "model ready: $CACHE"
