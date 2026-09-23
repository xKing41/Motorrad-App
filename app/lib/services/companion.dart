import 'emergency.dart';

// ---------------------------------------------------------------------------
//  BEGLEIT-SMS ("Ich bin unterwegs")
//
//  Angehoerige wollen wissen, wo man ungefaehr ist - ohne Server, ohne
//  Konto, ohne dass jemand eine App installieren muss. Die App schickt
//  dem Notfallkontakt deshalb auf Wunsch eine SMS beim Losfahren, in
//  festen Abstaenden eine Position und am Ende "Fahrt beendet". SMS
//  braucht nur Netz, keine Datenverbindung, und kostet praktisch keinen
//  Akku.
//
//  Nur mit ausdruecklicher Zustimmung (Schalter im Notfall-Bereich) und
//  nur mit der Android-Berechtigung "SMS senden".
// ---------------------------------------------------------------------------

class Companion {
  Companion(this.em, {this.send});

  final Emergency em;

  /// Versand; fuer Tests austauschbar. Standard: direkte SMS.
  final Future<bool> Function(String text)? send;

  DateTime? _startedAt;
  DateTime? _lastSent;

  bool get active => _startedAt != null;

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String link(double lat, double lon) {
    final la = lat.toStringAsFixed(5), lo = lon.toStringAsFixed(5);
    return 'https://www.openstreetmap.org/?mlat=$la&mlon=$lo#map=14/$la/$lo';
  }

  String get _who =>
      em.riderName.trim().isEmpty ? 'Ich' : em.riderName.trim();
  bool get _named => em.riderName.trim().isNotEmpty;

  String startText(DateTime now, {double? lat, double? lon, String? tour}) {
    final b = StringBuffer(
        '$_who ${_named ? 'ist' : 'bin'} um ${_clock(now)} losgefahren');
    if (tour != null && tour.trim().isNotEmpty) b.write(' (${tour.trim()})');
    b.write('.');
    if (lat != null && lon != null) b.write(' Start: ${link(lat, lon)}');
    if (em.companionEveryMin > 0) {
      b.write(' Position kommt etwa alle ${em.companionEveryMin} Minuten.');
    }
    b.write(' (Schräglage-App)');
    return b.toString();
  }

  String updateText(DateTime now, double km, {double? lat, double? lon}) {
    final b = StringBuffer('$_who unterwegs, ${_clock(now)} Uhr, '
        'bisher ${km.round()} km.');
    if (lat != null && lon != null) {
      b.write(' Position: ${link(lat, lon)}');
    } else {
      b.write(' Gerade kein GPS.');
    }
    b.write(' (Schräglage-App)');
    return b.toString();
  }

  String endText(DateTime now, double km) =>
      '$_who ${_named ? 'hat' : 'habe'} die Fahrt um ${_clock(now)} beendet'
      ' - ${km.round()} km. (Schräglage-App)';

  bool get _enabled => em.companion && em.hasContact;

  Future<bool> _send(String text) async {
    final f = send;
    if (f != null) return f(text);
    return em.sendText(text);
  }

  /// Fahrt beginnt.
  Future<void> rideStarted(DateTime now,
      {double? lat, double? lon, String? tour}) async {
    if (!_enabled) return;
    _startedAt = now;
    _lastSent = now;
    await _send(startText(now, lat: lat, lon: lon, tour: tour));
  }

  /// Regelmaessig aufrufen (z. B. jede Minute).
  Future<void> tick(DateTime now, double km, {double? lat, double? lon}) async {
    if (!_enabled || _startedAt == null || em.companionEveryMin <= 0) return;
    final last = _lastSent ?? _startedAt!;
    if (now.difference(last).inMinutes < em.companionEveryMin) return;
    _lastSent = now;
    await _send(updateText(now, km, lat: lat, lon: lon));
  }

  /// Fahrt beendet.
  Future<void> rideEnded(DateTime now, double km) async {
    final was = _startedAt != null;
    _startedAt = null;
    _lastSent = null;
    if (!_enabled || !was) return;
    await _send(endText(now, km));
  }
}
