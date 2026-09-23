import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:schraeglage/services/power.dart';
import 'package:schraeglage/services/telemetry.dart';

void main() {
  test('GPS: Fahrt voll, App offen sparsam, Hintergrund aus', () {
    expect(Telemetry.gpsModeFor(active: true, foreground: false), GpsMode.ride);
    expect(Telemetry.gpsModeFor(active: true, foreground: true), GpsMode.ride);
    expect(Telemetry.gpsModeFor(active: false, foreground: true), GpsMode.idle);
    expect(Telemetry.gpsModeFor(active: false, foreground: false), GpsMode.off);
  });

  test('nur bei Fahrt laeuft der Vordergrunddienst', () {
    final ride = Telemetry.settingsFor(GpsMode.ride) as AndroidSettings;
    expect(ride.foregroundNotificationConfig, isNotNull);
    expect(ride.foregroundNotificationConfig!.enableWakeLock, isTrue);
    final idle = Telemetry.settingsFor(GpsMode.idle) as AndroidSettings;
    expect(idle.foregroundNotificationConfig, isNull);
    expect(idle.distanceFilter, greaterThan(0));
  });

  test('Bildschirm: nur bei Fahrt/Navigation und nur im Vordergrund', () {
    bool on(bool fg, bool nav, bool rec, bool pref) => PowerPolicy.wantScreenOn(
        foreground: fg, navigating: nav, recording: rec, screenOnWhileRiding: pref);
    expect(on(true, false, false, true), isFalse); // Planen: normal
    expect(on(true, false, true, true), isTrue); // Fahrt, Cockpit an
    expect(on(true, false, true, false), isFalse); // Fahrt, Akku sparen
    expect(on(true, true, true, false), isTrue); // Navigation: immer an
    expect(on(false, true, true, true), isFalse); // Hintergrund
  });
}
