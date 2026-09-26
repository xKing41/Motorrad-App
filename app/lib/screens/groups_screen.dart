import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/route_plan.dart';
import '../services/geo.dart';
import '../services/geocoder.dart';
import '../services/group_ride.dart';
import '../services/headset.dart';
import '../theme.dart';
import 'map_pick_screen.dart';

// ---------------------------------------------------------------------------
//  GRUPPEN (Test-App)
//
//  Wie eine kleine Community: Gruppen bleiben gemerkt, bis man austritt,
//  man kann in mehreren sein, schreiben, Ausfahrten mit Treffpunkt planen
//  und zu- oder absagen. Beim Fahren sieht man sich auf der Karte und
//  kann funken.
// ---------------------------------------------------------------------------

const _small = TextStyle(fontSize: 10.5, color: steel, height: 1.4);

const _weekdays = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

String _two(int v) => v.toString().padLeft(2, '0');

String fmtClock(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// "Heute 18:30", "Morgen 10:00", "Sa 12.10. 10:00".
String fmtWhen(DateTime d, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  final label = switch (diff) {
    0 => 'Heute',
    1 => 'Morgen',
    -1 => 'Gestern',
    _ => '${_weekdays[d.weekday - 1]} ${d.day}.${d.month}.',
  };
  return '$label ${fmtClock(d)}';
}

String _fmtDist(double m) => m < 1000
    ? '${(m / 10).round() * 10} m'
    : m < 10000
        ? '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
        : '${(m / 1000).round()} km';

class GroupsScreen extends StatelessWidget {
  const GroupsScreen({
    super.key,
    this.route,
    this.lat,
    this.lon,
    required this.onLoadTour,
    required this.onGoTo,
    this.hub,
  });

  /// Aktuelle Tour auf der Karte (zum Teilen / an eine Ausfahrt haengen).
  final RoutePlan? route;
  final double? lat;
  final double? lon;
  final void Function(RoutePlan) onLoadTour;
  final void Function(Place) onGoTo;
  final GroupHub? hub;

  GroupHub get _hub => hub ?? GroupHub.instance;

  Future<void> _create(BuildContext context) async {
    final name = await _askText(context,
        title: 'NEUE GRUPPE', hint: 'Name, z. B. Sauerland-Biker');
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final s = await _hub.create(name.trim());
    if (context.mounted) _open(context, s);
  }

  Future<void> _join(BuildContext context) async {
    final raw = await _askText(context,
        title: 'BEITRETEN',
        hint: 'Code, z. B. K7Q2M-9XA4F',
        caps: true);
    if (raw == null || !context.mounted) return;
    final c = GroupSession.normalize(raw);
    if (c == null) {
      toast(context, 'Code: 10 Zeichen, z. B. K7Q2M-9XA4F');
      return;
    }
    final s = await _hub.join(c);
    if (context.mounted) _open(context, s);
  }

  void _open(BuildContext context, GroupSession s) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupScreen(
          session: s,
          hub: _hub,
          route: route,
          lat: lat,
          lon: lon,
          onLoadTour: onLoadTour,
          onGoTo: onGoTo,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GRUPPEN')),
      body: ListenableBuilder(
        listenable: _hub,
        builder: (context, _) {
          final now = DateTime.now();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              if (_hub.sessions.isNotEmpty)
                Row(children: [
                  Icon(Icons.circle,
                      size: 9, color: _hub.online ? signal : steel),
                  const SizedBox(width: 6),
                  Text(_hub.online ? 'Verbunden' : 'Nicht verbunden - wird wiederholt',
                      style: _small),
                ]),
              const SizedBox(height: 8),
              for (final s in _hub.sessions) _tile(context, s, now),
              if (_hub.sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Noch in keiner Gruppe. Gründe eine für deine Clique '
                    'oder tritt mit einem Code bei. Gruppen bleiben, bis du '
                    'austrittst - auch wenn die App zu ist. Du kannst in '
                    'mehreren Gruppen sein.',
                    style: TextStyle(fontSize: 12.5, color: chalk, height: 1.45),
                  ),
                ),
              const SizedBox(height: 14),
              FlatButton2(
                label: 'NEUE GRUPPE GRÜNDEN',
                color: signal,
                fill: signal,
                strong: true,
                tall: true,
                onTap: () => _create(context),
              ),
              const SizedBox(height: 10),
              FlatButton2(
                label: 'MIT CODE BEITRETEN',
                color: cool,
                tall: true,
                onTap: () => _join(context),
              ),
              const SizedBox(height: 16),
              const Text(
                'Alles ist Ende-zu-Ende verschlüsselt: nur wer den Code '
                'hat, kann mitlesen. Dein Name kommt aus dem Notfall-Bereich '
                '("Eigener Name"). Deine Position sehen die anderen nur, '
                'solange du eine Fahrt aufzeichnest oder navigierst.',
                style: _small,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(BuildContext context, GroupSession s, DateTime now) {
    final live = s.members.values.where((m) => !m.staleAt(now)).length;
    final next = s.upcoming.firstOrNull;
    final last = s.chat.lastOrNull;
    return InkWell(
      onTap: () => _open(context, s),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: panel,
          border: Border(
              left: BorderSide(color: s.unread > 0 ? signal : cool, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(s.name ?? s.code,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: chalk)),
              ),
              if (live > 0) ...[
                const Icon(Icons.two_wheeler, size: 14, color: cool),
                const SizedBox(width: 3),
                Text('$live', style: const TextStyle(fontSize: 11, color: cool)),
                const SizedBox(width: 8),
              ],
              if (s.unread > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  color: signal,
                  child: Text('${s.unread}',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: asphalt)),
                ),
            ]),
            if (next != null) ...[
              const SizedBox(height: 4),
              Text('${fmtWhen(next.when)} · ${next.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: amber)),
            ],
            if (last != null) ...[
              const SizedBox(height: 3),
              Text('${last.from}: ${last.text}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _small),
            ],
            if (s.error != null) ...[
              const SizedBox(height: 3),
              Text(s.error!, style: const TextStyle(fontSize: 10, color: amber)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Eine Gruppe: Chat, Ausfahrten, Mitglieder.
class GroupScreen extends StatefulWidget {
  const GroupScreen({
    super.key,
    required this.session,
    required this.hub,
    this.route,
    this.lat,
    this.lon,
    required this.onLoadTour,
    required this.onGoTo,
  });

  final GroupSession session;
  final GroupHub hub;
  final RoutePlan? route;
  final double? lat;
  final double? lon;
  final void Function(RoutePlan) onLoadTour;
  final void Function(Place) onGoTo;

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final _input = TextEditingController();

  GroupSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    s.addListener(_onChange);
    _tabs.addListener(_onChange);
    s.markRead();
  }

  @override
  void dispose() {
    s.removeListener(_onChange);
    _tabs.dispose();
    _input.dispose();
    super.dispose();
  }

  void _onChange() {
    // Chat offen: neue Nachrichten gelten als gelesen.
    if (_tabs.index == 0 && s.unread > 0) {
      scheduleMicrotask(s.markRead);
    }
    if (mounted) setState(() {});
  }

  /// Zur Karte zurueck und dort etwas tun.
  void _backToMap(VoidCallback then) {
    Navigator.of(context).popUntil((r) => r.isFirst);
    then();
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await s.sendChat(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(s.name ?? 'GRUPPE',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: signal,
          labelColor: chalk,
          unselectedLabelColor: steel,
          labelStyle: const TextStyle(fontSize: 11, letterSpacing: 1.6),
          tabs: [
            const Tab(text: 'CHAT'),
            Tab(text: 'AUSFAHRTEN (${s.upcoming.length})'),
            const Tab(text: 'MITGLIEDER'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_chat(), _rides(), _members()],
      ),
    );
  }

  // -------------------------------------------------------------------
  //  Chat
  // -------------------------------------------------------------------

  Widget _chat() {
    final msgs = s.chat.reversed.toList();
    return Column(children: [
      if (!widget.hub.online)
        Container(
          width: double.infinity,
          color: panel,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
              s.pending > 0
                  ? 'Offline - ${s.pending} Nachricht(en) warten und gehen raus, sobald Netz da ist.'
                  : 'Offline - neue Nachrichten kommen, sobald Netz da ist.',
              style: const TextStyle(fontSize: 10.5, color: amber)),
        ),
      Expanded(
        child: msgs.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'Noch keine Nachrichten. Schreib was - wer später '
                      'dazukommt, sieht die letzten 50 auch.',
                      textAlign: TextAlign.center,
                      style: _small),
                ),
              )
            : ListView.builder(
                reverse: true,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                itemCount: msgs.length,
                itemBuilder: (context, i) {
                  final m = msgs[i];
                  final older = i + 1 < msgs.length ? msgs[i + 1] : null;
                  return _bubble(m, showName: older?.fromId != m.fromId);
                },
              ),
      ),
      SafeArea(
        top: false,
        child: Container(
          color: panel,
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                maxLength: 1000,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: chalk, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'Nachricht',
                  counterText: '',
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            IconButton(
              tooltip: 'Senden',
              icon: const Icon(Icons.send, color: signal),
              onPressed: _send,
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _bubble(ChatMessage m, {required bool showName}) {
    final mine = m.fromId == s.myId;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: Container(
          margin: EdgeInsets.only(top: showName ? 8 : 3),
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: mine ? const Color(0xFF3A1A0C) : panel,
            border: Border.all(color: mine ? signal.withValues(alpha: 0.5) : line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showName && !mine)
                Text(m.from,
                    style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: cool)),
              SelectableText(m.text,
                  style: const TextStyle(fontSize: 14, color: chalk, height: 1.3)),
              const SizedBox(height: 2),
              Text(fmtWhen(m.at),
                  style: const TextStyle(fontSize: 9, color: steel)),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  //  Ausfahrten
  // -------------------------------------------------------------------

  Widget _rides() {
    final list = s.upcoming;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        FlatButton2(
          label: 'AUSFAHRT PLANEN',
          color: signal,
          fill: signal,
          strong: true,
          tall: true,
          onTap: _newRide,
        ),
        const SizedBox(height: 12),
        if (list.isEmpty)
          const Text(
              'Keine Ausfahrt geplant. Leg eine an - mit Zeit, Treffpunkt '
              'und auf Wunsch der Tour. Alle in der Gruppe können zu- oder '
              'absagen.',
              style: _small),
        for (final r in list) _rideCard(r),
      ],
    );
  }

  Widget _rideCard(RideEvent r) {
    final going = s.going(r.id);
    final mine = s.myRsvp(r.id);
    final tour = s.tourFor(r);
    final km = r.km;
    final me = widget.lat != null ? RoutePoint(widget.lat!, widget.lon!) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: panel,
        border: Border(left: BorderSide(color: amber, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(fmtWhen(r.when),
              style: const TextStyle(
                  fontSize: 12, letterSpacing: 1, color: amber)),
          const SizedBox(height: 2),
          Text(r.title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: chalk)),
          if (r.meetName != null || r.meet != null) ...[
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.place, size: 14, color: steel),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                    [
                      r.meetName ?? 'Treffpunkt',
                      if (me != null && r.meet != null)
                        _fmtDist(dist(me, r.meet!)),
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12, color: chalk)),
              ),
            ]),
          ],
          if (km != null) ...[
            const SizedBox(height: 2),
            Row(children: [
              const Icon(Icons.route, size: 14, color: steel),
              const SizedBox(width: 4),
              Text('Tour ${km.round()} km',
                  style: const TextStyle(fontSize: 12, color: chalk)),
            ]),
          ],
          const SizedBox(height: 6),
          Text(
              going.isEmpty
                  ? 'Noch keine Zusagen · angelegt von ${r.byName}'
                  : 'Dabei (${going.length}): ${going.join(', ')}',
              style: _small),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: FlatButton2(
                label: mine == true ? '✓ DABEI' : 'DABEI',
                color: signal,
                fill: mine == true ? signal : null,
                onTap: () => s.rsvp(r.id, true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FlatButton2(
                label: 'NICHT DABEI',
                color: mine == false ? amber : steel,
                onTap: () => s.rsvp(r.id, false),
              ),
            ),
          ]),
          Wrap(spacing: 4, children: [
            if (r.meet != null)
              TextButton.icon(
                icon: const Icon(Icons.navigation, size: 16, color: cool),
                label: const Text('ZUM TREFFPUNKT',
                    style: TextStyle(fontSize: 11, color: cool)),
                onPressed: () => _backToMap(() => widget.onGoTo(Place(
                      name: r.meetName ?? 'Treffpunkt ${r.title}',
                      lat: r.meet!.lat,
                      lon: r.meet!.lon,
                      kind: 'Treffpunkt',
                    ))),
              ),
            if (tour != null)
              TextButton.icon(
                icon: const Icon(Icons.download, size: 16, color: cool),
                label: const Text('TOUR LADEN',
                    style: TextStyle(fontSize: 11, color: cool)),
                onPressed: () => _backToMap(() => widget.onLoadTour(tour)),
              )
            else if (km != null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Tour wird geladen ...', style: _small),
              ),
            if (r.byId == s.myId)
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, size: 16, color: steel),
                label: const Text('ABSAGEN',
                    style: TextStyle(fontSize: 11, color: steel)),
                onPressed: () async {
                  final ok = await _confirm('Ausfahrt "${r.title}" absagen?',
                      'Sie verschwindet für alle.');
                  if (ok) await s.deleteRide(r.id);
                },
              ),
          ]),
        ],
      ),
    );
  }

  Future<void> _newRide() async {
    final r = await Navigator.push<RideEvent>(
      context,
      MaterialPageRoute(
        builder: (_) => RideEditScreen(
          session: s,
          route: widget.route,
          lat: widget.lat,
          lon: widget.lon,
        ),
      ),
    );
    if (r == null) return;
    await s.saveRide(r);
    // Wer plant, faehrt wohl mit.
    await s.rsvp(r.id, true);
  }

  // -------------------------------------------------------------------
  //  Mitglieder und Einstellungen
  // -------------------------------------------------------------------

  Widget _members() {
    final now = DateTime.now();
    final me = widget.lat != null ? RoutePoint(widget.lat!, widget.lon!) : null;
    final list = s.members.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const TinyLabel('GRUPPENCODE'),
        Row(children: [
          Expanded(
            child: SelectableText(s.code,
                style: const TextStyle(
                    fontSize: 22,
                    letterSpacing: 3,
                    fontWeight: FontWeight.w700,
                    color: cool)),
          ),
          IconButton(
            tooltip: 'Kopieren',
            icon: const Icon(Icons.copy, color: steel, size: 20),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: s.code));
              toast(context, 'Code kopiert');
            },
          ),
          IconButton(
            tooltip: 'Code teilen',
            icon: const Icon(Icons.share, color: cool),
            onPressed: () => SharePlus.instance.share(ShareParams(
              text: 'Komm in unsere Gruppe "${s.name ?? 'Motorrad'}" in der '
                  'Schräglage-App: Karte -> Gruppen-Symbol -> Mit Code '
                  'beitreten, Code ${s.code}',
            )),
          ),
        ]),
        const Text('Wer den Code hat, ist drin - nur an Leute geben, die '
            'mitlesen sollen.', style: _small),
        const SizedBox(height: 10),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          activeTrackColor: signal,
          inactiveTrackColor: line,
          title: const Text('Beim Fahren live sichtbar und Funk',
              style: TextStyle(fontSize: 12.5, color: chalk)),
          subtitle: const Text(
              'Position (während Aufzeichnung/Navi) und Sprachnachrichten '
              'gehen an diese Gruppe. Aus: nur Chat und Ausfahrten.',
              style: _small),
          value: s.shareLive,
          onChanged: (v) => widget.hub.setShareLive(s, v),
        ),
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.edit, color: steel, size: 20),
          title: const Text('Gruppe umbenennen',
              style: TextStyle(fontSize: 12.5, color: chalk)),
          onTap: () async {
            final n = await _askText(context,
                title: 'NAME DER GRUPPE', initial: s.name ?? '');
            if (n != null && n.trim().isNotEmpty) {
              await widget.hub.rename(s, n);
            }
          },
        ),
        if (widget.route != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.send, color: cool, size: 20),
            title: const Text('Meine Tour an die Gruppe schicken',
                style: TextStyle(fontSize: 12.5, color: chalk)),
            onTap: () async {
              await s.shareTour(widget.route!);
              if (mounted) toast(context, 'Tour an die Gruppe geschickt');
            },
          ),
        if (s.groupTour != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download, color: signal, size: 20),
            title: Text(
                'Tour von ${s.tourFrom ?? 'der Gruppe'} laden '
                '(${(s.groupTour!.distanceM / 1000).round()} km)',
                style: const TextStyle(fontSize: 12.5, color: chalk)),
            onTap: () => _backToMap(() => widget.onLoadTour(s.groupTour!)),
          ),
        const SizedBox(height: 10),
        TinyLabel('GERADE UNTERWEGS (${list.where((m) => !m.staleAt(now)).length})'),
        const SizedBox(height: 4),
        if (list.isEmpty)
          const Text('Niemand fährt gerade. Wer aufzeichnet oder navigiert, '
              'erscheint hier und auf der Karte.', style: _small),
        for (final m in list)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Icon(Icons.two_wheeler,
                  size: 16, color: m.staleAt(now) ? steel : cool),
              const SizedBox(width: 8),
              Expanded(
                child: Text(m.name,
                    style: const TextStyle(fontSize: 12.5, color: chalk)),
              ),
              Text(
                [
                  if (me != null) _fmtDist(dist(me, m.point)),
                  if (m.staleAt(now))
                    'vor ${_ago(now.difference(m.seen))}'
                  else
                    '${(m.speedMs * 3.6).round()} km/h',
                ].join(' · '),
                style: const TextStyle(fontSize: 10.5, color: steel),
              ),
            ]),
          ),
        if (s.voices.isNotEmpty) ...[
          const SizedBox(height: 10),
          const TinyLabel('FUNK (LETZTE SPRACHNACHRICHTEN)'),
          for (final v in s.voices.reversed)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.play_arrow, color: cool, size: 20),
              title: Text(
                  '${v.from} · ${v.duration.inSeconds} s · ${fmtClock(v.at)}',
                  style: const TextStyle(fontSize: 12, color: chalk)),
              onTap: () => Headset.instance.play(v.audio),
            ),
        ],
        const SizedBox(height: 16),
        FlatButton2(
          label: 'AUS GRUPPE AUSTRETEN',
          color: amber,
          onTap: () async {
            final ok = await _confirm('Aus "${s.name ?? s.code}" austreten?',
                'Chat und Ausfahrten verschwinden von diesem Handy. Mit dem '
                'Code kannst du später wieder beitreten.');
            if (!ok || !mounted) return;
            Navigator.pop(context);
            await widget.hub.leave(s);
          },
        ),
      ],
    );
  }

  static String _ago(Duration d) => d.inMinutes < 60
      ? '${d.inMinutes} min'
      : d.inHours < 24
          ? '${d.inHours} h'
          : '${d.inDays} Tagen';

  Future<bool> _confirm(String title, String text) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        shape: const RoundedRectangleBorder(),
        title: Text(title, style: const TextStyle(fontSize: 15, color: chalk)),
        content: Text(text, style: const TextStyle(fontSize: 12.5, color: steel)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('ABBRECHEN', style: TextStyle(color: steel))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('JA', style: TextStyle(color: signal))),
        ],
      ),
    );
    return r == true;
  }
}

