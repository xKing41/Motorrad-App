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
- Erfinde NIEMALS Koordinaten, Tankstellen oder Adressen. Stopps benennst du
  nur nach ihrer ART - den echten Ort sucht die App in den Kartendaten.
- Ortsnamen gibst du nur weiter, wenn der Fahrer sie selbst nennt:
  * "destination": Die Tour soll dort ENDEN (dann round_trip = false).
  * "towards": Eine Rundtour soll ueber diesen Ort oder in diese Gegend
    fuehren ("Runde ueber den Edersee", "Richtung Sauerland").
  Sonst beide null. Die App sucht die Orte selbst in echten Kartendaten.
- "direction" nur setzen, wenn eine Himmelsrichtung genannt wird
  ("Richtung Norden" = "n"), sonst "any".
- Wenn eine Angabe fehlt, waehle einen vernuenftigen Standardwert,
  statt nachzufragen. Ohne Laengenangabe: 150 km. "after_km" nur, wenn der
  Fahrer einen Zeitpunkt nennt (2 Stunden entsprechen etwa 120 km), sonst null.
- Tankstopps: Ein einziger "fuel"-Stopp genuegt - die App ergaenzt
  automatisch so viele Tankstopps, wie die Reichweite des Fahrers verlangt.
  Mehrere Stopps derselben Art planst du nur, wenn der Fahrer sie
  ausdruecklich will ("zwei Kaffeepausen").
- Sicherheit geht vor: Wuensche nach Rekorden, Hoechstgeschwindigkeiten
  oder maximaler Schraeglage setzt du NICHT um. Plane in dem Fall eine
  normale kurvige Tour und setze "safety_note".

Erlaubte Werte:
  curviness: "direct" | "balanced" | "curvy" | "very_curvy"
  direction: "any" | "n" | "ne" | "e" | "se" | "s" | "sw" | "w" | "nw"
  stops[].kind: "fuel" | "viewpoint" | "food" | "rest" | "water" | "workshop"

