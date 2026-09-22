import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/emergency.dart';
import '../theme.dart';

/// Vollbild-Alarm nach einem erkannten Sturz.
///
/// Bewusst so gebaut, dass ein Fehlalarm harmlos ist: Es laeuft ein
/// Countdown mit einer sehr grossen Abbruchtaste, die auch mit
/// Handschuhen und zitternden Haenden zu treffen ist. Erst danach wird
/// die Nachricht vorbereitet.
class CrashAlarmScreen extends StatefulWidget {
  const CrashAlarmScreen({
    super.key,
    required this.lat,
    required this.lon,
  });

  final double? lat;
  final double? lon;

  @override
  State<CrashAlarmScreen> createState() => _CrashAlarmScreenState();
}

class _CrashAlarmScreenState extends State<CrashAlarmScreen> {
  final em = Emergency.instance;
  late int _left;
  Timer? _timer;
  bool _fired = false;
  bool _smsOpened = false;

  @override
  void initState() {
    super.initState();
    _left = em.countdownSec.clamp(10, 120);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // Vibration und Signalton bei jeder Sekunde: Wer nur kurz
      // benommen ist, soll den Alarm auch bemerken, wenn das Handy
      // nicht im Blickfeld liegt.
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
      setState(() => _left--);
      if (_left <= 0) _fire();
    });
    HapticFeedback.heavyImpact();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fire() async {
    if (_fired) return;
    _fired = true;
    _timer?.cancel();
    final ok = await em.sendSms(lat: widget.lat, lon: widget.lon);
    if (!mounted) return;
    setState(() => _smsOpened = ok);
  }

  void _cancel() {
    _timer?.cancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Zurueck-Wischen darf den Alarm nicht unbemerkt schliessen.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF2A0A0A),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              const SizedBox(height: 10),
              const Icon(Icons.warning_amber_rounded,
                  size: 54, color: redline),
              const SizedBox(height: 10),
              const Text('STURZ ERKANNT',
                  style: TextStyle(
                      fontSize: 24,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w700,
                      color: chalk)),
              const SizedBox(height: 6),
              if (!_fired)
                Text(
                  em.hasContact
                      ? 'Nachricht an ${em.contactName.isEmpty ? "den Notfallkontakt" : em.contactName} wird vorbereitet'
                      : 'Kein Notfallkontakt hinterlegt',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: chalk),
                )
              else
                Text(
                  _smsOpened
                      ? 'Die SMS-App wurde geöffnet. Nachricht dort absenden.'
                      : (em.hasContact
                          ? 'SMS-App ließ sich nicht öffnen. Bitte 112 anrufen.'
                          : 'Kein Notfallkontakt hinterlegt – bitte 112 anrufen.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12, color: _smsOpened ? amber : redline),
                ),
              const Spacer(),
              if (!_fired)
                Text('$_left',
                    style: const TextStyle(
                        fontSize: 96,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: redline)),
              const Spacer(),
              // Sehr grosse Flaeche: mit Handschuhen bedienbar.
              SizedBox(
                width: double.infinity,
                height: 90,
                child: ElevatedButton(
                  onPressed: _cancel,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: chalk,
                    foregroundColor: asphalt,
                    shape: const RoundedRectangleBorder(),
                  ),
                  child: const Text('MIR GEHT ES GUT',
                      style: TextStyle(
                          fontSize: 20,
                          letterSpacing: 3,
                          fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 58,
                    child: OutlinedButton(
                      onPressed: () => em.callEmergencyNumber(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: redline,
                        side: const BorderSide(color: redline, width: 1.5),
                        shape: const RoundedRectangleBorder(),
                      ),
                      child: const Text('112 ANRUFEN',
                          style: TextStyle(
                              fontSize: 14,
                              letterSpacing: 2,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 58,
                    child: OutlinedButton(
                      onPressed: _fired ? null : _fire,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: amber,
                        side: const BorderSide(color: amber),
                        shape: const RoundedRectangleBorder(),
                      ),
                      child: const Text('JETZT SENDEN',
                          style: TextStyle(
                              fontSize: 14,
                              letterSpacing: 2,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              const Text(
                'Diese Erkennung ist eine Hilfe, kein zugelassenes '
                'Notrufsystem. Bei einem echten Notfall immer selbst 112 '
                'rufen, wenn es möglich ist.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9.5, color: steel, height: 1.4),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
