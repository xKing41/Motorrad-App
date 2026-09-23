import 'package:shared_preferences/shared_preferences.dart';

import 'routing_engine.dart';
import 'fuel_prices.dart';
import 'speed_limits.dart';
import 'traffic_service.dart';
import 'traffic_sources.dart';

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
    this.hereKey = '',
    this.voice = true,
    this.showLimits = true,
    this.speedWarn = false,
    this.showCameras = false,
    this.curveWarn = true,
    this.tankerKey = '',
    this.fuelType = FuelType.e5,
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

  /// Tempolimit bei der Navigation anzeigen.
  final bool showLimits;

  /// Bei zu hohem Tempo einmal ansagen.
  final bool speedWarn;

  /// Schluessel fuer Tankerkoenig (Spritpreise, Deutschland). Leer =
  /// ohne Preise.
  final String tankerKey;

  /// Getankte Sorte - dieser Preis wird angezeigt.
  final FuelType fuelType;

  FuelPrices? fuelPrices() =>
      tankerKey.trim().isEmpty ? null : FuelPrices(tankerKey.trim());

  /// Vor engen Kurven warnen, wenn man zu schnell darauf zufaehrt.
  final bool curveWarn;

  /// Feste Blitzer bei der Planung zeigen (waehrend der Fahrt nie).
  final bool showCameras;

  /// Quelle fuer die Tempolimits (derselbe Valhalla-Server wie fuers
  /// Routing, falls ein eigener eingetragen ist).
  SpeedLimitSource? limitSource() {
    if (!showLimits) return null;
    final base = ValhallaEngine.normalizeUrl(valhallaUrl);
    return base == ValhallaEngine.publicUrl
        ? ValhallaSpeedLimits.instance
        : ValhallaSpeedLimits.forBase(base);
  }

  /// Schluessel fuer HERE Traffic (optional, zweite Quelle).
  final String hereKey;

  /// Profi-Verkehrsdaten mit Schluessel eingerichtet?
  bool get hasProTraffic =>
      tomtomKey.trim().isNotEmpty || hereKey.trim().isNotEmpty;

  /// Alle eingerichteten Verkehrsquellen. Die amtlichen Meldungen der
  /// Autobahn GmbH sind immer dabei - kostenlos, ohne Schluessel.
  TrafficFeed trafficFeed() => TrafficHub([
        if (tomtomKey.trim().isNotEmpty) TrafficService(tomtomKey.trim()),
        if (hereKey.trim().isNotEmpty) HereTraffic(hereKey.trim()),
        AutobahnTraffic(),
      ]);

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
    String? hereKey,
    bool? voice,
    bool? showLimits,
    bool? speedWarn,
    bool? showCameras,
    bool? curveWarn,
    String? tankerKey,
    FuelType? fuelType,
  }) =>
      RoutingSettings(
        service: service ?? this.service,
        valhallaUrl: valhallaUrl ?? this.valhallaUrl,
        ghUrl: ghUrl ?? this.ghUrl,
        ghKey: ghKey ?? this.ghKey,
        tomtomKey: tomtomKey ?? this.tomtomKey,
        hereKey: hereKey ?? this.hereKey,
        voice: voice ?? this.voice,
        showLimits: showLimits ?? this.showLimits,
        speedWarn: speedWarn ?? this.speedWarn,
        showCameras: showCameras ?? this.showCameras,
        curveWarn: curveWarn ?? this.curveWarn,
        tankerKey: tankerKey ?? this.tankerKey,
        fuelType: fuelType ?? this.fuelType,
      );

  static const _kService = 'routing_service';
  static const _kValhalla = 'valhalla_url';
  // Schluesselnamen aus Version 3/4 - bewusst beibehalten, damit ein
  // bereits eingetragener GraphHopper-Zugang erhalten bleibt.
  static const _kGhUrl = 'gh_url';
  static const _kGhKey = 'gh_key';
  static const _kTomtom = 'tomtom_key';
  static const _kHere = 'here_key';
  static const _kVoice = 'nav_voice';
  static const _kLimits = 'nav_limits';
  static const _kSpeedWarn = 'nav_speed_warn';
  static const _kCameras = 'plan_cameras';
  static const _kCurves = 'nav_curve_warn';
  static const _kTanker = 'tanker_key';
  static const _kFuelType = 'fuel_type';

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
      hereKey: sp.getString(_kHere) ?? '',
      voice: sp.getBool(_kVoice) ?? true,
      showLimits: sp.getBool(_kLimits) ?? true,
      speedWarn: sp.getBool(_kSpeedWarn) ?? false,
      showCameras: sp.getBool(_kCameras) ?? false,
      curveWarn: sp.getBool(_kCurves) ?? true,
      tankerKey: sp.getString(_kTanker) ?? '',
      fuelType: FuelTypeX.parse(sp.getString(_kFuelType)),
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kService, service.name);
    await sp.setString(_kValhalla, valhallaUrl.trim());
    await sp.setString(_kGhUrl, ghUrl.trim());
    await sp.setString(_kGhKey, ghKey.trim());
    await sp.setString(_kTomtom, tomtomKey.trim());
    await sp.setString(_kHere, hereKey.trim());
    await sp.setBool(_kVoice, voice);
    await sp.setBool(_kLimits, showLimits);
    await sp.setBool(_kSpeedWarn, speedWarn);
    await sp.setBool(_kCameras, showCameras);
    await sp.setBool(_kCurves, curveWarn);
    await sp.setString(_kTanker, tankerKey.trim());
    await sp.setString(_kFuelType, fuelType.name);
  }
}
