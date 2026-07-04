# EDA-IDE Phase 8+ — "Killer" Org ⇄ Claude Task Engine

**Status:** Architecture / brainstorm draft · 2026-07-04
**Author:** design pass with Claude (Opus 4.8)
**Reads as:** a continuation of `EDA-IDE-PLAN.md` (Phases 0–7) and `EDA-IDE-WORKFLOW.md`. Same vocabulary (DAEMON → WORKSPACE → WORKTREE, `eda/` namespace, role sub-agents, per-phase reversible rollout, explicit "contract" of preserved behavior). Nothing here rewrites the existing system; it adds an **org-driven lifecycle layer** on top of `eda-workspace-claude.el`.

> This document is the deliverable you asked for: (1) the current approach reviewed, (2) a numbered list of enhancements & concrete changes mapped to each of your requirements, (3) a separate "New strategies from research" heading, (4) open questions to brainstorm, and (5) a reversible phased rollout. Path is at the very bottom of our chat.

---

## 0. The one big idea

**Org is the kernel. A task's lifecycle is a state machine. Everything else — Claude sessions, worktrees, clocks, windows, memory, reports — is a projection of org state, driven by hooks.**

You never "manage Claude." You move an org task through `TODO → IN-PROGRESS → REVIEW → DONE`, and the system reconciles the world to match: spawn/resume the right Claude session in the right directory, place it in the right window slot, start its effort clock, and — at DONE — run the delivery ritual before letting go. Org is the single point of contact; Claude is a side effect of org state.

Two design inversions make it work:

1. **Effort clock ≠ org clock.** Because org allows only one live clock, we track effort with an independent **parallel-clock engine** that writes `CLOCK:` lines per task. Overlap is allowed and honest; the weekly report sums each task's full time and flags overlaps.
2. **Session handle is deterministic, stored in org, not scraped.** We pre-generate the session UUID (your code already does this) and store it in the task's `:CLAUDE_SESSION:` property + a copy-paste resume comment in the LOGBOOK. Resume never guesses — same on your Mac and on the client Linux box.

---

## 1. Decisions locked (from our Q&A)

| # | Decision | Consequence for design |
|---|----------|------------------------|
| D1 | **Client = separate isolated machine** (its own Emacs+Doom+Claude, never seen from here). One org file bridges. | Both machines run the *same portable config*. The client `tasks.org` is the shared trigger surface. No TRAMP/SSH to client. |
| D2 | **Mobile = iPhone / organice / Dropbox** *(revised in Phase-8 review, §5.E19)* | organice (client-side browser org editor) talks straight to Dropbox; desktop Emacs syncs the same folder. Only `personal.org` + an append-only client **outbox** live on Dropbox; last-writer-wins → small files, append-only on mobile, `.bak` guards. |
| D3 | **Client-file bridge = email** *(revised in Phase-8 review, §5.E18)* | `eda/client-sync` emails an org-subtree delta (new tasks + idle clocks) Mac→client; client emails full state back as a read-only mirror. Union-merge on apply; no live network to the client assumed. |
| D4 | **Claude runtime = `claude` CLI in vterm, resumed by `--session-id`/`--resume`** | Extend existing `eda/ws-claude--spawn`; keep vterm backend. |
| D5 | **Parallel clocks: overlap allowed, full time each; report flags overlap** | Custom parallel-clock engine writing `CLOCK:` lines; agenda `v c` for overlap audit. |
| D6 | **DONE-gate = all four: worktree committed + review prompt + Claude self-review of diff + memory updated** | A 4-step delivery state machine gates the `→ DONE` transition. |
| D7 | **Client OS = Linux, restricted (user-space only, flaky net)** | No root, no Homebrew paths, `executable-find` everywhere, graceful degradation, manual sync path. |
| D8 | **Memory = two isolated stores** (personal syncs everywhere; client memory never leaves the client box) | Two memory roots; per-worktree `CLAUDE.md` `@`-imports only the stores allowed on that machine. |

---

## 2. Current system — what we build on (recap)

Verified from your config:

- **Nesting:** `DAEMON (per IP family) → WORKSPACE (persp, per task) → WORKTREE (~/eda/wt/<task>/)`, with `persp-name == worktree dir` and `eda/ws--cd-to-worktree` syncing `default-directory` on persp switch.
- **Claude sessions:** `eda-workspace-claude.el` spawns role-specialised sessions via `claude-code.el` (vterm backend), using **`claude --session-id <uuid>`** (fresh) / **`claude --resume <uuid>`** (rejoin). UUID generated up front by `eda/ws-claude--uuid`; recorded **at spawn time** to `<worktree>/.claude/sessions/<role>.{history,session-id,md}` so resume survives a crash.
- **Tasks:** `eda-tasks.el` builds per-worktree `project.org` (`#+TODO: TODO IN-PROGRESS BLOCKED REVIEW | DONE WONTDO`), auto-discovered into `org-agenda-files`.
- **Roles/agents:** `architect, rtl-review, verification, integration, debug` markdown templates seeded into `.claude/agents/`; per-IP `CLAUDE.md` from `CLAUDE-templates/`.
- **Daemons:** one `emacs --bg-daemon=<ip-family>` each, registry in `eda-registry.el`.

**What's missing (your wishlist):** org-clock trigger, DONE-gate, window grids, cross-machine sync, shared memory, per-tag reporting, portability. All additive.

