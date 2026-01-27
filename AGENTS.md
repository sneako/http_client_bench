# Repository Guidelines

These guidelines describe how to navigate, build, test, and contribute to the HTTP client benchmark suite.

## Project Structure & Module Organization
- `bin/` contains the user-facing automation commands (`infra-up`, `bench-run`, `infra-down`).
- `infra/` contains Terraform, server config, and host inventory (`hosts.json`).
- `infra/server/` holds the OpenResty config and static payloads.
- `suite/` is a standalone Mix project implementing clients, runner, and reporting.
- `results/` contains benchmark artifacts (do not commit).
- `.agent/execplans/` contains ExecPlans for major work.

## Build, Test, and Development Commands
- `./bin/infra-up` provisions AWS infrastructure.
- `./bin/bench-run` runs the benchmark suite.
- `./bin/infra-down` destroys AWS infrastructure.
- `cd suite && mix deps.get` installs Elixir dependencies.
- `cd suite && mix compile` compiles the suite.
- `cd suite && MIX_ENV=bench mix test` runs suite tests.
- `cd suite && mix format` formats Elixir code.

## Coding Style & Naming Conventions
- Use `mix format` for consistent formatting; Elixir uses 2-space indentation and no tabs.
- Module names are `CamelCase`; file names are `snake_case.ex` or `snake_case.exs`.
- Keep APIs explicit and documented where public-facing; prefer small, focused functions.

## Testing Guidelines
- Use ExUnit with files named `*_test.exs` under `suite/test`.
- Favor deterministic tests; keep network/server helpers behind existing fixtures and helpers.

## Generated/Transient Directories
- `results/`, `infra/terraform/.terraform/`, `suite/_build/`, `suite/deps/`, and `suite/tmp/` are transient and should not be committed.

## ExecPlans
When writing complex features or significant refactors, use an ExecPlan (as described in `.agent/PLANS.md`) from design to implementation.
