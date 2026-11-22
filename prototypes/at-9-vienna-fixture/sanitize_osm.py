#!/usr/bin/env python3
"""Reduce an Overpass response to the fields the fixture uses, and nothing else.

  python3 sanitize_osm.py cache/osm-help-points-at9.raw.json sample/osm-help-points-at9.json

Keeps element type and id, coordinates (or a way centre) and only the tags amenity, emergency and
name. Contact, address, operator and payment tags are dropped: this prototype needs help-point
locations and names, not a copy of the map's business contact data.
"""
import hashlib
import json
import sys
from pathlib import Path

KEEP = ('amenity', 'emergency', 'name')


def sanitize(doc):
    out = {
        'version': doc.get('version', 0.6),
        'generator': doc.get('generator', ''),
        'osm3s': doc.get('osm3s', {}),
        'elements': [],
    }
    for el in sorted(doc.get('elements') or [], key=lambda e: (e['type'], e['id'])):
        tags = {k: v for k, v in (el.get('tags') or {}).items() if k in KEEP}
        row = {'type': el['type'], 'id': el['id']}
        if el['type'] == 'node':
            row['lat'], row['lon'] = el['lat'], el['lon']
        elif 'center' in el:
            row['center'] = {'lat': el['center']['lat'], 'lon': el['center']['lon']}
        else:
            continue
        if tags:
            row['tags'] = tags
        out['elements'].append(row)
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit('usage: sanitize_osm.py RAW.json OUT.json')
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    data = json.dumps(sanitize(json.loads(src.read_text(encoding='utf-8'))), ensure_ascii=False, indent=1,
                      sort_keys=True) + '\n'
    dst.write_text(data, encoding='utf-8')
    print(json.dumps({'path': str(dst), 'bytes': len(data.encode('utf-8')),
                      'sha256': hashlib.sha256(data.encode('utf-8')).hexdigest()}, indent=1))


if __name__ == '__main__':
    main()
