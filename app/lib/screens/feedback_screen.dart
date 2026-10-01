import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/crash_log.dart';
import '../services/voice.dart';
import '../theme.dart';

/// Fehler melden / Rueckmeldung geben. Der Bericht geht ueber den
/// Teilen-Dialog raus (Mail, Messenger ...) - die App schickt nichts
/// selbst und nichts ohne Zustimmung.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key, this.afterCrash = false});

  /// Aufgerufen, weil die App beim letzten Mal abgestuerzt ist.
  final bool afterCrash;

  /// Nach einem Absturz: kurz fragen, ob ein Bericht raus soll.
  static Future<void> offerCrashReport(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Da lief etwas schief'),
        content: const Text(
            'Beim letzten Mal ist in der App ein Fehler aufgetreten. '
            'Magst du einen Bericht schicken? Er enthält nur technische '
            'Angaben - keinen Standort, keine Namen oder Nummern. Du '
            'siehst ihn vorher.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('NEIN', style: TextStyle(color: steel))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('ANSEHEN')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => const FeedbackScreen(afterCrash: true)));
    }
  }

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _text = TextEditingController();
  bool _withLog = true;
  String? _preview;

  @override
  void initState() {
    super.initState();
    _withLog = true;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<String> _build() async {
    if (_withLog) {
      try {
        CrashLog.instance.context['Sprachausgabe'] =
            (await Voice.instance.diagnose()).replaceAll('\n', ' · ');
      } catch (_) {}
      return CrashLog.instance.report(userText: _text.text);
    }
    return 'SCHRÄGLAGE - RÜCKMELDUNG\n\n${CrashLog.header()}\n'
        '${_text.text.trim()}';
  }

  Future<void> _send() async {
    final text = await _build();
    await SharePlus.instance.share(ShareParams(
      text: text,
      subject: 'Schräglage: ${widget.afterCrash ? 'Fehlerbericht' : 'Rückmeldung'}',
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FEHLER MELDEN')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const Text(
            'Was ist passiert? Wo warst du in der App, was hast du '
            'gedrückt, was hast du erwartet? Auch Ideen und Wünsche sind '
            'willkommen.',
            style: TextStyle(fontSize: 16, color: steel, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            minLines: 4,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 17, color: chalk),
            decoration: const InputDecoration(
                hintText: 'z. B. Beim Planen einer Rundtour über 200 km '
                    'hing die App bei "Straßen werden geprüft"'),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Technische Angaben anhängen'),
            subtitle: const Text(
                'Version, Android-Version, letzte Rechenzeiten und das '
                'Fehlerprotokoll. Kein Standort, keine Namen oder Nummern.'),
            value: _withLog,
            onChanged: (v) => setState(() {
              _withLog = v;
              _preview = null;
            }),
          ),
          TextButton(
            onPressed: () async {
              final t = await _build();
              if (mounted) setState(() => _preview = t);
            },
            child: const Text('BERICHT ANSEHEN'),
          ),
          if (_preview != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(10),
              color: panel,
              child: SelectableText(_preview!,
                  style: const TextStyle(fontSize: 12.5, color: steel)),
            ),
          const SizedBox(height: 8),
          FlatButton2(
            label: 'SENDEN (MAIL, MESSENGER ...)',
            color: signal,
            fill: signal,
            strong: true,
            tall: true,
            onTap: _send,
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () async {
              await CrashLog.instance.clear();
              if (!context.mounted) return;
              setState(() => _preview = null);
              toast(context, 'Fehlerprotokoll gelöscht');
            },
            child: const Text('FEHLERPROTOKOLL LÖSCHEN',
                style: TextStyle(color: steel)),
          ),
        ],
      ),
    );
  }
}
