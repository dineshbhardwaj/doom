# EDA IDE — Daily Flow (Emacs + Claude + org)

Your everyday handbook for working in the Phase-8+ task engine: **org is the
kernel, Claude is the worker, the worktree is where code lands, and the weekly
report falls out for free.**

> All keys below are **verified against the live config**. `SPC` is the Doom
> leader. Every task command lives under **`SPC k o`** ("org task engine");
> client-sync lives under **`SPC k y`**.

---

## 1. The mental model (read once)

Four ideas the whole system rests on:

1. **The org heading IS the task.** One heading = one worktree = one persp =
   one Claude session. You never manage sessions by hand — you act on the
   heading and everything follows.
2. **One command to get anywhere:** `SPC k o j` (jump). It switches to the
   task's worktree perspective and raises/resumes its Claude session. This is
   your single point of contact.
3. **Effort clock ≠ org clock.** You can clock *multiple* tasks at once
   (parallel work), each earns full time, and idle overlap is subtracted only
   at report time — your raw `CLOCK:` lines are never mutated.
4. **Sessions are deterministic.** Each task stores its own
   `:CLAUDE_SESSION:` id, so Claude is always reattached by that stamped id —
   `--resume` when a transcript already exists, else created under the same id
   with `--session-id` (which then persists it) — never scraped from unstable
   log files. Kill Emacs, come back, resume exactly where you were.

---

## 2. The lifecycle of a task

```
TODO ──▶ STRT ──▶ REVIEW ──▶ DONE
 │        │         │          ▲
 │        │         │          └── passes the 4-check DONE gate
 │        │         └── work finished; Claude session STAYS LIVE so you can review
 │        └── you're actively working; Claude AUTO-STARTS on this transition
 └── captured, not started yet
```

Full keyword set (Doom stock + our `REVIEW`):
`TODO · PROJ · LOOP · STRT · WAIT · HOLD · IDEA · REVIEW | DONE · KILL`

- **`STRT`** = "started/working" → autostarts the Claude session for EDA tasks.
- **`REVIEW`** = "done working, awaiting the gate" → session **stays alive** so
  `SPC k o j` lands you on running Claude for the review conversation.
- **`DONE`** is only reachable through the gate (§6). A vetoed gate drops you
  back to `REVIEW`.

Cycle a keyword with `SPC m t` (or `t` in the agenda / `S-<left/right>` on the
heading).

---

## 3. Your screen — the grid

The window grid auto-rebuilds on every clock in/out. The front slots are fixed;
**elfeed is optional** and can be toggled out to make room for more Claude panes:

| Slot | Contents (elfeed **on**, default) | Contents (elfeed **off**) |
|------|-----------------------------------|---------------------------|
| 0 | Org **weekly agenda** | Org **weekly agenda** |
| 1 | **elfeed** search list | first **Claude pane** |
| 2 | **elfeed** article | Claude pane |
| 3+ | one **Claude pane per clocked task**, in clock order | Claude panes … |

- **elfeed on** (default): 3 front slots → Claude panes cap at **5**.
- **elfeed off** (`SPC k o e`): 1 front slot → Claude panes cap at **7**, for
  more parallel sessions. The grid **reflows automatically** to the new count.

Layout scales with front-slots + clocked tasks, capped at 8 windows. With elfeed
on: 0→1×3, 1→2×2, 2–3→2×3, 4+→2×4.

| Key | Action |
|-----|--------|
| `SPC k o g` | Rebuild / restore the grid on demand |
| `SPC k o e` | **Toggle elfeed in/out of the grid** (reflows; 5↔7 Claude panes) |
| `C-x 1` | Zoom current pane (suspends auto-relayout) |
| `C-x 0` | Restore the grid |
| `M-o` | Jump to a window (ace-window) |
| `s-1` … `s-9` | Jump straight to window N (winum) |

> The grid also renders itself automatically on the first frame of a fresh
> Emacs. If it ever looks collapsed, `SPC k o g` rebuilds it. A `C-x 1` zoom no
> longer strands the grid — the next clock in/out (or `SPC k o g`) rebuilds it
> cleanly even though the zoomed pane was dedicated to a Claude buffer.

