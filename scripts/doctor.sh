#!/bin/sh
# Checks that this Mac has what "Build it" in README.md needs, and says how to fix what's missing.
# It only reads: it installs nothing and changes no settings. Run it from the repository root:
#   scripts/doctor.sh
set -u

ok=0; bad=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; ok=$((ok + 1)); }
fail() { printf '  \033[31mfix\033[0m   %s\n' "$1"; shift; for line in "$@"; do printf '        %s\n' "$line"; done; bad=$((bad + 1)); }
note() { printf '  \033[33mnote\033[0m  %s\n' "$1"; shift; for line in "$@"; do printf '        %s\n' "$line"; done; }

root=$(cd "$(dirname "$0")/.." && pwd)
echo "Checking this Mac for building Mac Phone Bridge"
echo

echo "Mac app"
dev=$(xcode-select -p 2>/dev/null || true)
case "$dev" in
  *CommandLineTools*|"")
    fail "Xcode is not selected (only the Command Line Tools are)" \
      "Install Xcode 26 or later from the App Store, open it once, then run:" \
      "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" ;;
  *)
    ver=$(xcodebuild -version 2>/dev/null | sed -n 's/^Xcode //p')
    major=${ver%%.*}
    if [ -z "$ver" ]; then
      fail "xcodebuild did not run" "Open Xcode once to finish its setup and accept the licence, then try again."
    elif [ "$major" -ge 26 ] 2>/dev/null; then
      pass "Xcode $ver"
    else
      fail "Xcode $ver is too old (26 or later needed, for Swift 6.3)" "Update Xcode from the App Store."
    fi ;;
esac
if command -v xcodegen >/dev/null 2>&1; then pass "xcodegen $(xcodegen --version 2>/dev/null | sed 's/Version: //')"
else fail "xcodegen is missing" "brew install xcodegen"; fi
if command -v protoc >/dev/null 2>&1; then
  pv=$(protoc --version | sed 's/libprotoc //')
  if [ "$pv" = "36.2" ] || [ "$pv" = "4.36.2" ]; then pass "protoc $pv"
  else note "protoc $pv found; README pins 4.36.2" "Only scripts/gen-proto.sh needs it. The generated files are in the repo, so you can skip that step."; fi
else
  note "protoc not found" "Only scripts/gen-proto.sh needs it. The generated files are in the repo, so you can skip that step, or install it with the README's protoc snippet."
fi
echo

echo "Android app"
jver() { "$1/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1; }
jdk=""
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  v=$(jver "$JAVA_HOME")
  if [ "${v:-0}" -ge 17 ] 2>/dev/null; then pass "JAVA_HOME is Java $v"; jdk=$JAVA_HOME
  else fail "JAVA_HOME is Java ${v:-unknown}, but Gradle needs 17 or later (21 recommended)"; fi
else
  fail "JAVA_HOME is not set"
fi
if [ -z "$jdk" ]; then
  for c in "$(/usr/libexec/java_home -v 21 2>/dev/null)" "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
    /Library/Java/JavaVirtualMachines/*/Contents/Home "$HOME"/.gradle/jdks/*/Contents/Home "$HOME"/.gradle/jdks/*/*/Contents/Home; do
    if [ -n "$c" ] && [ -x "$c/bin/java" ] && [ "$(jver "$c")" -ge 17 ] 2>/dev/null; then
      note "A usable Java $(jver "$c") is already on this Mac. Before building, run:" "export JAVA_HOME=\"$c\""
      jdk=$c; break
    fi
  done
  [ -z "$jdk" ] && note "No Java 17+ found" "Install JDK 21 (for example from adoptium.net), or install Android Studio, which brings one."
fi

sdk=""
if [ -n "${ANDROID_HOME:-}" ]; then sdk=$ANDROID_HOME
elif [ -f "$root/android/local.properties" ]; then sdk=$(sed -n 's/^sdk\.dir=//p' "$root/android/local.properties")
fi
if [ -n "$sdk" ] && [ -d "$sdk" ]; then
  pass "Android SDK at $sdk"
elif [ -d "$HOME/Library/Android/sdk" ]; then
  fail "Gradle can't find the Android SDK" \
    "Android Studio's SDK is at ~/Library/Android/sdk. Tell Gradle with:" \
    "echo \"sdk.dir=$HOME/Library/Android/sdk\" > android/local.properties"
  sdk="$HOME/Library/Android/sdk"
else
  fail "No Android SDK found" "Install Android Studio, open it once so it downloads the SDK, then run scripts/doctor.sh again."
fi
if [ -n "$sdk" ] && [ -d "$sdk" ]; then
  if [ -d "$sdk/platforms/android-37.1" ]; then pass "Android platform 37.1"
  else fail "Android platform 37.1 is missing" "In Android Studio: Settings › Languages & Frameworks › Android SDK, tick Android 37.1, Apply." \
    "Or: \"$sdk/cmdline-tools/latest/bin/sdkmanager\" \"platforms;android-37.1\""; fi
fi
echo

free=$(df -g "$root" | awk 'NR==2 {print $4}')
if [ "${free:-0}" -ge 15 ] 2>/dev/null; then pass "${free} GB free disk space"
else fail "Only ${free} GB free" "A first build downloads and compiles about 10 to 15 GB. Free some space first."; fi

echo
if [ "$bad" -eq 0 ]; then echo "All set. Follow \"Build and test\" in README.md."
else echo "$bad thing(s) to fix above. Run scripts/doctor.sh again when done."; fi
[ "$bad" -eq 0 ]
