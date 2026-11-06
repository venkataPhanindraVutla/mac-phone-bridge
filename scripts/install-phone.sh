#!/bin/sh
# Installs the Mac Phone Bridge beta on an Android phone plugged into this Mac with a USB cable.
#
# For phones where Google Play Protect says "App blocked to protect your device": in some countries
# Android blocks apps that can read notifications when they come from a browser or a file manager.
# An install over USB isn't blocked. Run it from Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/venkataPhanindraVutla/mac-phone-bridge/main/scripts/install-phone.sh | sh
#
# or, in a clone of the repository: scripts/install-phone.sh [path/to/app.apk]
#
# It downloads the newest beta APK from GitHub Releases and checks it against the release's
# SHA256SUMS.txt. If this Mac has no adb, it downloads Google's platform-tools into
# ~/Library/Caches/MacPhoneBridge. It changes no settings on the Mac or the phone.
set -eu

REPO="venkataPhanindraVutla/mac-phone-bridge"
CACHE="$HOME/Library/Caches/MacPhoneBridge"

say() { printf '%s\n' "$*"; }
stop() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

work=$(mktemp -d)
own_adb=""
# Stops adb only if this script brought its own copy, so a developer's adb server keeps running.
cleanup() { [ -n "$own_adb" ] && "$adb" kill-server </dev/null >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT INT TERM

# 1. The app.
if [ $# -ge 1 ]; then
  apk=$1
  [ -f "$apk" ] || stop "There's no file at $apk."
else
  say "Finding the newest beta on GitHub..."
  urls=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=5" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(https[^"]*\)"/\1/') ||
    stop "Couldn't reach GitHub. Check this Mac's internet connection and try again."
  apk_url=$(printf '%s\n' "$urls" | grep '\.apk$' | head -1)
  [ -n "$apk_url" ] || stop "Couldn't find the Android app on the releases page."
  sums_url="${apk_url%/*}/SHA256SUMS.txt"
  name=${apk_url##*/}
  apk="$work/$name"
  say "Downloading $name..."
  curl -fsSL -o "$apk" "$apk_url" || stop "The download failed. Try again."
  want=$(curl -fsSL "$sums_url" | awk -v n="$name" '$2 == n {print $1}')
  have=$(shasum -a 256 "$apk" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$have" ] || stop "The download doesn't match the release's checksum, so it wasn't installed. Try again."
  say "Checked: it matches the release."
fi

# 2. adb, Android's tool for installing over USB.
adb=$(command -v adb 2>/dev/null || true)
[ -z "$adb" ] && [ -x "$HOME/Library/Android/sdk/platform-tools/adb" ] && adb="$HOME/Library/Android/sdk/platform-tools/adb"
[ -z "$adb" ] && [ -x "$CACHE/platform-tools/adb" ] && adb="$CACHE/platform-tools/adb"
if [ -z "$adb" ]; then
  say "Downloading Google's Android platform-tools (about 15 MB, once)..."
  mkdir -p "$CACHE"
  curl -fsSL -o "$work/pt.zip" "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip" ||
    stop "Couldn't download platform-tools from Google. Try again."
  unzip -q -o "$work/pt.zip" -d "$CACHE"
  adb="$CACHE/platform-tools/adb"
fi
[ "$adb" = "$CACHE/platform-tools/adb" ] && own_adb=1
"$adb" start-server </dev/null >/dev/null 2>&1 || true

# 3. The phone. Every adb call reads from /dev/null: run as `curl ... | sh`, the rest of this script
# is on stdin, and adb would swallow it.
say ""
say "Plug the phone into this Mac with a USB cable, unlock it,"
say "and tap Allow if it asks to allow USB debugging."
hinted=""
i=0
while :; do
  state=$("$adb" get-state </dev/null 2>&1 || true)
  case "$state" in
    device) break ;;
    *unauthorized*) [ "$hinted" = u ] || say "Waiting: tap Allow on the phone (tick Always allow from this computer)."; hinted=u ;;
    *"more than one"*) stop "More than one Android device is connected. Unplug the others and run this again." ;;
    *) [ "$hinted" = n ] || say "Waiting for the phone. If nothing happens, turn on USB debugging: Settings › About phone, tap Build number 7 times, then Developer options › USB debugging."; hinted=n ;;
  esac
  i=$((i + 1))
  [ $i -lt 120 ] || stop "No phone after 2 minutes. Check the cable (some only charge) and USB debugging, then run this again."
  sleep 1
done
model=$("$adb" shell getprop ro.product.model </dev/null 2>/dev/null | tr -d '\r')
say "Found ${model:-the phone}. Installing (the phone may ask you to allow it)..."

# 4. Install. -r keeps the app's data, so an existing pairing stays.
out=$("$adb" install -r "$apk" </dev/null 2>&1) || true
case "$out" in
  *Success*)
    say ""
    say "Installed. Open Mac Phone Bridge on the phone and carry on with step 3, Pair them."
    say "You can turn USB debugging off again: Full mode doesn't need it." ;;
  *UPDATE_INCOMPATIBLE*)
    stop "The phone has a copy of Mac Phone Bridge signed by someone else. Uninstall it from the phone, then run this again (you'll pair again afterwards)." ;;
  *USER_RESTRICTED*)
    stop "The phone blocked installs over USB. On Xiaomi, Redmi and POCO, turn on Install via USB in Developer options, then run this again." ;;
  *VERSION_DOWNGRADE*)
    stop "The phone already has a newer version of Mac Phone Bridge. Nothing to do." ;;
  *INSUFFICIENT_STORAGE*)
    stop "The phone is out of space. Free some up and run this again." ;;
  *)
    printf '%s\n' "$out" >&2
    stop "The install didn't work. Send the lines above to whoever shared this beta with you." ;;
esac
