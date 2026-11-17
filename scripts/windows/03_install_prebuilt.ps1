# Path A: installs the prebuilt UAT APK on the running emulator.
# Usage: .\03_install_prebuilt.ps1 [-Apk C:\path\to\riise.apk]
# Without -Apk it downloads the newest release APK of this repo with the GitHub CLI (gh auth login first).
param([string]$Apk)
. "$PSScriptRoot\common.ps1"
if (-not $Apk) {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "Pass -Apk, or install the GitHub CLI (winget install GitHub.cli; gh auth login)." }
  $dl = Join-Path $ROOT '.download'; New-Item -ItemType Directory -Force $dl | Out-Null
  Push-Location $ROOT; gh release download --pattern '*.apk' --dir .download --clobber; Pop-Location
  $Apk = (Get-ChildItem "$dl\*.apk" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
$abis = adb shell getprop ro.product.cpu.abilist
if ($abis -notmatch 'arm64-v8a') { throw "This emulator image cannot run ARM apps ($abis). The app ships ARM libraries only; use the google_apis Android 13 image from 01_create_emulator.ps1." }
adb install -r $Apk | Select-Object -Last 1
adb shell am start -n "$PKG/$ACT" | Select-Object -Last 1
