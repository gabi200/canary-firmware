# Hub Software Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the hub's Pis from Administration → Hub (all Pis one at a time, or one Pi), see GitHub's new commits and each Pi's commit, with automatic rollback.

**Architecture:** A stdlib-only Python helper (`canary-updater`, systemd, port 8010) on every Pi runs git / docker compose / health checks outside Docker and coordinates rollouts. The backend only proxies to the helpers (`/api/v1/hub/software`). The Hub tab gets a Software section and per-Pi software rows.

**Tech Stack:** Python 3 stdlib (helper), FastAPI + SQLAlchemy (backend), React + TanStack Query + TypeScript (web), bash.

**Spec:** `docs/superpowers/specs/2026-11-02-hub-software-updates-design.md`

## Global Constraints

- Helper: Python 3 standard library only; no pip install on the host.
- Helper port **8010**; auth header **`X-Canary-Updater-Key`** = `CANARY_UPDATER_KEY` from `RPISoftware/.env`; wrong/missing key → **404**.
- Only `main`; fast-forward only; commits must match `^[0-9a-f]{40}$` and be ancestor-or-equal of `origin/main`.
- Build time limit **1800 s**; health wait **300 s**; background fetch every **900 s**; UI polling **10 s**, **3 s** while an update runs; helper log keeps the last **50** lines; `/incoming` returns at most **30** commits.
- Roles for every `/api/v1/hub/software` endpoint: `hoa_manager`, `technician` (`system_admin` passes `require_roles` already).
- No Docker socket or host shell in the backend container.
- All new UI text in English and Romanian (`web/src/i18n.tsx`).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Helper dies mid-update (power cut, crash) → on restart a persisted `updating`/`rolling_back` state becomes `failed` with "interrupted", never stuck "updating" forever (Task 3).
2. Peer helper briefly unreachable while it rebuilds or restarts itself during a rollout → the coordinator keeps polling until the per-Pi timeout instead of stopping the rollout (Task 4).
3. Two clicks / two users at once → the second `/update` or `/rollout` gets 409 "busy", not a second job (Task 5).
4. `docker compose ps --format json` prints either one JSON object per line or one JSON array, depending on the Compose version → both parse (Task 3).
5. Dashboard served by the Pi that is rebuilding → the page keeps showing the last data with "reconnecting" and recovers by itself (Task 8).

---

## File Structure

```
RPISoftware/cluster/updater/__init__.py      package marker
RPISoftware/cluster/updater/runner.py        Result, Runner (subprocess, HTTP, sleep, clock)
RPISoftware/cluster/updater/config.py        Config, load_config (.env parsing)
RPISoftware/cluster/updater/gitops.py        git queries and moves
RPISoftware/cluster/updater/store.py         StateStore (JSON state file)
RPISoftware/cluster/updater/pi.py            PiUpdater: one Pi's update, health, rollback
RPISoftware/cluster/updater/rollout.py       Rollout: update all Pis in order
RPISoftware/cluster/updater/server.py        HTTP API, auth, job lock, fetch timer
RPISoftware/cluster/updater/__main__.py      entry point (python3 -m updater)
RPISoftware/cluster/updater/tests/fakes.py   FakeRunner
RPISoftware/cluster/updater/tests/test_*.py
RPISoftware/cluster/canary-updater.service   systemd unit
RPISoftware/scripts/hub_update.sh            shell client
RPISoftware/scripts/pi_setup.sh              + CANARY_UPDATER_KEY, install hint
RPISoftware/backend/app/config.py            + updater_key, updater_port
RPISoftware/backend/app/software.py          helper client + aggregation
RPISoftware/backend/app/api/software.py      /api/v1/hub/software router
RPISoftware/backend/app/main.py              include router
RPISoftware/backend/tests/test_software.py
RPISoftware/web/src/api/types.ts             Software* types
RPISoftware/web/src/api/adminHooks.ts        useSoftware, useSoftwareFetch, useSoftwareUpdate
RPISoftware/web/src/lib/software.ts          status → text/tone, blockers
RPISoftware/web/src/lib/software.check.ts    runnable check
RPISoftware/web/src/views/admin/SoftwarePanel.tsx   Software section + PiSoftware row
RPISoftware/web/src/views/admin/HubTab.tsx   mount both
RPISoftware/web/src/i18n.tsx                 sw.* strings (en + ro)
RPISoftware/RUNME.md                         new section, 3.1 port list, 3.3 row
```

Helper tests run with: `cd RPISoftware/cluster && ../backend/.venv/bin/python -m pytest updater/tests -q`.
Backend tests: `cd RPISoftware/backend && .venv/bin/python -m pytest -q`.