---

## 3. Requirement → enhancement traceability

| Your requirement | Status today | Delivered by |
|---|---|---|
| Clock/start a task → start Claude | ✗ manual only | **E2, E4** |
| Clock/click → resume specific session (id in org) | ◐ id in files, not org | **E1, E4** |
| Auto-close Claude when task DONE/clocked-out | ✗ | **E2, E6** |
| Block close until "delivered" (git-checkable review) | ✗ | **E6** |
| Weekly report per-tag + collective | ✗ | **E10** |
| Mobile + desktop TODO sync | ◐ Dropbox by accident | **E7** |
| One org file synced to isolated client, editable here + mobile | ✗ | **E7** |
| Per-task worktree (my end + client end) | ◐ personal only | **E2, E9, E11** |
| Per-task bash `source` for client, set at task creation | ◐ fixed `.envrc` only | **E9** |
| Collective memory .md at both ends, sourced before Claude | ◐ CLAUDE.md only | **E8** |
| 4 / 6 / 8 window grids + fast switch keys | ✗ | **E5** |
| Portable config (Mac + client Linux) | ✗ Mac-only | **E11** |
| Org log records how to restart/resume session | ◐ in files/docs | **E1, E4** |
| Simultaneous multi-task clocking, overlap allowed | ✗ (org = 1 clock) | **E3** |
| Session name written to log on TODO→other state | ✗ | **E4** |
| Org = single point of contact to jump to active Claude window | ✗ | **E2 (`eda/task-jump`)** |
| Read task intent + notes to bootstrap/resume Claude | ✗ | **E4** |
| Ask for review when closing | ✗ | **E6** |
| Open file scoped to focused task's worktree (`SPC p f`) | ✗ | **E13** |
| Buffer names = file + org task name (`SPC b B`) | ✗ | **E14** |
| `C-x 1` zoom / `C-x 0` restore default grid | ✗ | **E15** |
| Grid order = clocked-task order in weekly agenda | ✗ | **E16** |
| Auto 1×2 / 2×2 / 2×3 / 2×4 relayout on clock in/out | ✗ | **E16** |
| Single-key clock in/out from agenda → pane open/close | ✗ | **E16** |
| Idle task subtracted from overlapping tasks | ✗ | **E17** |
| Client state read-only on my Mac; add-task + idle allowed | ✗ | **E18** |
| Email bridge for client tasks | ✗ | **E18** |
| Mobile via organice + Dropbox | ✗ | **E19** |

`◐ = partial`, `✗ = absent`.

---

## 4. Target architecture (layers)

```
┌─────────────────────────────────────────────────────────────────────┐
│ L0  eda-portable.el   host/OS profile · tool discovery · path resolve │  E11
├─────────────────────────────────────────────────────────────────────┤
│ L1  ORG KERNEL        task schema: PROPERTIES + LOGBOOK               │  E1
│      (single point of contact: agenda, capture, jump)                 │
├─────────────────────────────────────────────────────────────────────┤
│ L2  eda-task-engine.el   lifecycle: task-start / stop / done / jump   │  E2
│      triggers = clock-in hook · todo-state-change hook · keys         │
├──────────────┬──────────────┬───────────────┬────────────────────────┤
│ L3 pclock    │ L4 session   │ L5 grid       │ L6 done-gate            │  E3/E4/E5/E6
│  eda-pclock  │  (extends    │  eda-grid     │  eda-done-gate          │
│  overlap     │  ws-claude)  │  1+3/2x3/2x4  │  4-check ritual         │
├──────────────┴──────────────┴───────────────┴────────────────────────┤
│ L7  eda-sync.el   client bridge file · beorg/iCloud · conflict guard  │  E7
│ L8  eda-memory.el two isolated stores · bootstrap-source · capture    │  E8
│ L9  eda-report.el weekly clocktable · per-tag · per-client · delivery │  E10
└─────────────────────────────────────────────────────────────────────┘
```

New files (all `eda-*.el`, matching your convention). Existing files touched: `config.el` (hooks, keys, org-clock config), `eda-workspace-claude.el` (session-binding hooks), `eda-tasks.el` (schema + capture), `packages.el` (2–3 packages).

---

## 5. Enhancements (detailed)

### E1 — Task schema: the org contract

Every actionable task carries this drawer. It is the **portable handle** — the same properties resolve on Mac and client Linux; only path/tool resolution differs (L0).

```org
* IN-PROGRESS Gen7 link-init FSM              :eda:pcie:acme:billable:
:PROPERTIES:
:ID:              a1b2...                 ; org-id, stable cross-file link
:TASK_SLUG:       pcie-gen7-link-init
:WORKTREE:        eda/wt/pcie-gen7-link-init   ; RELATIVE to profile root, resolved by L0
:CLAUDE_SESSION:  4a3a0edc-afc6-43ea-8371-7be9c3064c0b   ; preset UUID (deterministic resume)
:CLAUDE_ROLE:     rtl-review
:CLIENT:          acme                    ; empty ⇒ personal task
:CLIENT_SRC:      $CLIENT_ENV/acme/env.sh ; bash sourced before claude (client tasks only)
:MEM_SCOPE:       client-acme             ; which memory store to source (personal|client-<x>)
:WINDOW_SLOT:     2                        ; preferred grid pane
:DELIVERY:        pending                  ; pending→committed→reviewed→memory→done (E6)
:END:
:LOGBOOK:
CLOCK: [2026-07-04 Fri 09:00]--[2026-07-04 Fri 10:30] =>  1:30
- Resume ▶  (cd <worktree> && [source $CLIENT_SRC &&] claude --resume 4a3a0edc… )   ; E4 writes this
- Session ▶ role=rtl-review started 2026-07-04, id 4a3a0edc…                        ; E4 writes this
:END:
```

