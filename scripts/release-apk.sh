#!/bin/sh
# Builds the release APK for GitHub Releases and signs it with the project's release key.
#
#   scripts/release-apk.sh [output-dir]      (default: dist/)
#
# The first run creates the key: a 4096-bit RSA key in a PKCS#12 keystore at
#   $MPB_KEYSTORE   (default: ~/.mac-phone-bridge/release-key.p12)
# keytool and apksigner ask for its password in this terminal, so the password is never written
# to a file, a Gradle property or the shell history.
#
# KEEP THE KEYSTORE AND ITS PASSWORD SAFE, AND BACK BOTH UP. Android only installs an update
# signed with the same key, so if either is lost, every user has to uninstall the app (and pair
# again) to get the next version. Never commit the keystore.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
ks=${MPB_KEYSTORE:-$HOME/.mac-phone-bridge/release-key.p12}
alias=mac-phone-bridge
out=${1:-$root/dist}

stop() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# A JDK 17+ for Gradle and the signing tools (scripts/doctor.sh explains how to get one).
if [ -z "${JAVA_HOME:-}" ] || ! "$JAVA_HOME/bin/java" -version 2>&1 | grep -qE 'version "(1[7-9]|[2-9][0-9])'; then
  for c in "$(/usr/libexec/java_home -v 21 2>/dev/null || true)" "$HOME"/.gradle/jdks/*/*/Contents/Home "$HOME"/.gradle/jdks/*/Contents/Home \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
    if [ -n "$c" ] && [ -x "$c/bin/java" ] && "$c/bin/java" -version 2>&1 | grep -qE 'version "(1[7-9]|[2-9][0-9])'; then JAVA_HOME=$c; break; fi
  done
fi
[ -n "${JAVA_HOME:-}" ] || stop "No Java 17 or later found. Run scripts/doctor.sh."
export JAVA_HOME

sdk=${ANDROID_HOME:-$(sed -n 's/^sdk\.dir=//p' "$root/android/local.properties" 2>/dev/null || true)}
[ -n "$sdk" ] || sdk="$HOME/Library/Android/sdk"
bt=$(ls -d "$sdk"/build-tools/* 2>/dev/null | sort -V | tail -1)
[ -x "$bt/apksigner" ] || stop "No Android build-tools found in $sdk. Run scripts/doctor.sh."

# 1. The key, once.
if [ ! -f "$ks" ]; then
  echo "No release key yet. Creating one at $ks"
  echo "Choose a strong password and store it in your password manager. You'll need it for every release."
  mkdir -p "$(dirname "$ks")"
  chmod 700 "$(dirname "$ks")"
  "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$ks" -storetype PKCS12 -alias "$alias" \
    -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=Mac Phone Bridge"
  chmod 600 "$ks"
  echo
  echo "Created. Back up $ks now (for example to an encrypted USB drive), with its password stored separately."
  echo
fi

# 2. The unsigned release build.
echo "Building the release APK..."
(cd "$root/android" && ./gradlew :app:assembleOssRelease --console=plain -q)
unsigned="$root/android/app/build/outputs/apk/oss/release/app-oss-release-unsigned.apk"
[ -f "$unsigned" ] || stop "The build made no $unsigned."
version=$("$bt/aapt2" dump badging "$unsigned" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")
name="MacPhoneBridge-$version.apk"

# 3. Align (AGP's unsigned output usually already is), then sign: apksigner asks for the password.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
"$bt/zipalign" -c -P 16 4 "$unsigned" >/dev/null 2>&1 && cp "$unsigned" "$work/aligned.apk" || "$bt/zipalign" -P 16 -f 4 "$unsigned" "$work/aligned.apk"
mkdir -p "$out"
echo "Signing $name (enter the release key's password)..."
"$bt/apksigner" sign --ks "$ks" --ks-key-alias "$alias" --out "$out/$name" "$work/aligned.apk"
rm -f "$out/$name.idsig"

# 4. Check it, and print what to publish.
"$bt/apksigner" verify --min-sdk-version 29 "$out/$name" || stop "The signed APK doesn't verify."
cert=$("$bt/apksigner" verify --print-certs "$out/$name" | sed -n 's/.*certificate SHA-256 digest: //p' | head -1)
echo
echo "Done: $out/$name ($(stat -f %z "$out/$name") bytes)"
echo "SHA-256 of the APK:      $(shasum -a 256 "$out/$name" | cut -d' ' -f1)"
echo "Signing certificate:     $cert"
echo "(Publish the certificate digest with the release, so anyone can check an APK came from you.)"
