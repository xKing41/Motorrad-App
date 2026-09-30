import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/route_plan.dart';
import '../services/curve_warning.dart';
import '../services/lanes.dart';
import '../services/speed_limits.dart';
import '../theme.dart';

// ---------------------------------------------------------------------------
//  Bausteine fuer Karte und Navigation - gross, kontrastreich, mit
//  Handschuhen zu bedienen. Ausgelagert aus der Kartenansicht.
// ---------------------------------------------------------------------------

/// "350 m", "1,2 km", "123 km".
String fmtDist(double m) {
  if (m < 0) m = 0;
  if (m < 1000) {
    final r = m < 200 ? (m / 10).round() * 10 : (m / 50).round() * 50;
    return '$r m';
  }
  return fmtKm(m);
}

String fmtKm(double m) =>
    '${(m / 1000).toStringAsFixed(m >= 100000 ? 0 : 1).replaceAll('.', ',')} km';

String clockText(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String fmtDuration(int sec) {
  final h = sec ~/ 3600;
  final m = ((sec % 3600) / 60).round();
  if (h == 0) return '$m min';
  return '$h h ${m.toString().padLeft(2, '0')} min';
}

IconData trafficIcon(TrafficCategory c) => switch (c) {
      TrafficCategory.jam => Icons.traffic,
      TrafficCategory.closed => Icons.block,
      TrafficCategory.laneClosed => Icons.merge,
      TrafficCategory.roadworks => Icons.construction,
      TrafficCategory.accident => Icons.car_crash,
      TrafficCategory.weather => Icons.cloud,
      _ => Icons.warning_amber,
    };

IconData maneuverIcon(int type) => switch (type) {
      ManeuverType.start => Icons.trip_origin,
      ManeuverType.slightRight => Icons.turn_slight_right,
      ManeuverType.right => Icons.turn_right,
      ManeuverType.sharpRight => Icons.turn_sharp_right,
      ManeuverType.uturnRight => Icons.u_turn_right,
      ManeuverType.uturnLeft => Icons.u_turn_left,
      ManeuverType.sharpLeft => Icons.turn_sharp_left,
      ManeuverType.left => Icons.turn_left,
      ManeuverType.slightLeft => Icons.turn_slight_left,
      ManeuverType.rampRight || ManeuverType.exitRight => Icons.ramp_right,
      ManeuverType.rampLeft || ManeuverType.exitLeft => Icons.ramp_left,
      ManeuverType.stayRight => Icons.fork_right,
      ManeuverType.stayLeft => Icons.fork_left,
      ManeuverType.merge => Icons.merge,
      ManeuverType.roundaboutEnter || ManeuverType.roundaboutExit =>
        Icons.roundabout_right,
      ManeuverType.ferry => Icons.directions_boat,
      _ when ManeuverType.isDestination(type) => Icons.flag,
      _ => Icons.straight,
    };

IconData poiIcon(PoiKind k) => switch (k) {
      PoiKind.fuel => Icons.local_gas_station,
      PoiKind.viewpoint => Icons.photo_camera,
      PoiKind.food => Icons.restaurant,
      PoiKind.rest => Icons.park,
      PoiKind.water => Icons.water_drop,
      PoiKind.workshop => Icons.build,
    };

Color poiColor(PoiKind k) => switch (k) {
      PoiKind.fuel => amber,
      PoiKind.viewpoint => cool,
      PoiKind.food => go,
      _ => steel,
    };

/// Spuren wie auf dem Schild: empfohlene hell, andere grau.
class LaneRow extends StatelessWidget {
  const LaneRow(this.info, {super.key});
  final LaneInfo info;

  static IconData _icon(Set<String> ind) {
    bool has(String x) => ind.contains(x);
    if (has('reverse')) return Icons.u_turn_left;
    if (has('left') || has('sharp_left')) return Icons.turn_left;
    if (has('right') || has('sharp_right')) return Icons.turn_right;
    if (has('slight_left') || has('merge_to_left')) return Icons.turn_slight_left;
    if (has('slight_right') || has('merge_to_right')) {
      return Icons.turn_slight_right;
    }
    return Icons.straight;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: asphalt,
        border: Border.all(color: line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < info.lanes.length; i++) ...[
          if (i > 0)
            Container(width: 1, height: 30, color: steel.withValues(alpha: 0.5)),
          SizedBox(
            width: 40,
            child: Icon(_icon(info.lanes[i].indications),
                size: 32,
                color: info.lanes[i].recommended
                    ? chalk
                    : steel.withValues(alpha: 0.45)),
          ),
        ],
      ]),
    );
  }
}

/// Warnung vor einer engen Kurve: Richtung, Entfernung, Richttempo.
class CurveChip extends StatelessWidget {
  const CurveChip(this.curve, this.distM, {super.key});
  final RoadCurve curve;
  final double distM;