Elisp: `org-entry-get`/`org-entry-put`, `org-id-get-create`. `:WORKTREE:` stored **relative** so it resolves under each machine's profile root (`eda/portable-root`).
Config: `(setq org-log-into-drawer t)` so notes and CLOCK lines live in LOGBOOK; `(setq org-clock-into-drawer "LOGBOOK")`.

**Covers:** resume-id-in-org, resume-comment-in-log, dir-associated-with-task, client-source-command, memory-scope.

---

### E2 — Task lifecycle engine (`eda-task-engine.el`)

The master verbs. Every trigger funnels here so behavior is identical whether you clock in, change TODO state, or hit a key.

```
eda/task-start   ; ensure worktree → ensure session (resume or new) → pclock-in
                 ;   → place in window slot → write resume/session log lines
eda/task-stop    ; pclock-out (write CLOCK line) → snapshot session (keep alive)
eda/task-done    ; run DONE-gate (E6); on pass: snapshot+commit, kill session, pclock-out
eda/task-jump    ; SINGLE POINT OF CONTACT: from any org/agenda line, switch persp +
                 ;   raise that task's Claude window (reads :CLAUDE_SESSION:/:WORKTREE:)
```

**Triggers wired in `config.el`:**
- `org-clock-in-hook` → `eda/task-start` (guarded: `(when (markerp org-clock-hd-marker) (org-with-point-at org-clock-hd-marker …))`).
- `org-after-todo-state-change-hook`:
  - leaving `TODO` (→ IN-PROGRESS/REVIEW) ⇒ `eda/task-start` + write session/resume lines (E4).
  - → `DONE`/`WONTDO` ⇒ intercept with `eda/task-done` (E6 gate; may veto and reset state).
- `org-clock-out-hook` → `eda/task-stop` for the focused task.
- Keys under `SPC k t` (new "task" group): `s` start, `p` stop, `d` done, `j` jump, `g` grid.

**`eda/task-jump`** makes org the switchboard: cursor on any task (in `project.org`, client `tasks.org`, or agenda) → jumps to its persp/worktree and raises its live Claude buffer; if the session isn't running, resumes it from `:CLAUDE_SESSION:`.

**Covers:** clock→start, auto-close on DONE, org-as-single-point-of-contact, resume-on-restart.

---

### E3 — Parallel-clock engine (`eda-pclock.el`)  ⚠ works around org's 1-clock limit

Because native org has exactly one live clock, effort is tracked independently:

- `eda/pclock-table` : hash `task-id → start-timestamp` for every *active* task (a task is active while its Claude session is up).
- `eda/pclock-in` : record start; add task to mode-line indicator (`⏱×3` shows how many run).
- `eda/pclock-out` : compute span, **write a `CLOCK:` line into that task's LOGBOOK** via org API (bypassing the single live clock). Overlap is allowed and preserved.
- Optional **focus mirror:** the task you're actively typing at can also drive org's *real* clock (`org-clock-in`) purely for the familiar mode-line/idle features; switching focus juggles it (`org-clock-in-last`, `org-mru-clock`). All *reporting* reads the written `CLOCK:` lines, not the live clock.
- Persistence: `org-clock-persist` + a small `eda/pclock` state file so active timers survive restart (pairs with your at-spawn session recording).

**Reporting truth:** clocktable happily sums overlapping `CLOCK:` lines → "full time each." Agenda `v c` (`org-agenda-log-mode` clock-check) highlights overlaps → "report flags overlap." Exactly D5.

**Covers:** simultaneous multi-task clocking, overlap-allowed reporting.

---

### E4 — Claude session binding (extends `eda-workspace-claude.el`)

Bind the existing role-session machinery to org tasks.

- **Resume by property, not scrape.** `eda/task-start` reads `:CLAUDE_SESSION:`; if empty, generate via `eda/ws-claude--uuid`, `org-entry-put` it, then `eda/ws-claude--spawn` with `--session-id`; if present, `--resume`. (Keeps your durable at-spawn recording as a backstop; stops relying on parsing the unstable `~/.claude/projects/**.jsonl`.)
- **Intent + notes injection.** Before/at spawn, generate `<worktree>/.claude/task-context.md` from the task's heading, `:PROPERTIES:`, Goal, and latest LOGBOOK notes; the worktree `CLAUDE.md` `@`-imports it, so resuming Claude re-reads "what this task is and where we left off."
- **Client source command.** If `:CLIENT_SRC:` set, the vterm launch is `source <expanded CLIENT_SRC> && claude …` (env for client tooling). New tasks for a client get it prefilled (E9).
- **Log-writing on state change.** On TODO→other, append to LOGBOOK: the `Session ▶ role=… id=…` line and the copy-paste `Resume ▶ (cd … && [source …] claude --resume …)` comment. → your "session name in log" + "always store resume comment" requirements.
- **Git-checkable delivery.** Session `.md` snapshot (existing `eda/ws-claude--snapshot-one`) is committed to the worktree branch during DONE-gate, so the diff of "what Claude did" is reviewable in magit.

