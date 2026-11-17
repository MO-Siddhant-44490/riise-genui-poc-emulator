# Shared settings for the Mac/Linux scripts. Sourced, not run.
AVD=${AVD:-RIISE_API_33}
PKG=com.mosl.mobile.uat
ACT=com.mosl.mobile.MainActivity
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
[ -d "$SDK" ] || { echo "Android SDK not found at $SDK. Install Android Studio or set ANDROID_HOME."; exit 1; }
export PATH="$SDK/platform-tools:$SDK/emulator:$SDK/cmdline-tools/latest/bin:$PATH"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
