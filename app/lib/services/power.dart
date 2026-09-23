import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'telemetry.dart';

/// Bildschirm und Android-Energieeinstellungen.
///
/// Vorher blieb der Bildschirm IMMER an, solange die App offen war - auch
/// beim Planen auf dem Sofa. Jetzt nur noch waehrend einer Fahrt oder
/// Navigation (und bei Fahrt nur, wenn der Fahrer das will). Die
/// Aufzeichnung laeuft bei ausgeschaltetem Bildschirm trotzdem weiter.
class PowerPolicy {
  PowerPolicy._();
  static final PowerPolicy instance = PowerPolicy._();

  static const _system = MethodChannel('schraeglage/system');
  static const _kScreen = 'screen_on_ride';
  static const _kAsked = 'bg_setup_asked';

  final _t = Telemetry.instance;

  /// Bildschirm waehrend einer Fahrt anlassen (Cockpit sichtbar).
  /// Bei Navigation bleibt er immer an.
  final ValueNotifier<bool> screenOnWhileRiding = ValueNotifier(true);

  bool? _wakeOn;

  Future<void> init() async {
    try {
      final sp = await SharedPreferences.getInstance();
      screenOnWhileRiding.value = sp.getBool(_kScreen) ?? true;
    } catch (_) {}
    _t.addListener(_update);
    screenOnWhileRiding.addListener(_update);
    _update();
  }

  Future<void> setScreenOnWhileRiding(bool v) async {
    screenOnWhileRiding.value = v;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kScreen, v);
    } catch (_) {}
  }

  /// Soll der Bildschirm an bleiben?
  static bool wantScreenOn({
    required bool foreground,
    required bool navigating,
    required bool recording,
    required bool screenOnWhileRiding,
  }) =>
      foreground && (navigating || (recording && screenOnWhileRiding));

  void _update() {
    final want = wantScreenOn(
      foreground: _t.foreground,
      navigating: _t.navigating,
      recording: _t.recording,
      screenOnWhileRiding: screenOnWhileRiding.value,
    );
    if (want == _wakeOn) return;
    _wakeOn = want;
    try {
      want ? WakelockPlus.enable() : WakelockPlus.disable();
    } catch (_) {}
  }

  /// Einmal vor der ersten Fahrt: Benachrichtigungen erlauben (fuer die
  /// Anzeige "Fahrt laeuft"). Rueckgabe true, wenn noch nach der
  /// Akku-Optimierung gefragt werden sollte.
  Future<bool> prepareFirstRide() async {
    try {
      await _system.invokeMethod<bool>('requestNotifications');
      final sp = await SharedPreferences.getInstance();
      if (sp.getBool(_kAsked) ?? false) return false;
      await sp.setBool(_kAsked, true);
      final ignoring =
          await _system.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return ignoring == false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openBatterySettings() async {
    try {
      await _system.invokeMethod<bool>('openBatterySettings');
    } catch (_) {}
  }
}
