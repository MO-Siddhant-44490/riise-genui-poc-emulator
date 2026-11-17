#!/bin/bash
# Removes every POC change from your checkout of the company repo.
# Usage: 99_remove_overlay.sh <path-to-company-repo>
set -eu
REPO=${1:?path to your checkout of the company repo}
cd "$REPO"
git checkout -- apps/super_app/pubspec.yaml apps/super_app/lib/Investor/presentation/landingpage/landing_page_header/landingpage_header.dart pubspec.lock
rm -rf packages/mo_genui apps/super_app/android/app/src/uat/AndroidManifest.xml
rmdir apps/super_app/android/app/src/uat 2>/dev/null || true
echo "Removed. git status:"; git status --short
