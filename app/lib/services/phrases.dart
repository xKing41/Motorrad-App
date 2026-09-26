import '../models/route_plan.dart';

// ---------------------------------------------------------------------------
//  ANSAGETEXTE
//
//  Frueher kamen die Saetze wortwoertlich vom Routing-Server: "Biegen Sie
//  rechts ab auf die Schwerter Strasse/L 674. Dann weiter auf L 674." -
//  lang, foermlich, und im Helm schwer zu verstehen. Gute Navis sagen
//  kurz, was zu tun ist:
//
//     "In 400 Metern rechts auf die B 54."   (Vorwarnung)
//     "Jetzt rechts."                         (an der Abbiegung)
//
//  Manoever, bei denen man nichts tun muss (Strasse wechselt den Namen,
//  geradeaus weiter, Kreisel verlassen), werden gar nicht angesagt.
// ---------------------------------------------------------------------------

class Phrases {
  /// Manoever ohne Ansage - man faehrt einfach weiter.
  static bool silent(int type) => const {
        ManeuverType.none,
        ManeuverType.becomes,
        ManeuverType.straight,
        ManeuverType.stayStraight,
        ManeuverType.merge,
        ManeuverType.roundaboutExit,
      }.contains(type);

  static const _ordinal = [
    'erste', 'zweite', 'dritte', 'vierte', 'fünfte', 'sechste', 'siebte',
    'achte',
  ];

  /// Kurzform: "rechts", "Ausfahrt rechts", "im Kreisverkehr die zweite
  /// Ausfahrt" ... null = nicht ansagen.
  static String? action(RouteStep s) {
    switch (s.type) {
      case ManeuverType.right:
        return 'rechts';
      case ManeuverType.slightRight:
        return 'halb rechts';
      case ManeuverType.sharpRight:
        return 'scharf rechts';
      case ManeuverType.left:
        return 'links';
      case ManeuverType.slightLeft:
        return 'halb links';
      case ManeuverType.sharpLeft:
        return 'scharf links';
      case ManeuverType.uturnLeft:
      case ManeuverType.uturnRight:
        return 'wenden';
      case ManeuverType.rampRight:
        return 'rechts auffahren';
      case ManeuverType.rampLeft:
        return 'links auffahren';
      case ManeuverType.exitRight:
        return 'Ausfahrt rechts';
      case ManeuverType.exitLeft:
        return 'Ausfahrt links';
      case ManeuverType.stayRight:
        return 'rechts halten';
      case ManeuverType.stayLeft:
        return 'links halten';
      case ManeuverType.roundaboutEnter:
        final n = s.exitCount;
        return n != null && n >= 1 && n <= _ordinal.length
            ? 'im Kreisverkehr die ${_ordinal[n - 1]} Ausfahrt'
            : 'in den Kreisverkehr';
      case ManeuverType.ferry:
        return 'auf die Fähre';
      default:
        return null;
    }
  }

  static bool _isTurn(int t) =>
      t >= ManeuverType.slightRight && t <= ManeuverType.slightLeft &&
      t != ManeuverType.uturnLeft && t != ManeuverType.uturnRight;

  /// " auf die B 54" - nur bei Abbiegungen und kurzen, sprechbaren Namen.
  static String streetPart(RouteStep s) {
    final st = s.street;
    if (st == null || !_isTurn(s.type)) return '';
    final clean = st.split('/').first.trim();
    if (clean.isEmpty || clean.length > 28) return '';
    // Strassennummern: "B 54", "L674" -> "auf die B 54"; Namen mit
    // Artikel: "auf die Schwerter Straße" / "auf den Hellweg".
    final isRef = RegExp(r'^[ABLKS] ?\d').hasMatch(clean);
    final lower = clean.toLowerCase();
    final article = isRef ||
            lower.endsWith('straße') ||
            lower.endsWith('strasse') ||
            lower.endsWith('allee') ||
            lower.endsWith('chaussee') ||
            lower.endsWith('gasse')
        ? 'die'
        : (lower.endsWith('weg') || lower.endsWith('ring') || lower.endsWith('damm')
            ? 'den'
            : null);
    if (article == null) return '';
    return ' auf $article ${_spokenRef(clean)}';
  }

  /// "L674" -> "L 674", damit die Sprachausgabe es richtig liest.
  static String _spokenRef(String s) =>
      s.replaceAllMapped(RegExp(r'^([ABLKS])(\d)'), (m) => '${m[1]} ${m[2]}');

  /// Vorwarnung: "In 400 Metern rechts auf die B 54."
  static String? pre(RouteStep s, String spokenDistance,
      {bool withStreet = true, String? lane}) {
    final a = action(s);
    if (a == null) return null;
    final street = withStreet ? streetPart(s) : '';
    final l = lane != null ? ', $lane' : '';
    return 'In $spokenDistance $a$street$l.';
  }

  /// Direkt an der Abbiegung: "Jetzt rechts." - optional mit dem, was
  /// gleich danach kommt.
  static String? now(RouteStep s, {RouteStep? then}) {
    final a = action(s);
    if (a == null) {
      if (ManeuverType.isDestination(s.type)) return 'Ziel erreicht.';
      return null;
    }
    final first = switch (s.type) {
      ManeuverType.uturnLeft || ManeuverType.uturnRight => 'Bitte wenden.',
      ManeuverType.roundaboutEnter => '${_cap(a)}.',
      ManeuverType.stayLeft || ManeuverType.stayRight => '${_cap(a)}.',
      _ => 'Jetzt $a.',
    };
    final t = then == null ? null : action(then);
    return t == null ? first : '$first Danach gleich $t.';
  }

  static String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// "die rechte Spur" -> "rechte Spur", "die beiden linken Spuren" ->
  /// "beide linken Spuren" (angehaengt an die Vorwarnung).
  static String laneHint(String spoken) => spoken
      .replaceFirst(RegExp('^die '), '')
      .replaceFirst(RegExp('^beiden'), 'beide');
}
