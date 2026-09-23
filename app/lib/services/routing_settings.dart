import 'package:shared_preferences/shared_preferences.dart';

import 'routing_engine.dart';

/// Welcher Dienst die Routen berechnet.
enum RoutingService {
  /// Valhalla - Standard, ohne Schluessel. Oeffentlicher FOSSGIS-Server
  /// oder ein eigener Valhalla-Server.
  valhalla,

  /// GraphHopper - offizielle API mit Schluessel oder eigener Server.
  graphhopper,
}

/// Gespeicherte Einstellungen zur Routenberechnung.
class RoutingSettings {
  const RoutingSettings({
    this.service = RoutingService.valhalla,
    this.valhallaUrl = '',
    this.ghUrl = '',
    this.ghKey = '',
    this.tomtomKey = '',
    this.voice = true,
  });

  final RoutingService service;

  /// Leer = oeffentlicher FOSSGIS-Server.
  final String valhallaUrl;
  final String ghUrl;
  final String ghKey;

  /// Schluessel fuer die TomTom-Verkehrslage (leer = ohne Verkehrslage).
  final String tomtomKey;

  /// Sprachansagen bei der Navigation.
  final bool voice;

  bool get hasTraffic => tomtomKey.trim().isNotEmpty;

  /// Ist die Auswahl vollstaendig? GraphHopper braucht eine Adresse.
  bool get isUsable =>
      service == RoutingService.valhalla || ghUrl.trim().isNotEmpty;

  RoutingEngine engine() {
    if (service == RoutingService.graphhopper && ghUrl.trim().isNotEmpty) {
      return GraphHopperEngine(
        baseUrl: ghUrl.trim(),
        apiKey: ghKey.trim().isEmpty ? null : ghKey.trim(),
      );
    }
    return ValhallaEngine(baseUrl: valhallaUrl);
  }

  RoutingSettings copyWith({
    RoutingService? service,
    String? valhallaUrl,
    String? ghUrl,
    String? ghKey,
    String? tomtomKey,
    bool? voice,
  }) =>
      RoutingSettings(
        service: service ?? this.service,
        valhallaUrl: valhallaUrl ?? this.valhallaUrl,
        ghUrl: ghUrl ?? this.ghUrl,
        ghKey: ghKey ?? this.ghKey,
        tomtomKey: tomtomKey ?? this.tomtomKey,
        voice: voice ?? this.voice,
      );

  static const _kService = 'routing_service';
  static const _kValhalla = 'valhalla_url';
  // Schluesselnamen aus Version 3/4 - bewusst beibehalten, damit ein
  // bereits eingetragener GraphHopper-Zugang erhalten bleibt.
  static const _kGhUrl = 'gh_url';
  static const _kGhKey = 'gh_key';
  static const _kTomtom = 'tomtom_key';
  static const _kVoice = 'nav_voice';

  static Future<RoutingSettings> load() async {
    final sp = await SharedPreferences.getInstance();
    final ghUrl = sp.getString(_kGhUrl) ?? '';
    final raw = sp.getString(_kService);
    final RoutingService service;
    if (raw == 'graphhopper') {
      service = RoutingService.graphhopper;
    } else if (raw == 'valhalla') {
      service = RoutingService.valhalla;
    } else {
      // Aeltere Version: Wer dort GraphHopper eingetragen hatte, behaelt es.
      service = ghUrl.trim().isNotEmpty
          ? RoutingService.graphhopper
          : RoutingService.valhalla;
    }
    return RoutingSettings(
      service: service,
      valhallaUrl: sp.getString(_kValhalla) ?? '',
      ghUrl: ghUrl,
      ghKey: sp.getString(_kGhKey) ?? '',
      tomtomKey: sp.getString(_kTomtom) ?? '',
      voice: sp.getBool(_kVoice) ?? true,
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kService, service.name);
    await sp.setString(_kValhalla, valhallaUrl.trim());
    await sp.setString(_kGhUrl, ghUrl.trim());
    await sp.setString(_kGhKey, ghKey.trim());
    await sp.setString(_kTomtom, tomtomKey.trim());
    await sp.setBool(_kVoice, voice);
  }
}
