#!/usr/bin/env bash
# Builds the KIDNOVA Android app (kidnova.apk) without Gradle, using the Android SDK build tools.
# Needs: JDK 17+, ANDROID_HOME with platforms;android-34 and build-tools;35.0.0,
# and a signing key: KEYSTORE (path), KEYSTORE_PASS. Keep the same key for every update.
set -euo pipefail
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:?set ANDROID_HOME}"
BT="$SDK/build-tools/35.0.0"
JAR="$SDK/platforms/android-34/android.jar"
OUT="${1:-../kidnova.apk}"
: "${KEYSTORE:?set KEYSTORE}" "${KEYSTORE_PASS:?set KEYSTORE_PASS}"
rm -rf build && mkdir -p build/res build/gen build/classes build/dex
"$BT/aapt2" compile --dir res -o build/res/res.zip
"$BT/aapt2" link -I "$JAR" --manifest AndroidManifest.xml -o build/base.apk \
  --java build/gen build/res/res.zip --min-sdk-version 24 --target-sdk-version 34 --auto-add-overlay
javac -source 8 -target 8 -encoding UTF-8 -Xlint:-options -classpath "$JAR" -d build/classes \
  $(find src build/gen -name '*.java')
(cd build/classes && jar cf ../classes.jar .)
"$BT/d8" --release --min-api 24 --lib "$JAR" --output build/dex build/classes.jar
cp build/base.apk build/unsigned.apk
(cd build/dex && zip -q -j ../unsigned.apk classes.dex)
"$BT/zipalign" -f -p 4 build/unsigned.apk build/aligned.apk
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass env:KEYSTORE_PASS --ks-key-alias kidnova --out "$OUT" build/aligned.apk
"$BT/apksigner" verify "$OUT"
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
