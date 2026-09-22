import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/route_plan.dart';

/// KI-Schicht der Routenplanung.
///
/// ============================================================
///  ARCHITEKTUR - bitte beim Weiterbauen beibehalten
/// ============================================================
///  Das Sprachmodell berechnet KEINE Route und erfindet KEINE Orte.
///  Es hat genau zwei Aufgaben:
///
///   1) Uebersetzen:  Freitext  ->  RouteRequest (Zahlen und Flags)
///   2) Erzaehlen:    fertige Route + echte POIs  ->  schoener Text
///
///  Dazwischen liegt immer echte Technik:
///   Freitext -> [AiRoutePlanner.interpret] -> RouteRequest
///            -> GraphHopper (echte Strassen)
///            -> PoiService/Overpass (echte Orte)
///            -> [AiRoutePlanner.describe] -> Text fuer den Fahrer
///
///  Warum so streng? Ein Modell, das Koordinaten frei erfindet, schickt
///  den Fahrer zu einer Tankstelle, die es nicht gibt. Im Wohnzimmer ist
///  das ein Fehler, auf dem Motorrad mit Restreichweite ein Problem.
/// ============================================================
///
///  SICHERHEITSHINWEIS ZUM SCHLUESSEL
///  Ein API-Schluessel in der App ist auslesbar. Fuer eigene Tests auf dem
///  eigenen Geraet ist das in Ordnung. Sobald die App an andere geht, muss
///  der Aufruf ueber einen eigenen kleinen Server laufen, der den
///  Schluessel haelt - dann hier einfach [baseUrl] auf diesen Server
///  zeigen lassen und [apiKey] leer lassen.
class AiRoutePlanner {
  AiRoutePlanner({
    this.apiKey,
    this.baseUrl = 'https://api.anthropic.com/v1/messages',
    // Laut Anthropic-Doku ist claude-sonnet-5 der direkte Nachfolger
    // von claude-sonnet-4-6. Wird von AiConfig ueberschrieben.
    this.model = 'claude-sonnet-5',
  });

  /// Nur fuer die Testphase direkt im Geraet. Fuer den Livebetrieb leer
  /// lassen und [baseUrl] auf den eigenen Server richten.
  final String? apiKey;
  final String baseUrl;
  final String model;

  bool get isConfigured => (apiKey?.isNotEmpty ?? false) || !baseUrl.contains('anthropic.com');

  static const String _systemPrompt = '''
Du bist der Tourenplaner einer Motorrad-App. Du sprichst Deutsch.

Deine Aufgabe: Wandle den Wunsch des Fahrers in Planungsparameter um.

STRIKTE REGELN:
- Antworte AUSSCHLIESSLICH mit einem JSON-Objekt. Kein Text davor oder danach,
  keine Code-Bloecke, keine Erklaerung.
- Erfinde NIEMALS Koordinaten, Ortsnamen, Tankstellen oder Adressen.
  Du benennst nur die ART des Stopps, nicht den konkreten Ort.
  Den echten Ort sucht die App anschliessend in den Kartendaten.
- Wenn eine Angabe fehlt, waehle einen vernuenftigen Standardwert,
  statt nachzufragen.
- Sicherheit geht vor: Wuensche nach Rekorden, Hoechstgeschwindigkeiten
  oder maximaler Schraeglage setzt du NICHT um. Plane in dem Fall eine
  normale kurvige Tour und setze "safety_note".

Erlaubte Werte:
  curviness: "direct" | "balanced" | "curvy" | "very_curvy"
  stops[].kind: "fuel" | "viewpoint" | "food" | "rest" | "water" | "workshop"

Antwortformat:
$routeRequestSchema

Zusaetzlich erlaubt: "safety_note" (kurzer Hinweistext) und
"reply" (ein bis zwei Saetze, was du geplant hast).
''';

