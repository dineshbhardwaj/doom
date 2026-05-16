# EDA IDE — Workflow Guide

> Companion to `EDA-IDE-PLAN.md`. The plan describes *what was built*;
> this doc describes *how to use it day-to-day*.
> Version: 2026-05-15.

## 0. Where you are

All six phases of `EDA-IDE-PLAN.md` are implemented and sitting **uncommitted**
in `~/.config/doom/`. Manual finishing touches:

| Step | Done? | Command / Action |
|------|-------|------------------|
| Restart Emacs once | ⬜ | Quit + relaunch, OR `SPC q Q`, OR `doom run` |
| Install tree-sitter SV grammar | ⬜ | Inside Emacs: `M-x verilog-ts-install-grammar` |
| Seed soc/pcie/ucie daemons | partial (soc spawned) | `SPC k d S` from soc, OR `eda new pcie ~/eda/wt`, `eda new ucie ~/eda/wt` |
| OSS CAD Suite (for `sby` formal) | ⬜ | Download from https://github.com/YosysHQ/oss-cad-suite-build/releases → unpack to `~/oss-cad-suite/` |
| gptel API key | ⬜ | Add to `~/.authinfo` (mode 600): `machine api.anthropic.com login apikey password sk-ant-XXX` |
| Commit the phases | ⬜ | When you're ready; suggested: one commit per phase for fine-grained revert |

---

## 1. Mental model

Three levels of organization, nested:

```
DAEMON (one per IP family — soc, pcie, ucie, …)
   └── WORKSPACE (Doom persp — one per task within that IP)
          └── WORKTREE (git worktree — one checkout per task at ~/eda/wt/<task>/)
```

Concrete example:

```
daemon pcie
   ├── workspace pcie-gen7-link-init → worktree ~/eda/wt/pcie-gen7-link-init/
   ├── workspace pcie-cdc-fixes      → worktree ~/eda/wt/pcie-cdc-fixes/
   └── workspace pcie-coverage       → worktree ~/eda/wt/pcie-coverage/

daemon ucie
   ├── workspace ucie-sb-bringup     → worktree ~/eda/wt/ucie-sb-bringup/
   └── workspace ucie-d2d-handshake  → worktree ~/eda/wt/ucie-d2d-handshake/

daemon soc
   ├── workspace soc-top-integration → worktree ~/eda/wt/soc-top-integration/
   └── workspace soc-clock-tree      → worktree ~/eda/wt/soc-clock-tree/
```

**Why three levels?**

- **Daemon isolation** — a runaway sim in pcie cannot stall your soc work; each daemon has its own kill rings, magit state, eshell history.
- **Workspace isolation** — within a daemon, buffers per task don't leak into each other.
- **Worktree isolation** — independent filesystem checkouts, one `.git` shared, so you can have 40 branches "open" simultaneously without 40 clones.

---

## 2. Daily flow — start of day

```bash
# Pick the IP family you want to work on
eda pcie          # attaches a GUI frame; spawns the daemon if dead
```

Inside the frame:

| Key | Action |
|-----|--------|
| `SPC TAB TAB` | Workspace switcher |
| `SPC TAB <n>` | Jump to workspace N |
| `SPC TAB n` | New workspace |
| `SPC X` | Open `org-agenda` — every task's TODOs across all 40 |
| `SPC SPC` | Find file (vertico ranks by recency + project) |
| `SPC g g` | Magit status of the current worktree |
| `SPC b B` | Cross-workspace buffer picker |

### 2.1 Spawning a daemon — `eda new` in detail

```bash
# eda new <name> [path] [ip-family] [repo-url]
eda new pcie                                                            # minimal
eda new pcie ~/eda/pcie-main pcie  https://github.com/acme/pcie.git     # pinned
eda new ucie ~/eda/ucie-main ucie  git@github.com:acme/ucie.git
```

Arguments:

