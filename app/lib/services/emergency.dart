import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Notfalldaten des Fahrers und der Versand einer Notfallnachricht.
///
/// Bewusst ohne Server und ohne Konto: Die Daten bleiben auf dem Geraet,
/// die Nachricht geht ueber die normale SMS-App des Handys raus. Damit
/// funktioniert es auch dann, wenn kein mobiles Internet steht - SMS
/// braucht nur Netz, keine Datenverbindung.
class Emergency {
  Emergency._();
  static final Emergency instance = Emergency._();

  String contactName = '';
  String contactPhone = '';
  String riderName = '';
  String bloodGroup = '';
  String medical = ''; // Allergien, Medikamente, Vorerkrankungen
  String insurance = '';
  bool autoDetect = true; // Sturzerkennung aktiv?
  int countdownSec = 30;

  bool get hasContact => contactPhone.trim().length >= 5;

  // -----------------------------------------------------------------
  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    contactName = sp.getString('em_name') ?? '';
    contactPhone = sp.getString('em_phone') ?? '';
    riderName = sp.getString('em_rider') ?? '';
    bloodGroup = sp.getString('em_blood') ?? '';
    medical = sp.getString('em_medical') ?? '';
    insurance = sp.getString('em_insurance') ?? '';
    autoDetect = sp.getBool('em_auto') ?? true;
    countdownSec = sp.getInt('em_countdown') ?? 30;
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('em_name', contactName.trim());
    await sp.setString('em_phone', contactPhone.trim());
    await sp.setString('em_rider', riderName.trim());
    await sp.setString('em_blood', bloodGroup.trim());
    await sp.setString('em_medical', medical.trim());
    await sp.setString('em_insurance', insurance.trim());
    await sp.setBool('em_auto', autoDetect);
    await sp.setInt('em_countdown', countdownSec);
  }

  // -----------------------------------------------------------------
  /// Text der Notfallnachricht. Koordinaten in Dezimalgrad, dazu ein
  /// Kartenlink - beides, weil manche Handys Links nicht anzeigen und
  /// die Rettungsleitstelle mit reinen Zahlen ebenfalls arbeiten kann.
  String alertText({double? lat, double? lon, String? extra}) {
    final who = riderName.trim().isEmpty ? 'Der Fahrer' : riderName.trim();
    final b = StringBuffer()
      ..write('NOTFALL: $who hatte möglicherweise einen Motorradunfall.');
    if (lat != null && lon != null) {
      final la = lat.toStringAsFixed(5);
      final lo = lon.toStringAsFixed(5);
      b.write(' Letzte Position: $la, $lo');
      b.write(' – https://www.openstreetmap.org/?mlat=$la&mlon=$lo#map=17/$la/$lo');
    } else {
      b.write(' Position unbekannt (kein GPS).');
    }
    if (bloodGroup.trim().isNotEmpty) {
      b.write(' Blutgruppe: ${bloodGroup.trim()}.');
    }
    if (medical.trim().isNotEmpty) {
      b.write(' Medizinisch: ${medical.trim()}.');
    }
    if (extra != null && extra.trim().isNotEmpty) {
      b.write(' $extra');
    }
    b.write(' (Automatisch erzeugt von der Schräglage-App.)');
    return b.toString();
  }

  /// Oeffnet die SMS-App mit vorbereiteter Nachricht an den Notfallkontakt.
  ///
  /// Absichtlich NICHT vollautomatisch: Ein stiller SMS-Versand braucht
  /// eine Berechtigung, die Android sehr restriktiv behandelt, und ein
  /// automatischer Fehlalarm an die Familie waere schlimmer als ein
  /// zusaetzlicher Tastendruck.
  Future<bool> sendSms({double? lat, double? lon}) async {
    if (!hasContact) return false;
    final body = Uri.encodeComponent(alertText(lat: lat, lon: lon));
    final uri = Uri.parse('sms:${contactPhone.trim()}?body=$body');
    return _open(uri);
  }

  /// Ruft den Notfallkontakt an.
  Future<bool> callContact() async {
    if (!hasContact) return false;
    return _open(Uri.parse('tel:${contactPhone.trim()}'));
  }

  /// Ruft den europaeischen Notruf.
  Future<bool> callEmergencyNumber() => _open(Uri.parse('tel:112'));

  Future<bool> _open(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
