# High-load AWS benchmark suite for Finch

This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds.

PLANS.md is checked in at `.agent/PLANS.md` in this repo. This ExecPlan must be maintained in accordance with that file.

## Purpose / Big Picture

After this change, a developer can run three commands from the repository root to (1) provision a dedicated client VM and server VM in AWS EC2, (2) run a high-load, realistic HTTP benchmark suite that compares Finch against other Elixir/Erlang HTTP clients and against different Finch versions, and (3) tear down the infrastructure. Benchmarks can be run for Finch alone or for all included clients by setting `BENCH_CLIENTS`; the initial included set is Finch, Hackney 2.0, and Gun. Results will be stored locally under `results/<timestamp>/` with machine metadata, scenario definitions, and performance summaries so the user can compare runs over time. The system will be demonstrably working when `./bin/infra-up` provisions two instances, `./bin/bench-run` produces a results folder with benchmark summaries, and `./bin/infra-down` cleanly destroys all AWS resources.

## Progress

- [x] (2026-01-26 00:00Z) Drafted initial ExecPlan covering AWS infra, benchmark suite design, and automation commands.
- [x] (2026-01-26 00:00Z) Updated plan to narrow the client set to Finch, Hackney 2.0, and Gun, and to add a client registry plus `BENCH_CLIENTS` selection.
- [x] (2026-01-26 00:00Z) Updated plan to use OpenResty for the server and add a dynamic `/delay/<ms>` endpoint.
- [x] (2026-01-26 00:00Z) Updated plan to use mise instead of asdf for Erlang/Elixir installation on the client VM.
- [x] (2026-01-26 00:00Z) Updated plan to use ddskerl (ddskerl_counters) instead of hdr_histogram for latency percentiles.
- [x] (2026-01-26 16:00Z) Implement Terraform module and infra scripts for client/server VMs.
- [x] (2026-01-26 16:00Z) Implement bench suite Mix project with client adapters, config, and result handling.
- [x] (2026-01-26 16:00Z) Implement server provisioning and endpoint configuration using OpenResty.
- [x] (2026-01-26 16:00Z) Implement client adapters, runner, metrics, and results writer.
- [x] (2026-01-26 16:00Z) Implement orchestration script to sync code, run benchmarks remotely, and collect artifacts.
- [x] (2026-01-26 16:00Z) Add documentation, validation steps, and minimal tests for bench suite helpers.

## Surprises & Discoveries

- Observation: None yet.
  Evidence: Plan creation only; no implementation executed.

## Decision Log

- Decision: Use Terraform to build a dedicated VPC with one public subnet, an internet gateway, and two EC2 instances (client and server) with security groups that only allow benchmark traffic between them.
  Rationale: A dedicated VPC avoids dependency on a default VPC and makes the infrastructure self-contained and reproducible.
  Date/Author: 2026-01-26 / Codex

- Decision: Implement the benchmark suite as a separate Mix project under `suite` so it can depend on multiple HTTP client libraries without affecting Finch’s main dependencies.
  Rationale: Keeps benchmark dependencies isolated and avoids accidental changes to Finch’s public dependency graph.
  Date/Author: 2026-01-26 / Codex

- Decision: Provide three user-facing commands as shell scripts in `bin`: `infra-up`, `bench-run`, and `infra-down`.
  Rationale: The requirement explicitly asks for one command to provision, one to run, and one to tear down.
  Date/Author: 2026-01-26 / Codex

- Decision: Default Finch dependency in the bench suite to the local path (`../../`) and allow overrides via environment variables for git or hex versions.
  Rationale: This enables easy comparison of uncommitted local changes while still supporting version comparisons.
  Date/Author: 2026-01-26 / Codex

- Decision: Include Finch, Hackney 2.0, and Gun as the initial benchmarked clients and exclude Mint, Req, and :httpc for now.
  Rationale: This keeps the initial scope focused while still covering three distinct HTTP stacks.
  Date/Author: 2026-01-26 / Codex

- Decision: Use a client registry and a `BENCH_CLIENTS` selector so a run can target Finch only or all included clients, and adding new clients only requires a new adapter plus a registry entry.
  Rationale: This satisfies the requirement for easy single-client runs and ensures extensibility for future clients.
  Date/Author: 2026-01-26 / Codex

