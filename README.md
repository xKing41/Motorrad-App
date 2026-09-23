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
- GPS-Tacho, Brems- und Kurven-G, Maximalwerte. Kurven-G wird aus Tempo ×
  Drehrate gemessen (nicht aus der Schräglage geschätzt), Brems-G per GPS
  gegengeprüft, die Schräglage um die Reifenbreite korrigiert
  (`services/dynamics.dart`)
- Schräglage per Kalman-Filter mit Schätzung der Gyroskop-Drift,
  Nullpunkt-Nachmessung bei jedem Halt, Reifenbreite und Bauart des
  eigenen Motorrads einstellbar (`services/lean_filter.dart`)
- Nullpunkt-Kalibrierung: Das Handy darf hochkant, quer oder flach und
  beliebig schräg montiert sein; die Lage wird gespeichert
- Wetterstreifen mit Regen-, Frost- und Kaltreifenwarnung

**Karte und Routenplanung**
- OpenStreetMap, Live-Spur nach Schräglage eingefärbt
- **Offline-Karten**: angesehene Karten bleiben auf dem Handy, Route
  (automatisch beim Planen) und Kartenausschnitte vorab speichern; im
  Funkloch vergrößerte gröbere Kacheln statt leerer Flächen
- **Tempolimit** bei der Navigation (OpenStreetMap, auch offline), optional
  mit Ansage bei zu hohem Tempo; feste Blitzer nur bei der Planung
- Echte Motorrad-Routen ohne Schlüssel und ohne Konto (Valhalla auf dem
  Server der FOSSGIS, mit eigenem Motorrad-Profil)
- **Rundtouren**, die an deinem Standort beginnen und enden – mit
  Wunschlänge, Himmelsrichtung und optional „über“ einen Ort
- **Von A nach B** mit Zielsuche und kurvigen Umwegen
- Mehrere Varianten zur Auswahl, bewertet nach Kurvigkeit, Länge und
  doppelt gefahrenen Abschnitten; Sackgassen-Stiche werden
  herausgeschnitten
- Zwischenstopps über die ganze Strecke: Tanken nach Reichweite (einstellbar,
  als Kette – nie weiter als die Reichweite, wenn es irgend geht), Pausen im
  gewählten Abstand (Rastplatz und Einkehr im Wechsel), Aussichtspunkte
  gleichmäßig verteilt. Alle Stopps werden als echte Wegpunkte eingebaut,
  lange Touren stückweise
- „Bewährte Strecken bevorzugen“: Varianten auf Straßen, die du schon
  gefahren bist, werden bevorzugt
- GPX-Import und -Export (Export über den Teilen-Dialog des Handys)
- **Übergabe an andere Navis**: GPX (TomTom GO, Garmin, Kurviger,
  Calimoto, OsmAnd …), Google Maps mit bis zu 9 Zwischenpunkten auf der Tour
  (lange Touren in Abschnitten), Waze, beliebige Navi-App per „Öffnen mit“

**Navigation**
- Abbiegehinweise mit Entfernung und gestaffelten Sprachansagen (Autobahn
  3 km / 1 km / 400 m / davor, Landstraße 1 km / 400 m / davor, Ort 250 m /
  davor), Karte in Fahrtrichtung, flüssig mit ~30 Bildern je Sekunde
  (Position zwischen den GPS-Messungen auf der Route weitergerechnet),
  Zoom nach Tempo, Ankunftszeit, nächster Stopp
- Verfahren? Nach wenigen Sekunden neue Route – **zurück auf die Tour**,
  nicht irgendwie zum Ziel; der Rest der kurvigen Strecke bleibt erhalten
- Staus, Sperrungen, Baustellen, Unfälle aus mehreren Quellen (Autobahn GmbH
  immer, TomTom und HERE mit Schlüssel, doppelte Meldungen zusammengeführt),
  Verkehrsfluss farbig auf der Karte; schon beim
  Planen umfahren, unterwegs alle 5 Minuten geprüft. Sperrungen werden
  automatisch umfahren, bei Staus wird die Umfahrung angeboten, wenn sie
  schneller ist
