import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/ride.dart';
import '../services/backup_service.dart';
import '../services/ride_store.dart';
import '../services/tour_store.dart';
import '../theme.dart';
import 'ride_detail_screen.dart';
import 'rider_profile_screen.dart';

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
    // Ein versehentlicher Tipp auf das kleine X hat vorher sofort und
    // endgueltig eine Fahrt geloescht.
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        shape: const RoundedRectangleBorder(side: BorderSide(color: line)),
        title: const Text('FAHRT LÖSCHEN?',
            style: TextStyle(fontSize: 12, letterSpacing: 2.5, color: chalk)),
        content: Text(
          '${fmtDate(r.start)} · ${r.distanceKm.toStringAsFixed(1)} km\n'
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
    await RideStore.instance.deleteRide(r.id);
    await reload();
    if (mounted) toast(context, 'Fahrt gelöscht');
  }

  // -------------------------------------------------------------------
  //  Sicherung
  // -------------------------------------------------------------------
  bool _backupBusy = false;

  Future<void> _exportBackup() async {
    setState(() => _backupBusy = true);
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/${BackupService.fileName(DateTime.now())}');
      final res = await BackupService.export(
          f, RideStore.instance, await TourStore.open());
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(f.path, mimeType: 'application/gzip')],
        subject: 'Schräglage-Sicherung',
        text: 'Sicherung: ${res.text}',
      ));
    } catch (e) {
      if (mounted) toast(context, 'Sicherung fehlgeschlagen');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _importBackup() async {
    PlatformFile? f;
    try {
      f = await FilePicker.pickFile();
    } catch (_) {
      f = null;
    }
    if (f == null || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      final res = await BackupService.import(
          f.readAsByteStream(), RideStore.instance, await TourStore.open());
      await reload();
      if (mounted) toast(context, 'Eingespielt: ${res.text}');
    } on FormatException {
      if (mounted) toast(context, 'Das ist keine Schräglage-Sicherung');
    } catch (_) {
      if (mounted) toast(context, 'Einspielen fehlgeschlagen');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Widget _backupRow() {
    if (_backupBusy) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(color: signal, backgroundColor: line),
      );
    }
    return Row(children: [
      Expanded(
        child: FlatButton2(
          label: 'SICHERN & TEILEN',
          onTap: _exportBackup,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: FlatButton2(
          label: 'SICHERUNG EINSPIELEN',
          onTap: _importBackup,
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
          child: CircularProgressIndicator(color: signal));
    }

    if (_rides.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              'Noch keine Fahrten gespeichert.\n\n'
              'Tippe auf FAHRT STARTEN, fahre los\n'
              'und beende die Fahrt – sie landet dann hier,\n'
              'mit Karte und Kurvenauswertung.',
              textAlign: TextAlign.center,
              style: TextStyle(color: steel, height: 1.7, fontSize: 12),
            ),
            const SizedBox(height: 24),
            // Neues Handy: alte Fahrten und Touren zurueckholen.
            if (_backupBusy)
              const LinearProgressIndicator(color: signal, backgroundColor: line)
            else
              FlatButton2(
                label: 'SICHERUNG EINSPIELEN',
                onTap: _importBackup,
              ),
          ]),
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
        itemCount: _rides.length + 2,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          if (i == 0) {
            return Column(children: [
              Row(children: [
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
              ]),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FlatButton2(
                  label: 'MEIN FAHRSTIL - KURVENANALYSE',
                  color: cool,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const RiderProfileScreen()),
                  ),
                ),
              ),
            ]);
          }
          if (i == _rides.length + 1) {
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _backupRow(),
            );
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
