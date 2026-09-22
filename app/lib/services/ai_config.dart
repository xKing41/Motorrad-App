import 'package:shared_preferences/shared_preferences.dart';

import 'ai_planner.dart';

/// Auf welchem Weg die App an die KI kommt.
enum AiMode {
  /// Noch nicht verbunden.
  none,

  /// Eigener Anthropic-Schluessel, gespeichert auf DIESEM Geraet.
  /// Fuer eigene Tests gedacht.
  ownKey,

  /// Ein eigener kleiner Server haelt den Schluessel.
  /// Der Nutzer der App braucht dann selbst keinen Schluessel.
  ownServer,
}

/// Zentrale Stelle fuer die KI-Zugangsdaten.
///
/// Wichtig fuer die Bedienung: Der Zugang wird EINMAL eingerichtet und
/// bleibt danach gespeichert. Beim Planen wird nie wieder nach einem
/// Schluessel gefragt.
class AiConfig {
  const AiConfig({
    this.mode = AiMode.none,
    this.key = '',
    this.serverUrl = '',
    this.model = defaultModel,
  });

  /// Aktuelle Sonnet-Generation. Laut Anthropic-Dokumentation ist
  /// "claude-sonnet-5" der direkte Nachfolger von "claude-sonnet-4-6".
  static const String defaultModel = 'claude-sonnet-5';

  /// Guenstigere Variante. Der Modellname enthaelt das Datum - das
  /// gehoert zum Namen dazu und darf nicht weggelassen werden.
  static const String cheapModel = 'claude-haiku-4-5-20251001';

  final AiMode mode;
  final String key;
  final String serverUrl;
  final String model;

  bool get isConfigured =>
      (mode == AiMode.ownKey && key.trim().isNotEmpty) ||
      (mode == AiMode.ownServer && serverUrl.trim().isNotEmpty);

  /// Kurzer Text fuer die Anzeige, niemals der Schluessel selbst.
  String get label {
    if (mode == AiMode.ownServer) return 'Eigener Server';
    if (mode == AiMode.ownKey) return 'Eigener Schlüssel · ${modelLabel(model)}';
    return 'Nicht verbunden';
  }

  static String modelLabel(String m) {
    if (m == cheapModel) return 'Haiku 4.5';
    if (m == defaultModel) return 'Sonnet 5';
    return m;
  }

  AiConfig copyWith({
    AiMode? mode,
    String? key,
    String? serverUrl,
    String? model,
  }) =>
      AiConfig(
        mode: mode ?? this.mode,
        key: key ?? this.key,
        serverUrl: serverUrl ?? this.serverUrl,
        model: model ?? this.model,
      );

  /// Baut den passenden Planer. Nur sinnvoll, wenn [isConfigured] gilt.
  AiRoutePlanner planner() {
    if (mode == AiMode.ownServer) {
      return AiRoutePlanner(baseUrl: serverUrl.trim(), model: model);
    }
    return AiRoutePlanner(apiKey: key.trim(), model: model);
  }

  // ------------------------------------------------------------------
  // Speichern und Laden
  // ------------------------------------------------------------------
  static const String _kMode = 'ai_mode';
  static const String _kKey = 'ai_key';
  static const String _kServer = 'ai_server';
  static const String _kModel = 'ai_model';

  static Future<AiConfig> load() async {
    final sp = await SharedPreferences.getInstance();
    final key = sp.getString(_kKey) ?? '';
    final server = sp.getString(_kServer) ?? '';
    final model = sp.getString(_kModel) ?? defaultModel;
    final raw = sp.getString(_kMode);

    AiMode mode;
    if (raw == 'server') {
      mode = AiMode.ownServer;
    } else if (raw == 'key') {
      mode = AiMode.ownKey;
    } else {
      // Aeltere App-Version: dort wurde nur 'ai_key' gespeichert.
      mode = key.trim().isEmpty ? AiMode.none : AiMode.ownKey;
    }

    return AiConfig(mode: mode, key: key, serverUrl: server, model: model);
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    String raw = 'none';
    if (mode == AiMode.ownKey) raw = 'key';
    if (mode == AiMode.ownServer) raw = 'server';
    await sp.setString(_kMode, raw);
    await sp.setString(_kKey, key.trim());
    await sp.setString(_kServer, serverUrl.trim());
    await sp.setString(_kModel, model);
  }

  /// Trennt die Verbindung und loescht den Schluessel vom Geraet.
  static Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kMode);
    await sp.remove(_kKey);
    await sp.remove(_kServer);
    await sp.remove(_kModel);
  }
}
