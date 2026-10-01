/// Welche Ausgabe der App gerade laeuft.
///
/// * Normale App ("Schräglage"): das, was Kunden und Kollegen auf dem
///   Handy haben.
/// * Test-App ("Schräglage Testing"): zusaetzlich Werkzeuge zum
///   Ausprobieren (Probefahrt-Simulation ...). Eigene App-Kennung - sie
///   liegt NEBEN der normalen App auf dem Handy, mit eigenen Daten, und
///   kann nichts an den echten Fahrten veraendern.
///
/// Umgeschaltet wird beim Bauen:
///   flutter build apk --dart-define=SCHRAEGLAGE_TEST=true
const bool kTestBuild = bool.fromEnvironment('SCHRAEGLAGE_TEST');

/// Anzeigename der laufenden Ausgabe.
const String kAppName = kTestBuild ? 'Schräglage Testing' : 'Schräglage';

/// Versionsnummer (gleich wie in pubspec.yaml - wird zusammen gepflegt).
/// Steht in Fehlerberichten, damit klar ist, welcher Stand gemeint ist.
const String kAppVersion = '4.36.0';

/// Ausgabe fuer den Google Play Store (App-Bundle): ohne die Berechtigung
/// "SMS senden" - die erlaubt Google nur mit Sondergenehmigung. Die
/// Notfall-SMS oeffnet dort die SMS-App mit fertigem Text.
///   flutter build appbundle --dart-define=SCHRAEGLAGE_STORE=true
const bool kStoreBuild = bool.fromEnvironment('SCHRAEGLAGE_STORE');
