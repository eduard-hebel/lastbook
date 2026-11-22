#!/usr/bin/env python3
"""Cut a real AT-9 map set from the Vienna fixture with packaging/build_packs.py's own cutter.

  python3 cut_fixture.py

The fixture holds only the two genuine layers. The other layer files are empty schema stubs, so
build_packs can run without the US source snapshot. geo_source() is pointed at a temporary source
folder; no base from the library and no network is used.

Outputs:

  out/maps/AT-9/                  the map set the cutter wrote (no provenance inside it)
  out/AT-9.provenance.json        the sidecar, outside the set
  out/cutter-source/              the assembled input, kept for inspection

The sidecar is deliberately not copied into out/maps/AT-9/: state_maps.scan() allows only its fixed
file list, and map-set.json allows only name, files, bytes and seconds.
"""
import importlib.util
import json
import shutil
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
BUILD_PACKS = REPO / 'packaging' / 'build_packs.py'
FIXTURE = HERE / 'fixture'
OUT = HERE / 'out'
SOURCE = OUT / 'cutter-source'
MAP = OUT / 'AT-9'

STUBS = {
    'water.sqlite': '''
      CREATE TABLE resource(id INTEGER PRIMARY KEY, source_id TEXT, kind TEXT, name TEXT, lat REAL, lon REAL, detail TEXT, source TEXT, origin TEXT);
      CREATE TABLE spatial(id INTEGER PRIMARY KEY, minx REAL, maxx REAL, miny REAL, maxy REAL);
      CREATE TABLE feat(id INTEGER PRIMARY KEY, layer TEXT, cls TEXT, name TEXT, minz INTEGER, geom BLOB);
      CREATE VIRTUAL TABLE feat_idx USING rtree(id, minx, maxx, miny, maxy, minz, maxz);
      CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
      CREATE VIRTUAL TABLE water_fts USING fts5(name, other);''',
    'terrain.sqlite': '''
      CREATE TABLE tile(z INTEGER, x INTEGER, y INTEGER, data BLOB, PRIMARY KEY(z, x, y));
      CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);''',
    'map.sqlite': '''
      CREATE TABLE feat(id INTEGER PRIMARY KEY, layer TEXT, cls TEXT, name TEXT, minz INTEGER, geom BLOB);
      CREATE VIRTUAL TABLE feat_idx USING rtree(id, minx, maxx, miny, maxy, minz, maxz);
      CREATE TABLE poi(id INTEGER PRIMARY KEY, cls TEXT, name TEXT, lon REAL, lat REAL);
      CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);''',
    'buildings.sqlite': '''
      CREATE TABLE bldg(id INTEGER PRIMARY KEY, x INTEGER, y INTEGER, data BLOB);
      CREATE TABLE bldg_socal(id INTEGER PRIMARY KEY, x INTEGER, y INTEGER, data BLOB);
      CREATE TABLE bldg_osm(id INTEGER PRIMARY KEY, x INTEGER, y INTEGER, data BLOB);
      CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);''',
    'crops.sqlite': '''
      CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE resource(id INTEGER PRIMARY KEY, kind TEXT, name TEXT, lat REAL, lon REAL, detail TEXT, source TEXT, origin TEXT);
      CREATE TABLE spatial(id INTEGER PRIMARY KEY, minx REAL, maxx REAL, miny REAL, maxy REAL);
      CREATE TABLE tile(z INTEGER, x INTEGER, y INTEGER, data BLOB);''',
    'atlas.sqlite': '''
      CREATE TABLE resource(id INTEGER PRIMARY KEY, kind TEXT, name TEXT, lat REAL, lon REAL, detail TEXT, source TEXT, origin TEXT);
      CREATE TABLE spatial(id INTEGER PRIMARY KEY, minx REAL, maxx REAL, miny REAL, maxy REAL);
      CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT);''',
}


def load_build_packs():
    spec = importlib.util.spec_from_file_location('build_packs_cut', BUILD_PACKS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_stub(path, sql):
    path.unlink(missing_ok=True)
    db = sqlite3.connect(path)
    db.execute('PRAGMA journal_mode=DELETE')
    db.executescript(sql)
    db.commit()
    db.execute('PRAGMA journal_mode=DELETE')
    db.close()


def assemble_source():
    if SOURCE.exists():
        shutil.rmtree(SOURCE)
    SOURCE.mkdir(parents=True)
    for name in ('national.sqlite', 'places.sqlite'):
        shutil.copy2(FIXTURE / name, SOURCE / name)
    for name, sql in STUBS.items():
        make_stub(SOURCE / name, sql)


def build(out=OUT):
    out = Path(out)
    global OUT, SOURCE, MAP
    OUT, SOURCE, MAP = out, out / 'cutter-source', out / 'maps' / 'AT-9'
    assemble_source()
    if (out / 'maps').exists():
        shutil.rmtree(out / 'maps')
    bp = load_build_packs()
    bp.OUT = out
    bp.geo_source = lambda: SOURCE
    bp.need_space = lambda n: None     # the fixture is a few MB; the real floor is for library-sized packs
    import contextlib
    import io
    with contextlib.redirect_stdout(io.StringIO()):
        bp.build_map('AT-9')

    info = json.loads((MAP / 'map-set.json').read_text(encoding='utf-8'))
    provenance = json.loads((FIXTURE / 'provenance.json').read_text(encoding='utf-8'))
    provenance['cut'] = {
        'cutter': 'packaging/build_packs.py build_map("AT-9") with geo_source pointed at the fixture',
        'box': bp.subdivision_box('AT-9'),
        'map_set': {'name': info['name'], 'bytes': info['bytes'], 'files': info['files']},
        'source_files': {p.name: {'bytes': p.stat().st_size, 'sha256': __import__('hashlib').sha256(p.read_bytes()).hexdigest()}
                         for p in sorted(SOURCE.glob('*.sqlite'))},
    }
    (out / 'AT-9.provenance.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=1, sort_keys=True) + '\n',
                                              encoding='utf-8')
    return info


def main():
    info = build()
    print(json.dumps({'map': info['name'], 'bytes': info['bytes'], 'files': info['files']}, indent=1))
    print(f'sidecar: {OUT / "AT-9.provenance.json"} (outside the map set)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
