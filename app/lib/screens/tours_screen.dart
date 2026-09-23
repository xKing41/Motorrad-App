import 'package:flutter/material.dart';

import '../models/route_plan.dart';
import '../services/tour_store.dart';
import '../theme.dart';

/// Gespeicherte Touren. Antippen laedt die Tour auf die Karte (Rueckgabe
/// an den Aufrufer).
class ToursScreen extends StatefulWidget {
  const ToursScreen({super.key});

  @override
  State<ToursScreen> createState() => _ToursScreenState();
}

class _ToursScreenState extends State<ToursScreen> {
  List<TourMeta>? _tours;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final store = await TourStore.open();
    final l = await store.list();
    if (mounted) setState(() => _tours = l);
  }

  Future<void> _open(TourMeta m) async {
    final store = await TourStore.open();
    final plan = await store.load(m.id);
    if (!mounted) return;
    if (plan == null) {
      toast(context, 'Tour konnte nicht gelesen werden');
      return;
    }
    Navigator.pop<RoutePlan>(context, plan);
  }

  Future<void> _rename(TourMeta m) async {
    final ctrl = TextEditingController(text: m.isLast ? '' : m.title);
    final t = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        shape: const RoundedRectangleBorder(side: BorderSide(color: line)),
        title: Text(m.isLast ? 'ALS TOUR SPEICHERN' : 'UMBENENNEN',
            style: const TextStyle(
                fontSize: 12, letterSpacing: 2.5, color: chalk)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: chalk),
          decoration: const InputDecoration(hintText: 'Name der Tour'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ABBRECHEN',
                style: TextStyle(fontSize: 11, color: steel)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('OK',
                style: TextStyle(fontSize: 11, color: signal)),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (t == null || t.trim().isEmpty) return;
    final store = await TourStore.open();
    if (m.isLast) {
      // Die automatisch gemerkte Route dauerhaft als eigene Tour ablegen.
      final plan = await store.load(m.id);
      if (plan != null) await store.save(plan, title: t);
    } else {
      await store.rename(m.id, t);
    }
    await _reload();
  }

  Future<void> _delete(TourMeta m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        shape: const RoundedRectangleBorder(side: BorderSide(color: line)),
        title: const Text('TOUR LÖSCHEN?',
            style: TextStyle(fontSize: 12, letterSpacing: 2.5, color: chalk)),
        content: Text(
          '${m.title} · ${(m.distanceM / 1000).round()} km\n'
          'Das lässt sich nicht rückgängig machen.',
          style: const TextStyle(fontSize: 11.5, color: steel, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('BEHALTEN',
                style: TextStyle(fontSize: 11, color: steel)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('LÖSCHEN',
                style: TextStyle(fontSize: 11, color: redline)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await (await TourStore.open()).delete(m.id);
    await _reload();
  }

  static String _dur(int s) {
    final h = s ~/ 3600, m = (s % 3600) ~/ 60;
    return h > 0 ? '$h h ${m.toString().padLeft(2, '0')}' : '$m min';
  }

  @override
  Widget build(BuildContext context) {
    final tours = _tours;
    return Scaffold(
      appBar: AppBar(title: const Text('TOUREN')),
      body: tours == null
          ? const Center(child: CircularProgressIndicator(color: signal))
          : tours.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Noch keine Touren gespeichert.\n\nNach dem Planen: '
                    'oben auf das Lesezeichen tippen. Die zuletzt '
                    'geplante Route merkt sich die App von selbst.',
                    style: TextStyle(fontSize: 12, color: steel, height: 1.5),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: tours.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final m = tours[i];
                    return InkWell(
                      onTap: () => _open(m),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                        decoration: BoxDecoration(
                          color: panel,
                          border:
                              Border.all(color: m.isLast ? cool : line),
                        ),
                        child: Row(children: [
                          Icon(m.roundTrip ? Icons.loop : Icons.route,
                              size: 20, color: m.isLast ? cool : signal),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  m.isLast
                                      ? 'ZULETZT GEPLANT · ${m.title}'
                                      : m.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13, color: chalk),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  [
                                    '${(m.distanceM / 1000).round()} km',
                                    if (m.durationSec > 0) _dur(m.durationSec),
                                    if (m.curvLabel != null) m.curvLabel!,
                                    fmtDate(m.savedAt),
                                  ].join(' · '),
                                  style: const TextStyle(
                                      fontSize: 10, color: steel),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: m.isLast
                                ? 'Als Tour speichern'
                                : 'Umbenennen',
                            icon: Icon(
                                m.isLast ? Icons.bookmark_add : Icons.edit,
                                size: 18,
                                color: steel),
                            onPressed: () => _rename(m),
                          ),
                          IconButton(
                            tooltip: 'Löschen',
                            icon: const Icon(Icons.delete_outline,
                                size: 18, color: steel),
                            onPressed: () => _delete(m),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
    );
  }
}