- Decision: Use a standalone HTTP server (OpenResty) on the server VM instead of an Elixir test server, including a dynamic `/delay/<ms>` endpoint implemented in configuration.
  Rationale: Removes Elixir runtime dependency from the server VM and makes server behavior uniform and reproducible across runs; OpenResty provides the Lua support needed for `/delay/<ms>`.
  Date/Author: 2026-01-26 / Codex

- Decision: Use mise (not asdf) for installing Erlang and Elixir on the client VM.
  Rationale: Aligns with the preference specified for toolchain management.
  Date/Author: 2026-01-26 / Codex

- Decision: Use ddskerl (specifically the ddskerl_counters implementation) to compute percentiles with low overhead.
  Rationale: Avoids NIF build issues seen with hdr_histogram on OTP 28/arm64 while keeping insert overhead low.
  Date/Author: 2026-01-26 / Codex

- Decision: Raise file descriptor limits and set `fs.file-max`/`fs.nr_open` in user data, and apply `ulimit -n` in the run scripts.
  Rationale: Prevent OS limits from capping the benchmark workload on high concurrency runs.
  Date/Author: 2026-01-26 / Codex

## Outcomes & Retrospective

Implemented the Terraform module, OpenResty server configuration, benchmark suite (clients, runner, metrics, and result writer), automation scripts, and documentation/tests required to run the benchmarks end-to-end. The system has not yet been validated against live AWS infrastructure; the next step is to run `./bin/infra-up`, `./bin/bench-run`, and `./bin/infra-down` to confirm behavior and capture runtime evidence. (2026-01-26 / Codex)

## Context and Orientation

Finch is an HTTP client library whose source lives under `lib/`. This plan introduces a new benchmarking suite under `suite`, a standalone OpenResty-based server configuration under `infra/server`, and new infrastructure automation under `infra` and `bin`.

Terraform is a declarative tool that describes cloud infrastructure in text files and then creates, updates, or destroys it. EC2 is AWS’s virtual machine service. An AMI is a base machine image from which an EC2 instance is created. A VPC is a private virtual network; a subnet is a range of IP addresses inside a VPC. A security group is a virtual firewall that controls which IPs and ports can reach an instance. These terms are used throughout this plan.

The “client VM” will generate load and run the benchmark runner. The “server VM” will host a dedicated HTTP server that returns predictable responses designed for realistic load profiles. This separation ensures network and server overhead are representative of real deployments.

## Milestones

Milestone 1 establishes the infrastructure and automation primitives. At the end of this milestone, running `./bin/infra-up` will create two reachable EC2 instances and write a local `infra/hosts.json` with the IPs, SSH user, and ports. `./bin/infra-down` will destroy all created resources. Acceptance is a successful SSH connection to both instances and a passing `curl` from client to server on the benchmark port.

Milestone 2 implements server provisioning and endpoint configuration using OpenResty. At the end of this milestone, the server VM will run a standalone HTTP server that serves `/health`, `/small`, `/large`, `/json`, `/echo`, `/stream`, and `/delay/<ms>` with deterministic payload sizes. The `/delay/<ms>` endpoint must sleep for the requested number of milliseconds before responding. Acceptance is a `curl http://<server-ip>:8080/health` returning HTTP 200, `curl http://<server-ip>:8080/large` returning the expected byte size, and `curl http://<server-ip>:8080/delay/100` delaying roughly 100 ms before responding.

Milestone 3 implements the benchmark runner and client adapters. At the end of this milestone, `mix bench.run` will run one or more scenarios against the server, collecting throughput and latency metrics for each client, and writing results to a specified directory as JSON and CSV. Acceptance is a local run with `BENCH_CLIENTS=finch` producing a results directory with only Finch entries, and a run with `BENCH_CLIENTS=all` (or default) producing one entry per included client.

Milestone 4 connects infrastructure and runner automation. At the end of this milestone, `./bin/bench-run` will sync the current repo to both EC2 instances, start the server, run the benchmark on the client, collect results back to `results/<timestamp>/`, and stop the server. Acceptance is a completed end-to-end run on EC2 with results stored locally and `infra-down` successfully tearing down resources afterward.

## Plan of Work

