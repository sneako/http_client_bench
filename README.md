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

Results are written to `bench/results/<timestamp>/` on your local machine.

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

# Compare multiple Finch versions in a single run.
BENCH_FINCH_MATRIX=path,git:main,hex:0.19.2 ./bin/bench-run
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
- `BENCH_ERLANG_VERSION`, `BENCH_ELIXIR_VERSION` (override `bench/infra/versions.env`)

Benchmark run configuration:
- `BENCH_CLIENTS` (default `finch,hackney,gun` or `all`)
- `BENCH_SCENARIOS` (default all): comma-separated scenario names
- `BENCH_DURATION` (seconds, default 20)
- `BENCH_WARMUP` (seconds, default 5)
- `BENCH_CONCURRENCY` (default 100)
- `BENCH_POOL_SIZE`, `BENCH_POOL_COUNT` (Finch/Hackney pooling)
- `BENCH_GUN_CONNS` (Gun connection count)
- `BENCH_REQUEST_TIMEOUT_MS` (default 30000)
- `BENCH_DDSKERL_ERROR`, `BENCH_DDSKERL_BOUND` (DDSketch options)
- `BENCH_ECHO_BYTES` (default 1024)
- `BENCH_DELAY_MS` (default 100)

Finch version selection:
- `BENCH_FINCH_SOURCE` (`path`, `git`, or `hex`)
- `BENCH_FINCH_REF` (git ref when using `git`)
- `BENCH_FINCH_GIT` (git URL override)
- `BENCH_FINCH_VERSION` (hex version when using `hex`)
- `BENCH_FINCH_MATRIX` (comma-separated, e.g. `path,git:main,hex:0.19.2`)

## Server Endpoints

The OpenResty server provides deterministic endpoints:

- `/health` returns `OK`
- `/small` returns 4096 bytes
- `/large` returns 1048576 bytes
- `/json` returns a static JSON payload
- `/echo` returns the request body
- `/stream` returns 1048576 bytes in 64 flushed chunks
- `/delay/<ms>` sleeps for `<ms>` milliseconds before responding

These are configured in `bench/infra/server/openresty.conf`.
