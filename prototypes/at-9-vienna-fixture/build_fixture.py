#!/usr/bin/env python3
"""Build the AT-9 Vienna source fixture and its provenance sidecar.

  python3 build_fixture.py

Reads only frozen bounded samples: the derived BEV place-name JSON and the Overpass help-point
JSON. Writes two SQLite files in the schema packaging/build_packs.py cuts:

  fixture/national.sqlite   feat, feat_idx, poi, meta
  fixture/places.sqlite     place, place_fts

feat.layer='place' holds BEV's named points. poi holds the five OpenStreetMap help classes that
web/map.js has layers for. BEV names also go into place with their own source string, so the
fixture shows both a map pin and a place-finder row. The output is deterministic: no clock, no
paths and no network enter it.
"""
import hashlib
import json
import sqlite3
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOCK = HERE / 'sources.lock.json'
SAMPLE = HERE / 'sample'
FIXTURE = HERE / 'fixture'
BEV_JSON = SAMPLE / 'bev-vienna-names-20260323.json'
OSM_JSON = SAMPLE / 'osm-help-points-at9.json'
BOX = (16.1818, 48.1179, 16.5775, 48.3227)
OSM_CLASSES = ('hospital', 'pharmacy', 'fire_station', 'police', 'drinking_water')
BEV_SOURCE = 'BEV DLM Geographische Namen 23.03.2026'
BUILT = '2026-11-22'
Q = 1e6


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(1 << 22):
            h.update(chunk)
    return h.hexdigest()


def pack_point(lon, lat):
    x, y = int(round(lon * Q)), int(round(lat * Q))
    return struct.pack('<4i', 1, 1, x, y)


def bare(path):
    path.unlink(missing_ok=True)
    db = sqlite3.connect(path)
    db.execute('PRAGMA journal_mode=DELETE')
    db.execute('PRAGMA synchronous=OFF')
    return db


def finish(db):
    db.commit()
    db.execute('PRAGMA journal_mode=DELETE')
    db.execute('VACUUM')
    db.close()


def osm_rows():
    doc = json.loads(OSM_JSON.read_text(encoding='utf-8'))
    rows = []
    for el in sorted(doc['elements'], key=lambda e: (e['type'], e['id'])):
        tags = el.get('tags') or {}
        cls = tags.get('amenity')
        if cls not in OSM_CLASSES:
            continue
        if el['type'] == 'node':
            lat, lon = el['lat'], el['lon']
        else:
            center = el.get('center') or {}
            if 'lat' not in center:
                continue
            lat, lon = center['lat'], center['lon']
        name = tags.get('name')
        rows.append({'osm_type': el['type'], 'osm_id': el['id'], 'cls': cls, 'name': name,
                     'lon': round(lon, 7), 'lat': round(lat, 7)})
    return rows, doc['osm3s']['timestamp_osm_base']


