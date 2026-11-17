# Starts (or restarts) the emulator with DNS servers that match the laptop's current network.
# Re-run this whenever the laptop changes network (office, VPN, hotspot): the emulator keeps the
# DNS servers it was started with, and UAT hosts stop resolving after a switch.
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Continue'
$ns = Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ -notlike '127.*' -and $_ -notlike '169.254.*' } | Select-Object -Unique -First 3
$dns = (@($ns) + '8.8.8.8' | Where-Object { $_ }) -join ','
Write-Host "dns: $dns"
adb devices | Select-String '^emulator-\d+' | ForEach-Object { adb -s $_.Matches[0].Value emu kill | Out-Null }
Start-Sleep 5
Remove-Item "$env:USERPROFILE\.android\avd\$AVD.avd\*.lock" -Recurse -Force -ErrorAction SilentlyContinue
Start-Process -FilePath "$SDK\emulator\emulator.exe" -ArgumentList "-avd $AVD -no-snapshot-load -no-boot-anim -dns-server $dns"
Start-Sleep 15; adb wait-for-device
foreach ($i in 1..60) { if ((adb shell getprop sys.boot_completed 2>$null) -match '1') { break }; Start-Sleep 3 }
Write-Host "booted. UAT reachability from the emulator:"
foreach ($h in 'tradingapi.motilaloswaluat.com', 'api.dev.riseapp.in') { Write-Host "  $h -> $((adb shell "ping -c1 -W3 $h 2>&1 | head -1"))" }
if ((adb shell pm list packages) -match $PKG) { adb shell am start -n "$PKG/$ACT" | Select-Object -Last 1 }
