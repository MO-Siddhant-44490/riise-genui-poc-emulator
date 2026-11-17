#!/bin/bash
# Creates the Pixel 7 / Android 13 emulator the POC was tested on. Run once.
set -eu
. "$(dirname "$0")/common.sh"
command -v sdkmanager >/dev/null || { echo "sdkmanager missing: in Android Studio open SDK Manager > SDK Tools and tick 'Android SDK Command-line Tools (latest)'."; exit 1; }
case "$(uname -m)" in arm64|aarch64) ABI=arm64-v8a ;; *) ABI=x86_64 ;; esac
IMG="system-images;android-33;google_apis;$ABI"
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager "platform-tools" "emulator" "$IMG"
if emulator -list-avds | grep -qx "$AVD"; then echo "AVD $AVD already exists"; exit 0; fi
echo no | avdmanager create avd -n "$AVD" -k "$IMG" -d pixel_7
echo "Created $AVD ($ABI). Next: scripts/mac/02_start_emulator.sh"
