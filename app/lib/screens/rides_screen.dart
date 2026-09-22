import 'package:flutter/material.dart';

import '../models/ride.dart';
import '../services/ride_store.dart';
import '../theme.dart';
import 'ride_detail_screen.dart';

/// Liste aller gespeicherten Fahrten.
class RidesScreen extends StatefulWidget {
  const RidesScreen({super.key});

  @override
  State<RidesScreen> createState() => RidesScreenState();
}

class RidesScreenState extends State<RidesScreen> {
  List<RideSummary> _rides = [];
  Map<String, num> _totals = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final rides = await RideStore.instance.listRides();
    final totals = await RideStore.instance.totals();
    if (!mounted) return;
    setState(() {
      _rides = rides;
      _totals = totals;
      _loaded = true;
    });
  }

  Future<void> _delete(RideSummary r) async {
    await RideStore.instance.deleteRide(r.id);
    await reload();
    if (mounted) toast(context, 'Fahrt gelöscht');
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
          child: CircularProgressIndicator(color: signal));
    }

    if (_rides.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Noch keine Fahrten gespeichert.\n\n'
            'Tippe auf FAHRT STARTEN, fahre los\n'
            'und beende die Fahrt – sie landet dann hier,\n'
            'mit Karte und Kurvenauswertung.',
            textAlign: TextAlign.center,
            style: TextStyle(color: steel, height: 1.7, fontSize: 12),
          ),
        ),
      );
    }

    final totalKm = (_totals['distanceM'] ?? 0) / 1000;

    return RefreshIndicator(
      color: signal,
      backgroundColor: panel,
      onRefresh: reload,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _rides.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          if (i == 0) {
            return Row(children: [
              Expanded(
                child: StatCard(
                  label: 'FAHRTEN',
                  value: '${_totals['rides'] ?? 0}',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StatCard(
                  label: 'GESAMT',
                  value: totalKm.toStringAsFixed(0),
                  unit: ' km',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StatCard(
                  label: 'BESTE',
                  value: '${(_totals['maxLean'] ?? 0).round()}',
                  unit: '°',
                ),
              ),
            ]);
          }
          return _tile(_rides[i - 1]);
        },
      ),
    );
  }

  Widget _tile(RideSummary r) {
    return InkWell(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => RideDetailScreen(ride: r)),
        );
        await reload();
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: const BoxDecoration(
          color: panel,
          border: Border(
            left: BorderSide(color: signal, width: 3),
            top: BorderSide(color: line),
            right: BorderSide(color: line),
            bottom: BorderSide(color: line),
          ),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${fmtDate(r.start)}   ·   ${fmtDur(r.durationSec)}',
                    style: const TextStyle(
                        fontSize: 10, letterSpacing: 1, color: steel)),
                const SizedBox(height: 4),
                Text(
                  '${r.distanceKm.toStringAsFixed(1)} km   ·   '
                  'Ø ${r.avgSpeedKmh.round()}   ·   '
                  'Vmax ${r.maxSpeedKmh.round()} km/h',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: chalk),
                ),
                const SizedBox(height: 3),
                Text(
                  'Schräglage ${r.maxLeanL.round()}° L / '
                  '${r.maxLeanR.round()}° R   ·   '
                  'Brems ${r.maxBrakeG.toStringAsFixed(2)} G',
                  style: const TextStyle(fontSize: 10.5, color: steel),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16, color: steel),
            onPressed: () => _delete(r),
          ),
        ]),
      ),
    );
  }
}
