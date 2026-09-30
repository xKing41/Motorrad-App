# Datenschutzerklärung

Stand: Oktober 2026

Schräglage ist eine App für Motorradfahrer: Touren planen, navigieren, Fahrten aufzeichnen, Sturzerkennung. Die App hat **kein Benutzerkonto, keine Werbung und keine Nutzungsanalyse**. Was du aufzeichnest, bleibt auf deinem Handy.

## Verantwortlich

[NAME]
[ANSCHRIFT]
E-Mail: [E-MAIL]

## Was auf deinem Handy bleibt

- Aufgezeichnete Fahrten, gespeicherte Touren, Einstellungen, eigene Sperrliste
- Notfalldaten (Kontakt, Blutgruppe, Hinweise) - nur für die Notfall-SMS
- Schlüssel für optionale Dienste (TomTom, HERE, Tankerkönig, KI) - nie in Sicherungen
- Fehlerprotokoll (technische Angaben, keine Orte oder Namen)

Eine **Sicherung** erstellt nur, wer sie selbst anstößt. Wohin sie geht (Cloud, Mail, PC), entscheidest du.

## Standort

Die App braucht deinen Standort für Karte, Navigation, Aufzeichnung und Sturzerkennung. Im Hintergrund wird er nur verwendet, solange eine Fahrt aufgezeichnet oder navigiert wird.

## Dienste, an die Daten gehen

Für Karte, Suche und Routen fragt die App kostenlose Dienste an. Dabei werden die jeweils nötigen Koordinaten bzw. Suchbegriffe übertragen; der Dienst sieht außerdem deine IP-Adresse.

- **Karte:** OpenFreeMap (tiles.openfreemap.org), ersatzweise OpenStreetMap (tile.openstreetmap.org) - Kartenausschnitte
- **Routen, Tempolimits, Straßenprüfung:** Valhalla-Server der FOSSGIS e.V. (valhalla1.openstreetmap.de) oder ein von dir eingetragener Server; optional GraphHopper - Start, Ziel, Wegpunkte, Routenlinie
- **Suche:** Photon (photon.komoot.io), Nominatim (nominatim.openstreetmap.org) - Suchbegriff, ungefährer Ort
- **Orte, Spuren, Blitzer, Motorradverbote:** Overpass (overpass-api.de, overpass.kumi.systems) - Gebiet entlang der Route
- **Wetter:** Open-Meteo (api.open-meteo.com) - Orte entlang der Route
- **Verkehrsmeldungen Autobahn:** Autobahn GmbH des Bundes (verkehr.autobahn.de) - nur Autobahnnummern
- **Nur mit eigenem Schlüssel:** TomTom (Verkehr, Fahrzeit), HERE (Verkehr), Tankerkönig (Spritpreise), KI-Anbieter (Tourbeschreibung in deinen Worten, keine Koordinaten)

## Notfall- und Begleit-SMS

Bei einem erkannten Sturz (nach Countdown, abbrechbar) oder bei eingeschalteter Begleit-SMS schickt die App über dein Handy eine SMS an deinen Notfallkontakt: dein Name, deine Position und die Notfallangaben, die du eingetragen hast. Es entstehen die üblichen SMS-Kosten deines Tarifs.

## Gruppen (nur Test-App)

Positionen, Chat, Ausfahrten und Sprachnachrichten werden **Ende-zu-Ende verschlüsselt** (AES-256-GCM) über öffentliche Nachrichtendienste (broker.emqx.io, broker.hivemq.com) ausgetauscht. Der Dienst sieht nur verschlüsselte Daten und deine IP-Adresse. Deine Position sehen die anderen nur, solange du aufzeichnest oder navigierst. Das Mikrofon wird nur benutzt, während du eine Sprachnachricht aufnimmst.

## Fehlerberichte

Die App schickt nichts von selbst. Einen Fehlerbericht verschickst du selbst über den Teilen-Dialog; du siehst ihn vorher. Er enthält Version, Android-Version, letzte Rechenzeiten und das Fehlerprotokoll - keinen Standort, keine Namen, keine Nummern.

## Berechtigungen

- Standort (auch im Hintergrund während einer Fahrt)
- SMS (nur, wenn du das direkte Senden der Notfall-SMS einschaltest)
- Mikrofon und Bluetooth (nur Test-App: Headset und Sprachnachrichten)
- Benachrichtigungen (laufende Aufzeichnung)

## Deine Rechte

Du hast das Recht auf Auskunft, Berichtigung, Löschung, Einschränkung der Verarbeitung und Datenübertragbarkeit sowie auf Beschwerde bei einer Datenschutz-Aufsichtsbehörde. Da wir selbst keine Daten von dir speichern, genügt meist: Daten in der App löschen oder die App deinstallieren.

# Impressum

Angaben gemäß § 5 DDG

[NAME]
[ANSCHRIFT]
E-Mail: [E-MAIL]

Kartendaten © OpenStreetMap-Mitwirkende (ODbL). Schrift Barlow (SIL Open Font License).
