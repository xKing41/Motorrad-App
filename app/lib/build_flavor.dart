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