| Arg            | Required | Default          | Notes                                                                                   |
|----------------|----------|------------------|-----------------------------------------------------------------------------------------|
| `<name>`       | yes      | —                | Must match `[a-z0-9][a-z0-9-]{0,31}`. Refused if a daemon by that name is already alive. |
| `[path]`       | no       | `~/eda/wt/`      | Becomes the daemon's `default-directory`; clone target when `repo-url` is given.        |
| `[ip-family]`  | no       | same as `<name>` | Stored as a symbol in the registry; shown in `SPC k d l`.                               |
| `[repo-url]`   | no       | (no binding)     | When given, pins the daemon's `:root` to a checkout of this remote — see below.         |

Repo-binding rules (apply only when `repo-url` is given):

| `path` state                             | Action                                                  |
|------------------------------------------|---------------------------------------------------------|
| missing / empty                          | `git clone <repo-url> <path>`                           |
| existing git repo whose `origin` matches | reused as-is                                            |
| existing git repo, `origin` mismatch     | **refused** — fix the remote or pick a different path   |
| non-empty, not a git repo                | **refused** — move the path first                       |

No `repo-url`: `path` is created with `mkdir -p` (if missing) and the daemon
spawns there with `:repo` left as `nil`.

Side effects per spawn:

- `emacs --bg-daemon=<name>` started with cwd = `path`.
- Logs go to `~/.cache/eda/<name>.log` (handy when bring-up fails before any UI is up).
- Registry entry `(<name> :root <path> :ip-family <family> :repo <url|nil> :created … :notes "")` appended to `~/.config/doom/eda-registry.el`.

**Bootstrap caveat** — the shell wrapper writes the registry entry by sending
elisp to *another* already-running daemon. On the very first spawn (no daemon
alive yet), the new daemon comes up but **no registry entry is written**.
Backfill it with `SPC k d n` from inside the new daemon (same name + values) —
that path writes the registry directly. Subsequent `eda new` calls are fine
because the previously-spawned daemon serves as the elisp target.

The binding is shown in the **Repo** column of `SPC k d l`. The interactive
`SPC k d n` (`eda/new-daemon`) prompts, in order, for: name → root → ip-family
(seeded with the name) → repo URL (blank = none) → notes; it has no bootstrap
caveat because it writes the registry directly inside the daemon you're in.

Worktree creation (`SPC k d w`) defaults to the bound daemon's `:root`, so the
repo prompt is one-keystroke (`RET`) when you're already in the right daemon.

### 2.2 Authentication — talk to the remote from inside the daemon

One-time setup so HTTPS push/pull and Emacs Forge (PRs/issues) work without
re-prompting:

```bash
eda auth-setup
```

What it does (idempotent — safe to re-run):

1. `gh auth status`; if not logged in, runs `gh auth login` (browser flow).
2. `gh auth setup-git` — configures git's credential helper to use `gh`, so
   any `git clone/push/pull` over HTTPS just works (credentials live in the
   macOS keychain via `gh`).
3. Writes a Forge entry `machine api.github.com login <user>^forge password <token>`
   into `~/.authinfo.gpg` (or `~/.authinfo` with `chmod 600` if no default GPG
   key exists). Token is harvested via `gh auth token`. Forge in Emacs reads
   this for the GitHub API (PRs, issues, reviews).

Verify after setup:

```bash
git ls-remote https://github.com/<you>/<some-repo>   # should not prompt
# Inside Emacs, in a magit status of a GitHub repo:
M-x forge-pull                                       # populates issues/PRs
```

---

## 3. Starting a new task — full lifecycle

Example: brand-new task `pcie-gen7-link-init` under the `pcie` family.

### Step 1 — create the worktree

```bash
# From shell (preferred — gives you full git tab-completion)
git -C ~/eda/<repo> worktree add ~/eda/wt/pcie-gen7-link-init -b feature/pcie-gen7-link-init
```

Or from inside any running Emacs: `SPC k d w` → prompts for repo / branch / task name.

### Step 2 — attach to the daemon for this IP

```bash
eda pcie                  # or SPC k d s, pick pcie
```

