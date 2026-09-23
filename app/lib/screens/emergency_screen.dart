import 'package:flutter/material.dart';

import '../services/emergency.dart';
import '../theme.dart';

/// Notfalldaten einrichten und ansehen.
///
/// Der obere Teil ist die Karte, die im Ernstfall ein Helfer sieht -
/// deshalb gross, kontrastreich und ohne Fachbegriffe.
class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({super.key});

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen> {
  final em = Emergency.instance;

  late final TextEditingController _cName;
  late final TextEditingController _cPhone;
  late final TextEditingController _rider;
  late final TextEditingController _blood;
  late final TextEditingController _medical;
  late final TextEditingController _insurance;

  @override
  void initState() {
    super.initState();
    _cName = TextEditingController(text: em.contactName);
    _cPhone = TextEditingController(text: em.contactPhone);
    _rider = TextEditingController(text: em.riderName);
    _blood = TextEditingController(text: em.bloodGroup);
    _medical = TextEditingController(text: em.medical);
    _insurance = TextEditingController(text: em.insurance);
  }

  @override
  void dispose() {
    // Eingaben nicht verlieren, wenn ohne SPEICHERN zurueckgegangen wird.
    final changed = em.contactName != _cName.text ||
        em.contactPhone != _cPhone.text ||
        em.riderName != _rider.text ||
        em.bloodGroup != _blood.text ||
        em.medical != _medical.text ||
        em.insurance != _insurance.text;
    if (changed) {
      em.contactName = _cName.text;
      em.contactPhone = _cPhone.text;
      em.riderName = _rider.text;
      em.bloodGroup = _blood.text;
      em.medical = _medical.text;
      em.insurance = _insurance.text;
      em.save();
    }
    _cName.dispose();
    _cPhone.dispose();
    _rider.dispose();
    _blood.dispose();
    _medical.dispose();
    _insurance.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    em.contactName = _cName.text;
    em.contactPhone = _cPhone.text;
    em.riderName = _rider.text;
    em.bloodGroup = _blood.text;
    em.medical = _medical.text;
    em.insurance = _insurance.text;
    await em.save();
    if (!mounted) return;
    toast(context, 'Notfalldaten gespeichert');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NOTFALL')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _iceCard(),
          const SizedBox(height: 20),
          const TinyLabel('NOTFALLKONTAKT'),
          const SizedBox(height: 8),
          _field('Name', _cName, hint: 'z. B. Anna'),
          const SizedBox(height: 8),
          _field('Telefonnummer', _cPhone,
              hint: '+49 ...', keyboard: TextInputType.phone),
          const SizedBox(height: 18),
          const TinyLabel('ANGABEN FÜR HELFER'),
          const SizedBox(height: 8),
          _field('Eigener Name', _rider),
          const SizedBox(height: 8),
          _field('Blutgruppe', _blood, hint: 'z. B. 0 Rh+'),
          const SizedBox(height: 8),
          _field('Allergien, Medikamente, Vorerkrankungen', _medical,
              lines: 3),
          const SizedBox(height: 8),
          _field('Versicherung', _insurance),
          const SizedBox(height: 18),
          const TinyLabel('STURZERKENNUNG'),
          const SizedBox(height: 8),
          _toggle(),
          const SizedBox(height: 10),
          _countdownRow(),
          const SizedBox(height: 10),
          _autoSendToggle(),
          const SizedBox(height: 18),
          const TinyLabel('BEGLEIT-SMS (ICH BIN UNTERWEGS)'),
          const SizedBox(height: 8),
          _companionToggle(),
          if (em.companion) ...[
            const SizedBox(height: 10),
            _companionInterval(),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FlatButton2(
              label: 'SPEICHERN',
              color: signal,
              strong: true,
              onTap: _save,
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: FlatButton2(
                label: 'TEST-SMS VORBEREITEN',
                onTap: em.hasContact
                    ? () => em.sendSms(lat: null, lon: null, test: true)
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FlatButton2(
                label: 'KONTAKT ANRUFEN',
                onTap: em.hasContact ? () => em.callContact() : null,
              ),
            ),
          ]),
          const SizedBox(height: 18),
          _explainer(),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------
  Widget _iceCard() {
    final name = em.riderName.trim();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: panel,
        border: Border.all(color: redline, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.medical_services_outlined, size: 16, color: redline),
            SizedBox(width: 8),
            Text('IM NOTFALL',
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 3,
                    fontWeight: FontWeight.w700,
                    color: redline)),
          ]),
          const SizedBox(height: 10),
          _iceRow('Fahrer', name.isEmpty ? 'nicht angegeben' : name),
          _iceRow('Blutgruppe',
              em.bloodGroup.trim().isEmpty ? 'nicht angegeben' : em.bloodGroup),
          _iceRow('Medizinisch',
              em.medical.trim().isEmpty ? 'keine Angaben' : em.medical),
          _iceRow('Versicherung',
              em.insurance.trim().isEmpty ? 'nicht angegeben' : em.insurance),
          _iceRow(
              'Kontakt',
              em.hasContact
                  ? '${em.contactName.trim().isEmpty ? "Notfallkontakt" : em.contactName.trim()} · ${em.contactPhone.trim()}'
                  : 'nicht angegeben'),
        ],
      ),
    );
  }

  Widget _iceRow(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 96,
            child: Text(k,
                style: const TextStyle(fontSize: 10.5, color: steel)),
          ),
          Expanded(
            child: Text(v,
                style: const TextStyle(
                    fontSize: 12, color: chalk, height: 1.35)),
          ),
        ]),
      );

  Widget _field(
    String label,
    TextEditingController c, {
    String? hint,
    int lines = 1,
    TextInputType? keyboard,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: steel)),
        const SizedBox(height: 4),
        TextField(
          controller: c,
          maxLines: lines,
          keyboardType: keyboard,
          style: const TextStyle(fontSize: 12.5, color: chalk),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 11, color: steel),
            isDense: true,
            filled: true,
            fillColor: asphalt,
            contentPadding: const EdgeInsets.all(11),
            border: _b(line),
            enabledBorder: _b(line),
            focusedBorder: _b(signal),
          ),
        ),
      ],
    );
  }

  OutlineInputBorder _b(Color c) => OutlineInputBorder(
        borderSide: BorderSide(color: c),
        borderRadius: BorderRadius.zero,
      );

  Widget _toggle() {
    return InkWell(
      onTap: () async {
        setState(() => em.autoDetect = !em.autoDetect);
        await em.save();
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: panel,
          border: Border.all(color: em.autoDetect ? signal : line),
        ),
        child: Row(children: [
          Icon(em.autoDetect ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18, color: em.autoDetect ? signal : steel),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Sturz automatisch erkennen',
                style: TextStyle(fontSize: 12, color: chalk)),
          ),
        ]),
      ),
    );
  }

  Widget _autoSendToggle() {
    return InkWell(
      onTap: () async {
        if (!em.autoSend) {
          // Android fragt hier nach der Berechtigung "SMS senden".
          final ok = await em.smsPermission(request: true);
          if (!ok) {
            if (mounted) {
              toast(context, 'Ohne Berechtigung öffnet sich nur die SMS-App');
            }
            return;
          }
        }
        setState(() => em.autoSend = !em.autoSend);
        await em.save();
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: panel,
          border: Border.all(color: em.autoSend ? signal : line),
        ),
        child: Row(children: [
          Icon(em.autoSend ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18, color: em.autoSend ? signal : steel),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'SMS nach dem Countdown automatisch senden (empfohlen). '
              'Sonst öffnet sich nur die SMS-App - wer bewusstlos ist, '
              'kann dort nicht auf Senden tippen.',
              style: TextStyle(fontSize: 11.5, color: chalk, height: 1.35),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _companionToggle() {
    return InkWell(
      onTap: () async {
        if (!em.companion) {
          if (!em.hasContact) {
            toast(context, 'Erst oben eine Telefonnummer eintragen');
            return;
          }
          final ok = await em.smsPermission(request: true);
          if (!ok) {
            if (mounted) toast(context, 'Ohne Berechtigung "SMS senden" geht es nicht');
            return;
          }
        }
        setState(() => em.companion = !em.companion);
        await em.save();
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: panel,
          border: Border.all(color: em.companion ? signal : line),
        ),
        child: Row(children: [
          Icon(em.companion ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18, color: em.companion ? signal : steel),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Dem Kontakt per SMS Bescheid geben: beim Losfahren, '
              'unterwegs mit Kartenlink zur Position und am Ende "Fahrt '
              'beendet". Ohne Server, ohne Konto - der Kontakt braucht '
              'keine App. SMS braucht nur Netz, kein Internet.',
              style: TextStyle(fontSize: 11.5, color: chalk, height: 1.35),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _companionInterval() {
    String label(int m) => m == 0 ? 'nur Start/Ende' : '$m min';
    return Wrap(spacing: 6, runSpacing: 6, children: [
      const Padding(
        padding: EdgeInsets.only(top: 8, right: 4),
        child: Text('Position alle',
            style: TextStyle(fontSize: 11, color: steel)),
      ),
      for (final m in [0, 30, 60, 120])
        InkWell(
          onTap: () async {
            setState(() => em.companionEveryMin = m);
            await em.save();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: em.companionEveryMin == m ? panel : asphalt,
              border: Border.all(
                  color: em.companionEveryMin == m ? signal : line),
            ),
            child: Text(label(m),
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: em.companionEveryMin == m ? chalk : steel)),
          ),
        ),
    ]);
  }

  Widget _countdownRow() {
    return Row(children: [
      const Expanded(
        child: Text('Countdown vor dem Senden',
            style: TextStyle(fontSize: 11, color: steel)),
      ),
      for (final s in [20, 30, 45])
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: InkWell(
            onTap: () async {
              setState(() => em.countdownSec = s);
              await em.save();
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: em.countdownSec == s ? panel : asphalt,
                border: Border.all(
                    color: em.countdownSec == s ? signal : line),
              ),
              child: Text('$s s',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: em.countdownSec == s ? chalk : steel)),
            ),
          ),
        ),
    ]);
  }

  Widget _explainer() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: panel, border: Border.all(color: line)),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.info_outline, size: 14, color: amber),
              SizedBox(width: 6),
              TinyLabel('WAS DIE ERKENNUNG KANN – UND WAS NICHT', color: amber),
            ]),
            SizedBox(height: 8),
            Text(
              'Alarm gibt es nur, wenn alles zusammenkommt: Du warst kurz '
              'zuvor schneller als 25 km/h, es gab einen harten Stoß, danach '
              'acht Sekunden Stillstand - und das Handy liegt danach '
              'deutlich anders als vorher (Motorrad liegt, Handy '
              'weggeflogen). Damit lösen Schlaglöcher, ein Schlag vor der '
              'Ampel und ein umgefallenes Handy im Stand keinen Alarm aus.',
              style: TextStyle(fontSize: 10.5, color: steel, height: 1.55),
            ),
            SizedBox(height: 8),
            Text(
              'Das ist eine Hilfe, kein zugelassenes Notrufsystem. Ein '
              'sanftes Wegrutschen ohne harten Aufprall kann übersehen '
              'werden. Verlass dich nicht darauf – wenn du kannst, ruf '
              'immer selbst 112.',
              style: TextStyle(fontSize: 10.5, color: steel, height: 1.55),
            ),
            SizedBox(height: 8),
            Text(
              'Mit "automatisch senden" geht die SMS mit Position nach dem '
              'Countdown ohne weiteres Zutun raus. Ohne diese Einstellung '
              'öffnet sich nur die SMS-App mit fertiger Nachricht. SMS '
              'statt Internet, weil im Funkloch oft noch Netz für SMS '
              'reicht. Ein Fehlalarm kostet eine Entwarnung per Anruf - '
              'ein übersehener Sturz womöglich viel mehr.',
              style: TextStyle(fontSize: 10.5, color: steel, height: 1.55),
            ),
          ],
        ),
      );
}
