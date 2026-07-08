#!/usr/bin/env python3
"""EDA Claude transcript snapshot hook (M3).

Claude 2.1.x keeps the live interactive transcript in memory and only flushes
`<sid>.jsonl` on session exit (verified: `transcript_path` is not readable even
at `Stop` time). So we cannot rely on that file mid-session. Instead we build a
stable, worktree-local markdown transcript incrementally from the hook payloads
themselves, and finalize it from the complete jsonl at session end:

    <cwd>/.claude/sessions/<role>.transcript.md

Dispatched by `hook_event_name`:
  * UserPromptSubmit -> append the user's prompt          (payload: prompt)
  * Stop            -> append Claude's reply              (payload: last_assistant_message)
  * SessionEnd / PreCompact -> re-render the COMPLETE transcript from the now-
                    materialized jsonl (full fidelity incl. tool calls), if readable.

Role is resolved by matching session_id against the `<role>.session-id` files
the Emacs task engine writes. No-op outside an EDA worktree (safe globally).
Best-effort: never raises, always exits 0.
"""
import sys, json, os, glob, datetime

SUFFIX_SID = ".session-id"
SKIP_THINKING = True
DEBUG = False  # writes .transcript-hook.log; flip on to debug payloads


# ---- rendering the full jsonl (SessionEnd finalize path) -------------------

def content_to_text(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for b in content:
        if not isinstance(b, dict):
            continue
        bt = b.get("type")
        if bt == "text":
            parts.append(b.get("text", ""))
        elif bt == "thinking":
            if not SKIP_THINKING:
                parts.append("  💭 " + (b.get("thinking", "") or "").replace("\n", "\n  "))
        elif bt == "tool_use":
            inp = " ".join(str(b.get("input", "")).split())
            parts.append("  ⚙ %s  %s" % (b.get("name", ""), inp[:100]))
        elif bt == "tool_result":
            sub = " ".join(content_to_text(b.get("content")).split())
            parts.append("  ↳ " + sub[:120])
    return "\n".join(p for p in parts if p)


def short_ts(ts):
    if isinstance(ts, str) and len(ts) >= 16:
        return ts[:10] + " " + ts[11:16]
    return ts or ""


def render_full(jsonl_path, cwd, role, sid):
    out = []
    with open(jsonl_path, encoding="utf-8", errors="replace") as fh:
        for ln in fh:
            if '"type"' not in ln:
                continue
            try:
                o = json.loads(ln)
            except Exception:
                continue
            t = o.get("type")
            if t not in ("user", "assistant"):
                continue
            text = content_to_text((o.get("message") or {}).get("content")).strip()
            if not text:
                continue
            who = "▶ You" if t == "user" else "● Claude"
            out.append("\n\n## %s  %s\n%s" % (who, short_ts(o.get("timestamp")), text))
    header = "# %s · %s\n# %s\n" % (role, cwd, sid)
    return header + ("".join(out) if out else "\n(no messages yet)\n") + "\n"


# ---- helpers ----------------------------------------------------------------

def resolve_role(sessions_dir, sid):
    for f in glob.glob(os.path.join(sessions_dir, "*" + SUFFIX_SID)):
        try:
            with open(f, encoding="utf-8") as fh:
                if fh.read().strip() == sid:
                    return os.path.basename(f)[:-len(SUFFIX_SID)]
        except Exception:
            pass
    return None


def ensure_header(path, cwd, role, sid):
    if not os.path.exists(path):
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("# %s · %s\n# %s\n" % (role, cwd, sid))
        except Exception:
            pass


def append_block(path, who, ts, text):
    text = (text or "").strip()
    if not text:
        return
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("\n\n## %s  %s\n%s\n" % (who, ts, text))
    except Exception:
        pass


def atomic_write(path, data):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except Exception:
            pass


# ---- main -------------------------------------------------------------------

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    event = data.get("hook_event_name") or ""
    sid = data.get("session_id", "") or ""
    cwd = data.get("cwd") or os.getcwd()
    sessions_dir = os.path.join(cwd, ".claude", "sessions")
    if not os.path.isdir(sessions_dir):
        return  # not an EDA worktree

    role = resolve_role(sessions_dir, sid) or "session"
    out_path = os.path.join(sessions_dir, role + ".transcript.md")
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

    if DEBUG:
        tp = data.get("transcript_path") or ""
        try:
            with open(os.path.join(sessions_dir, ".transcript-hook.log"), "a", encoding="utf-8") as fh:
                fh.write("%s event=%s role=%s sid=%s keys=%s tp_readable=%s\n" % (
                    datetime.datetime.now().isoformat(timespec="seconds"),
                    event, role, sid[:8], ",".join(sorted(data.keys())),
                    bool(tp) and os.path.isfile(tp)))
        except Exception:
            pass

    if event == "UserPromptSubmit":
        ensure_header(out_path, cwd, role, sid)
        append_block(out_path, "▶ You", now, data.get("prompt"))

    elif event == "Stop":
        ensure_header(out_path, cwd, role, sid)
        msg = data.get("last_assistant_message")
        if not isinstance(msg, str):
            msg = content_to_text(msg) if isinstance(msg, list) else (str(msg) if msg else "")
        append_block(out_path, "● Claude", now, msg)

    elif event in ("SessionEnd", "PreCompact"):
        tp = data.get("transcript_path") or ""
        if tp and os.path.isfile(tp):
            try:
                atomic_write(out_path, render_full(tp, cwd, role, sid))
            except Exception:
                pass


if __name__ == "__main__":
    main()
