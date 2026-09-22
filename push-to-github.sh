#!/usr/bin/env bash
#
# Bringt dieses Verzeichnis zu GitHub. Laeuft unter Linux, macOS und in
# Termux (dort vorher: pkg install git).
#
# Vorher auf github.com ein leeres Repository anlegen - OHNE Haken bei
# "Add a README file", sonst gibt es beim ersten Push einen Konflikt.
#
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================================="
echo "   SCHRAEGLAGE zu GitHub bringen"
echo "=============================================================="
echo

if ! command -v git >/dev/null 2>&1; then
    echo "[FEHLER] git ist nicht installiert."
    echo "  Termux:  pkg install git"
    echo "  Ubuntu:  sudo apt install git"
    exit 1
fi

read -r -p "Adresse des leeren Repositories (https://github.com/NAME/REPO.git): " REMOTE
if [ -z "$REMOTE" ]; then
    echo "[ABBRUCH] Keine Adresse angegeben."
    exit 1
fi

# Name und E-Mail nur setzen, wenn noch nichts hinterlegt ist. So
# erscheinen die Commits unter DEINEM Konto und nicht unter einem
# fremden Namen.
if ! git config --get user.name >/dev/null 2>&1; then
    read -r -p "Dein Name fuer die Commits: " GN
    git config --global user.name "$GN"
fi
if ! git config --get user.email >/dev/null 2>&1; then
    read -r -p "Deine GitHub-E-Mail: " GE
    git config --global user.email "$GE"
fi

if [ ! -d .git ]; then
    git init
fi

git add .
if git diff --cached --quiet; then
    echo "Keine Aenderungen zum Uebertragen."
else
    git commit -m "Schraeglage App"
fi

git branch -M main

if git remote | grep -q '^origin$'; then
    git remote set-url origin "$REMOTE"
else
    git remote add origin "$REMOTE"
fi

echo
echo "Jetzt kommt die Anmeldung."
echo "WICHTIG: Beim Passwort NICHT das Kontopasswort eingeben, sondern"
echo "einen Personal Access Token."
echo "  GitHub -> Settings -> Developer settings ->"
echo "  Personal access tokens -> Fine-grained -> neues Token"
echo "  Zugriff auf dieses Repository, Recht: Contents = Read and write"
echo

git push -u origin main

echo
echo "=============================================================="
echo "   FERTIG"
echo "=============================================================="
echo "Der Build startet bei GitHub von selbst."
echo "APK holen:  Repository -> Reiter 'Actions' -> letzter Lauf"
echo "            -> unten unter 'Artifacts' -> Schraeglage-APK"
echo
