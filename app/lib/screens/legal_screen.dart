import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Datenschutzerklaerung und Impressum (aus assets/legal/datenschutz.md -
/// dieselbe Datei gehoert auch auf die Webseite fuer den Play Store).
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  static const asset = 'assets/legal/datenschutz.md';

  /// Sehr einfaches Markdown: # und ## Ueberschriften, - Listen,
  /// **fett**, Absaetze.
  static List<Widget> render(String md) {
    final out = <Widget>[];
    for (final raw in md.split('\n')) {
      final l = raw.trimRight();
      if (l.isEmpty) {
        out.add(const SizedBox(height: 8));
      } else if (l.startsWith('## ')) {
        out.add(Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(l.substring(3),
              style: const TextStyle(
                  fontSize: 19, fontWeight: FontWeight.w800, color: chalk)),
        ));
      } else if (l.startsWith('# ')) {
        out.add(Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 6),
          child: Text(l.substring(2),
              style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  fontStyle: FontStyle.italic,
                  color: chalk)),
        ));
      } else if (l.startsWith('- ')) {
        out.add(Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('•  ', style: TextStyle(fontSize: 16, color: signal)),
            Expanded(child: _rich(l.substring(2))),
          ]),
        ));
      } else {
        out.add(_rich(l));
      }
    }
    return out;
  }

  static Widget _rich(String s) {
    final spans = <TextSpan>[];
    final parts = s.split('**');
    for (var i = 0; i < parts.length; i++) {
      spans.add(TextSpan(
          text: parts[i],
          style: i.isOdd
              ? const TextStyle(fontWeight: FontWeight.w800, color: chalk)
              : null));
    }
    return Text.rich(TextSpan(
        style: const TextStyle(fontSize: 16, color: steel, height: 1.45),
        children: spans));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DATENSCHUTZ')),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(asset),
        builder: (context, snap) => snap.hasData
            ? ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                children: render(snap.data!),
              )
            : const Center(child: CircularProgressIndicator(color: signal)),
      ),
    );
  }
}
