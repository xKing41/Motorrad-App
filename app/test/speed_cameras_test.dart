import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/speed_cameras.dart';

void main() {
  test('Abfrage sucht nur feste Blitzer im Streifen um die Route', () {
    final q = SpeedCameras.query(const [
      RoutePoint(48.0, 9.0),
      RoutePoint(48.1, 9.1),
    ]);
    expect(q, contains('"highway"="speed_camera"'));
    expect(q, contains('around:150,'));
  });

  test('Antwort: doppelte Eintraege einmal, Limit gelesen', () {
    final c = SpeedCameras.parse({
      'elements': [
        {'id': 1, 'lat': 48.0, 'lon': 9.0, 'tags': {'maxspeed': '70'}},
        {'id': 2, 'lat': 48.00001, 'lon': 9.00001, 'tags': {}},
        {'id': 3, 'lat': 48.2, 'lon': 9.2, 'tags': {'maxspeed': '50 km/h'}},
        {'id': 4},
      ],
    });
    expect(c.length, 2);
    expect(c[0].kmh, 70);
    expect(c[1].kmh, 50);
  });
}
