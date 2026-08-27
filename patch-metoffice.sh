#!/usr/bin/env bash
# macOS bash port of Patch-MetOffice.ps1
# Mirrors the Windows PowerShell patcher: compiles the local proxy, injects it into
# the ReVanced patch bundle, patches base.apk, flips cleartext traffic, re-signs all
# splits, repackages the APKM, and optionally installs to a device over adb.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- config / args -----------------------------------------------------------
INPUT_APKM="${INPUT_APKM:-$SCRIPT_DIR/input/original.apkm}"
API_KEY_FILE="${API_KEY_FILE:-$SCRIPT_DIR/API.txt}"
OUTPUT_APKM="${OUTPUT_APKM:-$SCRIPT_DIR/output/metoffice-patched.apkm}"
ABI="${ABI:-arm64_v8a}"
LANGUAGE="${LANGUAGE:-en}"
DENSITY="${DENSITY:-xxhdpi}"
DO_INSTALL="${DO_INSTALL:-0}"        # set to 1 to adb install-multiple
DEVICE_SERIAL="${DEVICE_SERIAL:-}"

# --- toolchain (portable: Apple Silicon /opt/homebrew or Intel /usr/local) ----
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
# JAVA_HOME: honour env, else brew openjdk, else system JDK via java_home
if [ -z "${JAVA_HOME:-}" ]; then
  if [ -x "$BREW_PREFIX/opt/openjdk/bin/java" ]; then
    JAVA_HOME="$BREW_PREFIX/opt/openjdk"
  elif /usr/libexec/java_home >/dev/null 2>&1; then
    JAVA_HOME="$(/usr/libexec/java_home)"
  fi
fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$BREW_PREFIX/bin:$PATH"
# SDK root: env, else brew cmdline-tools layout, else Android Studio default
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$BREW_PREFIX/share/android-commandlinetools}}"
[ -d "$SDK_ROOT/build-tools" ] || SDK_ROOT="$HOME/Library/Android/sdk"

