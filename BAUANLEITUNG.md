# Schräglage bauen – Kurzfassung

Ausführlich steht alles in der [README.md](README.md). Hier nur die drei Wege
im Überblick.

| Weg | So geht's | Dauer |
|---|---|---|
| **Windows-PC** | `setup.bat` doppelklicken, die APK liegt danach auf dem Desktop | beim ersten Mal 10–30 min, danach wenige Minuten mit `C:\dev\schraeglage-neu-bauen.bat` |
| **Nur Handy (Cloud)** | Code nach GitHub bringen (`push-to-github.sh`), GitHub baut automatisch; APK unter **Actions → letzter Lauf → Artifacts** | 5–10 min je Build |
| **Linux, macOS, Termux** | `./build.sh` (Flutter muss installiert sein) | wenige Minuten |

Einzelheiten zum Cloud-Weg: [OHNE-PC-BAUEN.txt](OHNE-PC-BAUEN.txt).

## Wichtig zu wissen

- **Signatur:** Cloud-Builds haben immer denselben Schlüssel, PC-Builds den
  Schlüssel des jeweiligen PCs. Beim Wechsel zwischen beiden Wegen muss die
  App einmal deinstalliert werden, und die gespeicherten Fahrten gehen
  verloren. Am besten bei einem Weg bleiben.
- **Neue Version vom PC:** Eine neue ZIP-Version immer mit `setup.bat`
  bauen. `schraeglage-neu-bauen.bat` baut nur, was schon in
  `C:\dev\schraeglage` liegt.
- **Tests:** In der Cloud laufen vor jedem Build der Analyzer und die
  Unit-Tests (`app/test`). Ist dort etwas rot, entsteht keine APK.
- **iPhone:** Nur mit einem Mac und Xcode. In `ios/Runner/Info.plist` muss
  `NSLocationWhenInUseUsageDescription` eingetragen werden (siehe README).
