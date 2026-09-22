# KI-Anbindung – wie es gedacht ist

Kurzfassung: **Die KI plant keine Route. Sie übersetzt und erzählt.**
Dazwischen liegt immer echte Technik.

```
   Freitext des Fahrers
   "180 km, viele Kurven, einmal tanken, Pause mit Aussicht"
        │
        ▼
   AiRoutePlanner.interpret()      ← Claude, liefert nur JSON
        │
        ▼
   RouteRequest  { distance_km: 180, curviness: "curvy", stops: [...] }
        │
        ▼
   GraphHopperPlanner.plan()       ← echte Straßen aus OpenStreetMap
        │
        ▼
   StopResolver.attachStops()      ← echte Orte aus Overpass/OSM
        │
        ▼
   AiRoutePlanner.describe()       ← Claude, nur mit verifizierten Fakten
        │
        ▼
   RoutePlan auf der Karte
```

## Warum so streng getrennt?

In einem Motorradforum hat jemand ChatGPT direkt nach einer Route gefragt.
Die Antwort war hübsch – inklusive GPX-Download-Link. Den Link gab es nicht.

Auf dem Sofa ist das ein Fehler. Auf dem Motorrad mit 15 km Restreichweite
ist eine erfundene Tankstelle ein Problem. Deshalb gilt in diesem Code:

> **Koordinaten kommen ausschließlich aus Kartendaten oder vom Nutzer.
> Das Sprachmodell darf auswählen und beschreiben – niemals erfinden.**

Das Modell benennt nur die *Art* des Stopps (`fuel`, `viewpoint`, `food` …).
Den konkreten Ort sucht danach `PoiService` in OpenStreetMap.

## Die beteiligten Dateien

| Datei | Aufgabe |
|---|---|
| `models/route_plan.dart` | `RouteRequest`, `StopWish`, `Poi`, `RoutePlan` + JSON-Schema |
| `services/ai_planner.dart` | Claude-Aufruf, System-Prompt, JSON-Auswertung |
| `services/route_planner.dart` | Routing-Engine (GraphHopper) + Demo-Planer |
| `services/poi_service.dart` | echte Orte aus OpenStreetMap (Overpass) |
| `screens/route_planner_screen.dart` | Oberfläche: Regler **und** KI-Feld |

Die Schnittstelle ist `RouteRequest`. Regler und KI erzeugen dasselbe Objekt –
die KI ist nur der bequemere Weg dorthin. Deshalb funktioniert die App auch
komplett ohne KI.

## Testen (Testphase)

1. App starten → Tab **KARTE** → **PLANEN**
2. Ganz unten **EINSTELLUNGEN** aufklappen
3. Eintragen:
   - *Routing-Server*: `https://graphhopper.com/api/1` + Schlüssel,
     oder leer lassen für den Demo-Modus
   - *KI-Schlüssel*: dein Claude-Key (`sk-ant-...`)
4. **EINSTELLUNGEN SPEICHERN**
5. Oben die Tour in eigenen Worten beschreiben → **MIT KI PLANEN**

Was du dann siehst: Die Regler springen auf das, was die KI verstanden hat.
Das ist Absicht – so bleibt nachvollziehbar, was passiert, statt dass eine
Blackbox eine Route ausspuckt.

## Sicherheitshinweis zum Schlüssel

Ein API-Schlüssel in der App lässt sich aus dem Installationspaket auslesen.
Für deine eigenen Tests auf dem eigenen Gerät ist das in Ordnung.

**Sobald die App an andere geht**, muss der Aufruf über einen eigenen kleinen
Server laufen, der den Schlüssel hält. Im Code ist das schon vorbereitet:

```dart
// Testphase (Schlüssel im Gerät):
AiRoutePlanner(apiKey: '<dein key>')

// Später (Schlüssel auf dem Server):
AiRoutePlanner(baseUrl: 'https://dein-server.de/plan')
```

Der eigene Server muss nur die Anfrage entgegennehmen, den Schlüssel
ergänzen und an Anthropic weiterreichen. Das Antwortformat bleibt gleich.

Zweiter Grund für den eigenen Server: Ohne ihn kann jeder mit deinem
Schlüssel auf deine Rechnung Anfragen stellen.

## Kosten im Blick behalten

Jede Planung kostet zwei Modellaufrufe (übersetzen + beschreiben). Das ist
pro Anfrage sehr wenig, summiert sich aber mit jedem Nutzer – und zwar
dauerhaft. Genau daran sind Motorrad-Apps schon gescheitert.

Praktische Konsequenzen:
- `describe()` ist optional und wird übersprungen, wenn kein Schlüssel gesetzt ist
- `max_tokens` bewusst klein gehalten (800 bzw. 300)
- Später sinnvoll: Ergebnisse zwischenspeichern, Anfragen pro Tag begrenzen

## Was als Nächstes drankommt

- **Rückfragen-Dialog**: mehrere Runden statt einer Anfrage
  (`interpret()` nimmt bereits einen `history`-Parameter entgegen)
- **`prefer_known_good_roads` scharf schalten**: `RideStore.buildLeanHeatmap()`
  liefert schon die eigenen Strecken, `RouteScorer` bewertet Routen dagegen.
  Fehlt noch: diese Bereiche als bevorzugte Zonen an GraphHopper übergeben.
  Das ist das Feature, das sonst niemand hat – Routen, die deine eigenen
  Fahrdaten kennen.
- **Eigene Fotospots**: Nutzer markieren Stellen, `Poi.source = 'user'` ist
  dafür schon vorgesehen. Je mehr Spots die Community sammelt, desto
  schwerer kopierbar wird die App.
