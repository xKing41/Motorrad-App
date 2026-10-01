part of 'map_screen.dart';

// ---------------------------------------------------------------------------
//  Menues und Blaetter der Kartenansicht (Karte, Offline, Headset,
//  Tour-Details, Navi-App, Navi-Menue). Ausgelagert, damit die
//  Kartenansicht selbst uebersichtlich bleibt.
// ---------------------------------------------------------------------------

extension _MapSheets on _MapScreenState {
  /// Alles rund um die Karte an einer Stelle - grosse Kacheln.
  void _showMapMenu() {
    final vm = VectorMap.instance;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        Widget tile(IconData icon, String title, String sub, VoidCallback onTap,
                {Color color = chalk, bool active = false}) =>
            MenuTile(icon, title, sub, () {
              Navigator.pop(ctx);
              onTap();
            }, color: color, active: active);
        final off = _offline.offline.value;
        final job = _offline.job;
        final hs = Headset.instance.status;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('KARTE',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        fontStyle: FontStyle.italic,
                        color: chalk)),
              ),
              const SizedBox(height: 12),
              tileGrid([
                tile(
                  _night && vm.useVector ? Icons.dark_mode : Icons.layers,
                  'Kartenstil',
                  vm.style.label,
                  _showStyles,
                ),
                tile(
                  off ? Icons.cloud_off : Icons.download_for_offline,
                  'Offline-Karten',
                  job?.running == true
                      ? 'Lädt ... ${((job!.progress) * 100).round()} %'
                      : off
                          ? 'Offline-Modus an'
                          : 'Gebiet speichern',
                  _showOffline,
                  color: off ? amber : chalk,
                  active: off,
                ),
                if (_tomtomKey.isNotEmpty)
                  tile(Icons.traffic, 'Verkehr',
                      _showFlow ? 'Anzeige an' : 'Anzeige aus', () {
                    _update(() => _showFlow = !_showFlow);
                  }, color: _showFlow ? signal : chalk, active: _showFlow),
                if (kTestBuild)
                  tile(
                    hs.connected ? Icons.headset_mic : Icons.headset_off,
                    'Headset',
                    hs.connected
                        ? '${hs.label}${hs.battery >= 0 ? ' · ${hs.battery} %' : ''}'
                        : 'Nicht verbunden',
                    _showHeadset,
                    color: hs.connected
                        ? (hs.batteryLow ? amber : signal)
                        : chalk,
                  ),
                tile(
                  Icons.block,
                  'Eigene Sperren',
                  '${UserBlocks.instance.blocks.length} · lange auf die Karte drücken',
                  () => toast(context,
                      'Lange auf eine Straße drücken -> "Straße hier dauerhaft sperren"'),
                  color: redline,
                ),
              ]),
            ]),
          ),
        );
      },
    );
  }

  void _showStyles() {
    final vm = VectorMap.instance;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: vm,
          builder: (ctx, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('KARTE',
                    style: TextStyle(
                        fontSize: 15.5, letterSpacing: 1.2, color: chalk)),
              ),
            ),
            for (final m in MapStyle.values)
              ListTile(
                dense: true,
                leading: Icon(
                    vm.style == m
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: vm.style == m ? signal : steel,
                    size: 20),
                title: Text(m.label,
                    style: const TextStyle(fontSize: 16, color: chalk)),
                onTap: () => vm.setStyle(m),
              ),
            if (!vm.ready && vm.style != MapStyle.classic)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Die Vektorkarte braucht einmal Internet, bis dahin '
                  'zeigt die App die klassische Karte.',
                  style: TextStyle(fontSize: 13.5, color: amber, height: 1.4),
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Vektorkarte: scharf in jeder Zoomstufe, nachts dunkel '
                '(blendet nicht im Helm), offline deutlich kleiner.',
                style: TextStyle(fontSize: 13.5, color: steel, height: 1.4),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _showHeadset() {
    final h = Headset.instance;
    h.refresh();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: h,
          builder: (ctx, _) {
            final st = h.status;
            const small = TextStyle(fontSize: 13.5, color: steel, height: 1.4);
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              children: [
                const Text('HELM-HEADSET',
                    style: TextStyle(
                        fontSize: 15.5, letterSpacing: 1.2, color: chalk)),
                const SizedBox(height: 8),
                Row(children: [
                  Icon(st.connected ? Icons.headset_mic : Icons.headset_off,
                      color: st.connected ? signal : steel),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        st.connected
                            ? '${st.label}${st.brand.isNotEmpty && !st.name.toLowerCase().contains(st.brand.toLowerCase()) ? ' (${st.brand})' : ''}'
                            : 'Kein Headset verbunden',
                        style: const TextStyle(fontSize: 16.5, color: chalk)),
                  ),
                ]),
                if (st.connected && st.battery < 0 && !st.btPermission)
                  TextButton(
                    onPressed: h.requestPermissions,
                    child: const Text('AKKUSTAND ANZEIGEN (ERLAUBEN)',
                        style: TextStyle(fontSize: 13.5, color: cool)),
                  ),
                const SizedBox(height: 6),
                const Text(
                  'Sena, Cardo, Interphone, Midland ... jedes Bluetooth-'
                  'Headset. Navi-Ansagen und Sprachnachrichten der Gruppe '
                  'kommen im Helm, Musik wird dabei leiser. Mit '
                  'Audio-Multitasking am Headset auch während des Intercoms.',
                  style: small,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: signal,
                  inactiveTrackColor: line,
                  title: const Text('Headset-Tasten steuern die App',
                      style: TextStyle(fontSize: 16, color: chalk)),
                  subtitle: const Text(
                      'Play/Pause: Ansage wiederholen · Weiter: Sprechen an '
                      'die Gruppe (nochmal: senden) · Zurück: Restweg, '
                      'Ankunft, Tempolimit. Solange an, steuern die Tasten '
                      'keine Musik.',
                      style: small),
                  value: h.buttonsOn,
                  onChanged: (v) => h.setButtons(v),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _showOffline() {
    final visible = _mapReady ? _map.camera.visibleBounds : null;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: _offline,
          builder: (ctx, _) => _offlineSheet(ctx, visible),
        ),
      ),
    );
  }

  Widget _offlineSheet(BuildContext ctx, LatLngBounds? visible) {
    final job = _offline.job;
    const small = TextStyle(fontSize: 13.5, color: steel, height: 1.4);
    String areaInfo() {
      if (visible == null) return '';
      final z = OfflineMaps.areaMaxZoom(visible.south, visible.west,
          visible.north, visible.east, 8,
          top: _offline.sourceMaxZoom);
      final n = countTilesInBox(
          visible.south, visible.west, visible.north, visible.east,
          minZoom: 8, maxZoom: z);
      return 'Bis Zoomstufe $z · ca. ${formatBytes(n * _offline.tileBytes)}';
    }

    String routeInfo(RoutePlan r) {
      final n = _offline.routeTiles(r.points).length;
      return 'Streifen entlang der Tour · ca. ${formatBytes(n * _offline.tileBytes)}';
    }

    String jobText(OfflineJob j) {
      final r = j.result;
      if (r == null) {
        return '${j.label}: ${j.done} von ${j.total} Kacheln';
      }
      if (r.cancelled && r.failed > 0) {
        return '${j.label}: abgebrochen - kein Netz? '
            '${r.loaded + r.skipped} von ${j.total} gespeichert.';
      }
      if (r.cancelled) return '${j.label}: abgebrochen.';
      return '${j.label}: fertig, ${r.loaded + r.skipped} Kacheln auf dem Handy'
          '${r.failed > 0 ? ' (${r.failed} fehlgeschlagen)' : ''}.';
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        const Text('OFFLINE-KARTEN',
            style: TextStyle(fontSize: 15.5, letterSpacing: 1.2, color: chalk)),
        const SizedBox(height: 4),
        const Text(
          'Jede angesehene Karte bleibt auf dem Handy. Vorab geladene '
          'Strecken und Gebiete funktionieren auch im Funkloch - die '
          'Navigation läuft mit der gespeicherten Route weiter.',
          style: small,
        ),
        if (_offline.offline.value) ...[
          const SizedBox(height: 6),
          const Text('Gerade kein Netz - Karte kommt vom Handy.',
              style: TextStyle(fontSize: 14, color: amber)),
        ],
        if (job != null) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(
              value: job.progress, color: cool, backgroundColor: line),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: Text(jobText(job), style: small)),
            if (job.running)
              TextButton(
                onPressed: _offline.cancel,
                child: const Text('ABBRECHEN',
                    style: TextStyle(fontSize: 13.5, color: amber)),
              ),
          ]),
        ],
        const SizedBox(height: 6),
        if (_route != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.route, color: cool, size: 20),
            title: const Text('Route offline speichern',
                style: TextStyle(fontSize: 16, color: chalk)),
            subtitle: Text(routeInfo(_route!), style: small),
            onTap: () => _offline.saveRoute(_route!.points,
                label: _route!.title ?? 'Route'),
          ),
        if (visible != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.crop_free, color: cool, size: 20),
            title: const Text('Sichtbaren Ausschnitt speichern',
                style: TextStyle(fontSize: 16, color: chalk)),
            subtitle: Text(areaInfo(), style: small),
            onTap: () => _offline.saveArea(
                visible.south, visible.west, visible.north, visible.east),
          ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          activeTrackColor: signal,
          inactiveTrackColor: line,
          title: const Text('Geplante Routen automatisch speichern',
              style: TextStyle(fontSize: 16, color: chalk)),
          subtitle: const Text(
              'Lädt die Karte entlang jeder neuen Route gleich mit. '
              'Braucht mobile Daten - im WLAN planen spart Datenvolumen.',
              style: small),
          value: _offline.autoRoute,
          onChanged: (v) => _offline.setAutoRoute(v),
        ),
        FutureBuilder<TileCacheStats>(
          future: _offline.stats(),
          builder: (ctx, snap) {
            final s = snap.data;
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sd_storage, color: steel, size: 20),
              title: Text(
                  s == null
                      ? 'Speicher wird gezählt ...'
                      : 'Belegt: ${formatBytes(s.bytes)} (${s.tiles} Kacheln)',
                  style: const TextStyle(fontSize: 15.5, color: chalk)),
              subtitle: const Text(
                  'Höchstens 600 MB - älteste Kacheln werden automatisch '
                  'gelöscht.',
                  style: small),
              trailing: TextButton(
                onPressed: () async {
                  await _offline.clear();
                  PaintingBinding.instance.imageCache.clear();
                },
                child: const Text('LEEREN',
                    style: TextStyle(fontSize: 13.5, color: amber)),
              ),
            );
          },
        ),
      ],
    );
  }

  /// Alles, was der Planer ueber die Route weiss - auch WARUM er genau
  /// diese Variante vorschlaegt.
  void _showRouteInfo() {
    final r = _route;
    if (r == null) return;
    final st = r.stats;
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(
                child: Text(k,
                    style: const TextStyle(fontSize: 14.5, color: steel))),
            Text(v, style: const TextStyle(fontSize: 15, color: chalk)),
          ]),
        );

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            children: [
              Text((r.title ?? 'ROUTE').toUpperCase(),
                  style: const TextStyle(
                      fontSize: 15.5, letterSpacing: 1.2, color: chalk)),
              if (_variants.length > 1)
                Text('Variante ${_variantIdx + 1} von ${_variants.length}',
                    style: const TextStyle(fontSize: 13.5, color: cool)),
              const SizedBox(height: 10),
              row('Länge', fmtKm(r.distanceM)),
              if (r.durationSec > 0)
                row('Fahrzeit (Schätzung)', fmtDuration(r.durationSec)),
              if (_planEta != null)
                row(
                    'Fahrzeit mit Verkehr jetzt',
                    '${fmtDuration(_planEta!.travelSec)}'
                        '${_planEta!.delaySec >= 60 ? ' (+${(_planEta!.delaySec / 60).round()} min Stau)' : ''}'),
              if (st != null) ...[
                row('Kurvigkeit', st.curvLabel),
                row('Kurven je km',
                    st.bendsPerKm.toStringAsFixed(1).replaceAll('.', ',')),
                row('Doppelt gefahren', '${(st.overlapShare * 100).round()} %'),
                if (st.knownShare > 0)
                  row('Eigene bekannte Strecken',
                      '${(st.knownShare * 100).round()} %'),
              ],
              if (r.engineLabel != null) row('Berechnet mit', r.engineLabel!),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Tipp: Lange auf die Karte drücken, um die Tour zu ändern - '
                  'über einen Punkt führen, Straße meiden, Stopp entfernen.',
                  style: TextStyle(fontSize: 13.5, color: cool, height: 1.4),
                ),
              ),
              if (r.pois.isNotEmpty) ...[
                const SizedBox(height: 10),
                const TinyLabel('STOPPS'),
                const SizedBox(height: 4),
                for (final p in r.pois)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Icon(poiIcon(p.kind), size: 14, color: poiColor(p.kind)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          [
                            p.displayName,
                            if (_MapScreenState._detailOf(p) != null) _MapScreenState._detailOf(p)!,
                            if (_fuelPrices[p.id] != null)
                              _fuelPrices[p.id]!.text,
                          ].join(' · '),
                          style: const TextStyle(fontSize: 14.5, color: chalk),
                        ),
                      ),
                    ]),
                  ),
                if (_fuelPrices.isNotEmpty)
                  const Text(FuelPrices.attribution,
                      style: TextStyle(fontSize: 12, color: steel)),
              ],
              if (_weather != null) ...[
                const SizedBox(height: 10),
                const TinyLabel('WETTER UNTERWEGS (ABFAHRT JETZT)'),
                const SizedBox(height: 4),
                for (final w in _weather!.warnings().isEmpty
                    ? [_weather!.summary()]
                    : _weather!.warnings())
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(w,
                        style: const TextStyle(fontSize: 14.5, color: chalk)),
                  ),
                if (_betterDeparture != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Besser um ${RouteWeatherReport.clock(_betterDeparture!.departure)} '
                      'losfahren: ${_betterDeparture!.summary()}',
                      style: const TextStyle(fontSize: 14.5, color: signal),
                    ),
                  ),
                const Text(RouteWeather.attribution,
                    style: TextStyle(fontSize: 12, color: steel)),
              ],
              if (r.traffic.isNotEmpty) ...[
                const SizedBox(height: 10),
                const TinyLabel('VERKEHRSLAGE AN DER ROUTE'),
                const SizedBox(height: 4),
                for (final i in r.traffic)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(trafficIcon(i.category), size: 14, color: redline),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            [
                              'km ${(i.alongM / 1000).round()}: ${i.label}',
                              if (i.description != null) i.description!,
                            ].join(' · '),
                            style: const TextStyle(fontSize: 14.5, color: chalk),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              if (r.description != null) ...[
                const SizedBox(height: 10),
                Text(r.description!,
                    style: const TextStyle(
                        fontSize: 15, color: cool, height: 1.45)),
              ],
              for (final n in r.notes)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(n,
                      style: const TextStyle(fontSize: 14, color: amber)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Route an eine andere Navi-App uebergeben.
  void _showExport() {
    final r = _route;
    if (r == null) return;
    final from = _nav?.alongM ?? 0;
    final google = ExternalNav.googleMaps(r, fromM: from);
    final (target, targetName) = ExternalNav.nextTarget(r, fromM: from);

    Widget tile(IconData icon, String title, String sub, VoidCallback onTap) =>
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: cool, size: 20),
          title: Text(title,
              style: const TextStyle(fontSize: 16, color: chalk)),
          subtitle: Text(sub,
              style: const TextStyle(fontSize: 13.5, color: steel, height: 1.3)),
          onTap: onTap,
        );

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            children: [
              const Text('IN NAVI-APP ÖFFNEN',
                  style: TextStyle(
                      fontSize: 15.5, letterSpacing: 1.2, color: chalk)),
              const SizedBox(height: 4),
              const Text(
                'Die exakte Tour überträgt nur die GPX-Datei. Links an '
                'Google & Co. geben Zwischenpunkte auf der Tour vor - die '
                'App rechnet dazwischen selbst.',
                style: TextStyle(fontSize: 13.5, color: steel, height: 1.4),
              ),
              const SizedBox(height: 8),
              tile(
                Icons.route,
                'GPX-Datei (exakte Tour)',
                'TomTom GO, Garmin, Kurviger, Calimoto, OsmAnd, '
                    'MyRoute-app ... - im Teilen-Menü die App wählen',
                () {
                  Navigator.pop(ctx);
                  _shareGpx();
                },
              ),
              for (final g in google)
                tile(Icons.map, g.label, g.detail ?? '', () => _open(g.uri)),
              tile(Icons.navigation, 'Waze',
                  'Nur ein Ziel möglich: $targetName',
                  () => _open(ExternalNav.waze(target))),
              if (Platform.isIOS)
                tile(Icons.map_outlined, 'Apple Karten',
                    'Nur ein Ziel möglich: $targetName',
                    () => _open(ExternalNav.appleMaps(target))),
              if (Platform.isAndroid)
                tile(Icons.open_in_new, 'Andere Navi-App',
                    'TomTom GO, Sygic, HERE, Magic Earth ... - Ziel: $targetName',
                    () => _open(ExternalNav.geo(target, targetName))),
            ],
          ),
        ),
      ),
    );
  }

  /// Alles, was man unterwegs seltener braucht - grosse Kacheln.
  void _showNavMenu(NavigationSession nav) {
    final stop = nav.nextStop;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        Widget tile(IconData icon, String title, String sub, VoidCallback f,
                {Color color = chalk}) =>
            MenuTile(icon, title, sub, () {
              Navigator.pop(ctx);
              f();
            }, color: color);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              tileGrid([
                tile(Icons.refresh, 'Neu berechnen', 'ab hier', nav.rerouteNow),
                if (stop != null)
                  tile(Icons.skip_next, 'Stopp auslassen',
                      stop.poi.displayName, nav.skipNextStop)
                else
                  tile(Icons.ios_share, 'Navi-App', 'Tour dort öffnen',
                      _showExport),
                if (stop != null)
                  tile(Icons.ios_share, 'Navi-App', 'Tour dort öffnen',
                      _showExport),
                tile(Icons.layers, 'Karte', 'Stil, Offline, Verkehr',
                    _showMapMenu),
                tile(Icons.record_voice_over, 'Ansage testen',
                    'Lautstärke und Ausgabe prüfen', () async {
                  await Voice.instance.test();
                  await Future<void>.delayed(const Duration(seconds: 3));
                  final err = Voice.instance.lastError;
                  if (mounted && err != null) toast(context, err);
                }),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(
                  child: FlatButton2(
                    label: 'NAVI BEENDEN\n(halten)',
                    color: amber,
                    strong: true,
                    tall: true,
                    onTap: _holdHint,
                    onLongPress: () {
                      Navigator.pop(ctx);
                      _stopNav();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FlatButton2(
                    label: t.recording
                        ? 'FAHRT BEENDEN\n(halten)'
                        : 'FAHRT AUFZEICHNEN',
                    color: t.recording ? amber : signal,
                    strong: true,
                    tall: true,
                    onTap: t.recording
                        ? _holdHint
                        : () {
                            Navigator.pop(ctx);
                            widget.onToggleRide();
                          },
                    onLongPress: () {
                      Navigator.pop(ctx);
                      widget.onToggleRide();
                    },
                  ),
                ),
              ]),
            ]),
          ),
        );
      },
    );
  }
}
