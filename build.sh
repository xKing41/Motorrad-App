#!/usr/bin/env bash
#
# Baut die APK auf Linux, macOS oder in Termux.
# Gegenstueck zur setup.bat fuer Windows.
#
# Voraussetzung: Flutter ist installiert und "flutter" liegt im PATH.
#   Pruefen mit:  flutter doctor
#
# Aufruf:  ./build.sh
#
set -euo pipefail

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUELLE="$HIER/app"
ZIEL="${SCHRAEGLAGE_BUILD_DIR:-$HIER/proj}"

echo "=============================================================="
echo "   SCHRAEGLAGE - APK bauen"
echo "=============================================================="

if ! command -v flutter >/dev/null 2>&1; then
    echo "[FEHLER] flutter wurde nicht gefunden."
    echo "Installieren: https://docs.flutter.dev/get-started/install"
    exit 1
fi

if [ ! -f "$QUELLE/lib/main.dart" ]; then
    echo "[FEHLER] Quellcode nicht gefunden unter $QUELLE"
    exit 1
fi

# --- Geruest erzeugen -------------------------------------------------
# Liefert android/, Gradle-Dateien und Symbole. Wird jedes Mal frisch
# erzeugt, damit veraltete Build-Dateien keine Fehler verursachen.
echo "[1/4] Projektgeruest erzeugen ..."
rm -rf "$ZIEL"
flutter create --platforms=android --project-name schraeglage "$ZIEL" >/dev/null

# --- Eigene Dateien darueberlegen -------------------------------------
echo "[2/4] Eigenen Code einsetzen ..."
cp "$QUELLE/pubspec.yaml" "$ZIEL/pubspec.yaml"
rm -rf "$ZIEL/lib"
cp -r "$QUELLE/lib" "$ZIEL/lib"
cp -r "$QUELLE/android/." "$ZIEL/android/"

# minSdk 24 - wird von geolocator verlangt
for f in "$ZIEL/android/app/build.gradle.kts" "$ZIEL/android/app/build.gradle"; do
    if [ -f "$f" ]; then
        sed -i.bak 's/flutter\.minSdkVersion/24/g' "$f" && rm -f "$f.bak"
    fi
done

# compileSdk-Fix fuer die Plugin-Module anhaengen
if [ -f "$ZIEL/android/compilesdk-fix.txt" ]; then
    cat "$ZIEL/android/compilesdk-fix.txt" >> "$ZIEL/android/build.gradle.kts"
fi

# --- Termux-Hinweis ---------------------------------------------------
# In Termux laeuft das von Gradle geladene aapt2 nicht (x86-Programm auf
# ARM). Der Pfad zur ARM64-Fassung muss gesetzt werden - aber NUR dort,
# sonst bricht der Build auf PC und Mac ab.
if [ -n "${SCHRAEGLAGE_AAPT2:-}" ]; then
    echo "android.aapt2FromMavenOverride=$SCHRAEGLAGE_AAPT2" \
        >> "$ZIEL/android/gradle.properties"
    echo "      aapt2 gesetzt auf $SCHRAEGLAGE_AAPT2"
fi

# --- Bauen ------------------------------------------------------------
echo "[3/4] Abhaengigkeiten laden ..."
cd "$ZIEL"
flutter pub get

echo "[4/4] APK bauen (beim ersten Mal dauert es) ..."
if [ -n "${SCHRAEGLAGE_ARM64_ONLY:-}" ]; then
    flutter build apk --release --target-platform android-arm64
else
    flutter build apk --release
fi

APK="$ZIEL/build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$APK" ]; then
    echo "[FEHLER] Die APK wurde nicht erzeugt."
    exit 1
fi

cp "$APK" "$HIER/Schraeglage.apk"
echo
echo "=============================================================="
echo "   FERTIG"
echo "=============================================================="
echo "   $HIER/Schraeglage.apk"
echo
echo "   Aufs Handy uebertragen, antippen, installieren."
echo "   Beim ersten Start die Standort-Berechtigung erlauben."
echo