  /// Schritt 1: Freitext -> strukturierte Anfrage.
  ///
  /// [startLat]/[startLon] kommen IMMER von der App (aktuelle Position),
  /// niemals vom Modell.
  Future<AiInterpretation> interpret({
    required String userText,
    required double startLat,
    required double startLon,
    List<Map<String, String>> history = const [],
  }) async {
    final messages = <Map<String, dynamic>>[
      for (final h in history)
        {'role': h['role'], 'content': h['content']},
      {'role': 'user', 'content': userText},
    ];

    final headers = _headers();

    http.Response res;
    try {
      res = await http
          .post(
            Uri.parse(baseUrl),
            headers: headers,
            body: jsonEncode({
              'model': model,
              'max_tokens': 1200,
              'system': _systemPrompt,
              'messages': messages,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw AiException('KI nicht erreichbar. Internetverbindung pruefen.');
    }

    if (res.statusCode != 200) {
      throw AiException(
          _errorFor(res.statusCode, utf8.decode(res.bodyBytes)));
    }

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final text = _extractText(data);
    final json = _extractJson(text);
    if (json == null) {
      throw AiException('Antwort der KI war nicht verwertbar. '
          'Bitte den Wunsch etwas anders formulieren.');
    }

    return AiInterpretation(
      request: RouteRequest.fromModelJson(
        json,
        fallbackLat: startLat,
        fallbackLon: startLon,
      ),
      reply: json['reply'] as String?,
      safetyNote: json['safety_note'] as String?,
      raw: text,
    );
  }

  /// Schritt 2: fertige Route + ECHTE Orte -> Beschreibungstext.
  /// Dem Modell werden hier nur bereits verifizierte Daten gegeben.
  Future<String?> describe({
    required RoutePlan plan,
    required String userText,
  }) async {
    final facts = {
      'distance_km': plan.distanceKm.round(),
      'duration_min': (plan.durationSec / 60).round(),
      'stops': plan.pois
          .map((p) => {'kind': p.kind.label, 'name': p.displayName})
          .toList(),
    };

    final headers = _headers();

    try {
      final res = await http
          .post(
            Uri.parse(baseUrl),
            headers: headers,
            body: jsonEncode({
              'model': model,
              'max_tokens': 500,
              'system': 'Du beschreibst Motorradtouren kurz und sachlich auf '
                  'Deutsch, hoechstens drei Saetze. Nutze AUSSCHLIESSLICH die '
                  'uebergebenen Fakten. Erfinde keine Orte, Strassennamen oder '
                  'Sehenswuerdigkeiten. Keine Aufforderung zu schnellem Fahren.',
              'messages': [
                {
                  'role': 'user',
                  'content': 'Wunsch war: "$userText"\n'
                      'Geplante Route (Fakten): ${jsonEncode(facts)}',
                }
              ],
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) return null;
      return _extractText(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Kopfzeilen der Anfrage. Im Server-Modus wird KEIN Schluessel
  /// mitgesendet - dann haelt der eigene Server ihn.
  Map<String, String> _headers() {
    final h = <String, String>{'Content-Type': 'application/json'};
    if (apiKey?.isNotEmpty ?? false) {
      h['x-api-key'] = apiKey!;
      h['anthropic-version'] = '2023-06-01';
    }
    return h;
  }

  /// Prueft die Zugangsdaten mit einer sehr kleinen echten Anfrage.
  ///
  /// Rueckgabe: null = alles in Ordnung, sonst der Fehlertext fuer den
  /// Nutzer. So merkt man einen falschen Schluessel sofort beim
  /// Einrichten und nicht erst unterwegs am Strassenrand.
  Future<String?> testConnection() async {
    try {
      final res = await http
          .post(
            Uri.parse(baseUrl),
            headers: _headers(),
            body: jsonEncode({
              'model': model,
              'max_tokens': 16,
              'messages': [
                {'role': 'user', 'content': 'Antworte nur mit: OK'}
              ],
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) return null;
      return _errorFor(res.statusCode, utf8.decode(res.bodyBytes));
    } on TimeoutException {
      return 'Zeitüberschreitung. Internetverbindung prüfen.';
    } catch (_) {
      return 'Keine Verbindung möglich. Adresse und Internetverbindung prüfen.';
    }
  }

  /// Uebersetzt einen HTTP-Statuscode in etwas, mit dem man auch am
  /// Strassenrand etwas anfangen kann.
  static String _errorFor(int code, String body) {
    final detail = _apiMessage(body);
    final suffix = detail.isEmpty ? '' : ' ($detail)';
    if (code == 401 || code == 403) {
      return 'Schlüssel wurde nicht akzeptiert (Code $code). '
          'Bitte unter KI VERBINDEN prüfen.$suffix';
    }
    if (code == 402) {
      return 'Kein Guthaben auf dem API-Konto (Code 402).$suffix';
    }
    if (code == 404) {
      return 'Adresse oder Modell nicht gefunden (Code 404). '
          'Modellnamen prüfen.$suffix';
    }
    if (code == 429) {
      return 'Zu viele Anfragen (Code 429). Kurz warten, dann erneut.$suffix';
    }
    if (code == 400) {
      return 'Anfrage wurde abgelehnt (Code 400).$suffix';
    }
    if (code >= 500) {
      return 'Der KI-Dienst ist gerade überlastet (Code $code). '
          'Bitte in einem Moment erneut versuchen.';
    }
    return 'KI-Anfrage fehlgeschlagen (Code $code).$suffix';
  }

  /// Holt den Klartext aus einer Fehlerantwort, gekuerzt.
  static String _apiMessage(String body) {
    try {
      final m = jsonDecode(body);
      if (m is Map && m['error'] is Map) {
        final msg = (m['error'] as Map)['message'];
        if (msg is String && msg.isNotEmpty) {
          return msg.length > 140 ? '${msg.substring(0, 140)}…' : msg;
        }
      }
    } catch (_) {
      // Antwort war kein JSON - dann eben ohne Detail.
    }
    return '';
  }

  static String _extractText(Map<String, dynamic> data) {
    final content = (data['content'] as List?) ?? const [];
    final buf = StringBuffer();
    for (final c in content) {
      if (c is Map && c['type'] == 'text') buf.write(c['text']);
    }
    return buf.toString().trim();
  }

  /// Holt das JSON-Objekt aus der Antwort, auch wenn doch Text
  /// oder Code-Zaeune drumherum stehen.
  static Map<String, dynamic>? _extractJson(String text) {
    var t = text.trim();
    t = t.replaceAll(RegExp(r'^```(?:json)?', multiLine: true), '');
    t = t.replaceAll('```', '').trim();
    final start = t.indexOf('{');
    final end = t.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final v = jsonDecode(t.substring(start, end + 1));
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}

class AiInterpretation {
  AiInterpretation({
    required this.request,
    this.reply,
    this.safetyNote,
    this.raw,
  });

  final RouteRequest request;
  final String? reply;
  final String? safetyNote;
  final String? raw;
}

class AiException implements Exception {
  AiException(this.message);
  final String message;
  @override
  String toString() => message;
}
