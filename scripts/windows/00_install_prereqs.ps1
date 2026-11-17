# Installs what Path A needs on Windows, without Android Studio: JDK 17, Git, the GitHub CLI
# (through winget) and the Android command-line tools. Skips anything already present. Run once.
$ErrorActionPreference = 'Stop'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw "winget is required (App Installer from the Microsoft Store), or install JDK 17, Git and GitHub CLI by hand." }
if (-not (Get-Command java -ErrorAction SilentlyContinue)) { winget install -e --id Microsoft.OpenJDK.17 --accept-source-agreements --accept-package-agreements }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { winget install -e --id GitHub.cli --accept-source-agreements --accept-package-agreements }
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
if (-not (Test-Path "$sdk\cmdline-tools\latest\bin\sdkmanager.bat")) {
  $zip = Join-Path $env:TEMP 'android-cmdline-tools.zip'; $tmp = Join-Path $env:TEMP 'android-cmdline-tools'
  Invoke-WebRequest 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip' -OutFile $zip
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; Expand-Archive $zip $tmp
  New-Item -ItemType Directory -Force "$sdk\cmdline-tools" | Out-Null
  Move-Item "$tmp\cmdline-tools" "$sdk\cmdline-tools\latest"
}
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $sdk, 'User')
$hv = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
if (-not $hv) { Write-Warning "No hypervisor detected. The emulator needs 'Windows Hypervisor Platform' (Turn Windows features on or off; admin rights and a restart)." }
Write-Host "Prerequisites ready. Open a NEW PowerShell window (so java/gh are on PATH), run 'gh auth login', then scripts\windows\01_create_emulator.ps1"
