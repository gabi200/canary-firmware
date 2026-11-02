# Hub software updates from the dashboard: design

Date: 2026-11-02. Status: draft for approval.

## Why

Updating the hub today means SSH into each Pi, `git pull && docker compose up -d --build`, then
watching `patronictl list` before moving to the next one (RUNME.md 3.3). It is slow, easy to get
wrong (two Pis down at once drops the cluster's redundancy), and invisible from the dashboard.

The owner wants to see from the dashboard when GitHub has something new, see which commit each Pi
runs, and update with a button: all Pis, or one Pi on its own to try a change first.

## Goals

1. **See what is new.** Administration → Hub shows the newest commit on GitHub `main` and, when the
   Pis are behind, the list of new commits (short sha, subject, author, date).
2. **See each Pi's version.** Every Pi card shows the commit it runs (short sha + subject), whether
   it is up to date or N commits behind, and its update state.
3. **Update all Pis.** One button rolls the update out one Pi at a time, each healthy before the
   next starts, the Postgres leader last.
4. **Update one Pi.** A button on each Pi card updates only that Pi (for trying a change).
5. **Roll back automatically.** A Pi whose build fails, or that is not healthy in time, goes back to
   the commit it ran before, by itself. The page says it rolled back and why.
6. **Who:** the roles that see the Hub tab today, `hoa_manager` and `technician` (and
   `system_admin`, which `require_roles` always lets through). Both may press the buttons.
7. A **script** for the same from a shell on a Pi (`scripts/hub_update.sh`), for when the dashboard is
   not reachable.

## Non-goals

- Branches other than `main`, picking an arbitrary old commit, or downgrades from the UI.
- Updating the ESP32 firmware (already in the Firmware tab) or the OS / Docker itself.
- Scheduled or unattended automatic updates. A person always presses the button.
- Database migrations. The backend still creates its schema at start; a schema change that needs a
  manual step is out of scope (an update that fails health checks because of one rolls back).

## Anti-goals (would make this a failure even if it "works")

- An update that leaves **fewer than two healthy Pis** in a three-Pi hub, or interrupts alarms for
  longer than an ordinary failover does.
- The backend container getting the Docker socket or a shell on the host: the API is on the LAN
  (port 8000) and a hole there must not become root on the Pi.
- The UI accepting free text that ends up in a shell command (commit ids are validated as hex and
  must be on `origin/main`).
- A half-updated Pi left running with nobody told.

## How it is built

### 1. A host-side helper on every Pi: `canary-updater`

The backend and the dashboard run in Docker, and `docker compose up -d --build` rebuilds them, so
they cannot run the update themselves. Each Pi runs a small helper **outside Docker**, as a systemd
service like `hailo-ollama`:

- Code: `RPISoftware/cluster/updater/canary_updater.py`, Python 3 standard library only (Raspberry
  Pi OS ships Python 3; no pip install on the host). Unit file `RPISoftware/cluster/canary-updater.service`,
  `Restart=always`, running as the Pi's login user (who owns the checkout and is in the `docker` group).
- Listens on TCP **8010**: `CANARY_NODE_IP:8010` on a three-Pi hub, `0.0.0.0:8010` on one Pi (the
  backend reaches it at `host.docker.internal:8010`, already mapped in docker-compose.yml).
- Every request needs header `X-Canary-Updater-Key` equal to `CANARY_UPDATER_KEY` from
  `RPISoftware/.env`; otherwise 404 (as `/internal/...` does today). `scripts/pi_setup.sh` generates
  the key once, in both modes; on three Pis it travels with the copied `.env`.
- Keeps its state in `~/.local/state/canary-updater/state.json`, so a restart (including after it
  updated itself) does not lose a running rollout's outcome.

Its HTTP API (JSON):

| Method | Path | Does |
|---|---|---|
| GET | `/status` | this Pi: `node`, `commit` {sha, subject, date}, `branch`, `dirty`, `behind`, `ahead`, `fetched_at`, `state` (`idle` / `updating` / `rolling_back` / `rolled_back` / `failed`), `step`, `target`, `previous`, `error`, `log` (last ~50 lines), `rollout` (when this Pi coordinates one) |
| GET | `/incoming` | up to 30 commits between HEAD and `origin/main` (sha, subject, author, date) and `origin/main`'s head |
| POST | `/fetch` | `git fetch origin main` now (also every 15 min by itself) |
| POST | `/update` | `{"commit": "<sha>"}`: update this Pi to that commit (background), answers 202 |
| POST | `/rollout` | `{"commit": "<sha>"}`: coordinate "update all" from this Pi (below), answers 202 |

Fetch failures (no internet, GitHub down) show as `fetch_error` with the time of the last good fetch;
nothing else depends on them.

### 2. Updating one Pi (the helper's `/update`)

Refuse up front (409, with the reason shown in the UI) when: an update is already running here; the
checkout is not on `main`; the working tree has local changes (`git status --porcelain` not empty);
the commit is not an ancestor-or-equal of `origin/main`; or (three Pis) another Pi is not healthy, since
taking this one down would leave one.

Steps, each recorded as `step` and in `log`:

1. `previous` = current HEAD.
2. Three Pis, if this Pi is the Patroni leader: switch over to a healthy replica
   (`docker compose exec -T postgres patronictl switchover --leader <me> --candidate <other> --force`),
   wait until another member leads.
3. `git merge --ff-only <commit>` (fails safely if history diverged).
4. `docker compose up -d --build` (time limit 30 min: first builds on a Pi are slow).
5. Wait for healthy, up to 5 min: `curl localhost:8000/health` answers ok, `docker compose ps` shows
   every service of the active profiles running and healthy where it has a health check, and on three
   Pis this Pi's Patroni member is `streaming` or `running` (Patroni REST on `CANARY_NODE_IP:8008`).
6. Done: `state = idle`, `previous` kept for display.

Rollback (step 3, 4 or 5 failed): `git reset --hard <previous>`, `docker compose up -d --build`, wait
healthy as in 5. Success → `state = rolled_back`, `error` = what failed. Rollback also failing →
`state = failed`: the page shows it in red and says to check the Pi by hand (`docker compose logs`).
`rolled_back` / `failed` stay until the next update, or until someone dismisses it.

If the helper's own file changed in the update, it finishes the step, saves state and exits; systemd
starts the new version.

### 3. Updating all Pis (the helper's `/rollout`)

The backend sends `/rollout` to the helper on the Pi that is serving the request. The coordinating
helper is outside Docker, so it survives its own Pi's rebuild. It:

1. Checks all Pis' helpers answer, are idle and healthy, and have no local changes. Otherwise refuses
   and names the Pi.
2. Orders the Pis: the non-leaders first (`ai`, `processing`, `web` order among them), the current
   Patroni leader last. On one Pi: just that Pi.
3. For each Pi: `POST /update` to its helper (its own `/update` for itself), poll its `/status` every
   3 s until idle / rolled_back / failed.
4. Stops at the first Pi that did not end idle on the new commit: the remaining Pis stay on the old
   commit. Rollout result `stopped` with the Pi and reason; otherwise `done`.

The same commit goes to every Pi: the sha the user saw on the page, not whatever `main` is by then.

### 4. Backend: `/api/v1/hub/software`

New router `backend/app/api/software.py`, roles `hoa_manager` + `technician` (same as `/cluster`).
The backend calls the helpers with short timeouts (2 s) using the same raw-asyncio HTTP style as
`app.cluster._http_post`; it never runs git or docker itself.

| Method | Path | Returns / does |
|---|---|---|
| GET | `/api/v1/hub/software` | `{github: {head, fetched_at, fetch_error}, incoming: [...], nodes: [{name, ip, reachable, ...helper /status}], rollout}`. A helper that does not answer shows `reachable: false` ("updater not installed or Pi down") |
| POST | `/api/v1/hub/software/fetch` | asks every reachable helper to fetch |
| POST | `/api/v1/hub/software/update` | `{"scope": "all" \| "processing" \| "web" \| "ai" \| "hub", "commit": "<40-hex sha>"}` |

Each POST writes an audit entry (`software_update`, target = scope, detail = commit and user), as the
firmware tab does.

### 5. Dashboard: Administration → Hub

The Hub tab (`web/src/views/admin/HubTab.tsx`) gets a **Software** section above the Pi cards, polling
`/hub/software` every 10 s, every 3 s while something updates:

- **GitHub main:** newest commit (sha, subject, age), "Checked 4 min ago" and a **Check now** button.
  When Pis are behind: "N new commits" and the list (collapsed after 5).
- **Update all Pis** button (disabled with the reason when a Pi is down, busy, has local changes, or
  everything is up to date). Confirmation dialog (existing `ConfirmDialog`) names the commit and says
  the Pis restart one at a time.
- While a rollout runs: a progress line per Pi (waiting / updating: step / done / rolled back).

Each **Pi card** adds: the commit it runs (sha + subject), "up to date" or "N behind", its update
state and step, and an **Update this Pi** button with its own confirmation. A rolled-back or failed
Pi shows the reason and the last log lines (expandable). During its own Pi's rebuild the page may
lose the connection for a moment: it keeps polling and shows "reconnecting".

All new text in English and Romanian (`web/src/i18n.tsx`).

### 6. Shell script: `scripts/hub_update.sh`

Talks to the local helper with the key from `.env`: `status`, `fetch`, `all`, or a Pi name
(`processing` / `web` / `ai` / `hub`). Prints progress until done. Same rules as the UI.

### 7. Install and docs

- `scripts/pi_setup.sh` writes `CANARY_UPDATER_KEY` and prints the one-time install commands
  (`sudo cp cluster/canary-updater.service ...; systemctl enable --now canary-updater`), as RUNME 3.4
  does for hailo-ollama. It does not run sudo itself.
- RUNME.md: new section on updating from the dashboard; 3.3's "Update" row points to it. Port 8010
  added to the firewall list in 3.1.

## Testing

- Helper: unit tests for the decision logic (refusals, ordering leader last, rollback on each failing
  step, rollout stops at first failure) with git / docker / HTTP calls behind a small runner that tests
  replace. Run with `python -m pytest RPISoftware/cluster/updater/tests` (standard library + pytest only).
- Backend: pytest for `/hub/software` with fake helpers (reachable / unreachable / busy), role checks,
  commit validation, audit entries.
- Web: `npm run typecheck`, plus a `.check.ts` for any non-trivial status-to-text mapping, as
  `roomModel.check.ts` does.
- Not covered by automated tests: a real three-Pi rollout. A manual check on the Pis is listed in
  the plan.

## Decided by the owner

- A button to update; the page shows that there is a new commit and which commit each Pi has.
- Update all Pis, or only one Pi for testing.
- Automatic rollback to the previous commit on failure.
- `hoa_manager` and `technician` can both trigger updates.

## Calls made by Claude (check these)

- A host-side helper service per Pi instead of giving the backend container Docker access.
- Port 8010, a new `CANARY_UPDATER_KEY` (so a one-Pi hub, which has no cluster secret, works too).
- "Update all" stops at the first rollback; the remaining Pis stay on the old version.
- Refuse to update while any Pi is down or has local changes, rather than skipping it.
- `main` only, fast-forward only, the commit the user saw.
- Health wait 5 min, build limit 30 min; fetch from GitHub every 15 min plus "Check now".
- `pi_setup.sh` prints the sudo install commands rather than running them.

## Left to the builder

- Exact JSON field names beyond those above, polling details, CSS.
- How the helper's runner abstraction looks, as long as tests can replace git / docker / HTTP.