### Step 3 — new workspace named for the task

`SPC TAB n` → name it `pcie-gen7-link-init`.

### Step 4 — bootstrap task metadata

In the new workspace, with the worktree as default-directory:

| Key | What it does |
|-----|--------------|
| `SPC p e o` | Creates `project.org` from template; opens it |
| `SPC k a c` | Pick `pcie` → writes `CLAUDE.md` (PCIe-specific) |
| `SPC k a a` | Drops `.claude/agents/{rtl-review,verification,debug}-agent.md` |

### Step 5 — set up per-worktree environment (cocotb / OSS CAD)

```bash
cd ~/eda/wt/pcie-gen7-link-init

# .envrc for direnv (auto-activates venv + OSS CAD Suite)
cat > .envrc <<'EOF'
layout python3
source_env_if_exists ~/oss-cad-suite/environment
export VERILATOR_ROOT=$(brew --prefix verilator)/share/verilator
export SIM=verilator
EOF
direnv allow

# Python deps for cocotb
python3 -m venv .venv
source .venv/bin/activate
pip install "cocotb~=2.0" cocotb-coverage pytest
```

### Step 6 — start writing RTL

Open any `.sv` under `rtl/`. The mode line should show `Verilog-TS`. LSP, lint, format, hierarchy all live.

---

## 4. Editing — what every keystroke does

Inside a `.sv` / `.svh` / `.v` / `.vh` buffer:

### Navigation / understanding
| Key | Action |
|-----|--------|
| `K` (evil normal) | LSP hover docstring |
| `gd` | Go to definition (LSP xref) |
| `gr` | List references |
| `SPC m h` | verilog-ext hierarchy view (depends on flag set) |
| `SPC s o` | imenu jump to module / function / always-block |

### Lint / build / sim — under `SPC c e *`
| Key | Action |
|-----|--------|
| `SPC c e l` | `verilator --lint-only -Wall <current-file>` |
| `SPC c e v` | `make -C sim verilator-run` |
| `SPC c e C` | `verilator_coverage --annotate logs/annotated logs/coverage.dat` |
| `SPC c e i` | `make -C sim iverilog` |
| `SPC c e p` | `pytest -q tests/` (cocotb) |
| `SPC c e P` | `make -C sim cocotb SIM=<icarus\|verilator>` |
| `SPC c e y` | `yosys read+hierarchy+check` |
| `SPC c e Y` | `yosys show <module>` (xdot graph) |
| `SPC c e f` | `sby <task>` (SymbiYosys formal) |
| `SPC c e w` | Open trace in GTKWave |
| `SPC c e s` | Open trace in Surfer |

All compile-mode buffers have clickable errors (Verilator/Verible/Yosys/Icarus regex). Click anywhere in an error → jump to file:line.

### Task tracking — under `SPC p e *`
| Key | Action |
|-----|--------|
| `SPC p e o` | Open `project.org` (creates from template if missing) |
| `SPC p e t` | Capture a TODO under `* TODOs` |
| `SPC p e d` | Append timestamped entry to `* Debug log` |
| `SPC p e q` | Add to `* Open questions` |
| `SPC p e r` | Re-scan `~/eda/wt/` and refresh `org-agenda-files` |

### Claude — original `SPC k *` (untouched) + agents `SPC k a *`
| Key | Action |
|-----|--------|
| `SPC k k` | Start a Claude Code session (vterm) |
| `SPC k t` | Toggle Claude window visible/hidden |
| `SPC k e` | Send region/defun: "explain this code" |
| `SPC k v` | Send region/buffer: "review this Verilog" |
| `SPC k T` | "Write a testbench for this module" |
| `SPC k x` | "Explain this error" (paragraph at point) |
| `SPC k a r` | rtl-review-agent on current buffer |
| `SPC k a t` | verification-agent expands cocotb tests |
| `SPC k a d` | debug-agent triages the last `*compilation*` / `*eda-*` log |
| `SPC k a c` | Seed `CLAUDE.md` into a worktree |
| `SPC k a a` | Seed `.claude/agents/` into a worktree |