Create a new Terraform module under `infra/terraform`. Add `versions.tf` to pin Terraform and the AWS provider. Add `variables.tf` for region, instance types, key path, admin CIDR, and benchmark ports. Add `main.tf` to define a VPC, public subnet, internet gateway, route table, security groups, key pair, and two EC2 instances. Add `outputs.tf` to emit client and server public IPs, server private IP, and SSH user. Add `user_data_client.sh` and `user_data_server.sh` to install base packages, apply OS tuning (including `fs.file-max`, `fs.nr_open`, and nofile limits), and create working directories. The client VM bootstrap installs mise plus the Erlang/Elixir versions listed in `infra/versions.env`. The server VM bootstrap installs OpenResty and leaves it stopped so the bench script can start it with a repo-provided configuration. The user-facing `bin/infra-up` script will generate a `terraform.tfvars` from environment variables, run `terraform init` and `terraform apply`, and write `infra/hosts.json` from `terraform output -json`.

Create a new Mix project at `suite`. Add `suite/mix.exs` with dependencies on Finch (path/git/hex selectable), Hackney (2.0 series), Gun, Jason, and ddskerl (use ddskerl_counters) for percentile latencies. Add `suite/.formatter.exs` and `suite/config/config.exs` with baseline settings. Implement a `Bench.Config` module that loads settings from environment variables and an optional config file path, including a `BENCH_CLIENTS` selector that accepts `finch`, `hackney`, `gun`, or `all` (defaulting to all). Implement `Bench.Scenario` as a struct describing method, path, and body, with scenarios that target the OpenResty endpoints including `/delay/<ms>`.

Add a new server configuration directory at `infra/server`. Include an OpenResty configuration file (for example `infra/server/openresty.conf`) and any static payload files (for example `infra/server/static/small.bin`, `large.bin`, and `json.json`). The OpenResty config should define the endpoints `/health`, `/small`, `/large`, `/json`, `/echo`, `/stream`, and `/delay/<ms>`; `/delay/<ms>` must sleep for the requested milliseconds using Lua (`ngx.sleep(ms/1000)`), and `/stream` should emit chunked responses with `ngx.flush(true)` between chunks. The config should be written so it can be launched with `openresty -p /tmp/bench-server -c /path/to/openresty.conf` without requiring root-owned paths.

Implement `Bench.Client` as a behaviour and write adapters under `suite/lib/bench/clients/` for Finch, Hackney, and Gun. Add a `Bench.ClientRegistry` module that maps stable client ids (`:finch`, `:hackney`, `:gun`) to adapter modules so new clients can be added by implementing the behaviour and adding a single registry entry. Each adapter should support persistent connections and configurable pooling where the underlying client supports it. Implement a `Bench.Runner` that spawns a fixed number of worker processes, runs a warmup phase, runs for a fixed duration, captures per-request latency and error counts, and writes a result record per client and per scenario. Implement `Bench.Metrics` to aggregate stats using ddskerl_counters so p50, p90, p99, min, max, and mean are reported. Implement a `Bench.ResultWriter` to emit `summary.csv` and `metadata.csv` including scenario config, client versions, Finch source, and machine information.

Add `suite/lib/mix/tasks/bench.run.ex` so a user can run the benchmarks with `mix bench.run`. Add minimal ExUnit tests under `suite/test` for config parsing and metrics aggregation to satisfy validation requirements without adding heavy test burden.

Create automation scripts under `bin`. `bin/infra-up` provisions infra and bootstraps both machines by installing mise, Erlang, Elixir on the client VM, required packages, and OpenResty on the server VM, then writes `infra/hosts.json`. `bin/bench-run` uses `rsync` to copy the local repo to both VMs (excluding `_build`, `deps`, `tmp`, and `results`), configures and starts the standalone server on the server VM using the OpenResty config in `infra/server`, waits for `/health`, runs the benchmark on the client VM with the requested client list and Finch version(s), collects results to `results/<timestamp>/`, and stops the server. `bin/infra-down` runs `terraform destroy` using the same variables, and cleans up any generated `terraform.tfvars` and `hosts.json` files locally.

Add `README.md` describing the three commands, expected prerequisites, environment variables, and how to interpret the results. Ensure all added scripts are executable and use `bash` with `set -euo pipefail`.