**Covers:** resume-specific-session, intent/notes bootstrap, client source, session-name-to-log, resume-comment, git-checkable session.

---

### E5 — Window grid manager (`eda-grid.el`)

Fixed grids with a dedicated pane per Claude session and one org pane.

- `eda/grid-1+3` — org left (full height), 3 stacked Claude panes right. (Your default "4-split".)
- `eda/grid-2x3` — 2 rows × 3 cols (6 panes): slot 0 = org, 1–5 = Claude.
- `eda/grid-2x4` — 2 rows × 4 cols (8 panes): slot 0 = org, 1–7 = Claude.
- `eda/grid-auto` — **see E16**: layout auto-selected by *clocked* count and re-rendered on every clock in/out; panes ordered by clock order, slot 0 = org weekly agenda.
- Implementation: `delete-other-windows` → nested `split-window-right`/`-below` loops → `balance-windows`; Claude buffers pinned with `set-window-dedicated-p`; `display-buffer-alist` entry so Claude buffers only ever open in a grid pane.
- **Fast switching:** `winum` `M-1 … M-8` O(1) jump; `ace-window` `M-o` for actions; `windmove` `S-<arrow>`. `eda/grid-cycle` rotates focus. `C-x 1` zooms one pane; `C-x 0` restores the grid (**E15**). Layout persistence via `window-configuration-to-register` or `tab-bar`.
- **Readability caveat (research):** vterm/ghostel reflow the Claude TUI to pane width — narrow panes can garble it. Recommendation: use **vterm** (you already do) or **ghostel** backend for small panes, keep panes ≥ ~80 cols, and prefer 1+3 unless you truly need 8. Claude's replies/questions render inside its pane; you answer by focusing that pane (`M-<n>`).

**Covers:** 4/6/8 grids, fast switch keys, readable multi-session layout, org+Claude co-visible.

---

### E6 — DONE-gate: the delivery ritual (`eda-done-gate.el`)

Intercepts `→ DONE`. Advances `:DELIVERY:` through states; if any check fails, resets the task to `REVIEW` and reports what's missing. All four required (D6):

