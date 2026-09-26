import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/phrases.dart';
import 'package:schraeglage/services/routing_engine.dart';
import 'package:schraeglage/services/voice.dart';

RouteStep step(int type, {String? street, int? exit}) => RouteStep(
    text: 'x', distanceM: 0, pointIndex: 1, type: type, street: street, exitCount: exit);

void main() {
  test('kurze Vorwarnung mit Strasse', () {
    expect(Phrases.pre(step(ManeuverType.right, street: 'B54'), '400 Metern'),
        'In 400 Metern rechts auf die B 54.');
    expect(Phrases.pre(step(ManeuverType.left, street: 'Schwerter Straße/L 674'),
            '200 Metern'),
        'In 200 Metern links auf die Schwerter Straße.');
    expect(Phrases.pre(step(ManeuverType.slightRight, street: 'Hellweg'),
            '600 Metern'),
        'In 600 Metern halb rechts auf den Hellweg.');
    // Unbekannter Artikel: lieber ohne Strasse als falsches Deutsch.
    expect(Phrases.pre(step(ManeuverType.right, street: 'Am Markt'), '200 Metern'),
        'In 200 Metern rechts.');
    // Strasse nur bei der ersten Vorwarnung.
    expect(
        Phrases.pre(step(ManeuverType.right, street: 'B54'), '200 Metern',
            withStreet: false),
        'In 200 Metern rechts.');
  });

  test('Ausfahrt mit Spur, Kreisverkehr, direkt davor', () {
    expect(Phrases.pre(step(ManeuverType.exitRight), '500 Metern',
            lane: Phrases.laneHint('die rechte Spur')),
        'In 500 Metern Ausfahrt rechts, rechte Spur.');
    expect(Phrases.laneHint('die beiden linken Spuren'), 'beide linken Spuren');
    expect(Phrases.now(step(ManeuverType.roundaboutEnter, exit: 2)),
        'Im Kreisverkehr die zweite Ausfahrt.');
    expect(Phrases.now(step(ManeuverType.right)), 'Jetzt rechts.');
    expect(Phrases.now(step(ManeuverType.right), then: step(ManeuverType.left)),
        'Jetzt rechts. Danach gleich links.');
    expect(Phrases.now(step(ManeuverType.uturnLeft)), 'Bitte wenden.');
    expect(Phrases.now(step(ManeuverType.destination)), 'Ziel erreicht.');
  });

  test('nichts zu tun: keine Ansage', () {
    for (final t in [
      ManeuverType.becomes,
      ManeuverType.straight,
      ManeuverType.stayStraight,
      ManeuverType.roundaboutExit,
      ManeuverType.merge,
    ]) {
      expect(Phrases.silent(t), isTrue, reason: '$t');
    }
    expect(Phrases.silent(ManeuverType.right), isFalse);
  });

  test('Strassenname aus der Valhalla-Antwort: Nummer vor Name', () {
    expect(ValhallaEngine.firstName(['Schwerter Straße', 'L 674']), 'L 674');
    expect(ValhallaEngine.firstName(['Hauptstraße']), 'Hauptstraße');
    expect(ValhallaEngine.firstName(null), isNull);
  });

  test('Sprachausgabe: natuerlicher lesen, beste Stimme waehlen', () {
    expect(speakable('Weiter auf B54, noch 12 km, etwa 5 min.'),
        'Weiter auf B 54, noch 12 Kilometer, etwa 5 Minuten.');
    expect(speakable('mindestens'), 'mindestens');
    final v = bestVoice([
      const TtsVoice('de-de-x-a-network', 'de-DE', quality: 'very high', network: true),
      const TtsVoice('de-de-x-b-local', 'de-DE', quality: 'very high'),
      const TtsVoice('de-de-x-c-local', 'de-DE', quality: 'normal'),
      const TtsVoice('en-us-x-local', 'en-US', quality: 'very high'),
      const TtsVoice('de-de-x-d-local', 'de-DE', quality: 'very high', installed: false),
    ]);
    expect(v!.name, 'de-de-x-b-local'); // beste, die offline geht
    expect(TtsVoice.fromMap({
      'name': 'de-de-x-nfh-local',
      'locale': 'de-DE',
      'quality': 'high',
      'network_required': '0',
      'features': '',
    })!.label(0), 'Stimme 1 · hohe Qualität · offline');
  });
}
