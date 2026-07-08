;;; ~/.config/doom/eda-workspace-claude.el  -*- lexical-binding: t; -*-
;;;
;;; Per-workspace Claude sessions, role-specialised.
;;;
;;; Concept:
;;;   Each Doom workspace (persp = one task = one worktree) can host
;;;   multiple Claude sessions. Each session is bound to a ROLE drawn from
;;;   `eda/ws-claude-roles' — architect, rtl-review, verification,
;;;   integration, debug — and uses the matching sub-agent template from
;;;   ~/.config/doom/agent-templates/<role>-agent.md.
;;;
;;; Workspace-name → worktree path is derived as:
;;;   ~/eda/wt/<workspace-name>/
;;;
;;; Session identity & persistence (per workspace + role):
;;;   Every session id is *chosen by Emacs* (a fresh v4 UUID) and passed to
;;;   the CLI as `claude --session-id <uuid>'. The id is appended to
;;;     <worktree>/.claude/sessions/<role>.history   (one "<uuid>\t<time>" line)
;;;   the instant the session spawns — so it is durable even if Emacs is
;;;   force-killed by an OS restart or crash (no reliance on kill-emacs-hook).
;;;   A best-effort human-readable transcript is still dumped on snapshot to
;;;     <worktree>/.claude/sessions/<role>.md
;;;   and the most-recent id is mirrored to <role>.session-id for resume-all.
;;;
;;; Resume:
;;;   `eda/ws-claude-new' (SPC k w n) prompts for a ROLE, then offers a
;;;   picker listing every older session recorded for that role in this
;;;   workspace (labelled "<time> · <auto-title>"), plus a "New session"
;;;   entry. Choosing an old session resumes it in place via
;;;   `claude --resume <uuid>' (same id, conversation continues).
;;;   `eda/ws-claude-resume-all' resumes the most-recent session per role.

(require 'cl-lib)
(require 'persp-mode nil 'noerror)

;; --- Config ----------------------------------------------------------------

(defvar eda/ws-claude-roles
  '(architect rtl-review verification integration debug)
  "Roles available for workspace-bound Claude sessions.
Each role must have a matching <role>-agent.md in
`eda/agent-template-dir' (from eda-claude.el).")

(defvar eda/ws-claude-worktree-root
  (expand-file-name "~/eda/wt/")
  "Where each workspace name resolves to a worktree on disk.")