1. **Worktree committed** — `git -C <worktree> status --porcelain` empty (and branch not behind). If dirty: offer `magit` / auto-commit; block otherwise. → `committed`. **If the worktree is not a git repo, this step (and any push/pull) is voided and marked N/A** — the other three checks still apply.
2. **Review prompt answered** — ask (minibuffer/org-capture): *What was delivered? What was tested? Follow-ups?* Answers appended to LOGBOOK. → `reviewed`.
3. **Claude self-review of the diff** — headless `claude -p --bare "Review this diff for correctness/risks; be terse" < git diff <base>...HEAD` with `--output-format json`; summary appended to LOGBOOK; you confirm. (`--bare` = no auto-context, fast/cheap; run in the worktree so it's scoped.) → `reviewed`.
4. **Memory updated** — require a new entry in the task's memory store (E8) keyed by `TASK_SLUG`; if absent, pop a capture to write the lesson. → `memory`.

On all-pass: snapshot+commit the session transcript (E4), `eda/task-stop` (pclock-out), kill the Claude session (`eda/ws-claude-kill`), set `:DELIVERY: done`, allow `DONE`.

Mechanism: `org-after-todo-state-change-hook` (reset state on veto). Optionally `org-blocker-hook` to also prevent DONE while `:DELIVERY:` ≠ `done`.

**Covers:** don't-close-until-delivered, git-checkable, ask-for-review-on-close, memory-before-done, auto-close session.

---

### E7 — Sync spine (`eda-sync.el`)

Three file classes, three reaches. **Only the client task file + personal memory ever leave a machine; nothing else syncs** (matches your "sync only the client org file" + isolation rules).

| File | Personal Mac | iPhone (beorg) | Client Linux |
|---|---|---|---|
| `~/org/personal.org` (your TODOs) | ✔ home | ✔ iCloud | ✗ |
| `~/org/clients/<client>/tasks.org` (**the ONE shared client file**) | ✔ | ✔ iCloud | ✔ via `eda/client-sync` |
| `memory/personal/**` | ✔ | – | ✔ (chezmoi/git) |
| `memory/clients/<client>/**` | ✗ | ✗ | ✔ **client-only** |
| worktrees, session-ids, persp state, registry | machine-local (unchanged) | – | machine-local |

- **Mac ↔ iPhone:** beorg on iCloud. ⚠ iCloud/beorg is **last-writer-wins** — keep the client `tasks.org` small, edit from one device at a time, and `eda/sync-guard` writes a timestamped `.bak` on every load so a clobber is recoverable.
- **Mac ↔ Client (isolated, restricted, flaky net):** `eda/client-sync-export` writes `tasks.org` + a SHA to an agreed drop location (shared cloud folder / USB / whatever the client allows); `eda/client-sync-import` pulls it back with a **3-way union merge** (`git merge-file --union` on a local mirror) so concurrent edits on both ends don't lose lines. No live git assumed on the client. Manual, explicit, auditable.
- Both machines run identical `eda/task-start`; the client's Emacs reacts to *its* copy of `tasks.org` → "Claude opens the same way when a client task starts at the client end."

**Covers:** one-client-file sync, editable here+mobile+client, isolation of everything else.

---

### E8 — Two isolated memory stores (`eda-memory.el`)

- **Personal store** `~/.claude/memory/personal/` — how you work, general EDA skills, tool gotchas. Synced everywhere (chezmoi/git). `INDEX.md` `@`-imported by every worktree `CLAUDE.md`.
- **Client store** `~/.claude/memory/clients/<client>/` — confidential, per-client. **Exists only on the client machine**, never synced off. `@`-imported by worktree `CLAUDE.md` **only when the machine profile is that client** (L0 gates the import line).
- **Source-before-start:** because `CLAUDE.md` auto-loads at session start and supports `@path` imports (≤4 hops), a session automatically reads `personal/INDEX.md` (+ client store on the client box). No custom injection needed beyond generating the right `CLAUDE.md` per worktree.
- **Capture (DONE-gate step 4):** distilled lesson appended to the correct store by `:MEM_SCOPE:` — personal lessons travel, client lessons stay put. Keeps the boundary clean by construction.

**Covers:** collective memory both ends, sourced before Claude, personal/client isolation.

---

### E9 — Client task provisioning

New capture template `SPC k t c` ("new client task") that, in the client `tasks.org`, prompts for and fills: `:CLIENT:`, `:CLIENT_SRC:` (the bash to source before Claude), `:TASK_SLUG:`, `:WORKTREE:` (relative), `:MEM_SCOPE:`, generates `:CLAUDE_SESSION:` UUID, seeds the worktree (dir + `.claude/` + role agents + `CLAUDE.md` with the client memory import). On the client machine, `eda/task-start` then just works: `source $CLIENT_SRC && claude --resume …` in the task's directory.

**Covers:** per-task client source set at creation, dir-associated client task, worktree both ends.

---

### E10 — Reporting (`eda-report.el`)

- `eda/report-weekly` → generates `~/org/reports/weekly-<isoweek>.org` with:
  - **Collective** clocktable: `#+BEGIN: clocktable :scope agenda-with-archives :block thisweek :maxlevel 3 :wstart 1 :compact t`.
  - **Per-tag** breakdown: ffevotte's `clocktable-by-tag` dblock (or a generated loop of `:match "<tag>"` blocks — native `:tags t` only *displays* a column, it does **not** group). One section per IP-family / client / `billable`.
  - **Per-client** report filtered by `:CLIENT:` (for invoicing).
  - **Delivery log:** entries that hit `:DELIVERY: done` this week, with the review summary — a "what shipped" digest.
  - **Overlap note:** a line reminding that overlaps are intentional (D5), with an `v c` audit pointer.
- Auto-generation: `SPC k r w`, plus optional `emacs --batch … (org-update-all-dblocks) (save-buffer)` via launchd (Mac) / cron (Linux) each Friday. ⚠ batch must `(require 'org)`, set `org-agenda-files`, load the custom dblock, pin `:wstart 1`.

**Covers:** weekly report, per-tag + collective, per-client.

---

### E11 — Portability layer (`eda-portable.el`)

- **Profile detection:** `eda/host-profile` ∈ `{personal-mac, client-<name>}` from hostname / a marker file `~/.eda-profile` (works even when hostnames are opaque on client VMs).
- **Path resolution:** `eda/portable-root` (worktree root), memory roots, drop locations — all per-profile. `:WORKTREE:` is relative and resolved here.
- **Tool discovery:** `executable-find` for `claude`, `git`, sims, etc. — **no hardcoded `/opt/homebrew`**. Features self-disable when a tool is absent (restricted client).
- **OS conditionals:** `(eq system-type 'darwin|gnu/linux)` for keys/clipboard/daemon; the whole daemon/launchd stack is Mac-only and skipped on the client.
- **Config distribution:** **chezmoi** manages `~/.config/doom` across machines with `{{ if eq .chezmoi.os "darwin" }}…{{ end }}` templating; a git-ignored `.eda-local.el` holds per-machine secrets/paths. (chezmoi chosen over yadm — yadm's templating depends on unmaintained tooling.)
- **Graceful degradation:** on restricted Linux (no root, flaky net): no daemon spawn, no Homebrew, manual sync only, features gated on tool presence — the config *boots clean* and simply offers less.

**Covers:** portable Mac + restricted-Linux config, one config both machines.

---

### E12 — (Optional power-up) MCP bridge

Layer `claude-code-ide.el` so Claude can read Emacs Flycheck/Flymake diagnostics, xref, and open `ediff` on its own edits (great for the review step). ⚠ Research flags it "early development" with MCP reachability bugs — adopt as an *optional* Phase 12, gated behind a flag, never load-bearing. Your `claude-code.el` (stevemolitor) stays the primary driver.

---

### E13 — Worktree-follows-focus for file finding  *(new; point 1)*

Opening a file (`SPC p f` / project find-file / `SPC f f`) from any task pane must resolve inside **that pane's** worktree — not whatever project the persp last set. Because a grid puts several tasks' buffers in one frame, the project root is derived **per focused window**, not per persp.

- `eda/window-worktree` — from the focused window's buffer, resolve its task worktree (via the buffer→task map of E14, else the buffer's `default-directory`).
- Advice wrapping the project find-file command: `(let ((default-directory wt) (projectile-project-root wt)) …)` so both the completion candidates and the opened buffer land in the right worktree; also refresh the persp/`default-directory` so later commands stay consistent.
- Key: Doom's `SPC p f` (add a `SPC P F` alias if you like the capital binding).

**Covers:** file-find scoped to the task's worktree, auto project-switch.

---

### E14 — Task-annotated buffer names  *(new; point 2)*

Every task-bound buffer is named `‹basename› · ‹task-slug›`, so `SPC b B` shows both the real file and the org task:

- Claude panes → `claude:rtl-review · pcie-gen7-link-init`.
- Files opened inside a worktree → `link_fsm.sv · pcie-gen7-link-init` (rename-on-open via a buffer→task map keyed by the worktree path prefix).
- Implemented with a rename hook + a `consult-buffer` annotation/grouping fallback (buffers grouped by task in the switcher).

**Covers:** buffer switcher shows file + task name.

---

### E15 — Zoom & restore  *(new; point 3)*

- `C-x 1` — keep the stock *zoom to a single window* (`delete-other-windows`) to focus one buffer.
- `C-x 0` — **rebound** to `eda/grid-restore`: rebuild the default grid (org weekly agenda in slot 0 + one Claude pane per currently-clocked task, ordered by clock order, in the auto-selected 1×2/2×2/2×3/2×4 layout of E16). ⚠ This shadows the stock `delete-window`; stock delete moves to `SPC w d`. (Micro-fork MF3 — if you'd rather keep `C-x 0` stock, we bind restore to `SPC k g r`.)

**Covers:** single-buffer focus + one-key return to the default multi-pane layout.

---

### E16 — Clock-ordered, auto-relayout grid  *(refines E5; points 4, 5, 6)*

- **Slot order = clock order.** Slot 0 = the org **weekly agenda**; slots 1..n = clocked tasks in the order they appear/were clocked in that agenda. Deterministic — a task always sits in the same pane. → your requirement "order of Claude panes = order of clocked tasks on the agenda."
- **Auto layout by clocked count, re-rendered on *every* pclock-in/out:**
  - 0 clocked → org only.
  - 1 → org + 1 Claude (1×2).
  - 2–3 → **2×2** (org + up to 3 Claude).
  - 4–5 → **2×3** (org + up to 5 Claude).
  - 6–7 → **2×4** (org + up to 7 Claude).
- **Single-key clock from the agenda** (e.g. `I`/`O` in the agenda keymap) → `eda/task-start`/`eda/task-stop` → the Claude pane appears/disappears → grid relayouts automatically.
- Clocking **out kills** the Claude process (MF1, resolved) and removes its pane; re-clocking spawns a fresh `claude --resume <CLAUDE_SESSION>` from the stored id — a few seconds' reload but zero idle RAM. (The at-spawn session-id recording makes this safe.)
- Claude always starts with **cwd = the task's worktree**.

**Covers:** clock-ordered panes, auto grid switching on clock in/out, single-key clocking, Claude in worktree dir.

---

### E17 — Idle task & time reconciliation  *(new; points 7, 11, 13 — resolves Q2)*

- A special **Idle task per environment**: `Idle · personal` and `Idle · client-<x>`, tagged `:idle:`. One key clocks idle in/out.
- Parallel work tasks accrue full overlapping time (D5). **Idle time is subtracted from whatever was clocked during it.** When idle is clocked over span `[t0,t1]`, every non-idle task active during `[t0,t1]` has that overlap deducted.
- Mechanism (default MF2, non-destructive): idle `CLOCK:` lines are recorded; the weekly report computes `net = Σ task CLOCK − Σ overlapping idle`, and an `:IDLE_ADJ:` note is written to each affected task at idle clock-out for auditability. *(Alternative: trim each affected task's `CLOCK:` line directly at idle clock-out.)*
- **The client Idle task is clockable from your Mac / iPhone** (an allowed write, E18) and syncs to the client, so it deducts lunch/break time from the *client's* tasks that were clocking — even though you can't touch client work-task state. → "remove clock time from tasks clocked during that idle time."

**Covers:** idle-as-task, overlap subtraction, per-client idle, cross-machine idle correction.

---

### E18 — Asymmetric client permissions + email bridge  *(refines E7; points 10, 13, 14 — resolves Q5, Q7, Q8)*

**Write-permission matrix for the client `tasks.org`:**

| Action | Your Mac | iPhone | Client Linux |
|---|:--:|:--:|:--:|
| Change client work-task **state** / clock work tasks | ❌ | ❌ | ✅ |
| **Add** a new client task | ✅ (queued) | ✅ (queued) | ✅ |
| Clock the **client Idle** task | ✅ (queued) | ✅ (queued) | ✅ |
| **View** all client tasks | ✅ read-only | ✅ read-only | ✅ |

- On your Mac the client file opens with work-task edits **blocked** (read-only overlay); only "add task" and "idle clock" mutations are captured into an **outbox delta**.
- **Transport = email** (`eda/client-sync`): your Mac emails the outbox delta (new tasks + idle clocks, as an org subtree/patch) to the client mailbox; the client machine imports from email and union-merges. Reverse: the client emails its full current state and your Mac imports it as the read-only mirror. No live network to the client is assumed.
- Per-DONE, client memory is distilled **locally on the client** and is never emailed out (isolation, E8).

**Covers:** client-only state editing, add-task + idle from anywhere, email sync, all-tasks-visible-but-read-only on Mac.

---

### E19 — Mobile via organice + Dropbox  *(revises D2/E7; point 15)*

- **organice** (client-side browser org editor that talks straight to Dropbox) on your iPhone; **Dropbox** as the store; desktop Emacs syncs the same folder.
- Dropbox holds `personal.org` (full R/W) + a **client outbox** file (append-only: new client tasks + client-idle clocks organice can add). It does **not** hold full client state — the full client file lives only on your Mac (mirror) and the client box (confidentiality).
- Conflict model is last-writer-wins → keep files small, append-only on mobile, `.bak` on desktop load. organice is client-side (no server sees your data beyond the static app + your Dropbox token), which is why it beats a hosted editor.

**Covers:** iPhone editing, Dropbox sync, add-task/idle from mobile without exposing full client state.

---

## 6. New strategies from research (worth stealing)

> Separate heading as you asked — these are things not in your original ask that the 2026 research surfaced and I recommend adopting.

1. **`claude --worktree <name>` is native now.** Claude Code can create/own a git worktree itself (`.claude/worktrees/<name>`, branch `worktree-<name>`, `--worktree #<PR>` from a PR). Consider delegating worktree creation to Claude for ad-hoc work instead of `eda/new-worktree-for-task`. Keep your explicit worktrees for tracked tasks; use `--worktree` for throwaway experiments. Add `.claude/worktrees/` to `.gitignore`; use `.worktreeinclude` to copy `.env`/`.envrc` into new trees.
2. **`--bare` for all scripted/headless calls** (report review, memory distill). Skips auto-loading hooks/skills/MCP/CLAUDE.md → faster, cheaper, deterministic. Becomes the `-p` default upstream. Use it in E6 step 3 and E8 capture.
3. **Deterministic `--session-id` + `--output-format json` (`.session_id`) — never parse JSONL.** You already preset UUIDs (great); the research confirms the transcript JSONL format is explicitly unstable. **Migrate title/last-prompt scraping off JSONL** onto `/export` or a `-p --output-format json` call. This de-risks `eda/ws-claude--session-title`.
4. **`--fork-session`** avoids the "same session open in two terminals interleaves one transcript" corruption — use it if a task ever needs a branch of its own history.
5. **`org-mru-clock`** (unhammer) makes serial clock-juggling of the focus clock frictionless — good companion to E3's focus mirror.
6. **`clocktable-by-tag`** (ffevotte gist) is the established fix for true per-tag grouping — native clocktable can't group by tag. Pin the version.
7. **Orgzly Revived has a native git client now** (no Termux). If you ever add Android, git sync beats iCloud's last-writer-wins. For your iPhone/beorg choice, mitigate with the `.bak`/single-writer discipline in E7.
8. **`tab-bar` / `burly.el`** for named, restart-surviving window layouts — cleaner than manual register save for E5 persistence (`tab-bar` supersedes eyebrowse).
9. **Prior art = typester's CLAUDE.md org-clock convention** (a gist, not a package): CLAUDE.md instructs Claude to open org via `emacsclient` and punch its own `CLOCK:` entries tagged `:ai:`. We do the inverse (Emacs drives Claude), which is more robust — but their tag convention (`:ai:claude:`) is worth adopting so agent time is filterable in reports. **There is no mature package that does per-org-TODO agent+clocking — this is greenfield; we're building the reference implementation.**
10. **`set-window-dedicated-p` + `display-buffer-alist`** to stop Claude buffers from hijacking your org pane — essential for the grids to stay stable.

---

## 7. Decisions resolved in the Phase-8 review

| Q | Resolution | Where |
|---|---|---|
| Q1 focus-clock mirror | **No real org clock.** A single key clocks in/out by writing `CLOCK:` lines to the task LOGBOOK, readable as a clocktable. | E16/E17 |
| Q2 idle handling | **Idle is an explicit task**, whose time is subtracted from overlapping tasks. | E17 |
| Q3 role vs task | **One Claude per task**; if a task needs another role, split it into a **sub-task** with its own session/pane/clock (finer granularity). | E4/E16 |
| Q4 DONE-gate offline | Gate is **mandatory**; if the worktree isn't a git repo, git steps (commit/push/pull) are **voided**; review + self-review + memory still required. | E6 |
| Q5 client bridge | **Email.** | E18 |
| Q6 memory distill | **Per-DONE.** | E8 |
| Q7 parallel ceiling | **8 panes.** Two machine classes (yours + client); all tasks visible on your Mac but **client state is read-only there**. | E16/E18 |
| Q8 client editability | **Client state editable only at the client**; new-task add + client-idle clock allowed from Mac/iPhone. | E18 |
| Mobile | **organice + Dropbox** (was beorg/iCloud). | E19 |

### Micro-forks — all resolved

- **MF1 — Clock-out behavior:** ✅ **Kill the Claude process on clock-out**; re-clock spawns a fresh `claude --resume <id>` from the stored session-id. Zero idle RAM; ~seconds' reload. (E16)
- **MF2 — Idle subtraction timing:** ✅ **Compute net at report time** + write an audit `:IDLE_ADJ:` note. Raw `CLOCK:` lines stay untouched; overlap remains visible and reversible. (E17)
- **MF3 — `C-x 0` rebind:** ✅ **Rebind to `eda/grid-restore`** as requested; stock `delete-window` → `SPC w d`. (E15)

---

## 8. Reversible phased rollout (continues your Phase 0–7 style)

Each phase ends in a working Emacs + a revert-able commit. **Contract preserved:** all existing `SPC k`, `SPC k w`, `SPC k d`, `SPC c e`, elfeed/org/forge/slime behavior untouched; new work under `SPC k t`, `SPC k r`, `SPC k g`.

- **Phase 8 — Kernel & engine (no Claude coupling yet).** `eda-portable.el` (L0), E1 schema + migration of `project.org`, `eda-task-engine.el` skeleton with `eda/task-jump`. Test: jump works; nothing else changes. *Revert-safe.*
- **Phase 9 — Session binding.** E4: resume-by-property, log-writing on state change, intent injection. Wire `org-after-todo-state-change-hook` (start only, no gate). Test: TODO→IN-PROGRESS spawns/resumes correct session; LOGBOOK gets resume comment.
- **Phase 10 — Parallel clocks + idle.** E3 `eda-pclock.el` + mode-line indicator + **E17** Idle task & subtraction. Test: two active tasks both accrue; `v c` shows overlap; idle span deducts from both.
- **Phase 11 — Grids & buffers.** E5/**E16** `eda-grid.el` (clock-ordered, auto-relayout, single-key clock) + `winum`/`ace-window` keys + **E15** `C-x 1`/`C-x 0` + **E13** worktree-follows-focus + **E14** task-annotated buffer names. Test: 1×2/2×2/2×3/2×4 build, switch, and relayout on clock in/out; `SPC p f` opens in the focused task's worktree.
- **Phase 12 — DONE-gate.** E6 4-check ritual + auto-close. Test: dirty worktree blocks DONE; clean+reviewed+memory passes and kills session.
- **Phase 13 — Memory.** E8 two stores + `CLAUDE.md` import generation + capture. Test: personal lesson syncs, client lesson stays local.
- **Phase 14 — Sync spine.** E7/**E18** `eda-sync.el` email bridge (Mac↔client, asymmetric permissions: client read-only on Mac, add-task + client-idle queued) + **E19** organice/Dropbox mobile. Test: add a client task + clock client-idle on Mac → emailed delta imports & union-merges on client; edit `personal.org` in organice → appears on Mac; client work-task edit is blocked on Mac.
- **Phase 15 — Reporting.** E10 weekly + per-tag + per-client + batch job.
- **Phase 16 — Portability hardening.** chezmoi templating, dry-run boot on a Linux VM emulating the restricted client; graceful-degradation audit.
- **Phase 17 (optional) — MCP power-up.** E12 behind a flag.

---

## 9. File manifest

**New (`~/.config/doom/`):** `eda-portable.el`, `eda-task-engine.el`, `eda-pclock.el`, `eda-grid.el`, `eda-done-gate.el`, `eda-sync.el`, `eda-memory.el`, `eda-report.el`.
**Changed:** `config.el` (org-clock config, hooks, `SPC k t/r/g` keymaps), `eda-workspace-claude.el` (resume-by-property, log-writing, context injection, stop-JSONL-scraping), `eda-tasks.el` (E1 schema in template + client capture), `packages.el` (`winum`, `ace-window`, `clocktable-by-tag`; optional `org-mru-clock`, `claude-code-ide`).
**New dirs:** `~/.claude/memory/personal/`, `~/.claude/memory/clients/<client>/` (client machine only), `~/org/clients/<client>/tasks.org`, `~/org/reports/`.
**Distribution:** chezmoi source for `~/.config/doom` with OS/host templating; `.eda-local.el` git-ignored.

---

## 10. Risks & fragilities register

| Risk | Mitigation |
|---|---|
| Native org = 1 clock (can't do parallel) | E3 writes `CLOCK:` lines directly; don't rely on live clock for reporting |
| `claude-code.el` send uses private `--` fns | Already in use & stable in practice; pin package version; wrap in one adapter fn |
| JSONL transcript format unstable | Stop scraping it; use preset `--session-id` + `--output-format json` |
| iCloud/beorg last-writer-wins data loss | Tiny files, single-writer discipline, `.bak` on load, union-merge on client import |
| Restricted client: no net for `claude -p` review | DONE-gate step 3 waiver-with-log fallback (open Q4) |
| vterm reflow garbles TUI in narrow panes | Keep panes ≥80 cols; prefer 1+3; vterm/ghostel over eat |
| `claude-code-ide.el` MCP early/buggy | Optional Phase 17, flag-gated, never load-bearing |
| Client memory leaking off-box | Import line gated by machine profile; client store never in any synced path |

---

## 11. Next steps

1. You answer the **8 open questions** above (§7) — especially Q1 (focus-clock), Q5 (client drop medium), Q8 (client titles on iCloud).
2. I turn this into Phase 8 code: `eda-portable.el` + E1 schema + `eda/task-jump` — small, revert-safe, immediately useful.
3. We iterate phase by phase, each a working commit.

Bhai — this is the killer combination: **org as the cockpit, Claude as the crew, effort tracked honestly across parallel work, delivery gated by a real review ritual, memory that compounds, and one config that boots on both your Mac and the client's locked-down Linux.** Let's build it. 🚀