  @override
  Widget build(BuildContext context) {
    final c = curve;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: amber,
        border: Border.all(color: Colors.black26),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
            c.hairpin
                ? (c.right ? Icons.u_turn_right : Icons.u_turn_left)
                : (c.right ? Icons.turn_sharp_right : Icons.turn_sharp_left),
            size: 32,
            color: Colors.black),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(c.label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: Colors.black)),
              Text(
                  '${distM < 20 ? 'jetzt' : fmtDist(distM)} · '
                  'ca. ${c.adviseKmh} km/h',
                  style: const TextStyle(fontSize: 16, color: Colors.black)),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Tempolimit-Schild wie an der Strasse; bei zu hohem Tempo rot
/// hinterlegt, daneben das eigene Tempo.
class LimitSign extends StatelessWidget {
  const LimitSign(this.limit,
      {super.key, required this.speeding, required this.speedKmh});
  final SpeedLimit limit;
  final bool speeding;
  final double speedKmh;

  @override
  Widget build(BuildContext context) {
    final l = limit;
    final sign = Container(
      width: 70,
      height: 70,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: speeding ? redline : Colors.white,
        shape: BoxShape.circle,
        border: Border.all(
            color: l.isUnlimited ? Colors.black54 : redline, width: 5.5),
      ),
      child: l.isUnlimited
          ? Transform.rotate(
              angle: -math.pi / 4,
              child: Container(width: 52, height: 4, color: Colors.black54),
            )
          : Text('${l.kmh}',
              style: TextStyle(
                  fontSize: l.kmh >= 100 ? 24 : 30,
                  fontWeight: FontWeight.w800,
                  color: speeding ? Colors.white : Colors.black)),
    );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      sign,
      if (speeding) ...[
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: panel.withValues(alpha: 0.94),
          child: Text('${speedKmh.round()}',
              style: const TextStyle(
                  fontSize: 32, fontWeight: FontWeight.w800, color: redline)),
        ),
      ],
    ]);
  }
}

/// Kartenknopf mit Symbol und Beschriftung. Waehrend der Navigation
/// groesser ([big]) - mit Handschuhen trifft man kleine Flaechen schlecht.
class MapButton extends StatelessWidget {
  const MapButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.big = false,
    this.onLongPress,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool big;
  final VoidCallback? onLongPress;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? (active ? signal : chalk);
    return Material(
      color: panel.withValues(alpha: 0.96),
      shape: BeveledRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(7)),
        side: BorderSide(color: active ? signal : line, width: active ? 2 : 1.5),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: big ? kTouchRide + 8 : 62),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: big ? 32 : 27, color: c),
                const SizedBox(height: 3),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: big ? 14 : 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: c)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Runder Kartenknopf am rechten Rand, gross genug fuer Handschuhe.
class RailButton extends StatelessWidget {
  const RailButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = chalk,
    this.dot,
    this.label,
    this.progress,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;
  final Color? dot;
  final String? label;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: panel.withValues(alpha: 0.95),
        shape: const CircleBorder(side: BorderSide(color: line, width: 1.5)),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 58,
            height: 58,
            child: Stack(alignment: Alignment.center, children: [
              if (progress != null)
                SizedBox(
                  width: 52,
                  height: 52,
                  child: CircularProgressIndicator(
                      value: progress, strokeWidth: 3, color: cool),
                ),
              Icon(icon, size: 30, color: color),
              if (label != null)
                Positioned(
                  bottom: 5,
                  child: Text(label!,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: color)),
                ),
              if (dot != null)
                Positioned(
                  top: 7,
                  right: 7,
                  child: Container(
                    width: 13,
                    height: 13,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                      border: Border.all(color: panel, width: 2),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Grosse Kachel fuer Menues (auch mit Handschuh gut zu treffen).
class MenuTile extends StatelessWidget {
  const MenuTile(this.icon, this.title, this.sub, this.onTap,
      {super.key, this.color = chalk, this.active = false, this.onLongPress});

  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback onTap;
  final Color color;
  final bool active;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? color.withValues(alpha: 0.14) : panel2,
      shape: BeveledRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: active ? color : line, width: 1.5),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 84),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 30, color: color),
                const SizedBox(height: 6),
                Text(title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800, color: chalk)),
                if (sub.isNotEmpty)
                  Text(sub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, color: steel)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Kacheln, zwei je Reihe.
Widget tileGrid(List<Widget> tiles) {
  final rows = <Widget>[];
  for (var i = 0; i < tiles.length; i += 2) {
    rows.add(Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: tiles[i]),
          const SizedBox(width: 10),
          Expanded(child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox()),
        ]),
      ),
    ));
  }
  return Column(mainAxisSize: MainAxisSize.min, children: rows);
}
