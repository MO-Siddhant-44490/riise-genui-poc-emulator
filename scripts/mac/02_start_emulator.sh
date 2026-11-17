#!/bin/bash
# Starts (or restarts) the emulator with DNS servers that match the laptop's current network.
# Re-run this whenever the laptop changes network (office, VPN, hotspot): the emulator keeps the
# DNS servers it was started with, and UAT hosts stop resolving after a switch.
set -u
. "$(dirname "$0")/common.sh"
LOG=${1:-/tmp/riise_emulator.log}
ns=$(scutil --dns 2>/dev/null | grep -oE "nameserver\[[0-9]+\] : [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $3}' | sort -u | head -3 | tr '\n' ',' | sed 's/,$//')
dns="8.8.8.8,1.1.1.1"; [ -n "$ns" ] && dns="$ns,8.8.8.8"
echo "dns: $dns"
for s in $(adb devices | awk 'NR>1 && /emulator/ {print $1}'); do adb -s "$s" emu kill; done >/dev/null 2>&1
sleep 5; rm -f "$HOME/.android/avd/$AVD.avd/"*.lock 2>/dev/null
nohup emulator -avd "$AVD" -no-snapshot-load -no-boot-anim -dns-server "$dns" > "$LOG" 2>&1 &
sleep 15; adb wait-for-device
for i in $(seq 1 60); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break; sleep 3; done
echo "booted. UAT reachability from the emulator:"
for h in tradingapi.motilaloswaluat.com api.dev.riseapp.in; do printf '  %s -> ' "$h"; adb shell "ping -c1 -W3 $h 2>&1 | head -1" | tr -d '\r'; done
adb shell pm list packages | grep -q "$PKG" && adb shell am start -n "$PKG/$ACT" | tail -1