## Concrete Steps

From the repo root, create the new directories `infra/terraform`, `suite`, and `bin`. Add the Terraform files and user data scripts, then add the bench suite Mix project files and modules. After code changes, run formatting in `suite` and ensure scripts have execute bits.

When validating infrastructure locally, run the following from `/Users/nico/Code/github.com/sneako/finch`:

    ./bin/infra-up

Expected output includes a short summary and a populated `infra/hosts.json` file with `client_public_ip` and `server_public_ip`.

When validating the server locally, start OpenResty with the benchmark configuration (for example, from the repo root):

    openresty -p /tmp/bench-server -c /Users/nico/Code/github.com/sneako/http_client_bench/infra/server/openresty.conf

Then run:

    curl http://localhost:8080/health
    curl http://localhost:8080/large
    time curl http://localhost:8080/delay/100

Expected output includes HTTP 200 for `/health`, the expected byte size for `/large`, and an observed delay of roughly 100 ms for `/delay/100`. If OpenResty is not installed locally, skip this local server check and validate on the server VM after `./bin/infra-up`.

When validating the runner locally, with the server still running, run a Finch-only benchmark and an all-clients benchmark:

    MIX_ENV=bench mix deps.get
    MIX_ENV=bench mix compile
    BENCH_CLIENTS=finch MIX_ENV=bench mix bench.run
    BENCH_CLIENTS=all MIX_ENV=bench mix bench.run

Expected output includes results directory paths and summary lines showing requests per second and p99 latency for the selected clients.

When validating the end-to-end AWS run, run:

    ./bin/bench-run

Expected output includes the remote run start, a local results path, and a final summary line pointing to `results/<timestamp>/summary.csv`.

Finally, clean up with:

    ./bin/infra-down

Expected output shows Terraform destroying both EC2 instances and the VPC resources.

## Validation and Acceptance

Acceptance requires a full AWS run and a local smoke test.

For local validation, run `MIX_ENV=bench mix test` inside `suite` and expect all tests to pass. Then run the local OpenResty server and the benchmark runner to confirm a local results directory is created with `summary.csv` and `metadata.csv`.

For AWS validation, run `./bin/infra-up`, then `./bin/bench-run`, then `./bin/infra-down`. The benchmark run should produce at least one client result per scenario, with non-zero request counts and a p99 latency value. The server log should show at least one request for each scenario, and the client log should show zero or low error rate. Run at least one Finch-only pass (`BENCH_CLIENTS=finch`) and one all-clients pass (default or `BENCH_CLIENTS=all`). Acceptance is observed when these artifacts exist and contain plausible data.

## Idempotence and Recovery

`./bin/infra-up` must be safe to run multiple times; it should reuse existing Terraform state and only apply changes if necessary. If provisioning fails, rerun the same command after fixing the underlying issue; Terraform will converge on the desired state.

`./bin/bench-run` should be safe to rerun; it should create a new timestamped results directory each time and must stop the server even if the benchmark fails. If the server fails to start, the script should surface logs from `results/<timestamp>/server.log` and exit non-zero.

`./bin/infra-down` should be safe to run multiple times. If it fails, rerun until it completes; it should not require manual AWS cleanup in normal cases.

## Artifacts and Notes

The canonical results folder structure is:

    results/2026-01-26T120000Z/
      summary.csv
      metadata.csv
      client.log
      server.log
      system_client.txt
      system_server.txt

Example `summary.csv` columns should include `scenario`, `client`, `rps`, `latency_ms_p50`, `latency_ms_p90`, `latency_ms_p99`, `errors`, and `duration_seconds`. `metadata.csv` should include the Finch source (`path`, `git`, or `hex`), the Finch version or git SHA, the list of clients, and the full scenario configuration.

## Interfaces and Dependencies

The three user-facing scripts are required and must live at the following paths with the following behavior:

- `bin/infra-up` provisions infrastructure and writes `infra/hosts.json`. It accepts configuration via environment variables such as `AWS_PROFILE`, `AWS_REGION`, `BENCH_CLIENT_INSTANCE_TYPE`, `BENCH_SERVER_INSTANCE_TYPE`, `BENCH_SSH_KEY_PATH`, `BENCH_ADMIN_CIDR`, and `BENCH_RESULTS_BUCKET`. It must print the client and server IPs on success.

