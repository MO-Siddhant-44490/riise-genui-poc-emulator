# Creates the Pixel 7 / Android 13 emulator the POC was tested on. Run once.
. "$PSScriptRoot\common.ps1"
if (-not (Get-Command sdkmanager.bat -ErrorAction SilentlyContinue)) { throw "sdkmanager missing: in Android Studio open SDK Manager > SDK Tools and tick 'Android SDK Command-line Tools (latest)'." }
$abi = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64-v8a' } else { 'x86_64' }
$img = "system-images;android-33;google_apis;$abi"
1..20 | ForEach-Object { 'y' } | sdkmanager.bat --licenses | Out-Null
sdkmanager.bat "platform-tools" "emulator" $img
if ((emulator.exe -list-avds) -contains $AVD) { Write-Host "AVD $AVD already exists"; exit 0 }
'no' | avdmanager.bat create avd -n $AVD -k $img -d pixel_7
Write-Host "Created $AVD ($abi). Next: scripts\windows\02_start_emulator.ps1"