**Mode line — what's clocked.** The mode line names your clocked tasks, so you
always know what's running without opening the agenda:
`⏱×2 1.trying something 2.killer emacs` — numbered in clock order, each shown as
its first couple of words (up to 4 tasks, then a `+N` tail). While you're on a
break the idle clock takes over the display — `⏸ Idle · personal (⏱×2 held)` —
and clearing idle (`SPC k o z` again) brings the task list back. Hover for the
full titles. Tune with `eda/pclock-mode-line-words` and
`eda/pclock-mode-line-max-tasks`.

---

## 4. A day in the life

### ☀️ Morning — orient
1. Start Emacs (or attach: `emacsclient -nw`). The grid comes up with your
   agenda in slot 0.
2. Skim the **agenda** (slot 0). Pick what you'll work on.
3. Optional health check: **`SPC k o P`** (doctor) — confirms profile, roots,
   tools, and which features are active on this machine.

### 🛠️ Start a task
1. **First time on a heading?** Stamp the schema: **`SPC k o i`** (init) — adds
   the worktree/role/client/session properties. Every prompt **autofills a
   sensible default** (the current value, else the last one you used) and offers
   **completion** over your history *plus the worktrees that exist on disk* — so
   past values are one `TAB` away and `RET` accepts the default. In a hurry?
   **`SPC k o I`** (quick) asks only for the slug and reuses everything else.
   If the worktree directory doesn't exist yet, init **offers to create it** —
   as a proper **git worktree** (pick a repo + branch; an existing branch is
   checked out, otherwise a new one is cut off your base ref) or a **plain
   directory**. You can also do it any time on a task with **`SPC k o w`**. If a
   task ends up pointing at the *wrong* workdir (e.g. it was clocked before the
   properties were stamped, so the grid can't find/resume its session), repair it
   with **`SPC k o W`** (`eda/task-set-worktree`) — it rewrites `:WORKTREE:` /
   `:TASK_SLUG:`, fixes the live clock's workspace, and relayouts.
2. Mark it **`STRT`** → Claude **auto-starts** for the task. (Or start it
   explicitly without changing state: **`SPC k o s`**.)
3. **Clock in for effort tracking:** **`SPC k o c`** — starts the effort timer,
   ensures the session, and **rebuilds the default grid so this task gets its own
   Claude window**. This always fires on clock-in, even if you'd zoomed a pane
   with `C-x 1` (the zoom-suspend is cleared).
4. Work: talk to Claude in its pane; edit code in the worktree. `SPC p f` finds
   files **scoped to the focused pane's worktree** automatically.

> `SPC k o s` (start) vs `SPC k o c` (clock-in): **start** just brings the
> session up; **clock-in** does that *and* starts counting your time. For real
> work, clock in — that's what feeds the report.

### 🔀 Work several tasks in parallel
- Clock in a second (third…) heading with **`SPC k o c`**. Overlapping clocks
  are allowed — **each task earns its full time**. The grid relayouts
  automatically.
- Move between them: **`SPC k o j`** (jump by task) or **`M-o` / `s-N`** (jump
  by window).
- Focus one thing: **`C-x 1`** to zoom, **`C-x 0`** to bring the grid back.
- See what's running: **`SPC k o l`** (list active clocks).

### ☕ Breaks / interruptions
- Stepping away? **`SPC k o z`** starts the per-environment **Idle** clock
  (`Idle · personal`, `Idle · client-<x>`). It's a **toggle** — **press
  `SPC k o z` again when you're back to end idle**. On the way out it drops a
  non-destructive `IDLE_ADJ ▶ overlapped …` note onto every task that was
  clocked, and idle time that overlaps your task clocks is **subtracted at
  report time** (net math), non-destructively.
- Other ways idle ends: **`SPC k o 0`** (clock out all) stops it along with
  everything else, and in the agenda **`z`** toggles it too.

### ✅ Finish a task
1. Move it to **`REVIEW`** when the work is done. The session stays live, so
   `SPC k o j` lands you on running Claude for a final review chat.
2. Run the gate: **`SPC k o d`** (done). See §6 — it checks commit + review +
   Claude self-review + memory before it will set `DONE`.
3. Don't want to hand-write the memory note? **`SPC k o m`** — Claude distills
   the lesson from the heading + diff and files it for you.
4. On pass: state → `DONE`, the session is killed, and the transcript is
   committed. On veto: you're back at `REVIEW` to fix what it flagged.

### 🌙 End of day
- **`SPC k o 0`** clocks out **everything** (and kills those sessions), or clock
  out one at a time with **`SPC k o C`**.
- Anything left in `STRT`/`REVIEW` is simply tomorrow's starting point.

### 📅 End of week — the report
- **`SPC k o r`** → writes `reports/weekly-<isoweek>.org` and opens it.

---

## 5. Keybinding cheat-sheet

### `SPC k o` — org task engine
| Key | Command | What it does |
|-----|---------|--------------|
| `i` | `eda/task-init` | Stamp the task schema (prompts autofill + remember past values) |
| `I` | `eda/task-init-quick` | Fast stamp: asks only for the slug, reuses the rest |
| `s` | `eda/task-start` | Start/raise the Claude session (idempotent) |
| `j` | `eda/task-jump` | **Go to task**: worktree persp + raise/resume Claude |
| `w` | `eda/task-create-worktree` | Create the worktree dir (git worktree or plain dir) |
| `y` | `eda/task-copy-resume` | Copy the `claude --resume …` command |
| `t` | `eda/task-view-transcript` | Open the conversation in a scrollable buffer (also `C-c t` inside the vterm) |
| `c` | `eda/task-clock-in` | Start effort clock (+ session + timer) + rebuild grid |
| `C` | `eda/task-clock-out` | Stop clock, write `CLOCK:` line, kill session |
| `z` | `eda/pclock-idle-toggle` | Toggle the Idle clock — once to start, **again to end** (logs overlap on active tasks) |
| `l` | `eda/pclock-list` | List active (overlapping) clocks |
| `0` | `eda/pclock-out-all` | Clock out everything |
| `d` | `eda/task-done` | Run the **DONE gate** |
| `m` | `eda/mem-distill-for-task` | Have Claude distill a memory entry |
| `r` | `eda/report-weekly` | Generate this week's report |
| `g` | `eda/grid-refresh` | Rebuild the window grid |
| `e` | `eda/grid-toggle-elfeed` | Toggle elfeed in/out of the grid (5↔7 Claude panes) |
| `W` | `eda/task-set-worktree` | Set/repair a task's worktree by hand + relayout |
| `R` | `eda/pclock-resync-workspaces` | Re-derive `:ws` for clocks whose workdir went missing |
| `P` | `eda/portable-doctor` | Environment / degradation audit |
| `?` | `eda/portable-describe` | Show profile + roots |
| `M` | `eda/mcp-toggle` | Toggle the optional MCP bridge |

### `SPC k y` — client sync
| Key | Command | What it does |
|-----|---------|--------------|
| `a` | `eda/client-add-task` | Add a client task (queued to outbox off-client) |
| `i` | `eda/client-idle-clock` | Log client idle (queued) |
| `e` | `eda/client-sync-export` | Export (full on client / delta on Mac) + email |
| `m` | `eda/client-sync-import` | Import (union-merge on client / mirror on Mac) |

### In the agenda
| Key | Action |
|-----|--------|
| `I` / `O` | Clock in / out the task at point |
| `z` | Toggle idle |
| `g j` | Jump to the task |

---

## 6. The DONE gate (`SPC k o d`)

`DONE` is earned, not typed. The gate runs **four checks in order** and advances
a `:DELIVERY:` marker (`pending → committed → reviewed → memory → done`):

1. **Committed** — worktree is clean (`git status` porcelain). Dirty? It offers
   to auto-commit. *Not a git repo? → this check is VOIDED (N/A).*
2. **Review prompt** — three quick questions (delivered? / tested? /
   follow-ups?) logged into the `LOGBOOK`.
3. **Claude self-review** — `claude -p` reviews your branch diff; you accept or
   veto. If Claude is unavailable, you can waive-with-log.
4. **Memory** — a non-trivial memory entry must exist in the task's
   `:MEM_SCOPE:` store. Missing? It offers to distill one (or writes a stub and
   sends you to fill it) — and **fails the gate** so a human reviews memory
   before `DONE`.

On all-pass: session killed, transcript committed as a git-checkable delivery,
`:DELIVERY: done`, state → `DONE`. Any veto → state resets to `REVIEW`.

---

## 7. The weekly report (`SPC k o r`)

Writes `reports/weekly-<isoweek>.org` for the current ISO week (Mon 00:00
onward). Everything is computed in elisp, so the numbers are exact and testable.

What's in it:
- **Collective time** — gross, idle-overlap, and **net** (gross − idle∩task).
- **By tag** — net time per tag (billable, project, etc.).
- **By client** — net time per client.
- **By task** — net time per task, sorted high→low.
- **Delivered digest** — every task marked `DONE` this week, with its review
  line.

Idle math is **non-destructive**: raw `CLOCK:` lines stay intact; overlap is
merged and subtracted only in the report. `v c` in the agenda still audits raw
overlap.

**Headless / cron:** `eda/report-weekly-batch` runs the same thing from
launchd/cron with no frame.

---

## 8. Client machine + mobile (only if you use them)

- **Client** = an isolated Linux box running its *own* Emacs + Claude. You never
  SSH into it from the Mac. It's bridged by **email + Dropbox**, not a live
  connection.
- **Asymmetric permissions:** on the Mac, client `tasks.org` is **read-only**.
  You *can* add client tasks (`SPC k y a`) and log client idle (`SPC k y i`)
  from the Mac/iPhone — those get **queued to an outbox**, not written directly.
- **Sync:** `SPC k y e` exports (full state on the client, a delta from the Mac)
  to the Dropbox drop dir + email; `SPC k y m` imports (union-merge on the
  client, mirror-replace on the Mac). Re-importing never duplicates.
- **Mobile** = **organice + Dropbox** over `personal.org` + the append-only
  outbox. Folder sync only — no extra tooling.

---

## 9. Memory — two isolated stores

- **Personal** (`~/.claude/memory/personal/`) — syncs everywhere.
- **Client** (`~/.claude/memory/clients/<x>/`) — lives on the client box
  **only**, never synced off it.

A task's `:MEM_SCOPE:` property picks the store; the personal Mac never imports
client memory. Entries are distilled per-DONE (auto via the gate, or on demand
with `SPC k o m`), and each task's `CLAUDE.md` `@`-imports the right INDEX so
Claude always has the machine-appropriate context.

---

## 10. If something looks off

| Symptom | Try |
|---------|-----|
| Grid collapsed to one window | `SPC k o g` to rebuild |
| Grid reports **"no session for …"** / a clocked task shows an empty `*scratch*` pane | Its workspace mis-resolved (usually clocked before `:WORKTREE:`/`:TASK_SLUG:` were stamped). Set the workdir by hand with **`SPC k o W`**; or if the org entry is already fixed and only the clock is stale, **`SPC k o R`** re-derives `:ws` for clocks whose dir is missing. |
| Want more Claude panes at once | **`SPC k o e`** toggles elfeed out of the grid — Claude cap goes 5 → 7 and the layout reflows |
| Claude didn't start on `STRT` | Confirm it's an EDA task (under the worktree root); `SPC k o s` to start manually |
| "Which machine am I on / what's missing?" | `SPC k o P` (doctor) — lists profile, roots, tools, disabled features |
| Lost the resume command | `SPC k o y` copies `claude --resume …` |
| `STRT`/clock-in opens a **fresh, empty** Claude — old conversation not resumed | Resume needs the transcript `~/.claude/projects/<flat-cwd>/<sid>.jsonl`; if it's missing, the spawn correctly falls back to a new session. Check `ls ~/.claude/projects/-Users-dinesh-eda-wt-<slug>/*.jsonl` — **empty for a task that has run** means transcripts aren't persisting. Usual cause: **Emacs was launched from *inside* a Claude session**, so `CLAUDECODE` / `CLAUDE_CODE_CHILD_SESSION` leaked into the spawned CLI and marked it a *child* session — and children never write a resumable transcript. `eda/ws-claude--spawn` now scrubs those vars; reload `eda-workspace-claude.el` and the **next** spawn persists. The current buffer can't be back-filled — the fix applies going forward. |
| Time looks wrong in the report | Check idle overlap; raw `CLOCK:` lines are in each task's `LOGBOOK`, `v c` audits overlap |
| Can't scroll up in a Claude pane | Claude runs on the terminal **alternate screen** (no scrollback) — the live pane and `C-\` copy-mode can't scroll back. Open the conversation in a normal, scrollable buffer: **`C-c t`** from *inside* the Claude vterm (the `SPC` leader is typed into Claude there, so `SPC k o t` only works from another window; `M-x eda/task-view-transcript` works anywhere). For a task-started Claude it auto-finds the session; for a plain `claude` vterm it shows a **picker** — choose yours by *time · project · title* (`C-u` always shows the picker). `g` refreshes, `q` buries. |

---

### TL;DR — the 6 keys you'll use every day
`SPC k o c` clock in · `SPC k o j` jump · `SPC k o z` idle · `SPC k o d` done ·
`SPC k o r` weekly report · `SPC k o 0` clock out all.