/// Neue Ausfahrt: Titel, Tag, Uhrzeit, Treffpunkt, Tour.
class RideEditScreen extends StatefulWidget {
  const RideEditScreen({
    super.key,
    required this.session,
    this.route,
    this.lat,
    this.lon,
  });

  final GroupSession session;
  final RoutePlan? route;
  final double? lat;
  final double? lon;

  @override
  State<RideEditScreen> createState() => _RideEditScreenState();
}

class _RideEditScreenState extends State<RideEditScreen> {
  final _title = TextEditingController();
  late DateTime _day;
  TimeOfDay _time = const TimeOfDay(hour: 10, minute: 0);
  Place? _meet;
  bool _withTour = false;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    // Vorschlag: naechster Samstag (heute Samstag: heute).
    final add = (DateTime.saturday - n.weekday) % 7;
    _day = DateTime(n.year, n.month, n.day + add);
    _withTour = widget.route != null;
    final t = widget.route?.title;
    if (t != null) _title.text = t;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  DateTime get _when =>
      DateTime(_day.year, _day.month, _day.day, _time.hour, _time.minute);

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: _time,
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (t != null) setState(() => _time = t);
  }

  Future<void> _meetHere() async {
    if (widget.lat == null) {
      toast(context, 'Kein GPS - Treffpunkt auf der Karte wählen');
      return;
    }
    setState(() => _locating = true);
    final p = await Geocoder.reverse(widget.lat!, widget.lon!);
    if (!mounted) return;
    setState(() {
      _locating = false;
      _meet = p ??
          Place(
              name: 'Mein Standort',
              lat: widget.lat!,
              lon: widget.lon!,
              kind: 'Treffpunkt');
    });
  }

  Future<void> _meetOnMap() async {
    final p = await Navigator.push<Place>(
      context,
      MaterialPageRoute(
        builder: (_) => MapPickScreen(
            lat: _meet?.lat ?? widget.lat,
            lon: _meet?.lon ?? widget.lon,
            title: 'TREFFPUNKT'),
      ),
    );
    if (p != null && mounted) setState(() => _meet = p);
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      toast(context, 'Wie heißt die Ausfahrt?');
      return;
    }
    if (_when.isBefore(DateTime.now().subtract(const Duration(minutes: 5)))) {
      toast(context, 'Die Zeit liegt in der Vergangenheit');
      return;
    }
    final s = widget.session;
    Navigator.pop(
      context,
      RideEvent(
        id: GroupSession.newRideId(),
        title: title.length > 80 ? title.substring(0, 80) : title,
        when: _when,
        byName: s.myName,
        byId: s.myId,
        meet: _meet != null ? RoutePoint(_meet!.lat, _meet!.lon) : null,
        meetName: _meet?.name,
        tour: _withTour ? widget.route : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final days = [for (var i = 0; i < 21; i++) DateTime(n.year, n.month, n.day + i)];
    return Scaffold(
      appBar: AppBar(title: const Text('AUSFAHRT PLANEN')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          const TinyLabel('WAS'),
          TextField(
            controller: _title,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(color: chalk, fontSize: 15),
            decoration: const InputDecoration(
                hintText: 'z. B. Sauerland-Runde, Eis am Möhnesee'),
          ),
          const SizedBox(height: 8),
          const TinyLabel('WANN'),
          const SizedBox(height: 6),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final d in days)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(
                        d == today
                            ? 'Heute'
                            : d.difference(today).inDays == 1
                                ? 'Morgen'
                                : '${_weekdays[d.weekday - 1]} ${d.day}.${d.month}.',
                        style: TextStyle(
                            fontSize: 12,
                            color: d == _day ? asphalt : chalk),
                      ),
                      selected: d == _day,
                      selectedColor: signal,
                      backgroundColor: panel,
                      showCheckmark: false,
                      shape: const RoundedRectangleBorder(),
                      onSelected: (_) => setState(() => _day = d),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          InkWell(
            onTap: _pickTime,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: panel,
              child: Row(children: [
                const Icon(Icons.schedule, color: steel, size: 20),
                const SizedBox(width: 10),
                Text('${_two(_time.hour)}:${_two(_time.minute)} Uhr',
                    style: const TextStyle(fontSize: 16, color: chalk)),
                const Spacer(),
                const Text('ÄNDERN', style: TextStyle(fontSize: 10.5, color: cool)),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          const TinyLabel('TREFFPUNKT'),
          const SizedBox(height: 6),
          if (_meet != null)
            Container(
              padding: const EdgeInsets.all(12),
              color: panel,
              child: Row(children: [
                const Icon(Icons.place, color: signal, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_meet!.name,
                      style: const TextStyle(fontSize: 13.5, color: chalk)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: steel, size: 18),
                  onPressed: () => setState(() => _meet = null),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: FlatButton2(
                label: _locating ? '...' : 'MEIN STANDORT',
                color: cool,
                onTap: _locating ? null : _meetHere,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FlatButton2(
                label: 'AUF KARTE WÄHLEN',
                color: cool,
                onTap: _meetOnMap,
              ),
            ),
          ]),
          if (widget.route != null) ...[
            const SizedBox(height: 10),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              activeTrackColor: signal,
              inactiveTrackColor: line,
              title: Text(
                  'Aktuelle Tour anhängen '
                  '(${(widget.route!.distanceM / 1000).round()} km)',
                  style: const TextStyle(fontSize: 12.5, color: chalk)),
              subtitle: const Text(
                  'Alle können sie mit einem Tipp laden und nachfahren.',
                  style: _small),
              value: _withTour,
              onChanged: (v) => setState(() => _withTour = v),
            ),
          ],
          const SizedBox(height: 18),
          FlatButton2(
            label: 'AUSFAHRT ANLEGEN',
            color: signal,
            fill: signal,
            strong: true,
            tall: true,
            onTap: _save,
          ),
        ],
      ),
    );
  }
}

/// Kurze Texteingabe im Dialog.
Future<String?> _askText(BuildContext context,
    {required String title,
    String hint = '',
    String initial = '',
    bool caps = false}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(),
      title: Text(title,
          style: const TextStyle(fontSize: 13, letterSpacing: 2, color: chalk)),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLength: 40,
        textCapitalization:
            caps ? TextCapitalization.characters : TextCapitalization.words,
        style: TextStyle(color: chalk, letterSpacing: caps ? 2 : 0),
        decoration: InputDecoration(hintText: hint, counterText: ''),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ABBRECHEN', style: TextStyle(color: steel))),
        TextButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('OK', style: TextStyle(color: signal))),
      ],
    ),
  ).whenComplete(() => WidgetsBinding.instance
      .addPostFrameCallback((_) => c.dispose()));
}
