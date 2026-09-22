# KI-Anbindung – wie es gedacht ist

Kurzfassung: **Die KI plant keine Route. Sie übersetzt und erzählt.**
Dazwischen liegt immer echte Technik.

```
   Freitext des Fahrers
   "180 km über den Edersee, viele Kurven, einmal tanken"
        │
        ▼
   AiRoutePlanner.interpret()      ← Claude, liefert nur JSON
        │                            (per Structured Outputs erzwungen)
        ▼
   RouteRequest  { distance_km: 180, curviness: "curvy",
                   towards: "Edersee", stops: [{kind: "fuel"}] }
        │
        ▼
   Geocoder.search("Edersee")      ← Ortsname → Koordinaten aus OSM
        │
        ▼
   Regler auf dem Bildschirm       ← zeigen, was die KI verstanden hat
        │
        ▼
   TourPlanner.plan()              ← echte Straßen (Valhalla, Motorrad-
        │                            Profil), mehrere Varianten, bewertet
        ▼
   TourPlanner.chooseStops()       ← echte Orte aus Overpass/OSM, als
        │                            Wegpunkte in die Route eingebaut
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

Ortsnamen darf das Modell weitergeben, aber nur, wenn der Fahrer sie selbst
nennt: `destination` (Tour endet dort) und `towards` (Rundtour führt darüber
oder in diese Richtung). Die Koordinaten dazu sucht `Geocoder` in echten
Kartendaten. Findet er den Ort nicht, sagt die App das, statt zu raten.
Koordinaten, die das Modell trotzdem schickt, werden verworfen.

## Die beteiligten Dateien

| Datei | Aufgabe |
|---|---|
| `models/route_plan.dart` | `RouteRequest`, `StopWish`, `Poi`, `RoutePlan`, lesbares Schema |
| `services/ai_planner.dart` | Claude-Aufruf, System-Prompt, erzwungenes JSON-Schema |
| `services/geocoder.dart` | Ortsnamen → Koordinaten (Photon, Nominatim) |
| `services/route_planner.dart` | `TourPlanner`: Rundtour, A→B, Varianten, Bewertung, Stopps |
| `services/routing_engine.dart` | Valhalla (Standard) und GraphHopper |
| `services/poi_service.dart` | echte Orte aus OpenStreetMap (Overpass) |
| `screens/route_planner_screen.dart` | Oberfläche: Regler **und** KI-Feld |

Die Schnittstelle ist `RouteRequest`. Regler und KI erzeugen dasselbe Objekt –
die KI ist nur der bequemere Weg dorthin. Deshalb funktioniert die App auch
komplett ohne KI.

## Testen (Testphase)

1. App starten → Tab **KARTE** → **PLANEN**
2. **KI VERBINDEN** antippen, Claude-Schlüssel (`sk-ant-...`) einsetzen,
   **VERBINDUNG TESTEN**, speichern. Ein Routing-Schlüssel ist nicht nötig –
   geroutet wird über den kostenlosen Valhalla-Server.
3. Oben die Tour in eigenen Worten beschreiben → **MIT KI PLANEN**

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
- `effort: "low"` für beide Aufrufe (bei Haiku entfällt der Wert, Haiku kennt
  ihn nicht) – die Aufgaben sind einfach, langes Nachdenken kostet nur
- `max_tokens` 2048 bzw. 1024: Sonnet 5 denkt standardmäßig kurz nach, und
  das zählt mit. Mit den alten 1200 bzw. 500 konnte die Antwort
  abgeschnitten werden – dann kam „Antwort nicht verwertbar“
- Später sinnvoll: Ergebnisse zwischenspeichern, Anfragen pro Tag begrenzen

## Was als Nächstes drankommt

- **Rückfragen-Dialog**: mehrere Runden statt einer Anfrage
  (`interpret()` nimmt bereits einen `history`-Parameter entgegen)
- **`prefer_known_good_roads` ausbauen**: Ist jetzt aktiv –
  `RideStore.buildLeanHeatmap()` liefert die eigenen Strecken, und
  `RouteScoring` gibt Varianten darauf einen Bonus. Nächster Schritt:
  gezielt Hilfspunkte auf Lieblingsstrecken legen, statt nur unter den
  Varianten auszuwählen. Das ist das Feature, das sonst niemand hat –
  Routen, die deine eigenen Fahrdaten kennen.
- **Eigene Fotospots**: Nutzer markieren Stellen, `Poi.source = 'user'` ist
  dafür schon vorgesehen. Je mehr Spots die Community sammelt, desto
  schwerer kopierbar wird die App.
