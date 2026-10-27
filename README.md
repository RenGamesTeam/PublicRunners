# PublicRunners

Runs an **ephemeral self-hosted runner for a GitHub organisation** out of ordinary
GitHub-hosted jobs and keeps it alive by handing over to a successor job.

```
hosted job ──► registers a runner ──► runner serves one job ──► deregisters
     ▲                                                              │
     └──────────── monitor job dispatches the next run ◄────────────┘
```

The setup is useful when an organisation needs a Linux or Windows machine with
a specific toolchain (for example a Unity build machine) that is reachable from
other repositories in the same organisation.

> ## ⚠️ Compliance warning
>
> A public repository gets unlimited free GitHub-hosted minutes. This project
> uses those minutes to run a runner that is registered to an **organisation**,
> so jobs from **private** repositories can run on it. That can be read as
> avoiding Actions billing and may violate the
> [GitHub Terms of Service](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service)
> and the [Actions billing rules](https://docs.github.com/en/billing/managing-billing-for-github-actions/about-billing-for-github-actions).
>
> Treat this repository as an experiment/learning project. Before using it for
> production work, confirm with your GitHub account manager or legal team that
> the usage is allowed, or use a regular self-hosted machine, a larger runner,
> or GitHub Enterprise Cloud with included minutes.

## How it works

Each workflow (`runner-ubuntu.yml`, `runner-windows.yml`) owns two jobs:

1. **`runner`** — runs on a hosted runner, installs the Actions runner, and
   starts a loop of *ephemeral* runners. Every iteration registers a uniquely
   named runner (`pr-ubuntu-<run_id>-<n>`), waits for one job, removes the
   workspace, and repeats until the time budget is used up.
2. **`monitor`** — runs after the runner job (`if: always()`), inspects the
   runner job through the API and dispatches a successor run when the chain
   should continue.

A `concurrency` group keeps one chain per workflow, so two runs never compete
for the same labels or delete each other's runners.

A third workflow, **`runner-watchdog.yml`**, runs on a schedule and restarts a
chain that died without handing over. It never starts a second chain while one
is active, respects a recent cancellation, and gives up after a streak of
failures.

### Why the chain is hard to kill

| Failure | Recovery |
| --- | --- |
| Runner job crashes or times out | Monitor sees the failed job, waits, dispatches a successor |
| Monitor job itself fails | Watchdog restarts the chain within 30 minutes |
| Runner chain stops after a cancellation | Watchdog waits 24h, then restarts |
| Token/permission broken | After 5 consecutive failures the chain stops instead of looping; fix the token and dispatch manually |
| Chain intentionally disabled | `RUNNER_CHAIN_ENABLED=false` disables runners, monitor dispatch and watchdog |

`MAX_CONSECUTIVE_FAILURES` (default 5) is the circuit breaker for a broken
setup: without it a bad token would produce hundreds of failing runs per day.

## Requirements

- An organisation owner token with the `admin:org` scope (or a GitHub App with
  the *Self-hosted runners* organisation permission). It is used **only** to
  create registration tokens and to list/delete stale runners.
- A repository secret `TOKEN` holding that token.
- The workflows on the default branch (the watchdog only dispatches workflows
  that exist there).

### Recommended: GitHub App instead of a PAT

A classic PAT is long-lived and grants broad access. A GitHub App with a
short-lived installation token is strongly preferred. The scripts only need a
token with `admin:org` equivalent (self-hosted runners) and, for the workflow
itself, no additional scopes.

## Setup

1. Create the repository secret `TOKEN` (organisation admin token, `admin:org`).
2. Merge the workflows into the default branch.
3. Dispatch `Ubuntu Runner` once by hand:

   ```bash
   gh workflow run runner-ubuntu.yml
   ```

   From this point on the chain dispatches its own successor, and the watchdog
   restarts it if it dies.

4. (Optional) Dispatch `Windows Runner` the same way.

### Dry run

`dry_run` exercises the entire chain without registering a runner and without
using an admin token:

```bash
gh workflow run runner-ubuntu.yml \
  -f dry_run=true \
  -f duration_seconds=90 \
  -f chain_budget=2
```

`chain_budget` is the total number of runs that may still exist in the chain;
`2` means this run plus one successor, after which the chain stops. The `dry_run`
run consumes no admin token and finishes in a couple of minutes, which makes it a
safe end-to-end test of the handover.

## Configuration

### Workflow inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `duration_seconds` | `18000` | Runner loop budget, capped at 5h (job limit is 6h) |
| `poll_interval_seconds` | `120` | Monitor polling interval |
| `retry_delay_seconds` | `600` | Wait before retrying after a failed runner job |
| `chain_budget` | `0` | Successor runs still allowed, `0` = unlimited |
| `runner_prefix` | `pr-ubuntu` / `pr-windows` | Runner names and cleanup prefix |
| `labels` | `self-hosted,Linux,X64` / `self-hosted,Windows,X64` | Runner labels |
| `dry_run` | `false` | Skip registration and just hold the job |

### Repository variables (Settings → Secrets and variables → Actions → Variables)

| Variable | Default | Meaning |
| --- | --- | --- |
| `RUNNER_CHAIN_ENABLED` | `true` | `false` stops runners and watchdog |
| `MAX_CONSECUTIVE_FAILURES` | `5` | Failure-circuit-breaker for the monitor |
| `WATCHDOG_WORKFLOWS` | `runner-ubuntu.yml` | Comma separated workflows to supervise |
| `WATCHDOG_MAX_IDLE_HOURS` | `12` | Never restart a chain older than this |
| `WATCHDOG_MAX_CONSECUTIVE_FAILURES` | `5` | Watchdog gives up after this many failures |
| `WATCHDOG_CANCEL_COOLDOWN_HOURS` | `24` | Honour a manual cancellation for this long |

### Stopping the chain

- Cancel the current run: the monitor treats `cancelled` as a deliberate stop
  and the watchdog stays away for `WATCHDOG_CANCEL_COOLDOWN_HOURS` (24h).
- Stop for good: set the repository variable `RUNNER_CHAIN_ENABLED=false`
  (and/or disable the workflows in the Actions tab).

## Repository layout

```
.github/workflows/
  runner-ubuntu.yml       chain for the Linux runner
  runner-windows.yml      chain for the Windows runner
  runner-watchdog.yml     schedule based supervisor
src/common/
  lib.sh                  logging + retrying GitHub API client
  monitor.sh              decides whether to dispatch a successor
  start_workflow.sh       workflow_dispatch with validation
  consecutive_failures.sh counts a failure streak
  watchdog.sh             restarts dead chains
  gen_runner_token.sh     organisation registration token
  remove_runner.sh        deletes stale runners by name prefix
src/ubuntu/
  setup.sh                downloads + checksum-verifies the runner
  run-loop.sh             ephemeral runner loop
src/windows/
  lib.ps1                 logging + retrying GitHub API client
  setup.ps1               downloads + checksum-verifies the runner
  run-loop.ps1            ephemeral runner loop
tests/
  mock_github.py          offline GitHub API mock
  run-tests.sh            test suite
  check-powershell.ps1    PowerShell syntax check
```

## Tests

The test suite is fully offline: it starts `tests/mock_github.py`, points the
scripts at it with `GITHUB_API_URL`, and checks the API traffic and exit codes.

```bash
bash tests/run-tests.sh
```

Requirements: `bash`, `curl`, `jq`, `python3`. `actionlint` is used when
present (see `.tools/`) but is optional.

## Security notes

- The admin token is passed through the environment (`RUNNER_ADMIN_TOKEN`),
  never as a command line argument, so it does not appear in the process list.
- Chain dispatching and monitoring use the short-lived `GITHUB_TOKEN`
  (`actions: write`), not the admin token.
- The runner archive is pinned and its SHA-256 checksum is verified before
  extraction. Actions are pinned to commit SHAs.
- Runners are **ephemeral**: they accept exactly one job, deregister, and their
  workspace is deleted. A compromised job cannot persist for the next one.
- Scripts are executed with `bash <path>`; the repository does not run
  `chmod -R 777` anywhere.
- Runner labels are visible to the whole organisation. An organisation runner
  can pick up jobs from any repository in the org unless you restrict it with
  runner groups (Settings → Actions → Runner groups).

## Limitations

- One runner job per operating system at a time (by design, to avoid a queue of
  pending runs). Increase the number of chains carefully: the cleanup deletes
  runners by prefix, so give each parallel chain its own `runner_prefix`.
- A hosted job is capped at 6 hours; the default cycle is 5 hours, leaving room
  for setup and handover.
- The hosted job consumes public-repository minutes (free) while the nested
  runner serves the organisation. See the compliance warning above.
