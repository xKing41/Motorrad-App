
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/services/group_ride.dart';
import 'package:schraeglage/services/headset.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'group_ride_test.dart' show Bus, MemTransport;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Status und Hersteller aus dem Geraetenamen', () {
    final s = HeadsetStatus.fromMap({
      'connected': true,
      'name': 'PACKTALK EDGE',
      'battery': 15,
      'micPermission': true,
      'btPermission': true,
    });
    expect(s.brand, 'Cardo');
    expect(s.label, 'PACKTALK EDGE · 15 %');
    expect(s.batteryLow, isTrue);
    expect(HeadsetStatus.fromMap({'connected': true, 'name': 'SENA 50S', 'battery': -1}).brand,
        'Sena');
    expect(const HeadsetStatus().label, 'Kein Headset');
    expect(HeadsetStatus.fromMap(null).connected, isFalse);
  });

  test('Tasten und Geraetewechsel kommen von Android an', () async {
    SharedPreferences.setMockInitialValues({});
    const ch = MethodChannel('schraeglage/headset');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ch, (call) async {
      if (call.method == 'status') {
        return {'connected': false, 'name': '', 'battery': -1};
      }
      return true;
    });
    final h = Headset.forTest(ch);
    await h.init();
    final got = <HeadsetButton>[];
    final sub = h.buttons.listen(got.add);
    Future<void> send(String method, Object? args) =>
        messenger.handlePlatformMessage(
            ch.name,
            const StandardMethodCodec()
                .encodeMethodCall(MethodCall(method, args)),
            (_) {});
    await send('button', 'next');
    await send('button', 'playpause');
    await send('changed', {'connected': true, 'name': 'SENA 50S', 'battery': 80});
    await Future<void>.delayed(Duration.zero);
    expect(got, [HeadsetButton.next, HeadsetButton.playPause]);
    expect(h.status.name, 'SENA 50S');
    expect(h.status.battery, 80);
    await sub.cancel();
    messenger.setMockMethodCallHandler(ch, null);
  });

  test('Sprachnachricht an die Gruppe, zu grosse abgelehnt', () async {
    final bus = Bus();
    final a = GroupSession(
        transport: MemTransport(bus), code: 'ABCDE-FGHJK', myId: 'a', myName: 'Faruk');
    final b = GroupSession(
        transport: MemTransport(bus), code: 'ABCDE-FGHJK', myId: 'b', myName: 'Tim');
    await a.start();
    await b.start();
    final got = <GroupVoice>[];
    final sub = b.voiceIn.listen(got.add);
    final audio = Uint8List.fromList(List.generate(3000, (i) => i % 256));
    expect(await a.sendVoice(audio, const Duration(seconds: 4)), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(got.single.from, 'Faruk');
    expect(got.single.audio, audio);
    expect(got.single.duration, const Duration(seconds: 4));
    expect(b.voices.length, 1);
    // Eigene Nachricht wird nicht zurueck abgespielt.
    expect(a.voices, isEmpty);
    expect(await a.sendVoice(Uint8List(GroupSession.maxVoiceBytes + 1),
        const Duration(seconds: 30)), isFalse);
    await sub.cancel();
  });
}
