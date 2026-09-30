# Schräglage in den Google Play Store bringen

Diese Anleitung führt Schritt für Schritt vom jetzigen Stand zur App im Store.
Stand: Oktober 2026 – Google ändert die Abläufe gelegentlich, im Zweifel gilt
die Play Console.

## 1. Entwicklerkonto

- https://play.google.com/console – einmalig 25 US-Dollar.
- Als Privatperson wird deine Adresse im Store angezeigt (Pflicht).
- **Wichtig:** Neue private Konten müssen die App zuerst in einem
  *geschlossenen Test* mit **mindestens 12 Testern über 14 Tage** laufen
  lassen, bevor sie öffentlich erscheinen darf. Freunde, Kollegen, Stammtisch
  reichen – sie brauchen nur ein Google-Konto.

## 2. Upload-Schlüssel anlegen (einmalig, gut aufheben!)

Der Schlüssel beweist Google, dass Updates von dir kommen. **Geht er verloren,
kannst du ihn bei Google zurücksetzen lassen – das dauert aber Tage.**
Leg ihn deshalb an einem sicheren Ort ab (z. B. Passwort-Manager + USB-Stick).

Auf dem PC (Java ist durch die setup.bat schon installiert, sonst Android
Studio), in einer Eingabeaufforderung:

```
keytool -genkeypair -v -keystore upload.jks -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Passwort merken. Danach die Datei in Text umwandeln (PowerShell):

```
[Convert]::ToBase64String([IO.File]::ReadAllBytes("upload.jks")) | Set-Content upload.txt
```

## 3. Schlüssel bei GitHub hinterlegen

GitHub → Repository → Settings → Secrets and variables → Actions →
„New repository secret“:

| Name | Inhalt |
|---|---|
| `UPLOAD_KEYSTORE_BASE64` | kompletter Inhalt von `upload.txt` |
| `UPLOAD_STORE_PASSWORD` | das Passwort aus Schritt 2 |
| `UPLOAD_KEY_ALIAS` | `upload` |
| `UPLOAD_KEY_PASSWORD` | das Passwort aus Schritt 2 |

Optional unter „Variables“: `STORE_APP_ID` (Standard: `de.schraeglage.app`).
**Die Kennung lässt sich nach dem ersten Hochladen nie mehr ändern.**

Ab dann baut jeder Lauf zusätzlich **Schraeglage-Store-AAB** – diese Datei wird
in der Play Console hochgeladen. Die APKs zum direkten Installieren bleiben wie
bisher.

## 4. Unterschiede der Store-Ausgabe

- Eigene App-Kennung (`de.schraeglage.app`) – sie liegt neben der bisher
  installierten App. Fahrten vorher über *Fahrten → Sichern* übertragen.
- **Keine automatische Notfall-SMS:** Google erlaubt das Senden von SMS nur
  mit Sondergenehmigung. Die Notfall-SMS öffnet die SMS-App mit fertigem Text.
  Ein automatischer Notruf über einen eigenen Server ist für „Pro“ geplant.
- Test-Funktionen (Gruppen, Headset, Probefahrt) sind nicht enthalten.

## 5. Datenschutzerklärung veröffentlichen

Google verlangt eine Adresse im Internet. Am einfachsten über GitHub Pages:
Settings → Pages → „Deploy from a branch“ → Branch `main`, Ordner `/docs`.
Die Adresse ist dann `https://<name>.github.io/<repo>/datenschutz`.

**Vorher in `docs/datenschutz.md` UND `app/assets/legal/datenschutz.md` die
Platzhalter [NAME], [ANSCHRIFT], [E-MAIL] ausfüllen.**

## 6. Play Console ausfüllen

- **Store-Eintrag:** Texte und Grafiken aus `docs/store/`.
- **Bildschirmfotos:** mindestens 2 im Hochformat (vom Handy oder die
  Vorschau-Bilder aus der Entwicklung).
- **Inhaltseinstufung:** Fragebogen – keine Gewalt, kein Glücksspiel, keine
  Nutzerinhalte (Gruppen sind in der Store-Ausgabe nicht enthalten).
- **Zielgruppe:** ab 18 (Motorradfahrer).
- **Datensicherheit** (Data safety):
  - Standort (genau): *erhoben*, nicht geteilt mit Dritten zu Werbezwecken;
    Zweck: App-Funktionen. Wird an Routing-/Kartendienste übertragen, um die
    Funktion zu erbringen.
  - Keine Konten, keine Werbung, keine Analyse.
  - Absturzberichte: nur vom Nutzer selbst verschickt.
  - Daten werden verschlüsselt übertragen (HTTPS).
  - Löschung: Daten liegen auf dem Gerät, Deinstallation löscht alles.
- **Berechtigungen:** Standort im Vordergrunddienst (Navigation/Aufzeichnung)
  – kein Hintergrund-Standort nötig. Für den Vordergrunddienst mit
  Standort verlangt Google ein kurzes Video, das die Aufzeichnung zeigt.
- **Werbung:** nein. **App-Zugriff:** ohne Anmeldung nutzbar.

## 7. Veröffentlichen

1. Geschlossener Test → AAB hochladen → Tester einladen (Liste mit E-Mails).
2. 14 Tage mit mindestens 12 Testern laufen lassen.
3. Produktions-Zugang beantragen → Veröffentlichen.
