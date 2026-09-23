import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/ride.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/gpx_service.dart';

void main() {
  test('lon vor lat und einfache Anfuehrungszeichen werden erkannt', () {
    const xml = '''<?xml version="1.0"?>
<gpx version="1.1"><trk><name>Test &amp; Tour</name><trkseg>
  <trkpt lon='7.1' lat='51.1'></trkpt>
  <trkpt lat="51.2" lon="7.2"/>
  <trkpt lon="7.3" lat="51.3"><ele>200</ele></trkpt>
</trkseg></trk></gpx>''';
    final plan = GpxService.parseRoute(xml);
    expect(plan.points.length, 3);
    expect(plan.points.first.lat, 51.1);
    expect(plan.points.first.lon, 7.1);
    expect(plan.title, 'Test & Tour');
  });

  test('Track hat Vorrang, Wegpunkte werden Markierungen', () {
    const xml = '''<gpx>
<wpt lat="50.0" lon="8.0"><name>Tanken</name></wpt>
<metadata><name>Datei</name></metadata>
<rte><name>Grobe Route</name><rtept lat="51.0" lon="7.0"/><rtept lat="51.5" lon="7.5"/></rte>
<trk><name>Genaue Spur</name><trkseg>
<trkpt lat="51.0" lon="7.0"/><trkpt lat="51.1" lon="7.1"/><trkpt lat="51.2" lon="7.2"/>
</trkseg></trk></gpx>''';
    final plan = GpxService.parseRoute(xml);
    expect(plan.points.length, 3);
    expect(plan.title, 'Genaue Spur');
    expect(plan.pois.single.name, 'Tanken');
    expect(plan.pois.single.lat, 50.0);
  });

  test('nur Routenpunkte: die bilden die Linie', () {
    const xml = '<gpx><rte><rtept lat="51.0" lon="7.0"/><rtept lat="51.5" lon="7.5"/></rte></gpx>';
    final plan = GpxService.parseRoute(xml);
    expect(plan.points.length, 2);
    expect(plan.distanceM, greaterThan(60000));
  });

  test('Export als Track laesst sich wieder einlesen', () {
    final plan = RoutePlan(
      points: const [RoutePoint(51.0, 7.0), RoutePoint(51.1, 7.1)],
      distanceM: 13000,
      title: 'Runde <1>',
      pois: [
        Poi(id: 'x', kind: PoiKind.fuel, lat: 51.05, lon: 7.05, name: 'Aral'),
      ],
    );
    final xml = GpxService.routeToGpx(plan);
    expect(xml, contains('<trk>'));
    expect(xml, isNot(contains('<rte>')));
    final back = GpxService.parseRoute(xml);
    expect(back.points.length, 2);
    expect(back.title, 'Runde <1>');
    expect(back.pois.single.name, 'Aral');
  });

  test('Fahrt-Export: Erweiterungen im eigenen Namensraum', () {
    final xml = GpxService.trackToGpx(
      RideSummary(
        id: 'r1',
        start: DateTime(2026, 5, 1),
        durationSec: 60,
        distanceM: 100,
        maxLeanL: 10,
        maxLeanR: 12,
        maxSpeedMs: 10,
        maxBrakeG: 0.3,
        maxLatG: 0.2,
        pointCount: 1,
      ),
      [
        TrackPoint(
            lat: 51, lon: 7, tMs: 0, speedMs: 10.5, lean: -12.3, altM: 150),
      ],
    );
    expect(xml, contains('xmlns:sl='));
    expect(xml, contains('<sl:lean>-12.3</sl:lean>'));
    // ele muss laut Schema vor time stehen.
    expect(xml.indexOf('<ele>'), lessThan(xml.indexOf('<time>')));
    expect(GpxService.parseRoute(xml).points.length, 1);
  });

  test('Dateinamen werden bereinigt', () {
    expect(GpxService.safeFileName('Rundtour · 152 km.gpx'), 'Rundtour_152_km.gpx');
    expect(GpxService.safeFileName('***'), 'route.gpx');
  });

  test('Umlaute als Zahlen-Entities im Namen', () {
    const xml = '<gpx><trk><name>R&#252;ckweg &#x00FC;ber M&amp;M</name>'
        '<trkseg><trkpt lat="51" lon="7"/><trkpt lat="51.1" lon="7"/>'
        '</trkseg></trk></gpx>';
    expect(GpxService.parseRoute(xml).title, 'Rückweg über M&M');
  });
}
