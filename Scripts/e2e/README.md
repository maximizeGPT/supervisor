# True-new-user E2E harness

Drives a **fully isolated** Supervisor instance through the scenarios a new
user hits — install, onboarding, first watched session, first flag,
double-launch, crash-relaunch — and asserts each one against the app's real
trace, SQLite, and AX tree. It never touches the live Supervisor on this
Mac: every instance runs under a per-run fake `$HOME`, a prefixed Keychain
namespace, and a namespaced single-instance lock.

## Safety model (why this can't hit your real instance)

- **`SUPERVISOR_HOME`** redirects every path the app derives — App Support,
  logs, SQLite, the single-instance pidfile, `~/.claude/projects`,
  `~/.codex/sessions`, reports, markers, and `UserDefaults` (per-home
  suite). Foundation ignores `$HOME` on macOS, which is why this seam
  exists.
- **`SUPERVISOR_KEYCHAIN_PREFIX`** moves the app's Keychain items to a
  `test.supervisor.e2e.*` namespace, disjoint from the live
  `live.supervisor.api.*` items — including the legacy-key migration's
  delete.
- **PRE-LAUNCH gate**: `common.sh` refuses to run any binary that doesn't
  answer `--print-paths` with the fake home + test prefix, so a stale build
  predating the seams can never boot against your real home.
- **Teardown** kills only the exact pid it launched (verified still our
  binary) and `rm -rf`s only a path that physically resolves under
  `/tmp/supervisor-e2e/`.

## One-time setup on this Mac

The app reads its API key from the login Keychain (SecItem ignores
`SUPERVISOR_HOME`; only the item *name* is namespaced). The first time an
ad-hoc-signed debug build reads a CLI-seeded item, macOS shows a
**SecurityAgent "Supervisor wants to use the keychain" prompt**. A headless
run can't click it, so approve it once:

```bash
# Run any key-reading scenario WITH the screen visible, click "Always Allow"
# when the prompt appears. That binary+item pairing is then silent for all
# later runs on this Mac.
bash Scripts/e2e/s05-running-state.sh
```

After that single approval, every scenario runs headless. (A fresh machine
or CI needs the click again — this is a property of the macOS Keychain ACL,
not the harness.)

`seed_provider_key` reuses an existing item whenever the value already
matches, so the approval survives. When the value does change it deletes and
re-adds rather than passing `-U`: an item's ACL is fixed at creation, so `-U`
would leave a changed key sitting behind the ACL of the item it replaced.
That is the same failure that stalled a live launch after a provider key was
replaced with `security add-generic-password ... -A -U`. The re-add costs one
fresh approval, which is honest.

## Running

```bash
swift build                          # the seams + driver + fake CLI must be built
bash Scripts/e2e/s05-running-state.sh
bash Scripts/e2e/s06-fake-session.sh
bash Scripts/e2e/s11-double-launch.sh
bash Scripts/e2e/s12-crash-relaunch.sh
```

Scenarios that exercise the model path need a real key:

```bash
E2E_API_KEY="<deepseek key>" bash Scripts/e2e/s03-onboarding-key.sh
E2E_API_KEY="<deepseek key>" bash Scripts/e2e/s07-first-flag.sh
```

Each script prints `PASS` or exits nonzero with a reason; a failed run's
evidence (trace log, app stdout, DB) is preserved at
`/tmp/supervisor-e2e/failures/<run-id>/` instead of being deleted.

## Scenarios

| Script | Covers | Headless |
|---|---|---|
| `s01-install-gatekeeper.sh` | dmg mount, quarantine, Gatekeeper assessment | yes |
| `s03-onboarding-key.sh` | onboarding key entry + validation (AX-driven) | needs key + AX-granted terminal |
| `s05-running-state.sh` | reaches running state fully inside the fake home | yes* |
| `s06-fake-session.sh` | discovery tails a scripted fake session | yes* |
| `s07-first-flag.sh` | rm -rf fixture → flag persisted (model path) | needs key |
| `s11-double-launch.sh` | duplicate bows out, incumbent unharmed | yes* |
| `s12-crash-relaunch.sh` | SIGKILL → relaunch reclaims the lock | yes* |
| `s13-hung-takeover.sh` | frozen incumbent is taken over | yes* |
| `selftest-teardown.sh` | the harness reclaims what it launched | yes (launches no app) |

\* after the one-time Keychain approval above.

## Nothing this harness starts may reach the owner's screen

A scenario instance is a REAL Supervisor. Its `SUPERVISOR_HOME` makes it
disjoint on disk, and the single-instance flock is namespaced by that same
home, so it coexists with a live Supervisor by design. Two rules keep that
isolation from ending at the filesystem:

1. **The app suppresses its hover band when the resolved home is not the real
   user home** (`ConfigPaths.isRealUserHome`). `await_running_ready` asserts the
   `hover band suppressed` trace line, so a binary that lost the gate fails the
   abort-gate instead of stacking a second pill on the owner's screen.
2. **Every launched pid goes in the ledger** (`$RUN_ROOT/launched.pids`) at the
   moment it is spawned, and teardown kills the whole ledger on every exit path
   including `fail`, SIGINT and SIGTERM. Launch extra instances with
   `spawn_extra_app`, never a bare `"$APP_BIN" &`: the per-role pid files get
   overwritten (s13 replaces the frozen instance's pid with the relaunched one),
   and a pid nothing records is a Supervisor nothing can kill.

`selftest-teardown.sh` pins both rules against stand-in binaries, so it proves
the contract without putting a window on anyone's screen. It also runs inside
`swift test` as `E2ETeardownSelfTests`.
