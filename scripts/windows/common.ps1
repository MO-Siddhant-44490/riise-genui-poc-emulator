# Shared settings for the Windows scripts. Dot-sourced, not run.
$ErrorActionPreference = 'Stop'
$AVD = if ($env:AVD) { $env:AVD } else { 'RIISE_API_33' }
$PKG = 'com.mosl.mobile.uat'
$ACT = 'com.mosl.mobile.MainActivity'
$SDK = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
if (-not (Test-Path $SDK)) { throw "Android SDK not found at $SDK. Install Android Studio or set ANDROID_HOME." }
$env:PATH = "$SDK\platform-tools;$SDK\emulator;$SDK\cmdline-tools\latest\bin;$env:PATH"
$ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
