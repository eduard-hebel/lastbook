#!/usr/bin/env python3
"""Fetch the bounded public sources named in sources.lock.json and verify them.

  python3 fetch_sources.py            # download what is missing, verify everything
  python3 fetch_sources.py --offline  # verify local files only, never open a socket

Only two bounded files are fetched: BEV's 58.5 MB DLM Geographische Namen GeoPackage and one
Overpass response for the AT-9 box. No multi-GB layer, no address register and no credentials.
Each byte count and SHA-256 is checked against sources.lock.json before the file is kept.
"""
import argparse
import hashlib
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

from sanitize_osm import sanitize

HERE = Path(__file__).resolve().parent
CACHE = HERE / 'cache'
LOCK = HERE / 'sources.lock.json'
UA = 'LastbookAT9Prototype/0.1 (bounded offline map fixture; contact: eduard-hebel)'


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(1 << 22):
            h.update(chunk)
    return h.hexdigest()


def verify(path, meta):
    if not path.exists():
        return f'missing {path}'
    size = path.stat().st_size
    if size != meta['bytes']:
        return f'{path.name}: {size} bytes, expected {meta["bytes"]}'
    got = sha256_file(path)
    if got != meta['sha256']:
        return f'{path.name}: SHA-256 {got}, expected {meta["sha256"]}'
    return None


def download(url, dest, limit, data=None):
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + '.part')
    req = urllib.request.Request(url, data=data, headers={'User-Agent': UA, 'Accept': '*/*'})
    with urllib.request.urlopen(req, timeout=120) as r:
        declared = r.headers.get('Content-Length')
        if declared and int(declared) > limit:
            raise SystemExit(f'{url}: Content-Length {declared} exceeds the {limit}-byte guard')
        total = 0
        with open(tmp, 'wb') as f:
            while chunk := r.read(1 << 20):
                total += len(chunk)
                if total > limit:
                    tmp.unlink(missing_ok=True)
                    raise SystemExit(f'{url}: more than the {limit}-byte guard, stopped')
                f.write(chunk)
        headers = {k: r.headers.get(k) for k in ('Content-Type', 'Content-Length', 'Last-Modified', 'ETag')}
        status = r.status
    tmp.replace(dest)
    return {'status': status, 'headers': headers, 'bytes': total, 'fetched_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--offline', action='store_true')
    args = ap.parse_args()
    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    sources = lock['sources']
    report, failures = {}, []

    bev = sources['bev_dlm_names_20260323']
    path = CACHE / Path(bev['url']).name
    problem = verify(path, bev)
    if problem and not args.offline:
        print(f'fetching {bev["url"]}', flush=True)
        report['bev_dlm_names_20260323'] = download(bev['url'], path, bev['download_guard_bytes'])
        problem = verify(path, bev)
    if problem:
        failures.append(problem)
    else:
        report.setdefault('bev_dlm_names_20260323', {}).update({'sha256': bev['sha256'], 'bytes': path.stat().st_size})

    osm = sources['osm_help_points_at9']
    sample = HERE / 'sample' / 'osm-help-points-at9.json'
    raw = CACHE / 'osm-help-points-at9.raw.json'
    raw_meta = {'bytes': osm['raw_bytes'], 'sha256': osm['raw_sha256']}
    problem = verify(sample, osm)
    if problem and not args.offline:
        if verify(raw, raw_meta):
            query = (HERE / osm['query_file']).read_text(encoding='utf-8')
            body = urllib.parse.urlencode({'data': query}).encode('utf-8')
            print(f'fetching {osm["endpoint"]}', flush=True)
            report['osm_raw'] = download(osm['endpoint'], raw, osm['download_guard_bytes'], data=body)
        raw_problem = verify(raw, raw_meta)
        if raw_problem:
            failures.append(raw_problem)
        else:
            text = json.dumps(sanitize(json.loads(raw.read_text(encoding='utf-8'))), ensure_ascii=False, indent=1,
                              sort_keys=True) + '\n'
            sample.write_text(text, encoding='utf-8')
            problem = verify(sample, osm)
    if problem:
        failures.append(problem)
    else:
        report.setdefault('osm_help_points_at9', {}).update({'sha256': osm['sha256'], 'bytes': sample.stat().st_size})
    if raw.exists() and args.offline:
        raw_problem = verify(raw, raw_meta)
        if raw_problem:
            failures.append(raw_problem)

    if report:
        log = CACHE / 'fetch-log.json'
        log.write_text(json.dumps(report, indent=1, sort_keys=True) + '\n', encoding='utf-8')
    if failures:
        for f in failures:
            print(f'FAIL {f}', file=sys.stderr)
        return 1
    print(json.dumps({'mode': 'offline' if args.offline else 'verified', 'files': {k: v.get('bytes') for k, v in report.items()},
                      'sources': {k: v['sha256'] for k, v in sources.items()}}, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