- Auf Zuruf: „Sperrung“ meidet die Strecke direkt voraus, „Stopp
  überspringen“ lässt den nächsten Stopp aus
- Optionale KI-Unterstützung: Sie übersetzt nur deinen Wunsch in Vorgaben
  und beschreibt das Ergebnis. Wege und Orte kommen **immer** aus echten
  Kartendaten – erfundene Ziele sind damit ausgeschlossen

**Hintergrund und Akku**
- Während einer Fahrt oder Navigation läuft alles als Android-
  Vordergrunddienst weiter – auch bei ausgeschaltetem Bildschirm
- Ohne Fahrt ist im Hintergrund alles aus; bei offener App läuft das GPS
  sparsam; der Bildschirm bleibt nur während Fahrt/Navigation an

**Fahrten**
- Aufzeichnung mit Strecke, Dauer, Vmax, Maximalschräglage; die laufende
  Fahrt wird jede Minute gesichert und nach einem Abbruch gerettet
- Tiefenauswertung: Kurvenerkennung, Radien, Schräglagen-Histogramm,
  Kammscher Kreis, Fahrstil-Bewertung

**Notfall**
- Sturzerkennung: schlägt nur an, wenn drei Dinge zusammenkommen – vorher
  schneller als 25 km/h, harter Stoß über 4 g, danach acht Sekunden
  Stillstand
- Zusätzlich muss das Handy danach anders liegen als vorher (Motorrad
  liegt) – kein Fehlalarm nach einem Schlag vor der Ampel
- Countdown mit großer Abbruchtaste und Sprachansage, danach SMS mit
  Koordinaten – auf Wunsch automatisch gesendet (Berechtigung „SMS senden“)
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

`.github/workflows/build-apk.yml` prüft den Code (Analyzer und Tests) und
baut die APK bei jedem Push auf `main`, `master` und `claude/…`-Zweige.
Abholen unter **Actions → letzter Lauf → Artifacts → Schraeglage-APK**.
Von Hand starten über **Run workflow**. Damit reicht ein Handy mit Browser.

Alle Cloud-Builds sind mit demselben Schlüssel signiert
(`app/android/ci-signing.jks`), damit sich jede neue APK als Update über
die alte installieren lässt. Eine am PC gebaute APK hat eine andere
Signatur – beim Wechsel zwischen PC- und Cloud-Build muss die App einmal
deinstalliert werden (dabei gehen die gespeicherten Fahrten verloren).

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

### Tests

```
cd proj        # das von build.sh erzeugte Projekt
flutter analyze
flutter test
```

Die Tests prüfen die Streckenlogik ohne Netz: Kurvigkeit, Sackgassen,
Rundtour-Form, Längenkorrektur, Stoppauswahl, Valhalla-Anfragen und
-Antworten, GPX, Folgen-Modus, Tankkette, Navigation (Ansagen,
Neuberechnung, Umfahrung), Verkehrsmeldungen, Links für andere Navis.
In der Cloud laufen sie vor jedem Build.

---

## Aufbau

```
app/lib/
  main.dart                     App-Hülle, Tabs, Sturzalarm
  theme.dart                    Farben und gemeinsame Bausteine
  models/ride.dart              Datenmodell, Kurvenerkennung
  models/route_plan.dart        Routenanfrage, Route, Orte, KI-Schema
  services/
    telemetry.dart              Sensorfusion, GPS, Aufzeichnung
    crash_detector.dart         Sturzerkennung
    emergency.dart              Notfalldaten und Notruf
    weather_service.dart        Wetter und Regenwarnung
    ride_analysis.dart          Histogramm, Kammscher Kreis, Bewertung
    route_planner.dart          Tourenplaner: Rundtour, A→B, Varianten,
                                Bewertung, Zwischenstopps
    routing_engine.dart         Valhalla (Standard) und GraphHopper
    routing_settings.dart       gespeicherte Routing-Einstellungen
    geo.dart                    Geometrie: Kurvigkeit, Doppelstrecken,
                                Sackgassen, Projektion auf die Route
    geocoder.dart               Ortssuche (Photon, Nominatim)
    poi_service.dart            Orte aus OpenStreetMap (Overpass)
    route_follow.dart           Folgen-Modus: Position auf der Route
    route_patch.dart            Routen stückweise ersetzen (Umfahrung,
                                Rückführung auf die Tour)
    navigation.dart             Navigation: Hinweise, Ansagen,
                                Neuberechnung, Verkehrslage
    traffic_service.dart        Staus/Sperrungen (TomTom), Umfahrungen
    external_nav.dart           Links für Google Maps, Waze & Co.
    voice.dart                  Sprachansagen
    gpx_service.dart            GPX lesen, schreiben, teilen
    ride_store.dart             Fahrten dateibasiert ablegen
    ai_planner.dart             Anbindung an die Claude-API
    ai_config.dart              Zugangsdaten für die KI
  screens/                      Cockpit, Karte, Planer, Fahrten, Notfall
  widgets/                      Anzeige, Diagramme, Quellenangabe
app/test/                       Unit-Tests (Geometrie, Planer, GPX …)
app/android/                    Manifest, Gradle-Korrektur, Cloud-Schlüssel
tools/check_dart.py             Strukturprüfung aller Dart-Dateien
```