---

### Task 1: Helper foundation: runner, config, git, state store

**Files:**
- Create: `RPISoftware/cluster/updater/{__init__,runner,config,gitops,store}.py`, `RPISoftware/cluster/updater/tests/{__init__,fakes}.py`
- Test: `RPISoftware/cluster/updater/tests/test_foundation.py`

**Interfaces:**
- Produces:
  - `runner.Result(code: int, out: str)` (dataclass); `runner.Runner` with
    `run(args: list[str], *, cwd: Path, timeout: float) -> Result` (timeout → `Result(124, "timed out")`, missing binary → `Result(127, ...)`),
    `http(method: str, url: str, *, body: dict | None = None, headers: dict[str, str] | None = None, timeout: float = 3.0) -> tuple[int, dict]` (status 0 and `{}` on connection error; non-JSON body → `{}`),
    `sleep(s: float) -> None`, `now() -> float` (monotonic).
  - `tests/fakes.FakeRunner(Runner)`: `on(prefix: tuple[str, ...], result: Result | Callable[[list[str]], Result])` matches `run` args by longest prefix; `on_http(method: str, url: str, reply: tuple[int, dict] | Callable[[dict | None], tuple[int, dict]])`; `calls: list[list[str]]`; `http_calls: list[tuple[str, str, dict | None]]`; `sleep` advances `now()`; unmatched run → `Result(0, "")`, unmatched http → `(0, {})`.
  - `config.Config(repo: Path, app_dir: Path, node: str, triple: bool, node_ip: str, peers: dict[str, str], key: str, port: int, state_file: Path)` (frozen dataclass). `peers` maps name → IP for all three Pis including this one in triple mode, `{"hub": "127.0.0.1"}` in single mode.
  - `config.load_config(app_dir: Path, repo: Path, state_file: Path) -> Config`: reads `app_dir/.env` (`KEY=VALUE`, `#` comments, blank lines; values not unquoted); `triple` = `CANARY_CLUSTER_MODE == "triple"`; `node` = `CANARY_NODE_NAME` (triple) else `"hub"`; `node_ip` = `CANARY_NODE_IP` (triple) else `"127.0.0.1"`; peers from `CANARY_PROCESSING_IP/WEB_IP/AI_IP`; `key` = `CANARY_UPDATER_KEY`; `port` = `CANARY_UPDATER_PORT` or 8010.
  - `gitops.SHA_RE`; functions taking `(r: Runner, repo: Path, ...)`:
    `head(r, repo, ref="HEAD") -> dict` (`{"sha", "subject", "date"}` via `git log -1 --format=%H%x1f%s%x1f%cI <ref>`; `None` if it fails),
    `branch(r, repo) -> str`, `dirty(r, repo) -> bool` (`git status --porcelain --untracked-files=no` non-empty),
    `counts(r, repo) -> tuple[int, int]` (behind, ahead from `git rev-list --left-right --count origin/main...HEAD`),
    `incoming(r, repo, limit=30) -> list[dict]` (`{"sha","subject","author","date"}`, `git log HEAD..origin/main -n 30 --format=%H%x1f%s%x1f%an%x1f%cI`),
    `fetch(r, repo) -> Result` (`git fetch --quiet origin main`, timeout 120),
    `on_main(r, repo, sha) -> bool` (`git merge-base --is-ancestor <sha> origin/main` code 0),
    `ff_merge(r, repo, sha) -> Result` (`git merge --ff-only <sha>`), `reset_hard(r, repo, sha) -> Result`,
    `changed(r, repo, a, b, path) -> bool` (`git diff --name-only a b -- path` non-empty).
  - `store.StateStore(path: Path)`: `load() -> dict` (`{}` if missing or corrupt), `save(state: dict) -> None` (write tmp file in same dir + `os.replace`, creates parent dirs).

