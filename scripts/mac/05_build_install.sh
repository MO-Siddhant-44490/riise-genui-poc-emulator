#!/bin/bash
# Path B, step 2: builds the UAT debug APK with the AI router settings and installs it on the emulator.
# Usage: 05_build_install.sh <path-to-company-repo>
# Reads genui.env from this repo's root (copy genui.env.example). The values are passed as
# --dart-define only; nothing is written into the company repo.
# OFFLINE=1  build with Gradle --offline (when the dependencies are already in the Gradle cache)
# NO_INSTALL=1  build only
set -eu
. "$(dirname "$0")/common.sh"
REPO=${1:?path to your checkout of the company repo}
ENVF="$ROOT/genui.env"; [ -f "$ENVF" ] || { echo "Create $ENVF from genui.env.example first."; exit 1; }
val() { grep -E "^$1=" "$ENVF" | head -1 | cut -d= -f2- | tr -d '\r'; }
URL=$(val GENUI_AI_URL); TOKEN=$(val GENUI_AI_TOKEN); MODEL=$(val GENUI_MODEL); MODEL=${MODEL:-qwen.qwen3-32b-v1:0}
[ -n "$URL" ] && [ -n "$TOKEN" ] || { echo "GENUI_AI_URL and GENUI_AI_TOKEN must be set in genui.env"; exit 1; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
DEFS="$(b64 "GENUI_AI_URL=$URL"),$(b64 "GENUI_AI_TOKEN=$TOKEN"),$(b64 "GENUI_MODEL=$MODEL")"
APP="$REPO/apps/super_app"
[ -f "$APP/android/local.properties" ] || ( cd "$APP" && flutter pub get >/dev/null && cd "$REPO" && git checkout -- pubspec.lock 2>/dev/null || true )
cd "$APP/android"
./gradlew assembleUatDebug ${OFFLINE:+--offline} -Ptarget=lib/main_uat.dart -Pdart-defines="$DEFS" -q
APK="$APP/build/app/outputs/flutter-apk/app-uat-debug.apk"
echo "built $APK ($(du -h "$APK" | cut -f1))"
[ "${NO_INSTALL:-0}" = "1" ] && exit 0
adb install -r "$APK" | tail -1
adb shell am start -n "$PKG/$ACT" | tail -1
