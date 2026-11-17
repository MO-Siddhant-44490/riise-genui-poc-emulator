#!/bin/bash
# Installs what Path A needs on a Mac, without Android Studio: JDK 17, the Android command-line
# tools and the GitHub CLI, through Homebrew. Skips anything already present. Run once.
set -eu
command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh (install it, then re-run)"; exit 1; }
/usr/libexec/java_home -v 17+ >/dev/null 2>&1 || brew install --cask temurin@17
command -v gh >/dev/null || brew install gh
if [ ! -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}/cmdline-tools/latest" ] && [ ! -d "$(brew --prefix)/share/android-commandlinetools/cmdline-tools/latest" ]; then
  brew install --cask android-commandlinetools
fi
gh auth status >/dev/null 2>&1 || echo "Next: run 'gh auth login' (GitHub.com, HTTPS, browser)."
echo "Prerequisites ready. Next: scripts/mac/01_create_emulator.sh"
