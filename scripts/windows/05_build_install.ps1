# Path B, step 2: builds the UAT debug APK with the AI router settings and installs it on the emulator.
# Usage: .\05_build_install.ps1 -Repo C:\path\to\company-repo [-Offline] [-NoInstall]
# Reads genui.env from this repo's root (copy genui.env.example). The values are passed as
# --dart-define only; nothing is written into the company repo.
param([Parameter(Mandatory)][string]$Repo, [switch]$Offline, [switch]$NoInstall)
. "$PSScriptRoot\common.ps1"
$envf = Join-Path $ROOT 'genui.env'
if (-not (Test-Path $envf)) { throw "Create $envf from genui.env.example first." }
$cfg = @{}; Get-Content $envf | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $null = $_ -match '^\s*([A-Z_]+)=(.*)$'; $cfg[$Matches[1]] = $Matches[2].Trim() }
if (-not $cfg.GENUI_AI_URL -or -not $cfg.GENUI_AI_TOKEN) { throw "GENUI_AI_URL and GENUI_AI_TOKEN must be set in genui.env" }
if (-not $cfg.GENUI_MODEL) { $cfg.GENUI_MODEL = 'qwen.qwen3-32b-v1:0' }
function B64($s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
$defs = (B64 "GENUI_AI_URL=$($cfg.GENUI_AI_URL)"), (B64 "GENUI_AI_TOKEN=$($cfg.GENUI_AI_TOKEN)"), (B64 "GENUI_MODEL=$($cfg.GENUI_MODEL)") -join ','
$app = Join-Path $Repo 'apps\super_app'
if (-not (Test-Path "$app\android\local.properties")) {
  Push-Location $app; flutter pub get | Out-Null; Pop-Location
  Push-Location $Repo; git checkout -- pubspec.lock 2>$null; Pop-Location
}
Push-Location "$app\android"
try {
  $gargs = @('assembleUatDebug', '-Ptarget=lib/main_uat.dart', "-Pdart-defines=$defs", '-q'); if ($Offline) { $gargs += '--offline' }
  & .\gradlew.bat @gargs; if ($LASTEXITCODE) { throw "Gradle build failed" }
} finally { Pop-Location }
$apk = Join-Path $app 'build\app\outputs\flutter-apk\app-uat-debug.apk'
Write-Host "built $apk"
if ($NoInstall) { exit 0 }
adb install -r $apk | Select-Object -Last 1
adb shell am start -n "$PKG/$ACT" | Select-Object -Last 1