(defvar eda/ws-claudes (make-hash-table :test 'equal)
  "Hash table: workspace-name → alist ((ROLE . BUFFER) ...).
Tracks live workspace-bound Claude sessions.")

(defvar eda/ws-claude-sids (make-hash-table :test 'equal)
  "Hash table: (WS . ROLE) → session-id of the live Claude for that pair.
Set at spawn so snapshots and kills reference the exact session, instead
of guessing by file mtime (which clobbers when several roles share one
worktree/project dir).")

;; --- Identity helpers ------------------------------------------------------

(defun eda/ws-claude--current-ws ()
  "Return the current persp's name, or nil if persp-mode is not active."
  (when (and (featurep 'persp-mode) (boundp 'persp-nil-name))
    (let ((p (and (fboundp 'get-current-persp) (get-current-persp))))
      (when p
        (let ((name (if (fboundp 'safe-persp-name)
                        (safe-persp-name p)
                      (persp-name p))))
          (and name (not (string= name persp-nil-name)) name))))))

(defun eda/ws-claude--worktree (ws)
  "Resolve workspace WS to its worktree path."
  (and ws (file-name-as-directory
           (expand-file-name ws eda/ws-claude-worktree-root))))

(defun eda/ws-claude--sessions-dir (wt)
  (expand-file-name ".claude/sessions/" wt))

(defun eda/ws-claude--sid-file (wt role)
  (expand-file-name (format "%s.session-id" role)
                    (eda/ws-claude--sessions-dir wt)))

(defun eda/ws-claude--md-file (wt role)
  (expand-file-name (format "%s.md" role)
                    (eda/ws-claude--sessions-dir wt)))

(defun eda/ws-claude--history-file (wt role)
  "Append-only per-role session index: lines of \"<uuid>\\t<time>\"."
  (expand-file-name (format "%s.history" role)
                    (eda/ws-claude--sessions-dir wt)))

(defun eda/ws-claude--read-sid (wt role)
  "Return the stored latest session-id for (WT, ROLE), or nil."
  (let ((f (eda/ws-claude--sid-file wt role)))
    (when (file-readable-p f)
      (string-trim
       (with-temp-buffer
         (insert-file-contents f)
         (buffer-string))))))

(defun eda/ws-claude--uuid ()
  "Generate a random RFC-4122 v4 UUID string for `claude --session-id'."
  (let ((s (md5 (format "%s-%s-%s-%s"
                        (random most-positive-fixnum)
                        (float-time) (emacs-pid) (recent-keys)))))
    (format "%s-%s-4%s-%s%s-%s"
            (substring s 0 8)
            (substring s 8 12)
            (substring s 13 16)
            (nth (random 4) '("8" "9" "a" "b"))
            (substring s 17 20)
            (substring s 20 32))))

;; --- Agent seeding ---------------------------------------------------------

(defun eda/ws-claude--ensure-agents (wt)
  "Copy every agent template into WT/.claude/agents/ (idempotent)."
  (let ((src-dir (expand-file-name "agent-templates/" doom-user-dir))
        (dst-dir (expand-file-name ".claude/agents/" wt)))
    (when (file-directory-p src-dir)
      (make-directory dst-dir t)
      (dolist (src (directory-files src-dir t "-agent\\.md\\'"))
        (let ((dst (expand-file-name (file-name-nondirectory src) dst-dir)))
          (unless (file-exists-p dst)
            (copy-file src dst)))))))

;; --- Session-id history & titles ------------------------------------------

(defun eda/ws-claude--flatten-dir (cwd)
  "Mirror Claude CLI's project-dir flattening of CWD.
`/Users/dinesh/eda/wt/foo' → `-Users-dinesh-eda-wt-foo'."
  (let ((abs (directory-file-name (file-truename (expand-file-name cwd)))))
    (replace-regexp-in-string "/" "-" abs)))

(defun eda/ws-claude--project-dir (wt)
  "Return the ~/.claude/projects/<flattened> dir for worktree WT."
  (expand-file-name (eda/ws-claude--flatten-dir wt)
                    (expand-file-name "~/.claude/projects/")))

(defun eda/ws-claude--latest-session-id (cwd)
  "Return the most-recently-modified Claude session id for CWD, or nil.
Reads ~/.claude/projects/<flattened-cwd>/*.jsonl.  Fallback only: the
history file is the authoritative per-role record."
  (let ((proj-dir (eda/ws-claude--project-dir cwd)))
    (when (file-directory-p proj-dir)
      (let* ((files (directory-files proj-dir t "\\.jsonl\\'"))
             (sorted (sort files
                           (lambda (a b) (file-newer-than-file-p a b)))))
        (and sorted (file-name-base (car sorted)))))))

(defun eda/ws-claude--record-session (wt role uuid)
  "Append UUID for (WT, ROLE) to the history file (de-duplicated).
Also mirrors UUID into <role>.session-id as the latest pointer.
Safe to call repeatedly; an already-recorded UUID is a no-op."
  (when (and uuid (stringp uuid) (> (length uuid) 0))
    (let* ((dir (eda/ws-claude--sessions-dir wt))
           (hist (eda/ws-claude--history-file wt role)))
      (make-directory dir t)
      (unless (and (file-readable-p hist)
                   (with-temp-buffer
                     (insert-file-contents hist)
                     (goto-char (point-min))
                     (re-search-forward
                      (concat "^" (regexp-quote uuid) "\t") nil t)))
        (with-temp-buffer
          (when (file-readable-p hist) (insert-file-contents hist))
          (goto-char (point-max))
          (insert uuid "\t" (format-time-string "%Y-%m-%d %H:%M") "\n")
          (write-region (point-min) (point-max) hist nil 'quiet)))
      (with-temp-file (eda/ws-claude--sid-file wt role)
        (insert uuid "\n")))))

(defun eda/ws-claude--history-entries (wt role)
  "Return ((UUID . TIME) ...) for ROLE in WT, newest-first, de-duplicated."
  (let ((hist (eda/ws-claude--history-file wt role))
        (seen '()) (out '()))
    (when (file-readable-p hist)
      (dolist (line (with-temp-buffer
                      (insert-file-contents hist)
                      (split-string (buffer-string) "\n" t)))
        (let* ((parts (split-string line "\t"))
               (uuid (car parts))
               (ts (or (cadr parts) "")))
          (when (and uuid (> (length uuid) 0) (not (member uuid seen)))
            (push uuid seen)
            ;; File is oldest-first; pushing yields newest-first.
            (push (cons uuid ts) out)))))
    out))

(defun eda/ws-claude--unescape (s)
  "Best-effort un-escape + flatten of a JSON string value S, truncated."
  (let ((x (or s "")))
    (setq x (replace-regexp-in-string "\\\\n" " " x))
    (setq x (replace-regexp-in-string "\\\\\"" "\"" x))
    (setq x (replace-regexp-in-string "\\\\\\\\" "\\\\" x))
    (setq x (string-trim (replace-regexp-in-string "[ \t]+" " " x)))
    (truncate-string-to-width x 64 nil nil "…")))

(defun eda/ws-claude--session-title (jsonl)
  "Extract a human label from transcript JSONL.
Prefers the most-recent auto-title (\"aiTitle\"), falls back to the last
prompt (\"lastPrompt\"); returns nil if neither is present."
  (when (file-readable-p jsonl)
    (with-temp-buffer
      (insert-file-contents jsonl)
      (or (progn
            (goto-char (point-max))
            (when (re-search-backward
                   "\"aiTitle\":\"\\(\\(?:[^\"\\\\]\\|\\\\.\\)*\\)\"" nil t)
              (eda/ws-claude--unescape (match-string 1))))
          (progn
            (goto-char (point-max))
            (when (re-search-backward
                   "\"lastPrompt\":\"\\(\\(?:[^\"\\\\]\\|\\\\.\\)*\\)\"" nil t)
              (eda/ws-claude--unescape (match-string 1))))))))

(defun eda/ws-claude--role-sessions (wt role)
  "Return ((LABEL . UUID) ...) newest-first for ROLE in WT.
Only sessions whose transcript still exists on disk are included."
  (let ((proj (eda/ws-claude--project-dir wt))
        (out '()))
    (dolist (e (eda/ws-claude--history-entries wt role))
      (let* ((uuid (car e))
             (ts (cdr e))
             (jsonl (expand-file-name (concat uuid ".jsonl") proj)))
        (when (file-readable-p jsonl)
          (let ((title (or (eda/ws-claude--session-title jsonl) "(untitled)")))
            (push (cons (format "%-16s · %s"
                                (if (string-empty-p ts) "????-??-?? ??:??" ts)
                                title)
                        uuid)
                  out)))))
    ;; history-entries is newest-first; pushing reversed it → nreverse back.
    (nreverse out)))

(defun eda/ws-claude--ordered-table (cands)
  "Completion table over CANDS that preserves their given order."
  (lambda (str pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action cands str pred))))

;; --- claude-code.el integration --------------------------------------------

(declare-function claude-code--start "claude-code")
(declare-function claude-code-send-command "claude-code")
(declare-function claude-code-kill "claude-code")
(declare-function claude-code--buffer-name "claude-code")

(defun eda/ws-claude--session-exists-p (wt sid)
  "Non-nil if a transcript for SID already exists under WT's Claude project dir.
This distinguishes a first launch from a resume: `claude --resume' fails when
the session was never actually created — exactly the case when the id was minted
at `eda/task-init' but the task had not been started yet. In that case we must
create the session with `--session-id SID', not try to resume a ghost."
  (and sid (stringp sid) (not (string-empty-p sid))
       (file-readable-p
        (expand-file-name (concat sid ".jsonl")
                          (eda/ws-claude--project-dir wt)))))

(defun eda/ws-claude--spawn (wt role &optional sid)
  "Spawn a claude-code instance for ROLE under worktree WT.
SID is the deterministic session id to use (a fresh v4 UUID is generated when
nil). If a transcript for SID already exists on disk we `--resume' it in place;
otherwise we create it up front with `--session-id SID'. This is the fix for a
first clock-in silently dying: the id stamped at task-init has no session yet,
so `--resume' would fail and the vterm would exit. Returns (BUFFER . SID)."
  ;; claude-code is deferred (`:after vterm' in config.el), and the private
  ;; `claude-code--start'/`claude-code--directory' we drive below are NOT
  ;; autoloaded (private `--' names carry no autoload cookie). On a fresh Emacs
  ;; (notably the Linux daemon) the library may not be loaded yet when this
  ;; runs, so the call would hit `void-function claude-code--start'. Force-load
  ;; it here so the spawn works regardless of load order / platform.
  (require 'claude-code)
  (let* ((wt-truename (file-truename wt))
         (instance-name (symbol-name role))
         (sid (or sid (eda/ws-claude--uuid)))
         (resume (eda/ws-claude--session-exists-p wt sid))
         (extra-switches (if resume
                             (list "--resume" sid)
                           (list "--session-id" sid))))
    ;; Override claude-code's directory + instance-name probes for this call.
    (cl-letf (((symbol-function 'claude-code--directory)
               (lambda () wt-truename))
              ((symbol-function 'claude-code--prompt-for-instance-name)
               (lambda (&rest _) instance-name)))
      ;; Scrub inherited child/agent markers so the spawned CLI is a proper
      ;; TOP-LEVEL session.  When Emacs itself is launched from inside a Claude
      ;; session, these vars leak in and Claude Code treats every spawned
      ;; instance as a child/agent — which never writes a resumable
      ;; `<sid>.jsonl' under ~/.claude/projects/. Result: `--resume' always
      ;; finds nothing and the self-healing spawn falls back to a fresh
      ;; `--session-id' buffer every time, and clean-exit flush has no
      ;; transcript to flush. Stripping them restores transcript persistence.
      (let ((process-environment
             (seq-remove
              (lambda (v)
                (string-match-p
                 "\\`\\(CLAUDECODE\\|CLAUDE_CODE_CHILD_SESSION\\|CLAUDE_CODE_ENTRYPOINT\\|CLAUDE_CODE_SESSION_ID\\|AI_AGENT\\)="
                 v))
              process-environment)))
        (claude-code--start nil extra-switches t nil)))
    ;; Look up the buffer claude-code just created (named per its convention).
    (let ((buf-name (format "*claude:%s:%s*"
                            (abbreviate-file-name wt-truename)
                            instance-name)))
      (cons (or (get-buffer buf-name)
                (error "Spawned Claude but cannot find buffer %s" buf-name))
            sid))))

(defun eda/ws-claude--register (ws role buf)
  "Record BUF as the Claude for (WS, ROLE) and bind it to the current persp."
  (let* ((entries (gethash ws eda/ws-claudes))
         (cleaned (cl-remove-if (lambda (e) (eq (car e) role)) entries)))
    (puthash ws (cons (cons role buf) cleaned) eda/ws-claudes))
  (when (and (featurep 'persp-mode)
             (fboundp 'persp-add-buffer)
             (fboundp 'get-current-persp)
             (get-current-persp))
    (persp-add-buffer buf)))

(defun eda/ws-claude--start (ws role &optional resume-sid)
  "Spawn (or resume) Claude for ROLE in workspace WS, register and record it.
With RESUME-SID, resume that session in place; otherwise start fresh and
seed a role-bootstrap prompt.  Returns the Claude buffer."
  (let ((wt (eda/ws-claude--worktree ws)))
    (unless (file-directory-p wt)
      (user-error "Worktree %s does not exist" wt))
    (eda/ws-claude--ensure-agents wt)
    (let* ((spawn (eda/ws-claude--spawn wt role resume-sid))
           (buf (car spawn))
           (sid (cdr spawn)))
      (eda/ws-claude--register ws role buf)
      (puthash (cons ws role) sid eda/ws-claude-sids)
      ;; Persist the id immediately — durable across hard restarts.
      (eda/ws-claude--record-session wt role sid)
      (unless resume-sid
        (with-current-buffer buf
          (claude-code-send-command
           (format
            "You are the %s for the workspace `%s` rooted at %s. Use the `%s-agent` sub-agent from .claude/agents/ for any role-specific action. Stay in role: defer cross-role work (RTL writing, verification, integration) to peer Claudes in this workspace by naming the sub-agent that should handle it."
            role ws wt role))))
      (pop-to-buffer buf)
      (message "%s Claude (%s) for workspace %s"
               (if resume-sid "Resumed" "Started") role ws)
      buf)))

;; --- Clean shutdown (transcript flush) -------------------------------------
;;
;; Claude keeps the live conversation in memory and only flushes `<sid>.jsonl'
;; when it EXITS.  Force-killing the vterm (SIGHUP/SIGKILL) therefore loses the
;; tail of the conversation, so the next `--resume' finds a stale or missing
;; transcript and opens a fresh, empty buffer.  `eda/ws-claude--graceful-exit'
;; asks Claude to quit (two C-c is its confirm-to-exit; C-d nudges an idle
;; prompt), then waits — bounded — for the process to die so the flush lands.

(defvar eda/ws-claude-exit-timeout 6
  "Seconds to wait for a Claude session to exit cleanly (flushing its
`<sid>.jsonl' transcript) before it is force-killed on clock-out / kill.")

(defun eda/ws-claude--send-ctrl (buf ch)
  "Send control-CH (CH is a letter char, e.g. ?c) into vterm BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((raw (string (- (upcase ch) ?@))))  ; ?c → \C-c (\x03), ?d → \x04
        (cond
         ((fboundp 'vterm-send-key)
          (vterm-send-key (char-to-string (downcase ch)) nil nil t))
         ((fboundp 'vterm-send-string) (vterm-send-string raw))
         ((fboundp 'term-send-raw-string) (term-send-raw-string raw)))))))

(defun eda/ws-claude--graceful-exit (buf &optional timeout)
  "Try to make the Claude in BUF exit cleanly so it flushes its transcript.
Sends the interactive quit sequence (two C-c, then a C-d nudge) — or SIGINT for
a non-vterm buffer — and waits up to TIMEOUT seconds (default
`eda/ws-claude-exit-timeout') for the process to terminate. Returns non-nil if
it exited within the window; nil means the caller should force-kill."
  (when (buffer-live-p buf)
    (let* ((proc (get-buffer-process buf))
           (limit (or timeout eda/ws-claude-exit-timeout))
           (deadline (+ (float-time) limit)))
      (if (not (and proc (process-live-p proc)))
          t                                   ; nothing running → already gone
        ;; Request quit.
        (if (with-current-buffer buf (derived-mode-p 'vterm-mode))
            (progn (eda/ws-claude--send-ctrl buf ?c)
                   (accept-process-output proc 0.2)
                   (eda/ws-claude--send-ctrl buf ?c))
          (ignore-errors (interrupt-process proc)))
        ;; Wait (bounded) for the process to die; nudge once past halfway.
        (let ((nudged nil))
          (while (and (process-live-p proc) (< (float-time) deadline))
            (accept-process-output proc 0.1)
            (sleep-for 0.05)
            (when (and (not nudged) (< (- deadline (float-time)) (/ limit 2.0)))
              (setq nudged t)
              (if (with-current-buffer buf (derived-mode-p 'vterm-mode))
                  (eda/ws-claude--send-ctrl buf ?d)   ; EOF at an empty prompt
                (ignore-errors (interrupt-process proc)))))
          (not (process-live-p proc)))))))

(defun eda/ws-claude--stop-buffer (buf)
  "Cleanly stop the Claude in BUF: graceful exit, else force-kill.
Returns non-nil if the session exited cleanly (transcript flushed)."
  (let ((exited (ignore-errors (eda/ws-claude--graceful-exit buf))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((claude-code-confirm-kill nil))
          (ignore-errors (claude-code-kill))))
      (when (buffer-live-p buf) (ignore-errors (kill-buffer buf))))
    exited))

;; --- Public commands -------------------------------------------------------

;;;###autoload
(defun eda/ws-claude-new (role)
  "Start or resume a Claude session for ROLE in the current workspace.

Prompts for ROLE, then offers a picker of every older session recorded
for that role in this workspace — labelled \"<time> · <auto-title>\" —
plus a \"New session\" entry.  Choosing an old session resumes it in
place via `claude --resume'; choosing \"New session\" starts a fresh one
seeded with the role bootstrap prompt."
  (interactive
   (list (intern (completing-read
                  "Role: "
                  (mapcar #'symbol-name eda/ws-claude-roles)
                  nil t))))
  (let* ((ws (or (eda/ws-claude--current-ws)
                 (user-error "No active workspace (persp-mode not loaded or default persp)")))
         (wt (eda/ws-claude--worktree ws)))
    (unless (file-directory-p wt)
      (user-error "Worktree %s does not exist" wt))
    (let* ((sessions (eda/ws-claude--role-sessions wt role))
           (new-label "➕  New session")
           (cands (cons new-label (mapcar #'car sessions)))
           (pick (completing-read
                  (format "%s session (%d older): " role (length sessions))
                  (eda/ws-claude--ordered-table cands) nil t nil nil new-label))
           (sid (unless (string= pick new-label)
                  (cdr (assoc pick sessions)))))
      (eda/ws-claude--start ws role sid))))

;;;###autoload
(defun eda/ws-claude-list ()
  "Show every workspace-bound Claude in a tabulated buffer."
  (interactive)
  (let ((buf (get-buffer-create "*Workspace Claudes*"))
        (rows '()))
    (maphash
     (lambda (ws entries)
       (dolist (e entries)
         (push (list (format "%s/%s" ws (car e))
                     (vector ws
                             (symbol-name (car e))
                             (if (buffer-live-p (cdr e)) "live" "dead")
                             (buffer-name (cdr e))))
               rows)))
     eda/ws-claudes)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (tabulated-list-mode)
        (setq tabulated-list-format
              [("Workspace" 24 t) ("Role" 14 t) ("State" 6 t) ("Buffer" 60 nil)])
        (setq tabulated-list-entries rows)
        (tabulated-list-init-header)
        (tabulated-list-print))
      (pop-to-buffer buf))))

;;;###autoload
(defun eda/ws-claude-switch ()
  "Pop to one of the current workspace's Claude buffers."
  (interactive)
  (let* ((ws (or (eda/ws-claude--current-ws)
                 (user-error "No active workspace")))
         (entries (gethash ws eda/ws-claudes)))
    (unless entries (user-error "No Claudes registered for workspace %s" ws))
    (let* ((choices (mapcar (lambda (e) (cons (symbol-name (car e)) (cdr e)))
                            entries))
           (pick (completing-read "Claude (role): "
                                  (mapcar #'car choices) nil t)))
      (pop-to-buffer (cdr (assoc pick choices))))))

;;;###autoload
(defun eda/ws-claude-kill ()
  "Snapshot, then kill, one of the current workspace's Claudes."
  (interactive)
  (let* ((ws (or (eda/ws-claude--current-ws)
                 (user-error "No active workspace")))
         (entries (gethash ws eda/ws-claudes)))
    (unless entries (user-error "No Claudes for workspace %s" ws))
    (let* ((role (intern (completing-read
                          "Kill which role: "
                          (mapcar (lambda (e) (symbol-name (car e))) entries)
                          nil t)))
           (buf (cdr (assoc role entries))))
      (when (buffer-live-p buf)
        (ignore-errors (eda/ws-claude--snapshot-one ws role buf))
        ;; Let Claude flush its transcript before we tear the buffer down.
        (eda/ws-claude--stop-buffer buf))
      (puthash ws (cl-remove-if (lambda (e) (eq (car e) role)) entries)
               eda/ws-claudes)
      (remhash (cons ws role) eda/ws-claude-sids)
      (message "Killed Claude %s for workspace %s" role ws))))

;;;###autoload
(defun eda/ws-claude-toggle ()
  "Toggle visibility of the current workspace's primary Claude buffer.
Primary = first registered for the workspace."
  (interactive)
  (let* ((ws (or (eda/ws-claude--current-ws)
                 (user-error "No active workspace")))
         (entries (gethash ws eda/ws-claudes)))
    (unless entries (user-error "No Claudes for workspace %s" ws))
    (let* ((buf (cdr (car entries)))
           (win (get-buffer-window buf)))
      (if win (delete-window win) (display-buffer buf)))))

;; --- Snapshot / resume -----------------------------------------------------

(defun eda/ws-claude--snapshot-one (ws role buf)
  "Write transcript + session-id files for (WS, ROLE).
The session-id is taken from the live spawn record (exact), falling back
to the stored pointer and finally to a mtime guess.  Returns the list of
files written."
  (let* ((wt (eda/ws-claude--worktree ws))
         (sessions-dir (eda/ws-claude--sessions-dir wt))
         (md (eda/ws-claude--md-file wt role))
         (sid (or (gethash (cons ws role) eda/ws-claude-sids)
                  (eda/ws-claude--read-sid wt role)
                  (eda/ws-claude--latest-session-id wt)))
         (written '()))
    (make-directory sessions-dir t)
    ;; Keep the durable id record current (no-op if already recorded).
    (when sid (eda/ws-claude--record-session wt role sid))
    (when (buffer-live-p buf)
      (with-temp-file md
        (insert (format "# %s — Claude session for workspace `%s`\n\n" role ws))
        (insert (format "*Snapshotted: %s*\n\n" (format-time-string "%Y-%m-%d %H:%M:%S")))
        (when sid (insert (format "*Session-id: `%s`*\n\n" sid)))
        (insert "---\n\n```\n")
        (insert (with-current-buffer buf
                  (buffer-substring-no-properties (point-min) (point-max))))
        (insert "\n```\n"))
      (push md written))
    written))

;;;###autoload
(defun eda/ws-claude-snapshot ()
  "Snapshot every Claude in the current workspace to .claude/sessions/."
  (interactive)
  (let* ((ws (or (eda/ws-claude--current-ws)
                 (user-error "No active workspace")))
         (entries (gethash ws eda/ws-claudes)))
    (unless entries (user-error "No Claudes to snapshot for %s" ws))
    (let ((count 0))
      (dolist (e entries)
        (when (eda/ws-claude--snapshot-one ws (car e) (cdr e))
          (cl-incf count)))
      (message "Snapshotted %d Claude(s) for %s" count ws))))

;;;###autoload
(defun eda/ws-claude-resume-all ()
  "Resume the most-recent snapshotted Claude for every role in this workspace.
For each role with recorded history, resumes its newest session in place."
  (interactive)
  (let* ((ws (or (eda/ws-claude--current-ws)
                 (user-error "No active workspace")))
         (wt (eda/ws-claude--worktree ws)))
    (unless (file-directory-p (eda/ws-claude--sessions-dir wt))
      (user-error "No sessions dir at %s" (eda/ws-claude--sessions-dir wt)))
    (let ((count 0))
      (dolist (role eda/ws-claude-roles)
        (let ((sessions (eda/ws-claude--role-sessions wt role)))
          (when sessions
            (eda/ws-claude--start ws role (cdr (car sessions)))
            (cl-incf count))))
      (message "Resumed %d Claude(s) for %s" count ws))))

;; --- Hooks -----------------------------------------------------------------

(defvar eda/ws-claude-shutdown-budget 8
  "Total seconds budgeted at Emacs shutdown to let ALL live Claude sessions
exit cleanly (flush their `<sid>.jsonl' transcripts). Sessions are asked to
quit in parallel and SHARE this budget — unlike `eda/ws-claude-exit-timeout',
which is per-session on clock-out — so shutdown is never blocked for long no
matter how many sessions are live.")

(defun eda/ws-claude--live-buffers ()
  "Return a list of (WS ROLE BUF) for every live workspace Claude buffer."
  (let (out)
    (maphash (lambda (ws entries)
               (dolist (e entries)
                 (when (buffer-live-p (cdr e))
                   (push (list ws (car e) (cdr e)) out))))
             eda/ws-claudes)
    out))

(defun eda/ws-claude--snapshot-all-on-shutdown ()
  "At Emacs shutdown: snapshot every workspace Claude, then let them all exit
cleanly IN PARALLEL so their `<sid>.jsonl' transcripts are flushed before the
processes are reaped.  Bounded by `eda/ws-claude-shutdown-budget' total, so
shutdown is never blocked for long; any session still alive at the deadline is
left for the OS to signal (its snapshot `.md' is already written).

Note: the durable session id is persisted at spawn, so resume survives even
when this hook does not run at all (e.g. an OS-forced restart)."
  (let ((live (eda/ws-claude--live-buffers)))
    ;; 1. Snapshot everything first (buffers still hold their text).
    (dolist (it live)
      (ignore-errors
        (eda/ws-claude--snapshot-one (nth 0 it) (nth 1 it) (nth 2 it))))
    ;; 2. Ask each Claude to quit — fan out, do NOT wait per-session.
    (dolist (it live)
      (let ((buf (nth 2 it)))
        (when (buffer-live-p buf)
          (ignore-errors
            (if (with-current-buffer buf (derived-mode-p 'vterm-mode))
                (progn (eda/ws-claude--send-ctrl buf ?c)
                       (eda/ws-claude--send-ctrl buf ?c))
              (let ((p (get-buffer-process buf)))
                (when (process-live-p p) (interrupt-process p))))))))
    ;; 3. Wait ONCE, up to the shared budget, for the processes to die.
    (let ((deadline (+ (float-time) eda/ws-claude-shutdown-budget))
          (nudged nil))
      (cl-flet ((any-live ()
                  (cl-some (lambda (it)
                             (let ((p (and (buffer-live-p (nth 2 it))
                                           (get-buffer-process (nth 2 it)))))
                               (and p (process-live-p p))))
                           live)))
        (while (and (< (float-time) deadline) (any-live))
          (accept-process-output nil 0.1)
          ;; Past halfway, nudge idle prompts once with C-d (EOF).
          (when (and (not nudged)
                     (< (- deadline (float-time))
                        (/ eda/ws-claude-shutdown-budget 2.0)))
            (setq nudged t)
            (dolist (it live)
              (let ((buf (nth 2 it)))
                (when (and (buffer-live-p buf)
                           (with-current-buffer buf (derived-mode-p 'vterm-mode)))
                  (ignore-errors (eda/ws-claude--send-ctrl buf ?d)))))))))))

(add-hook 'kill-emacs-hook #'eda/ws-claude--snapshot-all-on-shutdown)

;; --- Workspace → worktree default-directory -------------------------------
;;
;; persp-mode does not change `default-directory' when you switch workspaces,
;; so magit-status (SPC g g), find-file, shell, compile-mode, and friends keep
;; pointing at whatever directory the daemon was launched in. The hook below
;; sets default-directory to ~/eda/wt/<workspace-name>/ on activation, but
;; ONLY when that directory actually exists — so the default persp and any
;; workspace that isn't paired with a worktree are left untouched.

(defun eda/ws--cd-to-worktree (&rest _)
  "Set `default-directory' to the current workspace's worktree, if any.
Mapping is the same as `eda/ws-claude--worktree' (workspace-name →
~/eda/wt/<workspace-name>/). No-op if the workspace name has no matching
worktree directory."
  (let* ((ws (eda/ws-claude--current-ws))
         (wt (and ws (eda/ws-claude--worktree ws))))
    (when (and wt (file-directory-p wt))
      (setq default-directory wt)
      ;; Anchor non-file buffers so newly-opened ones (shell, compile, magit
      ;; status invoked from *scratch*, etc.) inherit the right cwd.
      (when (get-buffer "*scratch*")
        (with-current-buffer "*scratch*"
          (setq default-directory wt)))
      (when (get-buffer "*Messages*")
        (with-current-buffer "*Messages*"
          (setq default-directory wt))))))

(with-eval-after-load 'persp-mode
  (add-hook 'persp-activated-functions #'eda/ws--cd-to-worktree))

;; --- Keybindings under SPC k w * ------------------------------------------

(map! :leader
      (:prefix-map ("k w" . "workspace claudes")
       :desc "New / pick session (role)" "n" #'eda/ws-claude-new
       :desc "List all"                  "l" #'eda/ws-claude-list
       :desc "Switch (role)"             "s" #'eda/ws-claude-switch
       :desc "Kill (role)"               "k" #'eda/ws-claude-kill
       :desc "Toggle primary"            "t" #'eda/ws-claude-toggle
       :desc "Snapshot all"              "S" #'eda/ws-claude-snapshot
       :desc "Resume all from disk"      "R" #'eda/ws-claude-resume-all))

(provide 'eda-workspace-claude)
;;; eda-workspace-claude.el ends here
