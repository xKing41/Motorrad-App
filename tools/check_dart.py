"""Struktur-Kontrolle fuer die Dart-Dateien dieses Projekts.

Prueft Klammernbilanz, geschlossene Zeichenketten und Importpfade.

Der naive Ansatz "vom Anfuehrungszeichen bis zum naechsten springen" ist
falsch, sobald in einer Zeichenkette eine Interpolation steckt, die
selbst Zeichenketten enthaelt:

    'Werte: ${liste.join(', ')}'

Dort endet die Zeichenkette scheinbar mitten im Ausdruck, und die
Klammernbilanz wird unbrauchbar. Dieser Scanner fuehrt deshalb einen
Modus-Stapel: In einer Zeichenkette schaltet '${' zurueck in den
Code-Modus, die passende schliessende Klammer wieder zurueck.

Aufruf:  python3 tools/check_dart.py app/lib
"""

import io
import os
import re
import sys


def scan(src):
    """Liefert Code ohne Kommentare und Zeichenketten-Inhalte, plus Endzustand."""
    out = []
    i = 0
    n = len(src)
    modes = [['code', 0]]

    while i < n:
        m = modes[-1]

        if m[0] == 'code':
            two = src[i:i + 2]
            if two == '//':
                while i < n and src[i] != '\n':
                    i += 1
                continue
            if two == '/*':
                i += 2
                while i + 1 < n and src[i:i + 2] != '*/':
                    i += 1
                i += 2
                continue

            c = src[i]

            if c == 'r' and src[i + 1:i + 2] in ('"', "'"):
                j = i + 1
                triple = src[j:j + 3] in ('"""', "'''")
                q = src[j:j + 3] if triple else src[j]
                j += len(q)
                while j < n and src[j:j + len(q)] != q:
                    j += 1
                i = j + len(q)
                out.append('""')
                continue

            if c in '"\'':
                triple = src[i:i + 3] in ('"""', "'''")
                q = src[i:i + 3] if triple else c
                modes.append(['str', q])
                i += len(q)
                out.append('""')
                continue

            if c == '{':
                m[1] += 1
                out.append(c)
                i += 1
                continue

            if c == '}':
                if m[1] == 0 and len(modes) > 1:
                    modes.pop()
                    i += 1
                    continue
                m[1] -= 1
                out.append(c)
                i += 1
                continue

            out.append(c)
            i += 1
            continue

        q = m[1]
        if src[i] == '\\':
            i += 2
            continue
        if src[i:i + len(q)] == q:
            modes.pop()
            i += len(q)
            continue
        if src[i:i + 2] == '${':
            modes.append(['code', 0])
            i += 2
            continue
        i += 1

    return ''.join(out), modes


def main(root):
    files = []
    for base, _, names in os.walk(root):
        for nm in names:
            if nm.endswith('.dart'):
                files.append(os.path.join(base, nm))
    files.sort()

    if not files:
        print('Keine Dart-Dateien unter %s gefunden.' % root)
        return 1

    problems = 0
    for f in files:
        src = io.open(f, encoding='utf-8').read()
        code, modes = scan(src)

        if len(modes) != 1 or modes[0][0] != 'code':
            print('  NICHT GESCHLOSSEN %s: Zeichenkette oder Interpolation offen' % f)
            problems += 1
        elif modes[0][1] != 0:
            print('  KLAMMERN %s: geschweifte Klammern nicht ausgeglichen (Rest %d)'
                  % (f, modes[0][1]))
            problems += 1

        for op, cl, name in [('(', ')', 'runde'), ('[', ']', 'eckige')]:
            if code.count(op) != code.count(cl):
                print('  KLAMMERN %s: %s %d/%d'
                      % (f, name, code.count(op), code.count(cl)))
                problems += 1

        for mm in re.finditer(r"import '([^']+)'", src):
            tgt = mm.group(1)
            if tgt.startswith(('package:', 'dart:')):
                continue
            p = os.path.normpath(os.path.join(os.path.dirname(f), tgt))
            if not os.path.exists(p):
                print('  IMPORT %s: fehlt -> %s' % (f, tgt))
                problems += 1

    print('\n%d Dateien geprueft, %s'
          % (len(files),
             'keine Beanstandung' if problems == 0 else '%d Punkte' % problems))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'app/lib'))
