# SCHRÄGLAGE v3 – Telemetrie, Karte und Navigation fürs Motorrad

Native App für Android und iPhone (Flutter, ein Code für beide Plattformen).

## Was drin ist

**Cockpit**
- Schräglage mit 3-facher Sensorfusion: Gyroskop + Beschleunigungssensor +
  GPS-Methode `asin(v · Gierrate / g)` – dadurch stimmen auch lange Kurven
- GPS-Tacho, Brems-G und Kurven-G live und als Maximalwerte
- Nullpunkt-Kalibrierung, Handy darf beliebig schräg montiert sein

**Karte** (neu)
- Live-Position auf OpenStreetMap
- Aufgezeichnete Spur direkt während der Fahrt, eingefärbt nach Schräglage
- GPX-Import und Follow-Modus mit Reststrecke und Warnung bei Abweichung
- Routenplanung mit Länge, Kurvigkeit und Zwischenstopps
- Echte Orte aus OpenStreetMap: Tankstellen, Aussichtspunkte, Rastplätze,
  Einkehr, Trinkwasser, Werkstätten

**Fahrten**
- Jede Tour mit Karte, Kurvenauswertung (links/rechts, Ein- und Ausgangstempo)
  und GPX-Export
- Gesamtstatistik über alle Fahrten
- Alles lokal auf dem Gerät, kein Konto, keine Cloud

**KI-Routenplanung** – vorbereitet, siehe `KI-ANBINDUNG.md`

## Aufbau des Codes

```
lib/
  main.dart                     App-Einstieg, Tab-Navigation
  theme.dart                    Farben und gemeinsame Bausteine
  models/
    ride.dart                   Fahrt, Trackpunkt, Kurvenerkennung
    route_plan.dart             Route, POI, RouteRequest + KI-Schema
  services/
    telemetry.dart              Sensorfusion, GPS, Aufzeichnung
    ride_store.dart             Speicherung, Heatmap eigener Strecken
    gpx_service.dart            GPX Import/Export
    poi_service.dart            echte Orte aus OpenStreetMap
    route_planner.dart          Routing-Engine (austauschbar)
    route_follow.dart           Follow-Modus
    ai_planner.dart             Claude-Anbindung
  screens/                      Cockpit, Karte, Planer, Fahrten, Detail
  widgets/gauge.dart            Schräglagen-Anzeige
```

Die Routing-Engine steckt hinter der Schnittstelle `RoutePlanner` und ist
austauschbar. Ohne hinterlegten Server läuft ein Demo-Planer, damit Karte
und Follow-Modus sofort testbar sind.

## Bauen

**Windows:** `setup.bat` doppelklicken – lädt alles und baut die APK.

**Manuell:**
```
flutter create schraeglage
# pubspec.yaml, lib/ und android/ aus diesem Ordner darüberkopieren
flutter pub get
flutter build apk --release
```

**iPhone:** braucht Mac + Xcode. In `ios/Runner/Info.plist` vor `</dict>`:
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Für Tacho, Streckenaufzeichnung und präzise Schräglagenmessung wird der Standort benötigt.</string>
```

## Kartendaten

Die Karten kommen von OpenStreetMap. Für eigene Tests ist das in Ordnung.
Sobald die App an viele Nutzer geht, ist ein eigener Kartendienst nötig –
die Tile-Server von OpenStreetMap sind für den Dauerbetrieb einer App
nicht gedacht. Umgestellt wird das an genau einer Stelle: `urlTemplate`
in `map_screen.dart` und `ride_detail_screen.dart`.

## Benutzung

1. Standort-Berechtigung erlauben
2. Handy montieren, Motorrad gerade halten → **NULLPUNKT SETZEN**
3. **FAHRT STARTEN**, losfahren, am Ziel beenden
4. Fahrt im Tab **FAHRTEN** öffnen: Karte, Kurven, Export

**Sicherheit:** Bedienung nur im Stand. Alle Werte sind Näherungswerte und
nicht für Grenzbereichs-Tests gedacht.