Antwortformat:
$routeRequestSchema
''';

  /// Technisch erzwungenes Antwortformat (Structured Outputs). Jedes Feld
  /// ist Pflicht - "nicht angegeben" heisst null. Muss zu
  /// [routeRequestSchema] passen.
  static const Map<String, dynamic> outputSchema = {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'round_trip': {'type': 'boolean'},
      'distance_km': {'type': 'number'},
      'curviness': {
        'type': 'string',
        'enum': ['direct', 'balanced', 'curvy', 'very_curvy'],
      },
      'direction': {
        'type': 'string',
        'enum': ['any', 'n', 'ne', 'e', 'se', 's', 'sw', 'w', 'nw'],
      },
      'towards': {
        'anyOf': [
          {'type': 'string'},
          {'type': 'null'},
        ],
      },
      'destination': {
        'anyOf': [
          {'type': 'string'},
          {'type': 'null'},
        ],
      },
      'avoid_motorways': {'type': 'boolean'},
      'avoid_tolls': {'type': 'boolean'},
      'avoid_unpaved': {'type': 'boolean'},
      'prefer_known_good_roads': {'type': 'boolean'},
      'title': {'type': 'string'},
      'stops': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'kind': {
              'type': 'string',
              'enum': ['fuel', 'viewpoint', 'food', 'rest', 'water', 'workshop'],
            },
            'after_km': {
              'anyOf': [
                {'type': 'number'},
                {'type': 'null'},
              ],
            },
            'reason': {'type': 'string'},
          },
          'required': ['kind', 'after_km', 'reason'],
        },
      },
      'reply': {'type': 'string'},
      'safety_note': {
        'anyOf': [
          {'type': 'string'},
          {'type': 'null'},
        ],
      },
    },
    'required': [
      'round_trip',
      'distance_km',
      'curviness',
      'direction',
      'towards',
      'destination',
      'avoid_motorways',
      'avoid_tolls',
      'avoid_unpaved',
      'prefer_known_good_roads',
      'title',
      'stops',
      'reply',
      'safety_note',
    ],
  };

  /// Haiku 4.5 kennt keinen "effort"-Wert - dort wuerde er die Anfrage
  /// ablehnen.
  bool get _supportsEffort => !model.contains('haiku');

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

    Map<String, dynamic> body({required bool structured}) => {
          'model': model,
          // Genug Luft: Sonnet 5 denkt standardmaessig kurz nach, und das
          // zaehlt mit. Mit 1200 wurde die Antwort sonst abgeschnitten.
          'max_tokens': structured ? 2048 : 4096,
          'system': _systemPrompt,
          'messages': messages,
          if (structured)
            'output_config': {
              // Erzwingt gueltiges JSON nach dem Schema oben.
              'format': {'type': 'json_schema', 'schema': outputSchema},
              // Einfache Uebersetzungsaufgabe - wenig Nachdenken reicht.
              if (_supportsEffort) 'effort': 'low',
            },
        };

    // Erst mit erzwungenem Format. Lehnt der Server das ab (aelteres
    // Modell, eigener Server ohne Unterstuetzung), einmal ohne.
    var res = await _post(body(structured: true), const Duration(seconds: 40));
    if (res.statusCode == 400) {
      res = await _post(body(structured: false), const Duration(seconds: 40));
    }

    if (res.statusCode != 200) {
      throw AiException(
          _errorFor(res.statusCode, utf8.decode(res.bodyBytes)));
    }

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      // Etwa ein eigener Server, der etwas anderes als die Claude-Antwort
      // zurueckgibt.
      throw AiException('Antwort der KI war nicht verwertbar.');
    }
    if (data['stop_reason'] == 'refusal') {
      throw AiException('Die KI hat diesen Wunsch abgelehnt. '
          'Bitte die Tour anders beschreiben.');
    }
    final text = _extractText(data);
    final json = _extractJson(text);
    if (json == null) {
      throw AiException('Antwort der KI war nicht verwertbar. '
          'Bitte den Wunsch etwas anders formulieren.');
    }

    String? str(String k) {
      final v = json[k];
      return (v is String && v.trim().isNotEmpty) ? v.trim() : null;
    }

    return AiInterpretation(
      request: RouteRequest.fromModelJson(
        json,
        startLat: startLat,
        startLon: startLon,
      ),
      reply: str('reply'),
      safetyNote: str('safety_note'),
      raw: text,
    );
  }

  Future<http.Response> _post(Map<String, dynamic> body, Duration timeout) async {
    try {
      return await http
          .post(Uri.parse(baseUrl), headers: _headers(), body: jsonEncode(body))
          .timeout(timeout);
    } on TimeoutException {
      throw AiException('Die KI antwortet nicht (Zeitüberschreitung). '
          'Bitte erneut versuchen.');
    } catch (_) {
      throw AiException('KI nicht erreichbar. Internetverbindung prüfen.');
    }
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
      if (plan.stats != null) 'kurvigkeit': plan.stats!.curvLabel,
      if (plan.stats != null)
        'kurven_je_km': double.parse(plan.stats!.bendsPerKm.toStringAsFixed(1)),
      'stops': plan.pois
          .map((p) => {
                'kind': p.kind.label,
                'name': p.displayName,
                if (p.detail != null) 'detail': p.detail,
              })
          .toList(),
    };

    Map<String, dynamic> body({required bool withEffort}) => {
          'model': model,
          'max_tokens': 1024,
          if (withEffort && _supportsEffort) 'output_config': {'effort': 'low'},
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
        };

    try {
      var res = await _post(body(withEffort: true), const Duration(seconds: 25));
      if (res.statusCode == 400) {
        res = await _post(body(withEffort: false), const Duration(seconds: 25));
      }
      if (res.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (data['stop_reason'] == 'refusal') return null;
      final t = _extractText(data);
      return t.isEmpty ? null : t;
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
