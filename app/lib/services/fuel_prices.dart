import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/route_plan.dart';
import 'geo.dart';

// ---------------------------------------------------------------------------
//  SPRITPREISE AN DEN TANKSTOPPS (Tankerkoenig, nur Deutschland)
//
//  Die Tankstellen deutschlands melden ihre Preise an die
//  Markttransparenzstelle (MTS-K). Tankerkoenig stellt sie kostenlos
//  bereit - mit eigenem Schluessel (Anmeldung auf
//  creativecommons.tankerkoenig.de, ohne Kosten). Die App ordnet jedem
//  geplanten Tankstopp (aus OpenStreetMap) die gemeldete Tankstelle am
//  selben Ort zu und zeigt Preis und "geoeffnet".
//
//  Lizenz der Daten: CC BY 4.0 - die Quelle wird angezeigt.
// ---------------------------------------------------------------------------

enum FuelType { e5, e10, diesel }

extension FuelTypeX on FuelType {
  String get label => switch (this) {
        FuelType.e5 => 'Super E5',
        FuelType.e10 => 'Super E10',
        FuelType.diesel => 'Diesel',
      };
  String get short => switch (this) {
        FuelType.e5 => 'E5',
        FuelType.e10 => 'E10',
        FuelType.diesel => 'Diesel',
      };
  static FuelType parse(String? s) =>
      FuelType.values.firstWhere((f) => f.name == s, orElse: () => FuelType.e5);
}

class FuelStation {
  const FuelStation({
    required this.id,
    required this.name,
    required this.point,
    this.brand,
    this.isOpen,
    this.e5,
    this.e10,
    this.diesel,
  });

  final String id;
  final String name;
  final String? brand;
  final RoutePoint point;
  final bool? isOpen;
  final double? e5;
  final double? e10;
  final double? diesel;

  double? price(FuelType t) => switch (t) {
        FuelType.e5 => e5,
        FuelType.e10 => e10,
        FuelType.diesel => diesel,
      };
}

/// Preis an einem Tankstopp der Route.
class StopPrice {
  const StopPrice(this.station, this.type);
  final FuelStation station;
  final FuelType type;

  double? get price => station.price(type);

  /// "E5 1,839 €" - die dritte Stelle wie an der Zapfsaeule.
  String get text {
    final p = price;
    final s = p == null
        ? '${type.short}: kein Preis'
        : '${type.short} ${p.toStringAsFixed(3).replaceAll('.', ',')} €';
    return station.isOpen == false ? '$s · geschlossen' : s;
  }
}

class FuelPrices {
  FuelPrices(this.apiKey, {http.Client? client}) : _client = client;

  final String apiKey;
  final http.Client? _client;

  static const String attribution =
      'Spritpreise: Tankerkönig / MTS-K (CC BY 4.0)';

  /// Tankstellen im Umkreis von [radiusKm] (max. 25).
  Future<List<FuelStation>> near(double lat, double lon,
      {double radiusKm = 1.5}) async {
    final uri = Uri.parse(
        'https://creativecommons.tankerkoenig.de/json/list.php'
        '?lat=${lat.toStringAsFixed(5)}&lng=${lon.toStringAsFixed(5)}'
        '&rad=${radiusKm.toStringAsFixed(1)}&sort=dist&type=all'
        '&apikey=${Uri.encodeQueryComponent(apiKey)}');
    final c = _client;
    final res = await (c != null ? c.get(uri) : http.get(uri))
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw http.ClientException('Tankerkönig ${res.statusCode}', uri);
    }
    return parse(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  static List<FuelStation> parse(Object? data) {
    if (data is! Map || data['ok'] != true) {
      final msg = data is Map ? '${data['message'] ?? ''}' : '';
      throw FormatException(msg.isEmpty ? 'Tankerkönig: keine Daten' : msg);
    }
    double? num_(Object? v) =>
        v is num && v > 0.5 ? v.toDouble() : null; // false/0 = kein Preis
    return [
      for (final s in (data['stations'] as List? ?? const [])
          .whereType<Map<String, dynamic>>())
        if (s['lat'] is num && s['lng'] is num)
          FuelStation(
            id: '${s['id']}',
            name: '${s['name'] ?? s['brand'] ?? 'Tankstelle'}',
            brand: (s['brand'] as String?)?.trim().isEmpty == true
                ? null
                : s['brand'] as String?,
            point: RoutePoint(
                (s['lat'] as num).toDouble(), (s['lng'] as num).toDouble()),
            isOpen: s['isOpen'] as bool?,
            e5: num_(s['e5']),
            e10: num_(s['e10']),
            diesel: num_(s['diesel']),
          ),
    ];
  }

  /// Die gemeldete Tankstelle zu einem Tankstopp: die naechste
  /// innerhalb von [maxM] (OSM- und Meldeadresse liegen oft ein paar
  /// Dutzend Meter auseinander).
  static FuelStation? match(Poi stop, List<FuelStation> stations,
      {double maxM = 150}) {
    FuelStation? best;
    var bestD = maxM;
    final p = RoutePoint(stop.lat, stop.lon);
    for (final s in stations) {
      final d = dist(p, s.point);
      if (d <= bestD) {
        bestD = d;
        best = s;
      }
    }
    return best;
  }

  /// Preise fuer alle Tankstopps einer Route (eine Anfrage je Stopp).
  Future<Map<String, StopPrice>> forStops(List<Poi> pois, FuelType type) async {
    final out = <String, StopPrice>{};
    for (final p in pois) {
      if (p.kind != PoiKind.fuel) continue;
      try {
        final s = match(p, await near(p.lat, p.lon, radiusKm: 1));
        if (s != null) out[p.id] = StopPrice(s, type);
      } on FormatException {
        rethrow; // Schluessel ungueltig o. ae. - dem Nutzer sagen
      } catch (_) {
        // Netz: dieser Stopp ohne Preis
      }
    }
    return out;
  }
}