- `bin/bench-run` reads `infra/hosts.json`, syncs the repo to the VMs, starts the server, runs the benchmark, and copies results to `results/<timestamp>/`. It accepts `BENCH_CLIENTS` (comma-separated list of client ids, or `all`; default `finch,hackney,gun`), `BENCH_SCENARIOS`, `BENCH_DURATION`, `BENCH_CONCURRENCY`, `BENCH_FINCH_SOURCE`, `BENCH_FINCH_REF`, and `BENCH_FINCH_MATRIX` to run multiple Finch versions sequentially.

- `bin/infra-down` destroys infrastructure using the same Terraform state and variables used by `infra-up`.

The standalone server configuration lives under `infra/server`. The OpenResty config must implement the following fixed behaviors so benchmarks are comparable across runs: `/health` returns status 200 with body `OK`; `/small` returns exactly 4096 bytes; `/large` returns exactly 1048576 bytes; `/json` returns a deterministic JSON object from a static file; `/echo` returns the request body as-is; `/stream` returns exactly 1048576 bytes in 64 chunks flushed with `ngx.flush(true)`; `/delay/<ms>` sleeps for the requested number of milliseconds and then returns status 200 with a small body (for example `delayed <ms>`). These sizes must be documented in the config and re-used by the benchmark scenarios.

The benchmark suite must define the following interfaces:

In `suite/lib/bench/client.ex`, define a behaviour:

    defmodule Bench.Client do
      @callback id() :: atom()
      @callback setup(Bench.Config.t()) :: {:ok, state} | {:error, term()}
      @callback request(state, Bench.Scenario.t()) :: :ok | {:error, term()}
      @callback teardown(state) :: :ok
    end

In `suite/lib/bench/runner.ex`, define:

    defmodule Bench.Runner do
      @spec run(Bench.Config.t()) :: {:ok, Bench.Result.t()} | {:error, term()}
    end

In `suite/lib/bench/scenario.ex`, define:

    defmodule Bench.Scenario do
      defstruct name: nil,
                scheme: "http",
                host: "localhost",
                port: 8080,
                method: :get,
                path: "/health",
                headers: [],
                body: nil,
                response_bytes: 0
    end

The `Bench.Result` struct must include the client id, scenario name, request count, error count, elapsed time, and percentile latency fields. `Bench.ResultWriter` must emit `summary.csv` and `metadata.csv` to a directory specified by the config.

In `suite/lib/bench/client_registry.ex`, define:

    defmodule Bench.ClientRegistry do
      @spec all_ids() :: [atom()]
      @spec resolve([atom()]) :: [module()]
    end

The registry should expose all available client ids and provide a resolver for the selected client list. Adding a new client should only require implementing `Bench.Client` in a new module and adding it to this registry.

Dependencies required on the local machine are `terraform`, `ssh`, `rsync`, and `jq`; OpenResty is required only if you want to run the server locally for validation. Dependencies required on the VMs are `git`, `curl`, `build-essential`, OpenResty on the server VM, and the Erlang/Elixir versions specified in `infra/versions.env`, installed via mise on the client VM.

## Change Note

Initial ExecPlan created to satisfy the request for an AWS-backed, high-load, comparable benchmark suite with three command entry points.
Updated the plan to focus the initial client set on Finch, Hackney 2.0, and Gun, and to require an explicit client registry and `BENCH_CLIENTS` selector so Finch-only and all-client runs are trivial and new clients can be added easily. (2026-01-26 / Codex)
Updated the plan to use OpenResty as the standalone server, remove the Elixir server task, and add a dynamic `/delay/<ms>` endpoint. (2026-01-26 / Codex)
Updated the plan to use mise instead of asdf for Erlang/Elixir installation on the client VM. (2026-01-26 / Codex)
Updated the plan to use ddskerl (ddskerl_counters) instead of hdr_histogram for percentile metrics. (2026-01-26 / Codex)
Updated progress and outcomes to reflect completed implementation steps. (2026-01-26 / Codex)
Updated the plan to call out nofile/sysctl tuning to avoid OS limits during high-load runs. (2026-01-26 / Codex)