step() { printf '\n==> %s\n' "$1"; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
require_file() { [ -f "$1" ] || die "$2 not found: $1"; }
latest_dir() { ls -1d "$1"/*/ 2>/dev/null | sort -r | head -1 | sed 's#/$##'; }

for t in java javac jar keytool; do command -v "$t" >/dev/null || die "'$t' not on PATH (JAVA_HOME=$JAVA_HOME)"; done

BUILD_TOOLS="$(latest_dir "$SDK_ROOT/build-tools")"; [ -n "$BUILD_TOOLS" ] || die "no build-tools in $SDK_ROOT"
PLATFORM="$(latest_dir "$SDK_ROOT/platforms")";      [ -n "$PLATFORM" ]    || die "no platforms in $SDK_ROOT"
ANDROID_JAR="$PLATFORM/android.jar"
D8="$BUILD_TOOLS/d8"
ZIPALIGN="$BUILD_TOOLS/zipalign"
APKSIGNER="$BUILD_TOOLS/apksigner"
ADB="$(command -v adb || echo /opt/homebrew/bin/adb)"

require_file "$INPUT_APKM" "Input APKM"
require_file "$API_KEY_FILE" "API key file"
require_file "$SCRIPT_DIR/src/LocalProxyServer.java" "LocalProxyServer source"
require_file "$SCRIPT_DIR/patches/metoffice-revanced-patches-template.rvp" "Patch template"
require_file "$SCRIPT_DIR/tools/revanced-cli.jar" "ReVanced CLI"
require_file "$SCRIPT_DIR/tools/apktool.jar" "APKTool"
require_file "$ANDROID_JAR" "android.jar"
require_file "$D8" "d8"
require_file "$ZIPALIGN" "zipalign"
require_file "$APKSIGNER" "apksigner"
[ "$DO_INSTALL" = "1" ] && require_file "$ADB" "adb"

API_KEY="$(tr -d '\r\n' < "$API_KEY_FILE" | sed 's/[[:space:]]*$//')"
case "$API_KEY" in
  ""|"PUT-YOUR-MET-OFFICE-DATAHUB-API-KEY-HERE"|"PASTE YOUR API KEY HERE")
    die "API.txt is empty or still contains the placeholder value." ;;
esac

# --- work dirs ---------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$SCRIPT_DIR/work/$STAMP"
PROXY_SRC="$WORK/proxy-src"; PROXY_CLASSES="$WORK/proxy-classes"; PROXY_DEX="$WORK/proxy-dex"
RVP_DIR="$WORK/rvp"; UNPACKED="$WORK/unpacked-apkm"; PATCHED_RVP="$WORK/metoffice-revanced-patches-api.rvp"
CLI_TEMP="$WORK/revanced-temp"; MANIFEST_FIX="$WORK/manifest-fix"
INSTALL_SET="$SCRIPT_DIR/output/install-set"; SIGNING_DIR="$SCRIPT_DIR/signing"
KEYSTORE="$SIGNING_DIR/metoffice-patcher.p12"; KS_PASS="password"; KS_ALIAS="metoffice_patcher"
mkdir -p "$PROXY_SRC" "$PROXY_CLASSES" "$PROXY_DEX" "$RVP_DIR" "$UNPACKED" "$CLI_TEMP" "$MANIFEST_FIX" "$INSTALL_SET" "$SIGNING_DIR" "$(dirname "$OUTPUT_APKM")"
WORK_ANDROID_JAR="$WORK/android.jar"; cp -f "$ANDROID_JAR" "$WORK_ANDROID_JAR"

# --- 1. compile proxy --------------------------------------------------------
step "Compiling LocalProxyServer with API.txt"
# escape backslash and double-quote for embedding in a Java string literal
ESC_KEY="$(printf '%s' "$API_KEY" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
PROXY_SRC_FILE="$PROXY_SRC/LocalProxyServer.java"
perl -0pe 's/private\s+static\s+final\s+String\s+API_KEY\s*=\s*"[^"]*";/private static final String API_KEY = "'"$ESC_KEY"'";/' \
  "$SCRIPT_DIR/src/LocalProxyServer.java" > "$PROXY_SRC_FILE"

STUB_DIR="$PROXY_SRC/uk/gov/metoffice/weather/android"; mkdir -p "$STUB_DIR"
STUB_FILE="$STUB_DIR/MetOfficeApplication.java"
cat > "$STUB_FILE" <<'EOF'
package uk.gov.metoffice.weather.android;

public class MetOfficeApplication extends android.app.Application {
    public static MetOfficeApplication g() {
        return null;
    }
}
EOF

javac -source 1.8 -target 1.8 -classpath "$WORK_ANDROID_JAR" -d "$PROXY_CLASSES" "$PROXY_SRC_FILE" "$STUB_FILE"

# collect proxy classes, excluding the compile-only stub
CLASS_FILES=()
while IFS= read -r f; do CLASS_FILES+=("$f"); done < <(find "$PROXY_CLASSES" -name '*.class' ! -path '*/uk/gov/metoffice/weather/android/MetOfficeApplication.class')
[ "${#CLASS_FILES[@]}" -gt 0 ] || die "No proxy .class files were produced."

"$D8" --classpath "$WORK_ANDROID_JAR" --classpath "$PROXY_CLASSES" --output "$PROXY_DEX" "${CLASS_FILES[@]}"
require_file "$PROXY_DEX/classes.dex" "Compiled proxy dex"

# --- 2. rebuild patch bundle with proxy dex ----------------------------------
step "Rebuilding patch bundle with user API key"
( cd "$RVP_DIR" && jar xf "$SCRIPT_DIR/patches/metoffice-revanced-patches-template.rvp" )
cp -f "$PROXY_DEX/classes.dex" "$RVP_DIR/proxy_classes.dex"
rm -f "$PATCHED_RVP"
jar cf "$PATCHED_RVP" -C "$RVP_DIR" .

# --- 3. unpack APKM ----------------------------------------------------------
step "Unpacking source APKM"
( cd "$UNPACKED" && jar xf "$INPUT_APKM" )
BASE_APK="$UNPACKED/base.apk"; require_file "$BASE_APK" "base.apk inside APKM"

# --- 4. signing key ----------------------------------------------------------
step "Preparing local signing key"
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkeypair -storetype PKCS12 -keystore "$KEYSTORE" -alias "$KS_ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -dname "CN=MetOffice PC Patcher, OU=Weather, O=Local, L=Local, ST=Local, C=GB"
fi

# --- 5. ReVanced patch -------------------------------------------------------
step "Patching base.apk"
CLI_OUT="$WORK/revanced-output.apk"
java -jar "$SCRIPT_DIR/tools/revanced-cli.jar" patch -p "$PATCHED_RVP" -b -f -o "$CLI_OUT" -t "$CLI_TEMP" "$BASE_APK"
require_file "$CLI_OUT" "ReVanced patched base output"

# --- 6. allow localhost cleartext --------------------------------------------
step "Allowing localhost cleartext traffic"
DECODED="$MANIFEST_FIX/decoded"; FIXED_APK="$MANIFEST_FIX/base-cleartext.apk"
java -jar "$SCRIPT_DIR/tools/apktool.jar" d -f "$CLI_OUT" -o "$DECODED"
MANIFEST="$DECODED/AndroidManifest.xml"; require_file "$MANIFEST" "Decoded AndroidManifest.xml"
if ! grep -q 'android:usesCleartextTraffic=' "$MANIFEST"; then
  perl -0pi -e 's/<application\s+/<application android:usesCleartextTraffic="true" /' "$MANIFEST"
fi
NSC="$DECODED/res/xml/network_security_config_prod.xml"
[ -f "$NSC" ] && perl -0pi -e 's/cleartextTrafficPermitted="false"/cleartextTrafficPermitted="true"/g' "$NSC"
java -jar "$SCRIPT_DIR/tools/apktool.jar" b "$DECODED" -o "$FIXED_APK"

# --- 7. sign base + splits ---------------------------------------------------
step "Signing patched base and splits"
rm -rf "$INSTALL_SET"; mkdir -p "$INSTALL_SET"
ALIGNED_BASE="$WORK/base-aligned.apk"; SIGNED_BASE="$INSTALL_SET/base.apk"
"$ZIPALIGN" -f 4 "$FIXED_APK" "$ALIGNED_BASE"
"$APKSIGNER" sign --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" --ks-key-alias "$KS_ALIAS" --key-pass "pass:$KS_PASS" --out "$SIGNED_BASE" "$ALIGNED_BASE"

for split in "$UNPACKED"/split_*.apk; do
  [ -e "$split" ] || continue
  name="$(basename "$split")"; bname="${name%.apk}"
  aligned="$WORK/$bname-aligned.apk"; signed="$INSTALL_SET/$name"
  if printf '%s' "$name" | grep -Eq 'arm64|armeabi|x86'; then
    "$ZIPALIGN" -f -p 4096 "$split" "$aligned"
  else
    "$ZIPALIGN" -f 4 "$split" "$aligned"
  fi
  "$APKSIGNER" sign --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" --ks-key-alias "$KS_ALIAS" --key-pass "pass:$KS_PASS" --out "$signed" "$aligned"
done

# --- 8. repackage APKM -------------------------------------------------------
step "Building patched APKM"
PACKAGE="$WORK/package"; mkdir -p "$PACKAGE"
find "$UNPACKED" -maxdepth 1 -type f ! -name '*.apk' -exec cp -f {} "$PACKAGE/" \;
cp -f "$INSTALL_SET/base.apk" "$PACKAGE/base.apk"
for s in "$INSTALL_SET"/split_*.apk; do [ -e "$s" ] && cp -f "$s" "$PACKAGE/"; done
rm -f "$OUTPUT_APKM"
( cd "$PACKAGE" && zip -r -X -q "$OUTPUT_APKM" . )

# --- 9. verify ---------------------------------------------------------------
step "Verifying signed install set"
for apk in "$INSTALL_SET"/*.apk; do "$APKSIGNER" verify "$apk"; done

# --- 10. optional install ----------------------------------------------------
if [ "$DO_INSTALL" = "1" ]; then
  step "Installing selected split set via ADB"
  SEL=("$INSTALL_SET/base.apk" "$INSTALL_SET/split_config.$ABI.apk" "$INSTALL_SET/split_config.$LANGUAGE.apk" "$INSTALL_SET/split_config.$DENSITY.apk")
  for s in "${SEL[@]}"; do require_file "$s" "Selected install APK"; done
  ADB_ARGS=(); [ -n "$DEVICE_SERIAL" ] && ADB_ARGS+=(-s "$DEVICE_SERIAL")
  "$ADB" "${ADB_ARGS[@]}" install-multiple -r "${SEL[@]}"
fi

printf '\nDone.\nPatched APKM: %s\nADB install set: %s\nWork folder: %s\n' "$OUTPUT_APKM" "$INSTALL_SET" "$WORK"