---

## 5. Verification cycle

```
sketch DUT (rtl/<dut>.sv)
   ↓
write directed test (tests/test_<dut>.py)
   ↓
SPC c e p           pytest runs cocotb on Verilator
   ↓                clicks on failures → jump to RTL/TB
SPC k a t           verification-agent expands coverage
   ↓
SPC c e p           rerun, all green
   ↓
SPC c e C           verilator_coverage --annotate
   ↓                inspect logs/annotated/
   ↓ if cover holes:
add cover_property / cover_group
   ↓
SPC c e f bmc       sby BMC on properties (k-induction depth=20)
   ↓
SPC c e f cover     sby cover (any-trace existence proofs)
   ↓
SPC p e d           log conclusions in project.org's * Debug log
```

---

## 6. Debug cycle

A sim fails. The `*eda-verilator-build*` (or `*compilation*`) buffer is on screen.

```
1. Look at the FIRST error (don't fixate on cascaded ones).
   Click any line → cursor jumps to that file:line.

2. SPC k a d
   debug-agent reads the last 4 KB of the log, gives you:
     - the first symptom
     - 3 most-likely root causes ranked
     - a minimal experiment per cause

3. Try the top experiment (often: add a trace signal, narrow the test).

4. Once root cause is confirmed, fix in rtl/ or tb/.

5. SPC c e v (or SPC c e p) — rerun.

6. SPC p e d — capture what happened so future-you doesn't redo this debug.
```

---

## 7. Git / Forge workflow

You're inside a worktree. Magit picks it up automatically.

### Daily edit-commit-push
```
SPC g g          magit status
  s              stage hunk/file (or use TAB to expand sections)
  c c            commit; type message; C-c C-c
  P u            push to upstream
```

### When push fails

Two flavours:

**(a) "fetch first" / "non-fast-forward"** — remote moved while you worked.
```
F -r u           pull --rebase
                 resolve any conflicts:
                   K to discard (capital K under evil-collection)
                   s to stage resolved
                   r r to continue rebase
P u              push (now clean)
```

**(b) After YOU rebased** (rewrote SHAs) — force needed.
```
P -f u           push --force-with-lease (safer than plain --force)
```

### Pull request via Forge
```
SPC g g          magit status
  P              push first (if needed)
SPC g f          forge dispatch
  c p            create pull request
                 (Forge talks to Gitea; needs auth-token configured once)
```

### Worktree-specific operations
```
SPC g g          inside the worktree status:
  M-w            magit worktree menu (list/create/remove)
```

---

## 8. Multi-task — when 40 things are alive

### Survey what's running
```bash
eda ls                          # all daemons
SPC k d l                       # tabulated buffer inside any daemon
SPC X                           # agenda — every project.org TODO
```

### Switch contexts
```bash
eda pcie                        # GUI frame to pcie daemon
eda soc                         # GUI frame to soc daemon
```

Or from inside an existing daemon: `SPC k d s` → pick.

### Spawn a new IP family
```bash
eda new cxl ~/eda/wt           # from shell
SPC k d n                       # from any running daemon (interactive)
```

### Decommission
```bash
eda kill <name>                 # double-confirms
SPC k d k                       # interactive
```

---

## 9. Claude — when to reach for which tool

| Situation | Tool | Key |
|-----------|------|-----|
| One-line question about syntax | gptel | `M-x gptel` |
| Explain this function | claude-code.el | `SPC k e` |
| Review this RTL (quick) | claude-code.el | `SPC k v` |
| Review this RTL (full checklist) | rtl-review-agent | `SPC k a r` |
| Write/expand a cocotb test | verification-agent | `SPC k a t` |
| Triage a failing log | debug-agent | `SPC k a d` |
| Open-ended exploration | Claude Code CLI in vterm | `SPC k k` |
| Summarize an article | claude-code.el | `SPC m s` (elfeed) |

