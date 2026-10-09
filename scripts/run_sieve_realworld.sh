#!/usr/bin/env bash
# Linux JupyterHub runner. Reuses the successfully built NSDI24 artifact.
set -Eeuo pipefail
root="${SIEVE_REPRO_ROOT:-$HOME/repros/sieve-nsdi24}"
cd "$root"
run_dir="$root/repro-results/realworld-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/workflow.log") 2>&1
trap 'printf "FAILED line %s. See %s/workflow.log\n" "$LINENO" "$run_dir"' ERR
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$root/.repro-env"
export LD_LIBRARY_PATH="$CONDA_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export MPLBACKEND=Agg OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
test -x "$root/libCacheSim/_build/bin/cachesim"
# Keep the artifact source intact. Improve only CLI reporting in a private copy:
# exact byte capacities and 10-decimal miss ratios (no policy changes).
python - "$root/libCacheSim" "$run_dir/simulator-source" <<'PATCH'
import difflib, hashlib, shutil, sys
from pathlib import Path
source, target = map(Path, sys.argv[1:])
shutil.copytree(source, target, ignore=shutil.ignore_patterns('_build', '.git'))
p = target / 'libCacheSim/bin/cachesim/main.c'
before = p.read_text()
assert before.count('if (!args.ignore_obj_size) {') == 1
assert before.count('%.4lf') == 2
updated = before.replace('if (!args.ignore_obj_size) {', 'if (false && !args.ignore_obj_size) {').replace('%.4lf', '%.10lf')
p.write_text(updated)
(target.parent / 'reporting-only.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True), updated.splitlines(True), fromfile='official/main.c', tofile='reporting/main.c')))
(target.parent / 'official-main.sha256').write_text(hashlib.sha256(before.encode()).hexdigest())
PATCH
export PKG_CONFIG_PATH="$CONDA_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="$CONDA_PREFIX"
cmake -S "$run_dir/simulator-source" -B "$run_dir/build" -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_TESTS=OFF -DENABLE_GLCACHE=OFF -DENABLE_LRB=OFF -DUSE_HUGEPAGE=OFF \
  -DOPT_SUPPORT_ZSTD_TRACE=ON
cmake --build "$run_dir/build" --target cachesim --parallel 4
sim="$run_dir/build/bin/cachesim"
test -x "$sim"
# Python streaming decompression avoids downloading multi-GB complete traces.
python -c 'import zstandard' 2>/dev/null || python -m pip install 'zstandard==0.23.0'
git rev-parse HEAD > "$run_dir/commit.txt"
git status --short > "$run_dir/source-status.txt"
conda list --explicit > "$run_dir/conda-explicit.txt"
python -m pip freeze > "$run_dir/pip-freeze.txt"
uname -a > "$run_dir/system.txt"
python - "$run_dir" "$sim" "${WINDOW_REQUESTS:-1000000}" <<'PY'
import csv, hashlib, json, os, re, struct, subprocess, sys, time, urllib.request
from pathlib import Path
import zstandard as zstd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

out, sim = Path(sys.argv[1]), str(Path(sys.argv[2]).resolve())
window_n = int(sys.argv[3])
assert 100 <= window_n <= 100_000_000, 'WINDOW_REQUESTS must be 100..100000000'
base = 'https://ftp.pdl.cmu.edu/pub/datasets/twemcacheWorkload/cacheDatasets/'
traces = {
    'wiki-CDN': base + 'wiki/wiki_2019t.oracleGeneral.zst',
    'twitter-KV': base + 'twitter/cluster10.oracleGeneral.zst',
    'meta-CDN': base + 'metaCDN/meta_reag.oracleGeneral.zst',
}
record = struct.Struct('<IQIq')  # 24-byte official oracleGeneral format
fractions = [.001, .005, .01, .02, .05, .10, .20, .40]
algos = ['fifo', 'lru', 'clock', 'sieve']
manifest = {
    'datasets': traces, 'window_requests': window_n, 'windows_per_trace': 3,
    'scope': 'Three consecutive windows from each trace prefix; NOT whole-dataset reproduction.',
    'warmup': 'Same last 80% evaluation suffix. Cold: no prefix. 10%: immediately preceding 10%. 20%: preceding 20%.',
    'timestamp_conversion': 'Ordinal request index, TTL disabled; original timestamp ranges recorded.',
    'capacity_basis': 'Distinct IDs / sum of maximum observed size per ID in each full window.',
    'fractions': fractions, 'algorithms': algos, 'metadata_overhead': False,
    'zero_size': 'Skipped like official reader; counts and stream hashes recorded.',
    'precision': 'Reporting-only patch: exact capacities and 10 decimal places; eviction algorithms unchanged.',
    'interpretation': 'Deterministic replay; temporal windows are not independent random samples. No throughput claim.',
    'workloads': [],
}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
rows = []
ansi = re.compile(r'\x1b\[[0-9;]*m')
result_re = re.compile(r'\b(FIFO|LRU|Clock|Sieve)\s+cache size\s+(\d+)\s*,\s*(\d+) req, miss ratio ([0-9.]+), byte miss ratio ([0-9.]+)', re.I)


def prepare(window, tag):
    # All scenarios measure the identical suffix and start a fresh cache.
    split = window_n // 5
    eval_n = window_n - split
    maxima = {}
    for _, obj, size, _ in window:
        maxima[obj] = max(size, maxima.get(obj, 0))
    info = {'tag': tag, 'requests': window_n, 'evaluation_requests': eval_n,
            'original_first_timestamp': window[0][0], 'original_last_timestamp': window[-1][0],
            'distinct_objects': len(maxima), 'working_set_bytes_max_size': sum(maxima.values()),
            'variable_size_objects': len({obj for _, obj, size, _ in window if size != maxima[obj]}),
            'scenarios': []}
    paths = []
    for label, warm_n in [('cold', 0), ('warm10', window_n // 10), ('warm20', split)]:
        path = out / 'traces' / f'{tag}-{label}.oracleGeneral.bin'
        digest = hashlib.sha256()
        with path.open('wb') as f:
            for i, (_, obj, size, _) in enumerate(window[split-warm_n:]):
                # Future-access fields are unused by these four policies.
                data = record.pack(i, obj, size, -1)
                f.write(data)
                digest.update(data)
        paths.append((label, warm_n, path))
        info['scenarios'].append({'label': label, 'warmup_requests': warm_n,
                                 'path': str(path), 'sha256': digest.hexdigest()})
    return info, paths


def run_window(window, tag):
    info, paths = prepare(window, tag)
    manifest['workloads'].append(info)
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    for mode in ['objects', 'bytes']:
        ws = info['distinct_objects'] if mode == 'objects' else info['working_set_bytes_max_size']
        capacities = [max(1, int(ws * frac)) for frac in fractions]
        unique_caps = list(dict.fromkeys(capacities))
        for label, warm_n, path in paths:
            task = out / 'logs' / f'{tag}-{mode}-{label}'
            task.mkdir(parents=True)
            # Multi-cache branch uses time < warmup_sec, not <=; ordinal time
            # thus consumes exactly warm_n requests. Always pass four algorithms.
            cmd = [sim, str(path), 'oracleGeneral', ','.join(algos),
                   ','.join(map(str, unique_caps)), '--ignore-obj-size',
                   '1' if mode == 'objects' else '0', '--warmup-sec', str(warm_n),
                   '--num-thread', '4', '--use-ttl', '0', '--consider-obj-metadata', '0']
            (task / 'command.json').write_text(json.dumps(cmd, indent=2))
            print(f'RUN {tag} {mode} {label}: warmup={warm_n}, evaluation={info["evaluation_requests"]}', flush=True)
            start = time.monotonic()
            with (task / 'simulator.log').open('w') as log:
                subprocess.run(cmd, cwd=task, stdout=log, stderr=subprocess.STDOUT, check=True)
            raw = ansi.sub('', (task / 'simulator.log').read_text())
            matches = result_re.findall(raw)
            assert len(matches) == len(algos)*len(unique_caps), f'Incomplete output: {task}'
            parsed = {}
            for algo, cap, count, omr, bmr in matches:
                key = (algo.lower(), int(cap))
                assert key not in parsed, f'Duplicate result {key}'
                assert int(count) == info['evaluation_requests'], f'Wrong measured request count: {task}: {count}'
                assert 0 <= float(omr) <= 1 and 0 <= float(bmr) <= 1
                parsed[key] = (float(omr), float(bmr))
            if warm_n:
                counts = re.findall(r'finishes warm up using\s+with (\d+) requests', raw)
                assert len(counts) == len(matches) and all(int(n) == warm_n for n in counts), f'Warmup mismatch: {task}'
            for frac, cap in zip(fractions, capacities):
                for algo in algos:
                    omr, bmr = parsed[(algo, cap)]
                    rows.append(dict(workload=tag, mode=mode, warmup=label,
                                     warmup_requests=warm_n, evaluation_requests=info['evaluation_requests'],
                                     capacity_fraction=frac, capacity=cap, algorithm=algo,
                                     object_miss_ratio=omr, byte_miss_ratio=bmr))
            (task / 'wall_seconds.txt').write_text(str(time.monotonic()-start))
            with (out / 'miss_ratios.csv').open('w', newline='') as f:
                writer = csv.DictWriter(f, fieldnames=list(rows[0]))
                writer.writeheader(); writer.writerows(rows)
    return info

(out / 'traces').mkdir()
for name, url in traces.items():
    print(f'STREAM {name}: {url}', flush=True)
    # Read only a contiguous prefix, retaining order; no random request sampling.
    request = urllib.request.Request(url, headers={'User-Agent': 'SIEVE-artifact-validation/1.0'})
    digest = hashlib.sha256()
    skipped = 0
    consumed = 0
    pending = bytearray()
    window = []
    completed = 0
    windows = []
    with urllib.request.urlopen(request, timeout=120) as response:
        source_info = {'name': name, 'url': url, 'headers': dict(response.headers)}
        with zstd.ZstdDecompressor().stream_reader(response) as stream:
            while completed < 3:
                chunk = stream.read(24 * 16384)
                if not chunk:
                    raise RuntimeError(f'Trace ended before 3 full windows: {name}')
                pending.extend(chunk)
                nbytes = (len(pending)//24)*24
                for ts, obj, size, future in record.iter_unpack(pending[:nbytes]):
                    packed = record.pack(ts, obj, size, future)
                    digest.update(packed); consumed += 1
                    if size == 0:
                        skipped += 1
                        continue
                    window.append((ts, obj, size, future))
                    if len(window) == window_n:
                        completed += 1
                        windows.append(window)
                        window = []
                        if completed == 3:
                            break
                del pending[:nbytes]
    source_info.update(consumed_raw_records=consumed, skipped_zero_size=skipped,
                       consumed_raw_prefix_sha256=digest.hexdigest())
    (out / f'{name}-source.json').write_text(json.dumps(source_info, indent=2))
    for i, window in enumerate(windows, 1):
        run_window(window, f'{name}-window{i}')
    del windows, window

expected = 3*3*2*3*8*4
assert len(rows) == expected, (len(rows), expected)
summary = []
for row in rows:
    if row['algorithm'] != 'sieve':
        continue
    lru = next(r for r in rows if all(r[k] == row[k] for k in ['workload','mode','warmup','capacity_fraction']) and r['algorithm']=='lru')
    omr, baseline = row['object_miss_ratio'], lru['object_miss_ratio']
    summary.append({**{k:row[k] for k in ['workload','mode','warmup','capacity_fraction','capacity']},
                    'sieve_object_miss_ratio':omr, 'lru_object_miss_ratio':baseline,
                    'relative_object_miss_reduction_vs_lru':(baseline-omr)/baseline if baseline else None,
                    'absolute_object_miss_reduction':baseline-omr,
                    'sieve_byte_miss_ratio':row['byte_miss_ratio'], 'lru_byte_miss_ratio':lru['byte_miss_ratio']})
with (out / 'sieve_vs_lru.csv').open('w', newline='') as f:
    writer=csv.DictWriter(f, fieldnames=list(summary[0])); writer.writeheader(); writer.writerows(summary)
for name in traces:
    fig, axes = plt.subplots(3, 2, figsize=(12,12), sharex=True, sharey=True)
    for w in range(1,4):
        tag=f'{name}-window{w}'
        for col, mode in enumerate(['objects','bytes']):
            ax=axes[w-1,col]
            metric='object_miss_ratio' if mode=='objects' else 'byte_miss_ratio'
            for algo in algos:
                for warm, style in [('cold',':'),('warm10','--'),('warm20','-')]:
                    pts=[r for r in rows if r['workload']==tag and r['mode']==mode and r['algorithm']==algo and r['warmup']==warm]
                    ax.plot([r['capacity_fraction']*100 for r in pts], [r[metric] for r in pts],
                            linestyle=style, label=f'{algo} / {warm}')
            ax.set_xscale('log'); ax.set_ylim(0,1); ax.grid(alpha=.25)
            ax.set_title(f'{tag} / {mode}'); ax.set_xlabel('Capacity (% working set)'); ax.set_ylabel(metric)
    handles, labels = axes[0,0].get_legend_handles_labels()
    fig.legend(handles, labels, loc='lower center', ncol=4)
    fig.suptitle(f'{name}: ordered real trace prefix, common evaluation suffix')
    fig.tight_layout(rect=(0,.1,1,.96))
    fig.savefig(out / f'{name}-curves.png', dpi=180)
    fig.savefig(out / f'{name}-curves.pdf')
    plt.close(fig)
manifest['status']='complete'
manifest['rows']=len(rows)
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
print(f'SUCCESS: {len(rows)} configurations; results: {out}', flush=True)
PY
printf '\nCompleted. Results: %s\n' "$run_dir"
