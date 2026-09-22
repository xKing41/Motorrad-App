# Schräglage

Schräglagen-Messer und Fahrtenauswertung fürs Motorrad. Ein Flutter-Projekt,
das auf Android läuft und mit einem Mac auch aufs iPhone kommt.

Die App misst nicht nur, wie weit du legst, sondern wertet aus, **wie** du
gefahren bist – Einzelkurven, Zeit je Schräglage, Kammscher Kreis. Dazu
Sturzerkennung mit Notfallkontakt und eine Regenwarnung.

---

## Was drin ist

**Cockpit**
- Schräglage in Echtzeit, flüssig am Sensortakt (rund 50 Werte je Sekunde)
- Sensorfusion aus Gyroskop, Beschleunigungssensor und GPS. Bei Fahrt gilt
  `Schräglage = asin(v · Gierrate / g)` – dadurch stimmen die Werte auch in
  langen Kurven, wo reine Sensor-Apps zu wenig anzeigen
- GPS-Tacho, Brems- und Kurven-G, Maximalwerte
- Nullpunkt-Kalibrierung: Das Handy darf beliebig schräg montiert sein
- Wetterstreifen mit Regen-, Frost- und Kaltreifenwarnung

**Karte**
- OpenStreetMap, Live-Spur nach Schräglage eingefärbt
- Routenplanung mit Kurvigkeit, Zwischenstopps, GPX-Import und -Export
- Optionale KI-Unterstützung: Sie übersetzt nur deinen Wunsch in Vorgaben
  und beschreibt das Ergebnis. Wege und Orte kommen **immer** aus echten
  Kartendaten – erfundene Ziele sind damit ausgeschlossen

**Fahrten**
- Aufzeichnung mit Strecke, Dauer, Vmax, Maximalschräglage
- Tiefenauswertung: Kurvenerkennung, Radien, Schräglagen-Histogramm,
  Kammscher Kreis, Fahrstil-Bewertung

**Notfall**
- Sturzerkennung: schlägt nur an, wenn drei Dinge zusammenkommen – vorher
  schneller als 25 km/h, harter Stoß über 4 g, danach acht Sekunden
  Stillstand
- Countdown mit großer Abbruchtaste, danach SMS mit Koordinaten
- Notfallkarte mit Blutgruppe, Medikamenten, Versicherung

### Eine bewusste Entscheidung zur Bewertung

Mehr Schräglage gibt **keine** Punkte. Eine App, die für tieferes Legen
belohnt, treibt Leute auf öffentlichen Straßen ins Risiko. Bewertet werden
gleichmäßiger Schräglagenaufbau, Bremsdisziplin und die Balance zwischen
Links- und Rechtskurven.

---

## Bauen

Das Repository enthält den eigenen Code, nicht das komplette Flutter-Gerüst.
Alle Wege erzeugen das Gerüst mit `flutter create` und legen den Code
darüber. Das ist Absicht: So kommen die Gradle-Dateien immer von der
installierten Flutter-Version und passen zur jeweiligen Toolchain.

### Ohne PC: in der Cloud

`.github/workflows/build-apk.yml` baut die APK bei jedem Push. Abholen unter
**Actions → letzter Lauf → Artifacts → Schraeglage-APK**. Von Hand starten
über **Run workflow**. Damit reicht ein Handy mit Browser.

Einzelheiten in [OHNE-PC-BAUEN.txt](OHNE-PC-BAUEN.txt).

### Windows

```
setup.bat
```

Lädt beim ersten Lauf alles Nötige (Git, Java, Flutter, Android-Werkzeuge,
etwa 1–2 GB), baut die App und legt `Schraeglage.apk` auf den Desktop.

### Linux, macOS, Termux

```
./build.sh
```

Setzt ein installiertes Flutter voraus (`flutter doctor`).
In Termux zusätzlich:

```
export SCHRAEGLAGE_AAPT2=/pfad/zur/arm64/aapt2
export SCHRAEGLAGE_ARM64_ONLY=1
./build.sh
```

### iPhone

Braucht einen Mac mit Xcode – Vorgabe von Apple. In `ios/Runner/Info.plist`
muss zusätzlich hinterlegt werden:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Für Tacho und präzise Schräglagenmessung wird der Standort benötigt.</string>
```

---

## Aufbau

```
app/lib/
  main.dart                     App-Hülle, Tabs, Sturzalarm
  theme.dart                    Farben und gemeinsame Bausteine
  models/ride.dart              Datenmodell, Kurvenerkennung
  services/
    telemetry.dart              Sensorfusion, GPS, Aufzeichnung
    crash_detector.dart         Sturzerkennung
    emergency.dart              Notfalldaten und Notruf
    weather_service.dart        Wetter und Regenwarnung
    ride_analysis.dart          Histogramm, Kammscher Kreis, Bewertung
    route_planner.dart          Routing über GraphHopper
    ride_store.dart             Fahrten dateibasiert ablegen
    ai_planner.dart             Anbindung an die Claude-API
    ai_config.dart              Zugangsdaten für die KI
  screens/                      Cockpit, Karte, Fahrten, Auswertung, Notfall
  widgets/                      Anzeige, Diagramme, Quellenangabe
app/android/                    Manifest und Gradle-Korrekturen
tools/check_dart.py             Strukturprüfung aller Dart-Dateien
```

---

## Dienste und Schlüssel

| Zweck | Dienst | Schlüssel nötig |
|---|---|---|
| Karte | OpenStreetMap | nein |
| Wetter | Open-Meteo | nein |
| Zwischenstopps | Overpass | nein |
| Routing | GraphHopper | ja, kostenlos |
| KI-Planung | Claude-API | ja, optional |

**Im Code steckt kein Schlüssel.** Alle Zugangsdaten werden in der App
eingegeben und bleiben auf dem Gerät. Deshalb ist es unbedenklich, dieses
Repository öffentlich zu stellen.

Ohne Routing-Server arbeitet die Planung im Demo-Modus und zeichnet nur eine
Testschleife, die keinen echten Straßen folgt. Die App weist darauf hin.

---

## Lizenzen und Quellen

- Kartendaten: © OpenStreetMap-Mitwirkende, ODbL. Die Angabe erscheint auf
  beiden Kartenansichten – sie ist Pflicht und darf nicht entfernt werden.
- Kartenkacheln über `tile.openstreetmap.org`. Deren Nutzungsrichtlinie ist
  auf geringe Lasten ausgelegt. Für den Eigengebrauch passt das; bei vielen
  Nutzern gehört ein eigener Kachelserver her.
- Wetterdaten: Open-Meteo.com, CC BY 4.0. Angabe steht im Wetterstreifen.
- Für dieses Projekt selbst ist **noch keine Lizenz festgelegt**. Ohne
  Lizenzdatei behältst du alle Rechte, und andere dürfen den Code nicht
  weiterverwenden. Falls das erwünscht ist, eine `LICENSE` ergänzen –
  zum Beispiel die MIT-Lizenz.

---

## Sicherheit

Alle Werte sind Näherungen aus Sensor- und GPS-Daten. Radien und
Beschleunigungen werden gerechnet, nicht gemessen.

Die Sturzerkennung ist eine Hilfe, **kein zugelassenes Notrufsystem**. Ein
sanftes Wegrutschen ohne harten Aufprall kann übersehen werden. Verlass dich
nicht darauf – wenn du kannst, ruf immer selbst 112.

Bedienung nur im Stand.
