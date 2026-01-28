# Finch Benchmark Suite

This repository contains the automated benchmark infrastructure and suite for Finch.

## Prerequisites

- `terraform`, `ssh`, `rsync`, `jq` available locally
- AWS credentials configured (`AWS_PROFILE` or environment variables)
- A private SSH key for EC2 access (see `BENCH_SSH_KEY_PATH` below), plus the matching `.pub`

## Commands

1) Provision infrastructure:

```
./bin/infra-up
```

2) Run the benchmark suite:

```
./bin/bench-run
```

3) Tear down infrastructure:

```
./bin/infra-down
```

Results are written to `results/<timestamp>/` on your local machine:
- `summary.csv` (performance summary)
- `metadata.csv` (run metadata)
- `errors.csv` (error counts by client/scenario/reason)

When `BENCH_TUNE=1`, a `tune/` subdirectory is created with:
- `tune.csv` (per-combination results)
- `tune_winners.csv` (best pool size/count per scenario with zero errors)

## Notes

- OpenResty is installed automatically on the server VM by `infra-up`; no manual server setup is required.

## Running Benchmarks

Typical flow:

```
BENCH_SSH_KEY_PATH=~/.ssh/your_key ./bin/infra-up
./bin/bench-run
./bin/infra-down
```

Examples:

```
# Finch only, longer duration, higher concurrency.
BENCH_CLIENTS=finch BENCH_DURATION=60 BENCH_CONCURRENCY=500 ./bin/bench-run

# Tune Finch pool size/count combinations (Finch only).
BENCH_TUNE=1 ./bin/bench-run

# Compare multiple Finch versions in a single run.
BENCH_FINCH_MATRIX=path,git:main,hex:0.19.2 ./bin/bench-run
```

## Tuning Finch Pools

When `BENCH_TUNE=1` is set, the suite runs Finch-only sweeps of pool size/count
combinations. Each combination writes its own `summary.csv`/`metadata.csv` under
`results/<timestamp>/tune/ps<pool_size>_pc<pool_count>/`. Aggregated outputs are
written to `results/<timestamp>/tune/tune.csv` and `tune_winners.csv` (highest
RPS with zero errors per scenario).

Example:

```
BENCH_TUNE=1 BENCH_SCENARIOS=health,small BENCH_DURATION=10 ./bin/bench-run
```

## Common Environment Variables

Infrastructure:
- `BENCH_SSH_KEY_PATH` (optional): path to your private SSH key (defaults to `~/.ssh/id_ed25519` if present, otherwise `~/.ssh/id_rsa`)
- `BENCH_SSH_PUBLIC_KEY_PATH` (optional): path to your public SSH key (defaults to `$BENCH_SSH_KEY_PATH.pub`)
- `AWS_REGION` or `BENCH_AWS_REGION` (default `eu-central-1`)
- `BENCH_CLIENT_INSTANCE_TYPE` (default `c7a.2xlarge`)
- `BENCH_SERVER_INSTANCE_TYPE` (default `c7a.2xlarge`)
- `BENCH_ADMIN_CIDR` (default `0.0.0.0/0`)
- `BENCH_AMI_ID` (optional): override AMI ID
- `BENCH_ERLANG_VERSION`, `BENCH_ELIXIR_VERSION` (override `infra/versions.env`)
- `BENCH_TLS_PORT` (default 8443)

Benchmark run configuration:
- `BENCH_CLIENTS` (default `finch,hackney,gun` or `all`)
- `BENCH_SCENARIOS` (default all): comma-separated scenario names
- `BENCH_DURATION` (seconds, default 30)
- `BENCH_WARMUP` (seconds, default 5)
- `BENCH_CONCURRENCY` (default 25)
- `BENCH_POOL_SIZE`, `BENCH_POOL_COUNT` (Finch/Hackney pooling; defaults 200/32)
- `BENCH_GUN_CONNS` (Gun connection count)
- `BENCH_REQUEST_TIMEOUT_MS` (default 30000)
- `BENCH_HTTP_VERSION` (`http1` or `http2`, default `http1`)
- `BENCH_TLS_VERIFY` (`true`/`false`, default `false` when using HTTPS)
- `BENCH_DDSKERL_ERROR`, `BENCH_DDSKERL_BOUND` (DDSketch options)
- `BENCH_ECHO_BYTES` (default 1024; supported sizes: 1024, 4096, 131072, 1048576)
- `BENCH_DELAY_MS` (default 100)
- `BENCH_TARGET_RPS` (optional; when set and a scenario has an expected latency, concurrency becomes `ceil(target_rps * latency_ms / 1000)`)
- `BENCH_SCENARIO_LATENCY_MS` (optional; override expected latency per scenario, e.g. `delay:100,delay_var:110`)
- `BENCH_DYNAMIC_CONCURRENCY` (optional; when set, run a short preflight per scenario and increase concurrency based on observed max RPS)
- `BENCH_PREFLIGHT_S` (seconds, default 5)
- `BENCH_PREFLIGHT_CONCURRENCY` (default 25)
- `BENCH_MAX_CONCURRENCY` (optional cap for auto-computed concurrency)
- `BENCH_TUNE` (set to enable Finch pool size/count tuning)
- `BENCH_TUNE_POOL_SIZES` (optional, comma-separated; defaults to `50,100,200`)
- `BENCH_TUNE_POOL_COUNTS` (optional, comma-separated; defaults to `cpu/4,cpu/2,cpu,cpu*2,cpu*4`)

Finch version selection:
- `BENCH_FINCH_SOURCE` (`path`, `git`, or `hex`, default `git`)
- `BENCH_FINCH_REF` (git ref when using `git`, default `main`)
- `BENCH_FINCH_GIT` (git URL override)
- `BENCH_FINCH_VERSION` (hex version when using `hex`)
- `BENCH_FINCH_MATRIX` (comma-separated, e.g. `path,git:main,hex:0.19.2`)

## Server Endpoints

The OpenResty server provides deterministic endpoints:

- `/health` returns `OK`
- `/small` returns 4096 bytes
- `/medium` returns 131072 bytes (128 KiB)
- `/large` returns 1048576 bytes
- `/json` returns a static JSON payload
- `/echo` returns the request body
- `/stream` returns 1048576 bytes in 64 flushed chunks
- `/delay/<ms>` sleeps for `<ms>` milliseconds before responding
- `/delay_var` sleeps for a random 20–200ms before responding
- `/delay_post` sleeps for a random 20–200ms; accepts a JSON body and returns a 32KB JSON response 10% of the time

These are configured in `infra/server/openresty.conf`.

For HTTP/2 runs, the server listens on the TLS port (default 8443) and uses a self-signed cert.
Hackney HTTP/2 support requires Hackney 2.x and HTTPS (ALPN). This suite wires it when `BENCH_HTTP_VERSION=http2`.

## Benchmark Scenarios

The suite uses the endpoints above with fixed names. For the delay tests:
- `delay` uses the fixed value from `BENCH_DELAY_MS` (default 100ms)
- `delay_var` uses server-side random delays between 20–200ms
- `delay_post` sends a 32KB JSON body and the server randomly returns a 32KB JSON response 10% of the time (20–200ms delay)