def main():
    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    want = lock['derived']['bev_vienna_names']['sha256']
    got = sha256_file(BEV_JSON)
    if got != want:
        sys.exit(f'{BEV_JSON.name}: SHA-256 {got}, expected {want}')
    osm_meta = lock['sources']['osm_help_points_at9']
    got = sha256_file(OSM_JSON)
    if got != osm_meta['sha256']:
        sys.exit(f'{OSM_JSON.name}: SHA-256 {got}, expected {osm_meta["sha256"]}')

    bev = json.loads(BEV_JSON.read_text(encoding='utf-8'))
    places = bev['rows']
    pois, osm_stamp = osm_rows()
    west, south, east, north = BOX
    if any(not (west <= r['lon'] <= east and south <= r['lat'] <= north) for r in places + pois):
        sys.exit('a source row falls outside the AT-9 box')

    FIXTURE.mkdir(parents=True, exist_ok=True)
    national = bare(FIXTURE / 'national.sqlite')
    national.executescript('''
      CREATE TABLE feat(id INTEGER PRIMARY KEY, layer TEXT, cls TEXT, name TEXT, minz INTEGER, geom BLOB);
      CREATE VIRTUAL TABLE feat_idx USING rtree(id, minx, maxx, miny, maxy, minz, maxz);
      CREATE TABLE poi(id INTEGER PRIMARY KEY, cls TEXT, name TEXT, lon REAL, lat REAL);
      CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
      CREATE INDEX poi_cls ON poi(cls, lon, lat);''')
    for i, p in enumerate(places, 1):
        national.execute('INSERT INTO feat VALUES (?,?,?,?,?,?)',
                         (i, 'place', p['cls'], p['name'], p['minz'], pack_point(p['lon'], p['lat'])))
        national.execute('INSERT INTO feat_idx VALUES (?,?,?,?,?,?,?)',
                         (i, p['lon'], p['lon'], p['lat'], p['lat'], p['minz'], 30))
    for i, p in enumerate(pois, 1):
        national.execute('INSERT INTO poi VALUES (?,?,?,?,?)', (i, p['cls'], p['name'], p['lon'], p['lat']))
    credit = f'{lock["sources"]["bev_dlm_names_20260323"]["credit"]}; {osm_meta["credit"]}'
    national.executemany('INSERT INTO meta VALUES (?,?)', [
        ('source', f'BEV DLM Geographische Namen 23.03.2026 (CC BY 4.0); OpenStreetMap contributors (ODbL 1.0)'),
        ('data_as_of', f'2026-03-23 (BEV names); {osm_stamp} (OSM help points)'),
        ('bounds', ','.join(str(v) for v in BOX)),
        ('built', BUILT),
        ('licence', 'CC BY 4.0; ODbL 1.0'),
        ('attribution', credit),
        ('provenance', 'AT-9.provenance.json, a sidecar outside this map set'),
        ('note', 'private bounded prototype, not a complete or production Vienna map'),
    ])
    finish(national)

    places_db = bare(FIXTURE / 'places.sqlite')
    places_db.executescript('''
      CREATE TABLE place(id INTEGER PRIMARY KEY, name TEXT, kind TEXT, detail TEXT, lat REAL, lon REAL, rank INTEGER, source TEXT);
      CREATE VIRTUAL TABLE place_fts USING fts5(name, detail, content='place', content_rowid='id', tokenize='unicode61');''')
    n = 0
    for p in places:
        n += 1
        places_db.execute('INSERT INTO place VALUES (?,?,?,?,?,?,?,?)',
                          (n, p['name'], p['f_name'],
                           f'Wien ({p["category"]}); BEV DLM Geographische Namen, Stichtag 23.03.2026',
                           p['lat'], p['lon'], 2 if p['category'] == 'settlement' else 4, BEV_SOURCE))
    for p in pois:
        if not p['name']:
            continue
        n += 1
        places_db.execute('INSERT INTO place VALUES (?,?,?,?,?,?,?,?)',
                          (n, p['name'], p['cls'].replace('_', ' '),
                           'Wien (OpenStreetMap help point)', p['lat'], p['lon'], 4, 'OpenStreetMap'))
    places_db.execute("INSERT INTO place_fts(place_fts) VALUES ('rebuild')")
    finish(places_db)

    provenance = {
        'schema': 'lastbook-map-provenance/1',
        'map_id': 'AT-9',
        'fixture_files': {name: {'bytes': (FIXTURE / name).stat().st_size, 'sha256': sha256_file(FIXTURE / name)}
                          for name in ('national.sqlite', 'places.sqlite')},
        'status': 'private prototype; not production; not publishable as an Austrian map today',
        'generated': BUILT,
        'box': {'west': west, 'south': south, 'east': east, 'north': north,
                'source': 'docs/REGIONS-AT.md, BEV VGD 01.04.2026, unpadded'},
        'sources': [
            {**{k: lock['sources']['bev_dlm_names_20260323'][k] for k in
                ('title', 'publisher', 'record_id', 'catalogue_url', 'doi', 'url', 'licence', 'licence_url',
                 'credit', 'credit_note', 'access_date', 'bytes', 'sha256', 'last_modified', 'etag')},
             'used_for': f'{len(places)} named points in the AT-9 box, five DLM name tables',
             'local_file': 'cache/' + Path(lock['sources']['bev_dlm_names_20260323']['url']).name,
             'committed_sample': {'path': 'sample/bev-vienna-names-20260323.json', 'sha256': want,
                                  'bytes': BEV_JSON.stat().st_size}},
            {**{k: osm_meta[k] for k in
                ('title', 'publisher', 'endpoint', 'endpoint_note', 'query_file', 'box', 'licence', 'licence_url',
                 'credit', 'access_date', 'osm_base_timestamp', 'bytes', 'sha256', 'raw_bytes', 'raw_sha256', 'sanitized')},
             'url': osm_meta['endpoint'],
             'used_for': f'{len(pois)} help points with a web/map.js layer ({", ".join(OSM_CLASSES)})',
             'excluded': '427 emergency=defibrillator nodes were fetched but are not used: web/map.js has no defibrillator layer',
             'committed_sample': {'path': 'sample/osm-help-points-at9.json', 'sha256': osm_meta['sha256'],
                                  'bytes': OSM_JSON.stat().st_size}},
        ],
        'transformation': {
            'bev': f'EPSG:31255 -> EPSG:4326, {bev["source"]["transform"]}, then filtered to the AT-9 box',
            'osm': 'Overpass JSON, node lat/lon or way centre, filtered to the AT-9 box by the query',
            'determinism': 'rows sorted; built date fixed at 2026-11-22; no clock or absolute path written',
        },
        'layers': {
            'national.feat layer=place': f'{len(places)} BEV named points (cls city/town/suburb/village/hamlet/locality)',
            'national.poi': f'{len(pois)} OSM help points ({", ".join(OSM_CLASSES)})',
            'places.place': f'{len(places)} BEV rows + {sum(1 for p in pois if p["name"])} named OSM rows',
        },
        'limitations': [
            'Place names are points. BEV DLM Geographische Namen is not the address register, so street addresses and house numbers are absent.',
            'OpenStreetMap help points are community-mapped and may be incomplete or stale; the OSM base timestamp is recorded above.',
            'No terrain, buildings, crops, water lines or dams are present. The fixture is not a complete map.',
            'The canonical Overpass endpoints timed out from this host; the mirror named above is the actual endpoint used.',
            'An AT-9 build from the current US source snapshot would inherit the US low-zoom base and US gazetteer place rows, because base_set copies non-OpenStreetMap places without a region box. This fixture avoids that by making the base from a Vienna-only source.',
            'packaging/state_maps.py scan() requires the map-set file list to equal its ALLOWED set, so a provenance file inside the set fails the contract.',
            'map-set.json accepts only name, files, bytes and seconds; engine/setup/manifest.py rebuilds map entries from known fields and drops an extra attribution key. Neither file carries this provenance today.',
        ],
        'not_claimed': [
            'not that the manifest or map-set.json transfers this provenance',
            'not that the map set is publishable or complete',
            'not that BEV, the BMI or the City of Vienna reviewed this extract',
            'not that the OSM extract is complete',
        ],
    }
    (FIXTURE / 'provenance.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=1, sort_keys=True) + '\n',
                                             encoding='utf-8')
    print(json.dumps({'bev_points': len(places), 'osm_help_points': len(pois),
                      'omitted_defibrillators': 427, 'fixture': str(FIXTURE.relative_to(HERE))}, indent=1))


if __name__ == '__main__':
    main()