- [ ] **Step 1: Write failing tests** in `test_foundation.py`:
  - `test_load_config_triple`: `.env` with `CANARY_CLUSTER_MODE=triple`, `CANARY_NODE_NAME=web`, `CANARY_NODE_IP=10.0.0.12`, the three IPs, `CANARY_UPDATER_KEY=k`, a comment line → `cfg.triple is True`, `cfg.node == "web"`, `cfg.peers == {"processing": "10.0.0.11", "web": "10.0.0.12", "ai": "10.0.0.13"}`, `cfg.port == 8010`, `cfg.key == "k"`.
  - `test_load_config_single`: only `CANARY_UPDATER_KEY=k` → `node == "hub"`, `peers == {"hub": "127.0.0.1"}`, `triple is False`.
  - `test_counts_and_head_parse`: FakeRunner answers `rev-list` with `"3\t1\n"` and `log -1` with `"a"*40 + "\x1ffix it\x1f2026-11-02T10:00:00+02:00\n"` → `counts == (3, 1)`, `head(...)["subject"] == "fix it"`.
  - `test_sha_re`: accepts 40 lowercase hex, rejects 39 chars, uppercase, `"main"`, `"a"*40 + ";rm"`.
  - `test_store_roundtrip_and_corrupt`: save/load equality; a file containing `"{"` loads as `{}`.
  - `test_real_runner_timeout_and_missing`: `Runner().run(["sleep", "5"], cwd=tmp, timeout=0.2).code == 124`; `run(["no-such-binary-xyz"], ...)`.code == 127.
- [ ] **Step 2: Run** `cd RPISoftware/cluster && ../backend/.venv/bin/python -m pytest updater/tests -q` → FAIL (import errors).
- [ ] **Step 3: Implement** the five modules and `fakes.py` per the Interfaces. `Runner.run` uses `subprocess.run(..., capture_output=True, text=True)`, joins stdout+stderr. `Runner.http` uses `urllib.request`.
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: Commit** `git add RPISoftware/cluster/updater && git commit -m "Add the update helper's git, config and state basics"`

### Task 2: Health probes and Patroni queries

**Files:**
- Create: `RPISoftware/cluster/updater/health.py`
- Test: `RPISoftware/cluster/updater/tests/test_health.py`

**Interfaces:**
- Consumes: Task 1 `Runner`, `Config`.
- Produces (all `(cfg: Config, r: Runner)`):
  - `EXPECTED_SINGLE = ("mosquitto", "backend", "web")`, `EXPECTED_TRIPLE = EXPECTED_SINGLE + ("etcd", "postgres", "pgproxy", "keepalived")`.
  - `compose_problem(cfg, r) -> str | None`: runs `docker compose ps --format json` in `cfg.app_dir`; parses one-object-per-line **or** a JSON array; problem when an expected service is missing, `State != "running"`, or `Health` not in `("", "healthy")`. Returns e.g. `"backend is starting"` / `"web is missing"`.
  - `backend_problem(cfg, r) -> str | None`: `GET http://127.0.0.1:8000/health` must be 200 with `status == "ok"`.
  - `patroni_members(cfg, r) -> list[dict] | None`: `GET http://<ip>:8008/cluster` on each peer IP until one answers; returns its `members` (`name`, `role`, `state`).
  - `patroni_problem(cfg, r) -> str | None`: triple only (single → `None`): this node's member `state` in `("running", "streaming")`.
  - `problem(cfg, r) -> str | None`: first of compose, backend, patroni.
  - `peer_problem(cfg, r, name: str) -> str | None`: `GET http://<peers[name]>:8000/health` ok, else `"<name> Pi is not healthy"`.

- [ ] **Step 1: Write failing tests**: `test_compose_lines_and_array_both_parse` (same services as NDJSON and as an array → `None`); `test_compose_reports_unhealthy` (`backend` with `Health: "starting"` → `"backend is starting"`); `test_compose_reports_missing` (no `web` row → `"web is missing"`); `test_triple_expects_cluster_services` (triple cfg without `postgres` row → `"postgres is missing"`); `test_patroni_replica_streaming_ok_and_stopped_not` (members with this node `state: "streaming"` → `None`; `"stopped"` → message containing `"stopped"`); `test_patroni_tries_next_peer` (first peer `(0, {})`, second answers → members returned).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** `health.py`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `"Add the update helper's health checks"`

### Task 3: Updating one Pi with rollback (`PiUpdater`)

