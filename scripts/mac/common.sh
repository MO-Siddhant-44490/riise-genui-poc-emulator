# Shared settings for the Mac/Linux scripts. Sourced, not run.
AVD=${AVD:-RIISE_API_33}
PKG=com.mosl.mobile.uat
ACT=com.mosl.mobile.MainActivity
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
# No Android Studio: fall back to the Homebrew command-line tools location (00_install_prereqs.sh).
if [ ! -d "$SDK" ] && command -v brew >/dev/null && [ -d "$(brew --prefix)/share/android-commandlinetools" ]; then SDK="$(brew --prefix)/share/android-commandlinetools"; fi
export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
[ -d "$SDK" ] || { echo "Android SDK not found at $SDK. Run scripts/mac/00_install_prereqs.sh, or install Android Studio, or set ANDROID_HOME."; exit 1; }
export PATH="$SDK/platform-tools:$SDK/emulator:$SDK/cmdline-tools/latest/bin:$PATH"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
