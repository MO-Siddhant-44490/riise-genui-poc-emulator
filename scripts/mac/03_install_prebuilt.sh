#!/bin/bash
# Path A: installs the prebuilt UAT APK on the running emulator.
# Usage: 03_install_prebuilt.sh [path-to-apk]
# Without a path it downloads the newest release APK of this repo with the GitHub CLI (gh auth login first).
set -eu
. "$(dirname "$0")/common.sh"
APK=${1:-}
if [ -z "$APK" ]; then
  command -v gh >/dev/null || { echo "Pass the APK path, or install the GitHub CLI (brew install gh; gh auth login)."; exit 1; }
  mkdir -p "$ROOT/.download"; ( cd "$ROOT" && gh release download --pattern '*.apk' --dir .download --clobber )
  APK=$(ls -t "$ROOT"/.download/*.apk | head -1)
fi
abis=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')
case "$abis" in *arm64-v8a*) ;; *) echo "This emulator image cannot run ARM apps ($abis). Use a google_apis Android 13 image."; exit 1 ;; esac
adb install -r "$APK" | tail -1
adb shell am start -n "$PKG/$ACT" | tail -1