**Files:**
- Create: `RPISoftware/cluster/updater/pi.py`
- Test: `RPISoftware/cluster/updater/tests/test_pi.py`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces:
  - `class Refused(Exception)` (message shown to the user).
  - `BUILD_TIMEOUT_S = 1800`, `HEALTH_TIMEOUT_S = 300`, `POLL_S = 5`, `LOG_LINES = 50`, `SWITCHOVER_TIMEOUT_S = 60`.
  - `class PiUpdater(cfg: Config, r: Runner, store: StateStore)`:
    - `status() -> dict`: `{"node", "commit": head, "branch", "dirty", "behind", "ahead", "fetched_at", "fetch_error", "state", "step", "target", "previous", "error", "log", "rollout", "restart_needed"}`. Defaults: `state "idle"`, others `None` / `[]`.
    - `recover() -> None`: called once at start; persisted `state` in `("updating", "rolling_back")` → `state "failed"`, `error "the updater stopped during the update (power cut or crash): check this Pi"`.
    - `preflight(sha: str, check_peers: bool = True) -> None`: raises `Refused` with these exact reasons in this order: `"an update is already running on this Pi"` (state updating/rolling_back), `"not on branch main"`, `"this Pi has local changes"`, `"unknown commit: fetch first"` (not `on_main`), and, triple with `check_peers`, `peer_problem` of any other Pi.
    - `begin(sha: str) -> None`: `preflight`, then persist `state "updating"`, `target sha`, `previous` = current HEAD sha, `error None`, fresh `log`, `step "starting"`.
    - `run() -> None`: steps below, persisting `step` and appending `log` (trimmed to `LOG_LINES`) after each.
    - `fetch() -> None`: `gitops.fetch`; sets `fetched_at` (UTC ISO with `Z`) on success, `fetch_error` (last output line) on failure.
    - `dismiss() -> None`: `rolled_back` / `failed` → `idle`, clears `error`.
  - `run()` steps: (1) triple and this node's Patroni role is `leader`: `docker compose exec -T postgres patronictl switchover --leader <node> --candidate <sync_standby or any streaming member> --force`, then poll `patroni_members` every `POLL_S` until another member is `leader` (≤ `SWITCHOVER_TIMEOUT_S`); failure → stop with `state "idle"`, `error "could not move the database off this Pi: …"`, nothing changed. (2) `ff_merge`. (3) `docker compose up -d --build` with `BUILD_TIMEOUT_S`. (4) poll `health.problem` every `POLL_S` until `None` or `HEALTH_TIMEOUT_S`. Success → `state "idle"`, `step "done"`, `restart_needed = gitops.changed(previous, target, "RPISoftware/cluster/updater")`. Any failure in 2–4 → rollback: `state "rolling_back"`, `reset_hard(previous)`, `docker compose up -d --build`, health wait; ok → `state "rolled_back"`, `error` = the original failure (`"build failed: <last line>"`, `"not healthy after 5 min: <problem>"`, `"git: <last line>"`); rollback failing → `state "failed"`, `error` = original failure + `"; rollback also failed: …"`.

- [ ] **Step 1: Write failing tests** (FakeRunner, tmp state file):
  - `test_happy_path_single`: `run` calls in order include `git merge --ff-only <sha>` then `docker compose up -d --build`; final `state "idle"`, `step "done"`, `previous` = old HEAD.
  - `test_build_failure_rolls_back`: `up -d --build` returns code 1 once, then 0 → calls include `git reset --hard <previous>`; `state "rolled_back"`; `error.startswith("build failed")`.
  - `test_unhealthy_rolls_back_after_timeout`: compose rows report `backend` `starting` until the reset, healthy after → `state "rolled_back"`, `"not healthy"` in `error`.
  - `test_rollback_failure_is_failed`: every build fails → `state "failed"`, `"rollback also failed"` in `error`.
  - `test_preflight_refusals`: one test per reason above, asserting the exact message.
  - `test_leader_switches_over_first` (triple, this node `leader`): the `patronictl switchover --leader web --candidate ai --force` call comes before `git merge`; `test_switchover_failure_changes_nothing`: leader never changes → no `git merge` call, `state "idle"`, error starts with `"could not move the database"`.
  - `test_recover_marks_interrupted_failed`: store holds `state "updating"` → after `recover()`, `state "failed"`.
  - `test_restart_needed_when_updater_changed`: `git diff --name-only` answers a path → `restart_needed True`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** `pi.py`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `"Update one Pi with automatic rollback"`

### Task 4: Updating all Pis (`Rollout`)

**Files:**
- Create: `RPISoftware/cluster/updater/rollout.py`
- Test: `RPISoftware/cluster/updater/tests/test_rollout.py`

