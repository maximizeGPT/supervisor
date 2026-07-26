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

\* after the one-time Keychain approval above.
