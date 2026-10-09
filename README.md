# SIEVE reproduction experiments

Experiments using the official NSDI 2024 SIEVE artifact:
https://github.com/cacheMon/NSDI24-SIEVE

And you can read the technical report here: https://github.com/zakariarafi/sieve-reproduction/blob/main/technical_report.pdf

## Scope

- Synthetic experiment: bundled Zipf trace, FIFO/LRU/Clock/SIEVE,
  eight cache capacities, 32 configurations.
- Real-world experiment: three consecutive prefix windows per workload
  for wiki-CDN, twitter-KV, and meta-CDN; object and byte capacity modes;
  cold, 10%, and 20% warmup; 1,728 configurations.

These experiments are a partial reproduction, not a full reproduction
of the paper. They do not evaluate throughput.

## Contents

- scripts/: experiment runners
- results/: CSVs, plots, logs, manifests, and environment records

Each run's commit.txt records the upstream artifact revision.
The real-world run includes a reporting-only simulator patch.
Generated binary traces and build directories are excluded.