**Interfaces:**
- Consumes: Tasks 1–3 (`PiUpdater` for this Pi; peers over HTTP with header `X-Canary-Updater-Key: cfg.key`).
- Produces:
  - `PI_TIMEOUT_S = 3600`, `POLL_S = 3`, `ORDER = ("ai", "processing", "web")`.
  - `class Rollout(cfg, r, local: PiUpdater)`:
    - `order() -> list[str]`: single → `["hub"]`; triple → `ORDER` with the Patroni `leader` moved last (no Patroni answer → `ORDER`).
    - `begin(sha: str) -> None`: raises `pi.Refused` when any Pi's `/status` is unreachable (`"the <name> Pi's updater does not answer"`), is updating/rolling_back/failed, is dirty, or not on main; also `local.preflight(sha, check_peers=True)`. Then stores in local state `rollout = {"commit": sha, "order": [...], "results": {name: "waiting"}, "current": None, "outcome": "running", "reason": None, "started_at": iso}`.
    - `run() -> None`: for each name in order: `results[name] = "updating"`; self → `local.begin(sha, check_peers=False)` then `local.run()` (see Step 3); peer → `POST http://<ip>:<port>/update {"commit": sha}`; a non-202 answer → stop with that answer's `error`. Poll peer `/status` every `POLL_S`: unreachable answers are tolerated until `PI_TIMEOUT_S`; finished when `state` not in `("updating", "rolling_back")` and `target == sha`. Result `"done"` when `state "idle"` and `commit.sha == sha`, else the peer's state (`"rolled_back"` / `"failed"`) → `outcome "stopped"`, `reason "<name> Pi: <error>"`, remaining Pis stay `"waiting"`. All done → `outcome "done"`.

