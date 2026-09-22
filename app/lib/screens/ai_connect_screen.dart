import 'package:flutter/material.dart';

import '../services/ai_config.dart';
import '../theme.dart';

/// Einrichtung der KI-Anbindung.
///
/// Der Zugang wird hier EINMAL eingerichtet und bleibt danach auf dem
/// Geraet gespeichert. Beim Planen wird nie wieder nach einem Schluessel
/// gefragt.
///
/// Zwei Wege:
///  * Eigener Schluessel  - fuer eigene Tests, liegt auf diesem Geraet
///  * Eigener Server      - der Server haelt den Schluessel, der Nutzer
///                          der App braucht selbst keinen
class AiConnectScreen extends StatefulWidget {
  const AiConnectScreen({super.key, required this.config});

  final AiConfig config;

  @override
  State<AiConnectScreen> createState() => _AiConnectScreenState();
}

class _AiConnectScreenState extends State<AiConnectScreen> {
  late AiMode _mode;
  late String _model;
  late final TextEditingController _keyCtrl;
  late final TextEditingController _srvCtrl;

  bool _show = false;
  bool _busy = false;
  String? _error;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    // Beim ersten Aufruf gleich den bequemeren Weg vorauswaehlen.
    _mode = widget.config.mode == AiMode.none
        ? AiMode.ownKey
        : widget.config.mode;
    _model = widget.config.model;
    _keyCtrl = TextEditingController(text: widget.config.key);
    _srvCtrl = TextEditingController(text: widget.config.serverUrl);
    _ok = widget.config.isConfigured;
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _srvCtrl.dispose();
    super.dispose();
  }

  AiConfig _current() => AiConfig(
        mode: _mode,
        key: _keyCtrl.text.trim(),
        serverUrl: _srvCtrl.text.trim(),
        model: _model,
      );

  bool get _hasInput => _current().isConfigured;

  // ------------------------------------------------------------------
  Future<void> _test() async {
    final cfg = _current();
    if (!cfg.isConfigured) return;
    setState(() {
      _busy = true;
      _error = null;
      _ok = false;
    });
    final err = await cfg.planner().testConnection();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      _ok = err == null;
    });
  }

  Future<void> _save() async {
    final cfg = _current();
    await cfg.save();
    if (!mounted) return;
    Navigator.pop(context, cfg);
  }

  Future<void> _disconnect() async {
    await AiConfig.clear();
    if (!mounted) return;
    Navigator.pop(context, const AiConfig());
  }

  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: asphalt,
        elevation: 0,
        title: const Text('KI VERBINDEN',
            style: TextStyle(
                fontSize: 13, letterSpacing: 4, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Einmal einrichten, danach fragt die App nie wieder nach einem '
            'Schlüssel.',
            style: TextStyle(fontSize: 12, color: chalk, height: 1.5),
          ),
          const SizedBox(height: 16),
          const TinyLabel('WEG WÄHLEN'),
          const SizedBox(height: 8),
          _modeTile(
            mode: AiMode.ownKey,
            title: 'EIGENER SCHLÜSSEL',
            sub: 'Für eigene Tests. Der Schlüssel bleibt auf diesem Gerät.',
          ),
          const SizedBox(height: 8),
          _modeTile(
            mode: AiMode.ownServer,
            title: 'EIGENER SERVER',
            sub: 'Der Server hält den Schlüssel – Nutzer brauchen keinen.',
          ),
          const SizedBox(height: 18),
          if (_mode == AiMode.ownKey) ..._keySection() else ..._serverSection(),
          const SizedBox(height: 18),
          if (_error != null) _banner(_error!, redline, Icons.error_outline),
          if (_ok && _error == null)
            _banner('Verbindung steht. Die KI ist einsatzbereit.', cool,
                Icons.check_circle_outline),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Row(children: [
                SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: signal)),
                SizedBox(width: 10),
                Text('Verbindung wird geprüft ...',
                    style: TextStyle(fontSize: 11.5, color: steel)),
              ]),
            ),
          SizedBox(
            width: double.infinity,
            child: FlatButton2(
              label: 'VERBINDUNG TESTEN',
              onTap: (_busy || !_hasInput) ? null : _test,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FlatButton2(
              label: 'SPEICHERN',
              color: signal,
              strong: true,
              onTap: (_busy || !_hasInput) ? null : _save,
            ),
          ),
          if (widget.config.isConfigured) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FlatButton2(
                label: 'VERBINDUNG TRENNEN',
                onTap: _busy ? null : _disconnect,
              ),
            ),
          ],
          const SizedBox(height: 20),
          _hintBox(),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  List<Widget> _keySection() => [
        const TinyLabel('SCHLÜSSEL VON console.anthropic.com'),
        const SizedBox(height: 6),
        TextField(
          controller: _keyCtrl,
          obscureText: !_show,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontSize: 12, color: chalk),
          onChanged: (_) => setState(() {
            _ok = false;
            _error = null;
          }),
          decoration: InputDecoration(
            hintText: 'sk-ant-...',
            hintStyle: const TextStyle(fontSize: 11, color: steel),
            isDense: true,
            filled: true,
            fillColor: asphalt,
            contentPadding: const EdgeInsets.all(12),
            suffixIcon: IconButton(
              icon: Icon(_show ? Icons.visibility_off : Icons.visibility,
                  size: 18, color: steel),
              onPressed: () => setState(() => _show = !_show),
            ),
            border: _border(line),
            enabledBorder: _border(line),
            focusedBorder: _border(signal),
          ),
        ),
        const SizedBox(height: 14),
        const TinyLabel('MODELL'),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: _modelChip(
                AiConfig.defaultModel, 'SONNET 5', 'genauer'),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _modelChip(
                AiConfig.cheapModel, 'HAIKU 4.5', 'günstiger'),
          ),
        ]),
      ];

  List<Widget> _serverSection() => [
        const TinyLabel('ADRESSE DES EIGENEN SERVERS'),
        const SizedBox(height: 6),
        TextField(
          controller: _srvCtrl,
          autocorrect: false,
          keyboardType: TextInputType.url,
          style: const TextStyle(fontSize: 12, color: chalk),
          onChanged: (_) => setState(() {
            _ok = false;
            _error = null;
          }),
          decoration: InputDecoration(
            hintText: 'https://mein-server.de/plan',
            hintStyle: const TextStyle(fontSize: 11, color: steel),
            isDense: true,
            filled: true,
            fillColor: asphalt,
            contentPadding: const EdgeInsets.all(12),
            border: _border(line),
            enabledBorder: _border(line),
            focusedBorder: _border(signal),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Der Server nimmt die Anfrage entgegen, ergänzt den Schlüssel und '
          'gibt die Antwort unverändert zurück. In diesem Modus sendet die '
          'App keinen Schlüssel mit.',
          style: TextStyle(fontSize: 10.5, color: steel, height: 1.5),
        ),
      ];

  OutlineInputBorder _border(Color c) => OutlineInputBorder(
        borderSide: BorderSide(color: c),
        borderRadius: BorderRadius.zero,
      );

  Widget _modeTile({
    required AiMode mode,
    required String title,
    required String sub,
  }) {
    final sel = _mode == mode;
    return InkWell(
      onTap: () => setState(() {
        _mode = mode;
        _ok = false;
        _error = null;
      }),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: panel,
          border: Border(
            left: BorderSide(color: sel ? signal : line, width: 3),
            top: BorderSide(color: sel ? signal : line),
            right: BorderSide(color: sel ? signal : line),
            bottom: BorderSide(color: sel ? signal : line),
          ),
        ),
        child: Row(children: [
          Icon(sel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 16, color: sel ? signal : steel),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w700,
                        color: sel ? chalk : steel)),
                const SizedBox(height: 3),
                Text(sub,
                    style: const TextStyle(
                        fontSize: 10, color: steel, height: 1.4)),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _modelChip(String value, String title, String sub) {
    final sel = _model == value;
    return InkWell(
      onTap: () => setState(() {
        _model = value;
        _ok = false;
        _error = null;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: sel ? panel : asphalt,
          border: Border.all(color: sel ? signal : line),
        ),
        child: Column(children: [
          Text(title,
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: sel ? chalk : steel)),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(fontSize: 9.5, color: steel)),
        ]),
      ),
    );
  }

  Widget _banner(String text, Color c, IconData icon) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: panel,
          border: Border(left: BorderSide(color: c, width: 3)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 15, color: c),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 11, color: chalk, height: 1.45)),
          ),
        ]),
      );

  Widget _hintBox() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: panel,
          border: Border.all(color: line),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.info_outline, size: 14, color: amber),
              SizedBox(width: 6),
              TinyLabel('WICHTIG ZUM SCHLÜSSEL', color: amber),
            ]),
            SizedBox(height: 8),
            Text(
              'Ein Schlüssel, der in einer weitergegebenen App steckt, lässt '
              'sich aus dem Installationspaket auslesen – die Kosten landen '
              'dann bei dir. Für eigene Tests auf dem eigenen Gerät ist der '
              'Schlüssel-Modus in Ordnung. Sobald die App an andere geht, '
              'nimm den Server-Modus oder lass jeden seinen eigenen '
              'Schlüssel eintragen.',
              style: TextStyle(fontSize: 10.5, color: steel, height: 1.55),
            ),
            SizedBox(height: 10),
            Text(
              'Die KI plant übrigens nie selbst die Strecke. Sie übersetzt '
              'nur deinen Wunsch in Vorgaben und beschreibt danach das '
              'Ergebnis. Wege und Orte kommen immer aus echten Kartendaten.',
              style: TextStyle(fontSize: 10.5, color: steel, height: 1.55),
            ),
          ],
        ),
      );
}
