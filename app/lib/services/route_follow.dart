import '../models/ride.dart';
import '../models/route_plan.dart';

/// Zustand beim Abfahren einer Route.
class FollowState {
  FollowState({
    required this.nearestIndex,
    required this.offRouteM,
    required this.remainingM,
    required this.progress,
  });

  /// Index des naechstgelegenen Routenpunktes.
  final int nearestIndex;

  /// Abstand zur Route in Metern.
  final double offRouteM;

  /// Reststrecke bis zum Ziel in Metern.
  final double remainingM;

  /// Fortschritt 0..1
  final double progress;

  bool get isOffRoute => offRouteM > 80;
  double get remainingKm => remainingM / 1000;
}

/// Begleitet das Abfahren einer Route: sucht den naechsten Punkt,
/// misst den Abstand und rechnet die Reststrecke aus.
///
/// Bewusst schlank: kein Neuberechnen, kein Abbiegen-Ansagen. Das ist
/// der "Follow-Modus" - die Route liegt auf der Karte, der Fahrer sieht
/// wo er ist. Turn-by-turn kommt spaeter obendrauf.
class RouteFollower {
  RouteFollower(this.plan) {
    _cum = <double>[0];
    for (var i = 1; i < plan.points.length; i++) {
      _cum.add(_cum[i - 1] +
          distanceMeters(plan.points[i - 1].lat, plan.points[i - 1].lon,
              plan.points[i].lat, plan.points[i].lon));
    }
  }

  final RoutePlan plan;
  late final List<double> _cum;
  int _lastIndex = 0;

  double get totalM => _cum.isEmpty ? 0 : _cum.last;

  FollowState? update(double lat, double lon) {
    if (plan.points.length < 2) return null;

    // Zuerst im Fenster um die letzte Position suchen (schnell),
    // bei zu grossem Abstand die ganze Route absuchen.
    var best = _searchWindow(lat, lon, _lastIndex - 30, _lastIndex + 120);
    if (best.value > 200) {
      best = _searchWindow(lat, lon, 0, plan.points.length);
    }
    _lastIndex = best.key;

    final remaining = (totalM - _cum[best.key]).clamp(0.0, totalM);
    return FollowState(
      nearestIndex: best.key,
      offRouteM: best.value,
      remainingM: remaining,
      progress: totalM > 0 ? _cum[best.key] / totalM : 0,
    );
  }

  MapEntry<int, double> _searchWindow(
      double lat, double lon, int from, int to) {
    final a = from.clamp(0, plan.points.length - 1);
    final b = to.clamp(1, plan.points.length);
    var bestIdx = a;
    var bestDist = double.infinity;
    for (var i = a; i < b; i++) {
      final d = distanceMeters(lat, lon, plan.points[i].lat, plan.points[i].lon);
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return MapEntry(bestIdx, bestDist);
  }

  void reset() => _lastIndex = 0;
}
