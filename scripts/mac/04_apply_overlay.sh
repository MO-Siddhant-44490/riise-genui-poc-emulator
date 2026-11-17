#!/bin/bash
# Path B, step 1: adds the POC to your checkout of the company repo (mosl-riseapp-repo).
# Usage: 04_apply_overlay.sh <path-to-company-repo>
# Local changes only: one new package, two small edits, one new manifest. Do not commit or push them.
set -eu
. "$(dirname "$0")/common.sh"
REPO=${1:?path to your checkout of the company repo}
[ -f "$REPO/apps/super_app/pubspec.yaml" ] || { echo "$REPO does not look like the RIISE repo"; exit 1; }
cd "$REPO"
if grep -q "mo_genui" apps/super_app/pubspec.yaml; then echo "host edits already present; refreshing the package only"
else git apply --ignore-whitespace --3way "$ROOT/overlay/host.patch" 2>/dev/null || git apply --ignore-whitespace "$ROOT/overlay/host.patch"; fi
rm -rf packages/mo_genui; cp -R "$ROOT/overlay/packages/mo_genui" packages/mo_genui
mkdir -p apps/super_app/android/app/src/uat
cp "$ROOT/overlay/uat_AndroidManifest.xml" apps/super_app/android/app/src/uat/AndroidManifest.xml
git reset -q -- apps/super_app/pubspec.yaml apps/super_app/lib 2>/dev/null || true
if [ "${SKIP_PUB_GET:-0}" != "1" ]; then
  ( cd apps/super_app && flutter pub get )
  git checkout -- pubspec.lock 2>/dev/null || true   # keep the tracked lock file untouched
fi
echo "Overlay applied. git status:"; git status --short
echo "Expected base: $(tr '\n' ' ' < "$ROOT/BASE_COMMIT")"
