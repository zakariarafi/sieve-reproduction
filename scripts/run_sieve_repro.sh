#!/usr/bin/env bash
# Run on the Linux JupyterHub server, not on the local Mac.
set -Eeuo pipefail
repro_root="${SIEVE_REPRO_ROOT:-$HOME/repros/sieve-nsdi24}"
if [[ ! -d "$repro_root/.git" ]]; then
  mkdir -p "$(dirname "$repro_root")"
  git clone --depth 1 https://github.com/cacheMon/NSDI24-SIEVE.git "$repro_root"
fi
cd "$repro_root"
run_dir="$repro_root/repro-results/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/workflow.log") 2>&1
trap 'printf "FAILED at line %s. Log: %s\n" "$LINENO" "$run_dir/workflow.log"' ERR
printf 'Results directory: %s\n' "$run_dir"
git rev-parse HEAD | tee "$run_dir/commit.txt"
git status --short > "$run_dir/source-status-before.txt"
uname -a > "$run_dir/system.txt"
command -v conda >/dev/null || { echo 'Conda is required.'; exit 1; }
source "$(conda info --base)/etc/profile.d/conda.sh"
env_dir="$repro_root/.repro-env"
if [[ ! -f "$env_dir/conda-meta/history" ]]; then
  conda create --prefix "$env_dir" --override-channels -c conda-forge \
    python=3.10 'cmake>=3.12,<4' pkg-config glib zstd numpy matplotlib -y
fi
conda activate "$env_dir"
conda list --explicit > "$run_dir/conda-explicit.txt"
export PKG_CONFIG_PATH="$env_dir/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="$env_dir${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$env_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export OMP_NUM_THREADS=4 OPENBLAS_NUM_THREADS=4 MPLBACKEND=Agg
cmake -S libCacheSim -B libCacheSim/_build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$env_dir" \
  -DENABLE_TESTS=OFF -DENABLE_GLCACHE=OFF -DENABLE_LRB=OFF \
  -DUSE_HUGEPAGE=OFF -DOPT_SUPPORT_ZSTD_TRACE=ON \
  2>&1 | tee "$run_dir/configure.log"
cmake --build libCacheSim/_build --target cachesim --parallel 4 \
  2>&1 | tee "$run_dir/build.log"
test -x libCacheSim/_build/bin/cachesim
trace="$repro_root/mydata/zipf/zipf_1.0"
test -s "$trace"
sha256sum "$trace" > "$run_dir/trace.sha256"
wc -l "$trace" > "$run_dir/trace-lines.txt"
python libCacheSim/scripts/plot_mrc_size.py \
  --tracepath "$trace" --trace-format txt \
  --algos fifo,lru,clock,sieve \
  --sizes 0.001,0.005,0.01,0.02,0.05,0.10,0.20,0.40 \
  --ignore-obj-size --num-thread 4 --name "$run_dir/miss_ratio_curve" \
  2>&1 | tee "$run_dir/experiment.log"
python - "$run_dir" "$trace" <<'PY'
import csv
import json
import pickle
import sys
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

out = Path(sys.argv[1])
trace = Path(sys.argv[2])
# This pickle is generated locally by the official plotting script above.
source = Path('/tmp') / (trace.name + '.mrc.pickle')
with source.open('rb') as f:
    curves = pickle.load(f)
rows = [(algo, int(size), float(ratio))
        for algo, values in curves.items() for size, ratio in values]
assert len(curves) == 4, f'Expected 4 algorithms, got {list(curves)}'
assert all(len(values) == 8 for values in curves.values()), 'Incomplete size sweep'
assert all(0 <= ratio <= 1 for _, _, ratio in rows), 'Invalid miss ratio'
with (out / 'miss_ratios.csv').open('w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['algorithm', 'cache_capacity_objects', 'object_miss_ratio'])
    writer.writerows(sorted(rows))
with (out / 'miss_ratios.json').open('w') as f:
    json.dump(dict(curves), f, indent=2)
for algo, points in curves.items():
    points = sorted(points)
    plt.plot([p[0] for p in points], [p[1] for p in points], marker='o', label=algo)
plt.xscale('log')
plt.xlabel('Cache capacity (objects)')
plt.ylabel('Object miss ratio')
plt.title('SIEVE NSDI 2024 artifact: bundled Zipf trace')
plt.legend()
plt.grid(alpha=0.3)
plt.tight_layout()
plt.savefig(out / 'miss_ratio_curve.png', dpi=180)
print('\nalgorithm,cache_capacity_objects,object_miss_ratio')
for algo, size, ratio in sorted(rows):
    print(f'{algo},{size},{ratio:.6f}')
print('\nThis is the bundled synthetic-trace example, not full paper reproduction.')
PY
git status --short > "$run_dir/source-status-after.txt"
printf '\nSUCCESS: 4 algorithms x 8 sizes. Results: %s\n' "$run_dir"
