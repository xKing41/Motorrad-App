"""Erzeugt die Kartenstile der App aus den OpenFreeMap-Stilen.

Quelle: https://github.com/hyperknot/openfreemap-styles (liberty = Tag,
dark = Nacht), abgeleitet von OpenMapTiles (BSD/CC-BY).

Aufruf: python3 tools/make_map_styles.py liberty.json dark.json

Entfernt, was die App nicht darstellt (Relief-Rasterbild, 3D-Gebaeude),
und macht die Strassen im Nachtstil fuer die Navigation kraeftiger.
"""
import json
import sys


def clean(style, name):
    style = dict(style)
    style['id'] = name
    style['sources'] = {'openmaptiles': {'type': 'vector'}}
    style.pop('sprite', None)
    style.pop('glyphs', None)
    style['layers'] = [
        l for l in style['layers']
        if l['type'] not in ('raster', 'hillshade', 'fill-extrusion')
    ]
    return style


def brighten_night(style):
    """Dark-Matter-Stile sind fuer Datenkarten gedacht: Strassen fast
    schwarz auf schwarz. Beim Fahren muss man sie erkennen."""
    for l in style['layers']:
        if l['type'] != 'line' or l.get('source-layer') != 'transportation':
            continue
        lid = l['id']
        paint = l.setdefault('paint', {})
        if 'casing' in lid:
            paint['line-color'] = '#0b0d10'
            continue
        if 'motorway' in lid or 'trunk' in lid:
            paint['line-color'] = '#8a6a3a'
        elif 'primary' in lid or 'secondary' in lid or 'major' in lid:
            paint['line-color'] = '#6b6f76'
        elif 'rail' in lid:
            continue
        else:
            paint['line-color'] = '#474b52'
    return style


def main():
    day = json.load(open(sys.argv[1]))
    night = json.load(open(sys.argv[2]))
    out = 'app/assets/map'
    json.dump(clean(day, 'schraeglage-tag'),
              open(f'{out}/style_day.json', 'w'), ensure_ascii=False)
    json.dump(brighten_night(clean(night, 'schraeglage-nacht')),
              open(f'{out}/style_night.json', 'w'), ensure_ascii=False)


if __name__ == '__main__':
    main()