- [ ] **Step 1: Write failing tests**: `test_order_puts_leader_last` (leader `processing` → `["ai", "web", "processing"]`); `test_single_order_is_hub`; `test_refuses_when_peer_unreachable` (message names the Pi); `test_refuses_when_peer_dirty`; `test_runs_in_order_and_finishes` (fake peers flip to idle on the new sha after one poll; this Pi's update runs through `local`; `outcome "done"`, every result `"done"`, POST order matches `order()`); `test_stops_at_first_rollback` (`ai` ends `rolled_back` → `outcome "stopped"`, `processing` and `web` stay `"waiting"`, no POST to them); `test_tolerates_peer_restarting` (peer `/status` returns `(0, {})` three times then idle on sha → `"done"`).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** `rollout.py`. For this Pi inside a rollout use `local.preflight(sha, check_peers=False)` semantics: add `PiUpdater.begin(sha, check_peers: bool = True)` (default unchanged) and call `local.begin(sha, check_peers=False)` then `local.run()`, because the coordinator already checked the others and a peer mid-restart must not refuse its own step.
- [ ] **Step 4: Run** → PASS (Tasks 1–3 tests still pass).
- [ ] **Step 5: Commit** `"Roll an update out to all Pis, leader last"`

### Task 5: Helper HTTP server, entry point, systemd unit, shell script, setup

**Files:**
- Create: `RPISoftware/cluster/updater/server.py`, `RPISoftware/cluster/updater/__main__.py`, `RPISoftware/cluster/canary-updater.service`, `RPISoftware/scripts/hub_update.sh`
- Modify: `RPISoftware/scripts/pi_setup.sh` (section 1, after `CANARY_MQTT_PASSWORD`; final summary)
- Test: `RPISoftware/cluster/updater/tests/test_server.py`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `server.make_server(cfg: Config, local: PiUpdater, rollout: Rollout, host: str, port: int) -> ThreadingHTTPServer`; one `threading.Lock` "job" per process.
  - Routes (JSON, `KEY_HEADER = "X-Canary-Updater-Key"`, `hmac.compare_digest`; bad key → 404 empty body): `GET /status` → `local.status()`; `GET /incoming` → `{"head": gitops.head(origin/main), "commits": gitops.incoming(...)}`; `POST /fetch` → 200 status; `POST /update {"commit"}` / `POST /rollout {"commit"}` → bad sha 422 `{"error": "commit must be a 40-character hex id"}`, job lock held → 409 `{"error": "an update is already running on this Pi"}`, `Refused` → 409 `{"error": str(exc)}`, else `begin()` synchronously and run `run()` in a daemon thread holding the lock → 202 `local.status()`; `POST /dismiss` → 200 status.
  - After a job thread finishes with `restart_needed`, the server calls `os._exit(0)` (systemd restarts it).
  - `__main__.py`: `app_dir = Path(__file__).resolve().parents[2]`, `repo` = `git rev-parse --show-toplevel`, `state_file = ~/.local/state/canary-updater/state.json`; empty key → print `"CANARY_UPDATER_KEY is missing in .env: run scripts/pi_setup.sh"` and exit 1; `local.recover()`; fetch thread every 900 s (first fetch at start); bind `cfg.node_ip` (triple) or `0.0.0.0` (single) on `cfg.port`.
  - Unit: `Type=simple`, `User=pi` (sed-replaced at install, like `hailo-ollama.service`), `WorkingDirectory=/home/pi/canary-firmware/RPISoftware/cluster` (sed-replaced), `ExecStart=/usr/bin/python3 -m updater`, `Restart=always`, `RestartSec=5`, `After=network-online.target docker.service`, `WantedBy=multi-user.target`. Header comment with the install commands.
  - `hub_update.sh status|fetch|all|processing|web|ai|hub`: reads `CANARY_UPDATER_KEY` (and on three Pis `CANARY_NODE_IP`) from `.env`, uses `curl` against the local helper; `all` / a name: gets `origin/main` head sha from `/incoming`, POSTs `/rollout` (all) or `/update` (to that Pi's IP), then prints `state`/`step` every 5 s until not updating, exits 0 on idle-at-target, 1 otherwise. A Pi name in single mode other than `hub` → error.
  - `pi_setup.sh`: `add_secret CANARY_UPDATER_KEY "$(rand_hex 32)"` in both modes; summary prints the 4 install lines (`sudo cp cluster/canary-updater.service /etc/systemd/system/`, two `sudo sed -i` for `User=` and `WorkingDirectory=$ROOT/cluster`, `sudo systemctl daemon-reload && sudo systemctl enable --now canary-updater`), on three Pis "on every Pi".

- [ ] **Step 1: Write failing tests** (real server on port 0 in a thread, FakeRunner-backed `PiUpdater`/`Rollout`): `test_wrong_key_is_404`; `test_bad_commit_is_422`; `test_update_returns_202_then_409_while_busy` (block the fake build on a `threading.Event`); `test_refused_is_409_with_reason` (dirty tree → `"this Pi has local changes"`); `test_status_shape` (keys `node`, `commit`, `state`, `behind`).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** server, entry point, unit, `hub_update.sh` (`chmod +x`), `pi_setup.sh` changes.
- [ ] **Step 4: Run** helper tests → PASS; `bash -n RPISoftware/scripts/hub_update.sh RPISoftware/scripts/pi_setup.sh` → no output; `shellcheck` on both if installed → no new warnings.
- [ ] **Step 5: Manual smoke**: in a scratch clone with a `.env` holding a key, `cd RPISoftware/cluster && python3 -m updater` starts; `curl -H "X-Canary-Updater-Key: <key>" localhost:8010/status` returns JSON; without the header → 404.
- [ ] **Step 6: Commit** `"Serve the update helper over HTTP; add install and hub_update.sh"`

### Task 6: Backend `/api/v1/hub/software`

**Files:**
- Modify: `RPISoftware/backend/app/config.py` (cluster section: `updater_key: str = ""`, `updater_port: int = 8010`), `RPISoftware/backend/app/main.py` (import + `include_router`), `RPISoftware/docker-compose.yml` (nothing needed: `.env` is already the backend's `env_file`; verify)
- Create: `RPISoftware/backend/app/software.py`, `RPISoftware/backend/app/api/software.py`
- Test: `RPISoftware/backend/tests/test_software.py`

**Interfaces:**
- Consumes: helper HTTP API (Task 5); `app.cluster.triple()`, `node_ips()`, `node_name()`; `require_roles`; `AuditLogEntry`.
- Produces:
  - `software.helper_hosts() -> dict[str, str]`: triple → `node_ips()`; single → `{"hub": "host.docker.internal"}`.
  - `async software.call(host: str, method: str, path: str, body: dict | None = None, timeout: float = 2.0) -> tuple[int, dict]`: raw asyncio HTTP/1.1 like `cluster._http_post` (status 0 on any error), sending `X-Canary-Updater-Key: settings.updater_key`.
  - `async software.overview() -> dict`: `{"configured", "mode", "github": {"head", "fetched_at", "fetch_error"}, "incoming": [...], "nodes": [{"name", "ip", "reachable", "status"}], "rollout"}`, helpers asked in parallel (`asyncio.gather`). `incoming` and `github.head` come from the reachable helper with the largest `behind`; `fetched_at` / `fetch_error` from the most recent `fetched_at`; `rollout` = a helper's `rollout` with `outcome "running"`, else the one with the latest `started_at`, else `None`. `configured False` → no helper calls, nodes `reachable False`.
  - Router (`hoa_manager`, `technician`): `GET /api/v1/hub/software` → `overview()`; `POST /api/v1/hub/software/fetch` → POST `/fetch` to each helper, then `overview()`; `POST /api/v1/hub/software/update` body `{"scope": str, "commit": str}` → 422 for a bad sha or a scope not in `helper_hosts()` ∪ `{"all"}`; 503 `"updater key not configured"` when `configured` is false; `all` → `/rollout` on this Pi's helper (`helper_hosts()[node_name()]`), a name → `/update` on that helper; helper status 0 → 503 `"the <name> Pi's updater does not answer"`; helper 409/422 → same status with `detail` = helper `error`; 202 → audit `AuditLogEntry(actor=principal.user_id, action="software_update", target=scope, detail={"commit": commit})`, commit, return `overview()`; `POST /api/v1/hub/software/dismiss {"name"}` → `/dismiss` on that helper (503 if unreachable), returns `overview()`.

- [ ] **Step 1: Write failing tests** (monkeypatch `software.call` with a dict-driven fake; set `settings.updater_key`): `test_requires_staff_role` (`ana` → 403, `tehnician` → 200, `mihai` → 200); `test_unconfigured_reports_not_configured`; `test_overview_single_mode` (helper status merged, `incoming` passed through); `test_overview_triple_picks_most_behind_and_running_rollout`; `test_unreachable_helper_marked` (`reachable False`, `status None`); `test_update_all_goes_to_own_pi_as_rollout` (triple, node `processing` → call to `10.0.0.11` path `/rollout`); `test_update_one_goes_to_that_pi`; `test_update_rejects_bad_commit_and_scope` (422 for `"main"` and for scope `"hub"` in triple); `test_helper_refusal_passes_through` (409 `"this Pi has local changes"`); `test_update_writes_audit_entry`; `test_dismiss_forwards`.
- [ ] **Step 2: Run** `cd RPISoftware/backend && .venv/bin/python -m pytest tests/test_software.py -q` → FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** the full backend suite `.venv/bin/python -m pytest -q` → all pass.
- [ ] **Step 5: Commit** `"Add the hub software status and update API"`

### Task 7: Web data layer and status wording

**Files:**
- Modify: `RPISoftware/web/src/api/types.ts`, `RPISoftware/web/src/api/adminHooks.ts`, `RPISoftware/web/src/i18n.tsx`
- Create: `RPISoftware/web/src/lib/software.ts`, `RPISoftware/web/src/lib/software.check.ts`

**Interfaces:**
- Consumes: Task 6 JSON.
- Produces:
  - Types: `SoftwareCommit {sha; subject; date; author?}`, `PiSoftwareStatus` (helper `/status` fields from Task 3), `SoftwareNode {name; ip: string | null; reachable: boolean; status: PiSoftwareStatus | null}`, `SoftwareRollout {commit; order: string[]; results: Record<string, "waiting" | "updating" | "done" | "rolled_back" | "failed">; outcome: "running" | "done" | "stopped"; reason: string | null; started_at}`, `SoftwareOverview {configured; mode; github: {head: SoftwareCommit | null; fetched_at: string | null; fetch_error: string | null}; incoming: SoftwareCommit[]; nodes: SoftwareNode[]; rollout: SoftwareRollout | null}`.
  - Hooks: `useSoftware()` (key `["software"]`, enabled like `useCluster`, `refetchInterval` 3000 when `isBusy(data)` else 10000, `retry: false`); `useSoftwareFetch()` and `useSoftwareUpdate()` (`mutate({scope, commit})`), `useSoftwareDismiss()` (`mutate(name)`); all three set the query data from the response.
  - `lib/software.ts`: `isBusy(o: SoftwareOverview): boolean` (rollout running or any node updating/rolling_back); `targetCommit(o): string | null` (`github.head.sha`); `allBlocker(o): string | null` and `piBlocker(o, name): string | null` returning i18n keys in this precedence: `sw.block.notConfigured`, `sw.block.busy`, `sw.block.unreachable`, `sw.block.failed`, `sw.block.dirty`, `sw.block.notMain`, `sw.block.upToDate` (all: every reachable Pi at the target; one: that Pi at the target). `allBlocker` checks every Pi; `piBlocker` checks that Pi for dirty/notMain/failed/unreachable and every Pi for busy. `piLine(n: SoftwareNode): {tone: "ok" | "attention" | "danger" | "info"; key: string; vars?: Record<string, string | number>}`: unreachable → danger `sw.pi.unreachable`; failed → danger `sw.pi.failed`; rolled_back → attention `sw.pi.rolledBack`; updating → info `sw.pi.updating` `{step}`; rolling_back → attention `sw.pi.rollingBack`; behind > 0 → attention `sw.pi.behind` `{n}`; else ok `sw.pi.upToDate`.
  - i18n keys (en + ro) for every key above plus: `sw.title`, `sw.github`, `sw.checked` `{ago}`, `sw.checkNow`, `sw.fetchError` `{msg}`, `sw.newCommits` `{n}`, `sw.noNew`, `sw.showAll`, `sw.updateAll`, `sw.updateOne`, `sw.confirmAllTitle`, `sw.confirmAllBody` `{sha}`, `sw.confirmOneTitle` `{pi}`, `sw.confirmOneBody` `{sha}`, `sw.rollout.*` (`waiting`, `updating`, `done`, `rolled_back`, `failed`, `running`, `finished`, `stopped` `{reason}`), `sw.dismiss`, `sw.log`, `sw.reconnecting`, `sw.runs` `{sha}`.

- [ ] **Step 1: Write the failing check** `software.check.ts` in the `roomModel.check.ts` style: `allBlocker` returns `sw.block.upToDate` when every Pi is at head; `sw.block.busy` when one is updating; `sw.block.unreachable` when one has `reachable: false`; `piBlocker` for a dirty Pi returns `sw.block.dirty` while another Pi stays free; `piLine` for `behind: 3` gives `{tone: "attention", key: "sw.pi.behind", vars: {n: 3}}`; `isBusy` true with a running rollout.
- [ ] **Step 2: Run** `cd RPISoftware/web && node_modules/.bin/esbuild src/lib/software.check.ts --bundle --platform=node --format=esm --outfile=/tmp/sw.mjs && node /tmp/sw.mjs` → FAIL.
- [ ] **Step 3: Implement** types, hooks, `software.ts`, i18n strings.
- [ ] **Step 4: Run** the check → prints `software ok`; `npm run typecheck` → no errors.
- [ ] **Step 5: Commit** `"Add the web data layer for hub software updates"`

### Task 8: Hub tab Software section and per-Pi rows; docs

**Files:**
- Create: `RPISoftware/web/src/views/admin/SoftwarePanel.tsx`
- Modify: `RPISoftware/web/src/views/admin/HubTab.tsx`, `RPISoftware/web/src/styles.css` (reuse `hub-*` / `dev-*` classes; add only what is missing), `RPISoftware/RUNME.md`

**Interfaces:**
- Consumes: Task 7.
- Produces: `SoftwarePanel()` (rendered in `HubTab` between the status lines and the Pi grid) and `PiSoftware({ name }: { name: string })` (rendered at the bottom of each `PiCard`; single mode passes `"hub"`).

Behaviour:
- `SoftwarePanel`: GitHub head (short 7-char sha in `.mono`, subject, `fmtAgo` of date); `sw.checked` with `fmtAgo(fetched_at)` and **Check now**; `fetch_error` line; `sw.newCommits` + list of `incoming` (first 5, then `sw.showAll` toggle); **Update all Pis** (`disabled` with the `allBlocker` text shown beside it), confirmation via `ConfirmDialog`; when `rollout` exists: one line per Pi in `order` with `sw.rollout.<result>`, and the outcome line; mutation errors shown with `className="err"`. When the software query errors but has old data: `sw.reconnecting` and keep showing old data.
- `PiSoftware`: `sw.runs` with short sha + subject; `HubLine` for `piLine`; error text and an expandable `<details>` with `sw.log` lines for rolled_back / failed plus a **Dismiss** button (`useSoftwareDismiss`); **Update this Pi** button with `piBlocker` reason and confirmation naming the Pi (`piLabel`).

- [ ] **Step 1: Implement** `SoftwarePanel.tsx` and mount it.
- [ ] **Step 2: Run** `npm run typecheck` and `npm run build` → success.
- [ ] **Step 3: Check in the browser** (run skill / `npm run dev` against a backend with fake helpers, or the Playwright CLI): Hub tab shows the Software section in English and Romanian; at 375 px wide no horizontal scroll; buttons disabled with a reason when up to date.
- [ ] **Step 4: Docs**: RUNME.md new subsection "Updating the hub" under section 1 (install the helper, the Hub tab, `scripts/hub_update.sh`, rollback, what blocks an update); 3.1 firewall list adds `8010`; 3.3 "Update" row points to it.
- [ ] **Step 5: Commit** `"Show and trigger hub software updates on the Hub tab"`

### Task 9: Whole-branch verification

- [ ] **Step 1:** helper tests, backend suite, `npm run typecheck`, `software.check.ts` → all pass; paste the summary lines.
- [ ] **Step 2:** `docker compose config -q` in `RPISoftware` → no error.
- [ ] **Step 3:** Write the manual three-Pi checklist into the RUNME subsection: one-Pi update, "update all" with the leader last, a deliberately broken commit (e.g. failing backend import) rolls back and stops the rollout.
