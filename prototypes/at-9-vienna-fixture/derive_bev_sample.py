#!/usr/bin/env python3
"""Derive the bounded Vienna place-name sample from BEV's DLM Geographische Namen GeoPackage.

  python3 derive_bev_sample.py [--gpkg cache/DLM_7000_NAMEN_20260323.gpkg] [--check]

Reads the five point tables that name settlements, areas, terrain, water and other landmarks.
Ried names (field names) are left out: they are not help-map places. Coordinates are stored in
EPSG:31255 (MGI / Austria GK Central) and are transformed to EPSG:4326 with pyproj. Only rows
inside the unpadded AT-9 box from docs/REGIONS-AT.md are kept.

The raw 58.5 MB GeoPackage is not committed. The derived JSON is, so the fixture builds and the
smoke test runs offline from the frozen sample. The raw file's SHA-256 is checked first.
"""
import argparse
import hashlib
import json
import sqlite3
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = HERE / 'cache'
SAMPLE = HERE / 'sample'
LOCK = HERE / 'sources.lock.json'
RAW_NAME = 'DLM_7000_NAMEN_20260323.gpkg'
OUT = SAMPLE / 'bev-vienna-names-20260323.json'
BOX = (16.1818, 48.1179, 16.5775, 48.3227)

TABLES = {
    'NAM_7100_SIEDLUNG_P': 'settlement',
    'NAM_7200_GEBIET_P': 'area',
    'NAM_7300_GELAENDEFORM_P': 'terrain',
    'NAM_7500_GEWAESSER_P': 'water',
    'NAM_7600_SONSTIGE_P': 'landmark',
}
CLASS = {
    'Stadt': ('city', 6),
    'Markt': ('town', 9),
    'Stadtteil': ('suburb', 12),
    'Dorf': ('village', 11),
    'Einzelhäuser': ('hamlet', 14),
    'Dorf aufgelassen': ('locality', 14),
}
DEFAULT_CLASS = ('locality', 14)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(1 << 22):
            h.update(chunk)
    return h.hexdigest()


def point(blob):
    if blob is None or blob[:2] != b'GP':
        raise ValueError('not a GeoPackage geometry')
    flags = blob[3]
    if flags & 0x10:
        raise ValueError('empty geometry')
    envelope = (flags >> 1) & 7
    offset = 8 + {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}[envelope]
    if struct.unpack_from('<B', blob, offset)[0] != 1:
        raise ValueError('expected little-endian WKB')
    if struct.unpack_from('<I', blob, offset + 1)[0] % 1000 != 1:
        raise ValueError('expected a point')
    return struct.unpack_from('<dd', blob, offset + 5)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gpkg', default=str(CACHE / RAW_NAME))
    ap.add_argument('--check', action='store_true')
    args = ap.parse_args()

    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    src = lock['sources']['bev_dlm_names_20260323']
    gpkg = Path(args.gpkg)
    if not gpkg.exists():
        sys.exit(f'missing {gpkg}; run fetch_sources.py first (the raw file is not committed)')
    got = sha256_file(gpkg)
    if got != src['sha256']:
        sys.exit(f'SHA-256 mismatch for {gpkg}: {got} != {src["sha256"]}')
    if gpkg.stat().st_size != src['bytes']:
        sys.exit(f'size mismatch for {gpkg}')

    from pyproj import Transformer
    import pyproj
    transform = Transformer.from_crs('EPSG:31255', 'EPSG:4326', always_xy=True)
    west, south, east, north = BOX
    rows, counts = [], {}
    db = sqlite3.connect(f'file:{gpkg}?mode=ro', uri=True)
    for table, category in TABLES.items():
        n = 0
        for geom, f_code, f_name, name in db.execute(f'SELECT geom,F_CODE,F_NAME,NAME FROM "{table}"'):
            if not name:
                continue
            x, y = point(geom)
            lon, lat = transform.transform(x, y)
            if not (west <= lon <= east and south <= lat <= north):
                continue
            cls, minz = CLASS.get(f_name, DEFAULT_CLASS)
            rows.append({'table': table, 'category': category, 'f_code': f_code, 'f_name': f_name,
                         'name': name, 'lon': round(lon, 7), 'lat': round(lat, 7), 'cls': cls, 'minz': minz})
            n += 1
        counts[table] = n
    db.close()
    rows.sort(key=lambda r: (r['table'], r['f_code'] or 0, r['name'], r['lon'], r['lat']))

    out = {
        'schema': 'lastbook-at9-bev-names-sample/1',
        'source': {
            'title': src['title'],
            'publisher': src['publisher'],
            'record_id': src['record_id'],
            'catalogue_url': src['catalogue_url'],
            'doi': src['doi'],
            'url': src['url'],
            'licence': src['licence'],
            'licence_url': src['licence_url'],
            'credit': src['credit'],
            'access_date': src['access_date'],
            'sha256': src['sha256'],
            'bytes': src['bytes'],
            'crs': 'EPSG:31255',
            'transform': f'EPSG:31255 -> EPSG:4326 via pyproj {pyproj.__version__} / PROJ {pyproj.proj_version_str}',
            'box': list(BOX),
        },
        'counts': counts,
        'rows': rows,
    }
    data = json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True) + '\n'
    digest = hashlib.sha256(data.encode('utf-8')).hexdigest()
    want = lock.get('derived', {}).get('bev_vienna_names', {}).get('sha256')
    if args.check:
        if not OUT.exists():
            sys.exit(f'missing {OUT}; run without --check first')
        have = hashlib.sha256(OUT.read_bytes()).hexdigest()
        if have != want:
            sys.exit(f'{OUT} does not match sources.lock.json: {have} != {want}')
        print(f'{OUT.name}: {have} matches the lock')
        return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(data, encoding='utf-8')
    print(json.dumps({'path': str(OUT.relative_to(HERE)), 'rows': len(rows), 'counts': counts, 'sha256': digest}, indent=1))


if __name__ == '__main__':
    main()