---

## Dienste und Schlüssel

| Zweck | Dienst | Schlüssel nötig |
|---|---|---|
| Karte | OpenStreetMap | nein |
| Wetter | Open-Meteo | nein |
| Routing | Valhalla (FOSSGIS) | nein |
| Routing, alternativ | GraphHopper | ja, optional |
| Tempolimits entlang der Route | Valhalla trace_attributes (OSM maxspeed) | nein |
| Feste Blitzer (nur Planung) | Overpass (OSM) | nein |
| Ortssuche | Photon (komoot), Nominatim | nein |
| Zwischenstopps | Overpass | nein |
| Verkehrslage (Staus, Sperrungen), Verkehrsfluss-Karte | TomTom Traffic API | ja, optional (kostenlos, 2.500 Abfragen/Tag) |
| Verkehrslage, zweite Quelle | HERE Traffic API v7 | ja, optional |
| Baustellen, Sperrungen, Staus auf Autobahnen | Autobahn GmbH (verkehr.autobahn.de) | nein |
| Sprachansagen | Sprachausgabe des Handys | nein |
| KI-Planung | Claude-API | ja, optional |

**Im Code steckt kein API-Schlüssel.** Alle Zugangsdaten werden in der App
eingegeben und bleiben auf dem Gerät.

Einzige Ausnahme ist der Signaturschlüssel für die Cloud-Builds
(`app/android/ci-signing.jks`). Solange das Repository privat ist, ist das
unkritisch. Bei einem **öffentlichen** Repository könnte jemand damit eine
APK bauen, die sich als Update über deine App installieren lässt. Dann
entweder privat lassen oder den Schlüssel durch einen eigenen ersetzen.

Den Demo-Modus mit der gemalten Testschleife gibt es nicht mehr: Die App
plant ohne jede Einrichtung echte Routen über den öffentlichen
Valhalla-Server der FOSSGIS e. V. Der ist ein kostenloses Angebot für alle –
die App stellt deshalb höchstens eine Anfrage je Sekunde. Wer die App an
viele Leute weitergibt, braucht einen eigenen Valhalla-Server (Adresse in
der App unter **PLANEN → EINSTELLUNGEN**).

---

## Lizenzen und Quellen

- Kartendaten: © OpenStreetMap-Mitwirkende, ODbL. Die Angabe erscheint auf
  beiden Kartenansichten – sie ist Pflicht und darf nicht entfernt werden.
- Routing: Valhalla auf dem Server der FOSSGIS e. V., Daten aus
  OpenStreetMap. Ortssuche über Photon (komoot) und Nominatim.
- Kartenkacheln über `tile.openstreetmap.org`. Deren Nutzungsrichtlinie ist
  auf geringe Lasten ausgelegt. Für den Eigengebrauch passt das; bei vielen
  Nutzern gehört ein eigener Kachelserver her. Das Vorab-Laden hält die
  Regeln ein: höchstens 2 gleichzeitige Downloads, nur bis Zoomstufe 16,
  eindeutige App-Kennung, vorhandene Kacheln werden nicht erneut geholt.
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