Each daemon's Claude Code session reads the worktree's `CLAUDE.md` at start — so the context is **already correct** when you launch Claude from inside, say, `~/eda/wt/pcie-gen7-link-init/`.

---

## 10. End of day

Two options:

**Leave daemons running** (recommended — instant resume tomorrow):
```
SPC k q          quit frame only; daemon persists
```
Or just close the window. macOS doesn't kill the daemon when you close its frames.

**Shut everything down** (free memory):
```bash
eda kill soc
eda kill pcie
eda kill ucie
```

Persp state for each daemon is saved on shutdown to `~/.config/doom/.persp-state-<name>.el` so reopening restores your workspaces.

---

## 11. Quick reference card (print this)

```
DAEMONS          SPC k d
  n new          k kill          s switch
  l list         R restart       r rename
  S seed         w new-worktree

CLAUDE           SPC k
  k start        t toggle        x explain-error
  c continue     e explain       v review-verilog
  R resume       T write-tb      b send-buffer
  K kill         r send-region   s send-command

CLAUDE AGENTS    SPC k a
  r rtl-review   t verification  d debug
  c seed-md      a seed-agents

PROJECT (org)    SPC p e
  o open-project.org             r refresh-agenda
  t capture-TODO  d capture-debug  q capture-question

EDA BUILD/SIM    SPC c e
  l v-lint       v v-build+run   C v-coverage
  i icarus       p cocotb-pytest P cocotb-make
  y yosys-elab   Y yosys-show    f sby
  w gtkwave      s surfer

FORGE / GIT      SPC g
  g magit-status                 f forge-dispatch
  R list-PRs      I list-issues  N new-PR

EXISTING (untouched)
  SPC o R        elfeed-summary dashboard
  SPC m s/a/f    claude+elfeed wrappers
  SPC X          org-agenda
  SPC q s        save-and-quit (kills current frame only)

CAPTURE keys (in org-capture-templates)
  i u d w x      life.org Eisenhower (existing)
  pt pd pq       project.org (new)

SHELL
  eda ls                       list daemons
  eda <name>                   attach
  eda new <name> [path]        spawn
  eda kill <name>              stop
  eda restart <name>           restart
  eda exec <name> <elisp>      send code

BINARIES (Mac)
  verilator                    sim
  iverilog                     sim
  yosys                        synth / formal frontend
  verible-verilog-{ls,lint,format}
  gtkwave                      waveform
  (cocotb)                     per-worktree venv
  (sby, surfer)                manual install pending
```

---

## 12. Pitfalls + fixes (lessons from setup)

- **`eda ls` shows nothing but daemon is alive** — fixed in the post-Phase-6 patch (socket-based discovery instead of pgrep).
- **K in magit deletes the file instead of reverting** — that's evil-collection. For untracked files K removes; for modified files K reverts. Use `X h` (hard reset) for the safe whole-tree revert.
- **Submodule `+Subproject commit … -dirty`** — enter the submodule's magit (`RET` on the entry), then `X h` to reset to HEAD.
- **`+roam2 is deprecated`** — purely cosmetic warning; flag rename to `+roam` is safe but not done (per your choice).
- **GTKWave deprecated upstream** — still works for now; Surfer is the modern OSS alternative (cargo install pending).
- **gtkwave doesn't react to `gtkwave --version`** — that's normal; the version is only in the GUI.

---

## 13. When you outgrow this setup

These are escape hatches if/when:

- **You need commercial tools** — add a per-tool wrapper next to the verilator/yosys ones in `eda-sim.el`; same compile-mode pattern.
- **You need remote (Linux farm) sim/synth** — TRAMP into the farm, run `make` over SSH; the Verible LSP stays local for editing.
- **You need 100+ tasks** — switch from "daemon-per-IP" to "daemon-per-LARGER-grouping" (e.g., per-chip). The dynamic `SPC k d n` already supports it.
- **You want a richer workspace switcher** — the `:ui tabs` module gives you visual tab strips; tweak to taste via `centaur-tabs`.
