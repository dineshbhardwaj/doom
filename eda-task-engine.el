;;; ~/.config/doom/eda-task-engine.el  -*- lexical-binding: t; -*-
;;;
;;; Phase 8 · Layers 1–2 — org task schema (E1) + task lifecycle entry points.
;;;
;;; Org is the kernel. A task heading carries a PROPERTIES drawer that is the
;;; portable handle for the whole system — the same properties resolve on the
;;; Mac and the client Linux box; only path/tool resolution (eda-portable.el)
;;; differs per machine.
;;;
;;;   * IN-PROGRESS Gen7 link-init FSM            :eda:pcie:acme:
;;;   :PROPERTIES:
;;;   :ID:              <org-id>
;;;   :TASK_SLUG:       pcie-gen7-link-init
;;;   :WORKTREE:        pcie-gen7-link-init   ; rel to eda/portable-worktree-root
;;;   :CLAUDE_SESSION:  <uuid>                ; preset id → deterministic resume
;;;   :CLAUDE_ROLE:     rtl-review
;;;   :CLIENT:          acme                  ; empty ⇒ personal
;;;   :CLIENT_SRC:      /path/env.sh          ; bash sourced before claude
;;;   :MEM_SCOPE:       client-acme           ; personal | client-<x>
;;;   :DELIVERY:        pending               ; pending→committed→reviewed→memory→done
;;;   :END:
;;;
;;; Phase 8 ships the schema + two commands:
;;;   `eda/task-init'  — stamp/refresh the drawer on the heading at point.
;;;   `eda/task-jump'  — the SINGLE POINT OF CONTACT: from any org/agenda line,
;;;                      switch to the task's workspace and raise (or resume)
;;;                      its Claude session.
;;; Phase 9 adds session binding (E4): `org-clock-in-hook' and
;;; `org-after-todo-state-change-hook' funnel into `eda/task-start', which
;;; resumes-by-property, writes a per-task context file the worktree CLAUDE.md
;;; imports, and logs Session/Resume lines. The DONE-gate, parallel clocks,
;;; grids and sync arrive in later phases and build on these helpers.

(require 'org)
(require 'cl-lib)

;; From eda-portable / eda-tasks / eda-workspace-claude (loaded earlier).
(defvar eda/portable-worktree-root)
(defvar eda/project-org-filename)
(defvar eda/ws-claude-roles)
(defvar eda/ws-claudes)
(declare-function eda/ws-claude--start "eda-workspace-claude")
(declare-function eda/ws-claude--uuid "eda-workspace-claude")
(declare-function eda/ws-claude--snapshot-one "eda-workspace-claude")
(declare-function eda/ws-claude--project-dir "eda-workspace-claude")
(declare-function eda/ws-claude--stop-buffer "eda-workspace-claude")
(defvar eda/ws-claude-exit-timeout)
(declare-function claude-code-kill "claude-code")
(defvar eda/ws-claude-sids)
(defvar claude-code-confirm-kill)

;; Phase 9 — session-binding config.
(defvar eda/task-active-states '("STRT" "REVIEW")
  "TODO states that auto-start/resume an entry's Claude session (E4).
Must match the keywords actually registered in `org-todo-keywords'. This
config uses Doom's stock sequence TODO/PROJ/LOOP/STRT/WAIT/HOLD/IDEA | DONE/KILL
with a REVIEW(v) keyword added (see `eda/task--register-review-keyword'). STRT
is \"work in progress\"; REVIEW is \"work done, awaiting the DONE-gate review\".
Both keep the session live so `eda/task-jump' lands on a running Claude — that
is what makes the review actually reviewable.")
(defvar eda/task-autostart-on-state-change t
  "When non-nil, entering an `eda/task-active-states' state starts the session.")
(defvar eda/task-autostart-on-clock-in t
  "When non-nil, clocking into an EDA task starts/resumes its Claude session.")

;; --- Org clock/log storage: keep notes and clocks in a LOGBOOK drawer ------

(defun eda/task--register-review-keyword ()
  "Add a REVIEW(v) keyword before the `|' in the first org todo sequence.
Idempotent, and non-destructive: it splices REVIEW into whatever sequence Doom
(or the user) already established rather than clobbering `org-todo-keywords'.
REVIEW is the resting state between STRT and DONE — the DONE-gate resets vetoed
tasks here, and the session stays live so the work can be reviewed and finished."
  (let ((seqs org-todo-keywords))
    (unless (cl-some (lambda (s)
                       (and (consp s)
                            (cl-some (lambda (k)
                                       (member (car (split-string k "(")) '("REVIEW")))
                                     (cdr s))))
                     seqs)
      (let ((first (car seqs)))
        (when (and (consp first) (eq (car first) 'sequence))
          (let* ((kws (cdr first))
                 (pos (cl-position "|" kws :test #'equal))
                 (new (if pos
                          (append (cl-subseq kws 0 pos)
                                  (list "REVIEW(v)")
                                  (cl-subseq kws pos))
                        (append kws (list "REVIEW(v)")))))
            (setcdr first new)
            (setq org-todo-keywords seqs))))))
  ;; Give REVIEW a distinct look (idempotent).
  (unless (assoc "REVIEW" org-todo-keyword-faces)
    (push '("REVIEW" . +org-todo-active) org-todo-keyword-faces)))

(with-eval-after-load 'org
  (setq org-log-into-drawer t)          ; state-change notes → :LOGBOOK:
  (setq org-clock-into-drawer "LOGBOOK") ; CLOCK: lines → :LOGBOOK: too
  ;; Register the REVIEW stage LAST so it wins over Doom's stock sequence.
  (eda/task--register-review-keyword))

;; --- Locate the org entry at point (agenda-aware) --------------------------

(defun eda/task--marker ()
  "Return a marker to the org heading at point, working in org or agenda."
  (cond
   ((derived-mode-p 'org-agenda-mode)
    (or (org-get-at-bol 'org-hd-marker)
        (org-get-at-bol 'org-marker)
        (user-error "No org entry at this agenda line")))
   ((derived-mode-p 'org-mode)
    (save-excursion (org-back-to-heading t) (point-marker)))
   (t (user-error "Not in an org-mode or org-agenda buffer"))))

;; --- Property accessors ----------------------------------------------------

(defun eda/task-prop (marker prop &optional inherit)
  "Get PROP of the entry at MARKER (INHERIT walks ancestors)."
  (org-with-point-at marker (org-entry-get nil prop inherit)))

(defun eda/task-set-prop (marker prop val)
  "Set PROP=VAL on the entry at MARKER."
  (org-with-point-at marker (org-entry-put nil prop val)))

(defun eda/task-worktree (marker)
  "Resolve the worktree directory for the task at MARKER.
Uses :WORKTREE: (absolute, or relative to `eda/portable-worktree-root'),
then :TASK_SLUG: under the root, then the directory of the org file itself."
  (let* ((wt   (eda/task-prop marker "WORKTREE" t))
         (slug (eda/task-prop marker "TASK_SLUG" t))
         (file (buffer-file-name (marker-buffer marker))))
    (cond
     ((and wt (file-name-absolute-p wt))
      (file-name-as-directory (expand-file-name wt)))
     ((and wt (not (string-empty-p wt)))
      (file-name-as-directory (expand-file-name wt eda/portable-worktree-root)))
     ((and slug (not (string-empty-p slug)))
      (file-name-as-directory (expand-file-name slug eda/portable-worktree-root)))
     (file (file-name-directory file))
     (t default-directory))))

(defun eda/task-workspace (marker)
  "Workspace/persp name for the task at MARKER (= worktree basename)."
  (file-name-nondirectory (directory-file-name (eda/task-worktree marker))))

(defun eda/task-role (marker)
  "Return the task's Claude role as a symbol, or nil."
  (let ((r (eda/task-prop marker "CLAUDE_ROLE" t)))
    (and r (not (string-empty-p r)) (intern r))))

(defun eda/task-session-id (marker)
  "Return the task's stored Claude session id, or nil."
  (let ((s (eda/task-prop marker "CLAUDE_SESSION")))
    (and s (not (string-empty-p s)) s)))

(defun eda/task-client-src (marker)
  "Return the client bash-source command for the task, or nil."
  (let ((s (eda/task-prop marker "CLIENT_SRC" t)))
    (and s (not (string-empty-p s)) s)))

;; --- LOGBOOK note writing --------------------------------------------------

(defun eda/task--logbook-prepend (line)
  "Insert LINE (no trailing newline) at the top of the entry's LOGBOOK drawer.
Creates the drawer after any planning line + PROPERTIES drawer if absent.
Point must be within the entry (call inside `org-with-point-at')."
  (save-excursion
    (org-back-to-heading t)
    (let* ((hbeg (point))
           (hend (save-excursion (outline-next-heading) (point)))
           (text (concat line "\n")))
      (goto-char hbeg)
      (if (re-search-forward "^[ \t]*:LOGBOOK:[ \t]*$" hend t)
          (progn (forward-line 1) (beginning-of-line) (insert text))
        ;; No drawer yet — build one after heading + planning + properties.
        (goto-char hbeg)
        (forward-line 1)
        (when (and (< (point) hend)
                   (looking-at-p "^[ \t]*\\(?:SCHEDULED\\|DEADLINE\\|CLOSED\\):"))
          (forward-line 1))
        (when (and (< (point) hend)
                   (looking-at-p "^[ \t]*:PROPERTIES:[ \t]*$"))
          (when (re-search-forward "^[ \t]*:END:[ \t]*$" hend t)
            (forward-line 1)))
        (beginning-of-line)
        (insert ":LOGBOOK:\n" text ":END:\n")))))

(defun eda/task--append-logbook (text)
  "Prepend a timestamped note TEXT into the LOGBOOK of the entry at point."
  (eda/task--logbook-prepend
   (format "- %s %s" (format-time-string "[%Y-%m-%d %a %H:%M]") text)))

(defun eda/task-resume-command (marker)
  "Return a copy-pasteable shell command to (re)attach the task's Claude session.
Self-healing: it resumes the stored `:CLAUDE_SESSION:' id when that session's
transcript already exists on disk, and otherwise CREATES the session under the
same id via `--session-id'.  This is the fix for the ghost-resume failure — the
id is minted at `eda/task-init' before any session has ever run, so a plain
`claude --resume <sid>' on the first launch finds nothing to attach to and drops
you into a fresh, empty conversation (a \"new buffer\").  Guarding on the
transcript path makes the first launch create the session and every later launch
truly resume it, mirroring what the in-Emacs spawn path already does."
  (let* ((wt  (eda/task-worktree marker))
         (src (eda/task-client-src marker))
         (sid (eda/task-session-id marker)))
    (when sid
      (let* ((proj  (and (fboundp 'eda/ws-claude--project-dir)
                         (eda/ws-claude--project-dir wt)))
             (jsonl (and proj (expand-file-name (concat sid ".jsonl") proj)))
             (attach
              (if jsonl
                  ;; Resume if the transcript is present, else create with the id.
                  (format "if [ -f %s ]; then claude --resume %s; else claude --session-id %s; fi"
                          (shell-quote-argument jsonl) sid sid)
                ;; project-dir helper unavailable — fall back to the old behaviour.
                (format "claude --resume %s" sid))))
        (format "(cd %s && %s%s)"
                (shell-quote-argument (directory-file-name wt))
                (if src (format "source %s && " src) "")
                attach)))))

;; --- Commands --------------------------------------------------------------

(defun eda/task--suggest-slug ()
  "Suggest a kebab-case slug from the heading at point."
  (let ((h (or (org-get-heading t t t t) "task")))
    (downcase (replace-regexp-in-string
               "\\`-\\|-\\'" ""
               (replace-regexp-in-string "[^A-Za-z0-9]+" "-" (string-trim h))))))

;; --- E1b · easier schema entry: persistent history + completion ------------
;;
;; The original `eda/task-init' prompted with bare `read-string' and no memory,
;; so every task meant re-typing the worktree path, client and source command
;; by hand — no defaults you could just accept, no picking a value you'd used
;; before. These helpers keep a small per-field history (machine-local, cache
;; dir) and offer it — plus the worktrees that actually exist on disk and the
;; known client stores — as completion. So: past values autofill as the RET
;; default, and every value you've ever entered is one TAB away.

(defvar eda/task--init-history-file
  (expand-file-name "eda/task-init-history.eld"
                    (or (bound-and-true-p doom-cache-dir) user-emacs-directory))
  "Machine-local file storing per-field entry history for `eda/task-init'.")

(defvar eda/task--init-history nil
  "Alist (FIELD . VALUES) of recent values entered in `eda/task-init'.")

(defvar eda/task--init-history-max 25
  "How many past values to remember per field.")

(defun eda/task--hist-load ()
  "Load the entry history from `eda/task--init-history-file' (best-effort)."
  (when (file-readable-p eda/task--init-history-file)
    (with-demoted-errors "eda/task history load: %S"
      (with-temp-buffer
        (insert-file-contents eda/task--init-history-file)
        (setq eda/task--init-history (read (current-buffer)))))))

(defun eda/task--hist-save ()
  "Persist the entry history (best-effort)."
  (with-demoted-errors "eda/task history save: %S"
    (make-directory (file-name-directory eda/task--init-history-file) t)
    (with-temp-file eda/task--init-history-file
      (prin1 eda/task--init-history (current-buffer)))))

(defun eda/task--hist-get (field)
  "Recent values for FIELD, newest first."
  (cdr (assq field eda/task--init-history)))

(defun eda/task--hist-add (field val)
  "Record VAL for FIELD (dedup, newest first, capped), and persist."
  (when (and (stringp val) (not (string-empty-p val)))
    (let* ((cur (delete val (copy-sequence (eda/task--hist-get field))))
           (new (seq-take (cons val cur) eda/task--init-history-max)))
      (setf (alist-get field eda/task--init-history) new)
      (eda/task--hist-save))))

(defun eda/task--last (field)
  "Newest previously-entered value for FIELD, or nil."
  (car (eda/task--hist-get field)))

(defun eda/task--known-clients ()
  "Client names known from the client-memory stores on disk."
  (let ((dir (expand-file-name "clients" eda/portable-memory-root)))
    (when (file-directory-p dir)
      (seq-filter (lambda (d) (file-directory-p (expand-file-name d dir)))
                  (seq-remove (lambda (d) (member d '("." "..")))
                              (directory-files dir))))))

(defun eda/task--worktree-dirs ()
  "Names of worktree directories that already exist under the worktree root."
  (let ((r eda/portable-worktree-root))
    (when (and r (file-directory-p r))
      (seq-filter (lambda (d) (file-directory-p (expand-file-name d r)))
                  (seq-remove (lambda (d) (member d '("." "..")))
                              (directory-files r))))))

(defun eda/task--read (prompt field &optional default extra)
  "Read a value for FIELD via completion, then record it.
DEFAULT is returned on empty input and shown in the prompt; candidates are
EXTRA (e.g. on-disk worktrees) unioned with FIELD's history. Free text is
allowed — this is not a require-match — so brand-new values are fine."
  (let* ((default (and default (not (string-empty-p default)) default))
         (cands (delete-dups (append (and default (list default))
                                     (copy-sequence extra)
                                     (copy-sequence (eda/task--hist-get field)))))
         (val (string-trim
               (completing-read
                (if default (format "%s (default %s): " prompt default)
                  (format "%s: " prompt))
                cands nil nil nil t default))))
    (eda/task--hist-add field val)
    val))

(defun eda/task--stamp (slug client role wt &optional src)
  "Write the EDA task schema at point from SLUG/CLIENT/ROLE/WT (+ optional SRC).
Reuses an existing `:CLAUDE_SESSION:' or mints a deterministic one, sets
`:MEM_SCOPE:'/`:DELIVERY:', logs a `Resume ▶' line, and returns the session id.
The single writer shared by `eda/task-init' and `eda/task-init-quick'."
  (let* ((client (string-trim (or client "")))
         (mem (if (string-empty-p client) "personal" (concat "client-" client)))
         (sid (or (let ((s (org-entry-get nil "CLAUDE_SESSION")))
                    (and s (not (string-empty-p s)) s))
                  (eda/ws-claude--uuid))))
    (org-entry-put nil "TASK_SLUG" slug)
    (org-entry-put nil "WORKTREE" wt)
    (org-entry-put nil "CLAUDE_ROLE" role)
    (org-entry-put nil "CLAUDE_SESSION" sid)
    (if (string-empty-p client)
        (org-entry-delete nil "CLIENT")
      (org-entry-put nil "CLIENT" client))
    (when (and src (not (string-empty-p src)))
      (org-entry-put nil "CLIENT_SRC" src))
    (org-entry-put nil "MEM_SCOPE" mem)
    (unless (org-entry-get nil "DELIVERY")
      (org-entry-put nil "DELIVERY" "pending"))
    (let ((cmd (eda/task-resume-command (point-marker))))
      (when cmd (eda/task--append-logbook (concat "Resume ▶ " cmd))))
    (message "Task `%s' stamped · role=%s · wt=%s · session %s" slug role wt sid)
    sid))

;; --- E1c · create the worktree directory so Claude can actually spin up -----
;;
;; Stamping only records the `:WORKTREE:'; the directory may not exist yet, and
;; `eda/task-jump'/`eda/task-start' need a real dir to run Claude in. These
;; create it on demand — either as a proper git worktree (off a repo + branch,
;; reusing the `eda/new-worktree-for-task' pattern) or as a plain directory.

(defvar eda/task-offer-worktree-create t
  "When non-nil, `eda/task-init' offers to create a missing worktree directory.")

(defun eda/task--git-worktree-add (wt)
  "Create git worktree WT (absolute) off a chosen repo + branch/ref.
The worktree basename is the branch name: an existing branch is checked out,
otherwise a new one is created off the base ref. Returns non-nil on success."
  (let* ((branch (file-name-nondirectory (directory-file-name wt)))
         (repo   (expand-file-name
                  (read-directory-name
                   "Repo (main checkout): "
                   (or (eda/task--last 'repo) eda/portable-worktree-root))))
         (exists (eq 0 (call-process "git" nil nil nil
                                     "-C" repo "rev-parse" "--verify" "--quiet"
                                     (concat "refs/heads/" branch))))
         (ref    (unless exists (eda/task--read "Base branch / ref" 'ref "main")))
         (buf    (get-buffer-create "*eda-task-worktree*"))
         (args   (append (list "-C" repo "worktree" "add")
                         (if exists
                             (list (directory-file-name wt) branch)
                           (list "-b" branch (directory-file-name wt) ref)))))
    (eda/task--hist-add 'repo repo)
    (with-current-buffer buf (goto-char (point-max))
                         (insert (format "\n$ git %s\n" (string-join args " "))))
    (let ((code (apply #'call-process "git" nil buf t args)))
      (if (eq code 0)
          (progn (message "git worktree ready at %s (branch %s%s)"
                          (abbreviate-file-name wt) branch
                          (if exists " — existing" (format " off %s" ref)))
                 t)
        (pop-to-buffer buf)
        (user-error "git worktree add failed (exit %s) — see *eda-task-worktree*"
                    code)))))

(defun eda/task--symlink-worktree (wt)
  "Create worktree WT (absolute) as a symbolic link to a real working tree.
Prompts for the target directory (e.g. a checkout on scratch) and links
WT -> TARGET, replacing any stale/self-referential link already at WT.
Returns non-nil if WT resolves to a directory afterwards."
  (let* ((target (expand-file-name
                  (read-directory-name
                   "Link target (real working tree): "
                   (or (eda/task--last 'wt-target) eda/portable-worktree-root))))
         (link   (directory-file-name wt)))
    (unless (file-directory-p target)
      (user-error "Link target does not exist: %s" (abbreviate-file-name target)))
    (make-directory (file-name-directory link) t)
    ;; Replace any stale/self-referential link already sitting at this path.
    (when (file-symlink-p link) (delete-file link))
    (make-symbolic-link (directory-file-name target) link t)
    (eda/task--hist-add 'wt-target target)
    (message "Linked %s -> %s"
             (abbreviate-file-name link) (abbreviate-file-name target))
    (file-directory-p wt)))

(defun eda/task--worktree-usable-p (wt)
  "Non-nil if WT is a real directory, or a symlink to some dir other than the
worktree root itself. A self-referential link (e.g. `vega2a -> ./') resolves to
the root and is treated as NOT usable, so it can be re-pointed."
  (let ((link (directory-file-name wt)))
    (and (file-directory-p wt)
         (or (not (file-symlink-p link))
             (not (file-equal-p (file-truename link)
                                (file-truename eda/portable-worktree-root)))))))

(defun eda/task--create-worktree-at (wt)
  "Create the worktree directory WT (absolute) if it is missing.
Offers a git worktree, a symbolic link (to a real tree elsewhere, e.g. on
scratch), or a plain directory; returns non-nil if WT is usable after."
  (if (eda/task--worktree-usable-p wt)
      (progn (message "Worktree already exists: %s" (abbreviate-file-name wt)) t)
    (pcase (completing-read
            (format "Create %s as: " (abbreviate-file-name wt))
            '("git worktree" "symbolic link" "plain directory")
            nil t nil nil "git worktree")
      ("git worktree"  (eda/task--git-worktree-add wt))
      ("symbolic link" (eda/task--symlink-worktree wt))
      (_ (make-directory wt t)
         (message "Created directory %s" (abbreviate-file-name wt))
         (file-directory-p wt)))))

;;;###autoload
(defun eda/task-create-worktree ()
  "Create the worktree directory for the task at point, if it doesn't exist.
Resolves `:WORKTREE:' the same way `eda/task-jump' does, then offers to make it
a git worktree (repo + branch) or a plain directory."
  (interactive)
  (eda/task--create-worktree-at (eda/task-worktree (eda/task--marker))))

(defun eda/task--maybe-offer-worktree ()
  "If the task at point has a missing worktree, offer to create it now."
  (when eda/task-offer-worktree-create
    (let ((wt (eda/task-worktree (point-marker))))
      (when (and (not (eda/task--worktree-usable-p wt))
                 (y-or-n-p (format "Worktree %s doesn't exist — create it now? "
                                   (abbreviate-file-name wt))))
        (eda/task--create-worktree-at wt)))))

;;;###autoload
(defun eda/task-init ()
  "Stamp (or refresh) the EDA task schema on the org heading at point.
Prompts for slug, client, role, worktree and (for client tasks) the bash
source command. Each prompt autofills a sensible default (the entry's current
value, else the last one you used) and offers completion over your history plus
the worktrees that exist on disk; generates a deterministic Claude session id;
and writes a `Resume ▶' comment into the task's LOGBOOK.

For the common case, `eda/task-init-quick' (\\[eda/task-init-quick]) asks only
for the slug and reuses everything else."
  (interactive)
  (org-with-point-at (eda/task--marker)
    (org-id-get-create)
    (let* ((slug   (eda/task--read
                    "Task slug" 'slug
                    (or (org-entry-get nil "TASK_SLUG") (eda/task--suggest-slug))))
           (client (eda/task--read
                    "Client (blank = personal)" 'client
                    (or (org-entry-get nil "CLIENT") (eda/task--last 'client))
                    (eda/task--known-clients)))
           (role   (eda/task--read
                    "Role" 'role
                    (or (org-entry-get nil "CLAUDE_ROLE")
                        (eda/task--last 'role) "architect")
                    (mapcar #'symbol-name eda/ws-claude-roles)))
           (wt     (eda/task--read
                    "Worktree (rel to root, or absolute)" 'worktree
                    (or (org-entry-get nil "WORKTREE") slug)
                    (eda/task--worktree-dirs)))
           (src    (unless (string-empty-p client)
                     (eda/task--read
                      "Client bash source (before claude)" 'src
                      (or (org-entry-get nil "CLIENT_SRC") (eda/task--last 'src))))))
      (eda/task--stamp slug client role wt src)
      (eda/task--maybe-offer-worktree))))

;;;###autoload
(defun eda/task-init-quick ()
  "Fast schema stamp: ask only for the slug, reuse everything else.
Worktree defaults to the slug, role/client to this entry's value else your
last-used one, and the source command to whatever is already set. Ideal for the
common personal task; use `eda/task-init' when you need to change a field."
  (interactive)
  (org-with-point-at (eda/task--marker)
    (org-id-get-create)
    (let* ((slug   (eda/task--read
                    "Task slug" 'slug
                    (or (org-entry-get nil "TASK_SLUG") (eda/task--suggest-slug))))
           (client (or (org-entry-get nil "CLIENT") (eda/task--last 'client) ""))
           (role   (or (org-entry-get nil "CLAUDE_ROLE")
                       (eda/task--last 'role) "architect"))
           (wt     (or (org-entry-get nil "WORKTREE") slug))
           (src    (org-entry-get nil "CLIENT_SRC")))
      (eda/task--stamp slug client role wt src)
      (message "Task `%s' quick-stamped · role=%s · wt=%s%s"
               slug role wt (if (string-empty-p client) ""
                              (format " · client=%s" client)))
      (eda/task--maybe-offer-worktree))))

;;;###autoload
(defun eda/task-jump ()
  "Single point of contact: jump to the Claude session of the task at point.
Switches to the task's workspace (persp = worktree basename), then raises its
live Claude buffer, resumes it from the stored session id, or — if no session
is bound — opens the task's project.org."
  (interactive)
  (let* ((marker (eda/task--marker))
         (wt     (eda/task-worktree marker))
         (ws     (eda/task-workspace marker))
         (role   (eda/task-role marker))
         (sid    (eda/task-session-id marker)))
    (when (and (featurep 'persp-mode) (fboundp 'persp-switch))
      (persp-switch ws))
    (when (file-directory-p wt)
      (setq default-directory wt))
    (let* ((entries (and (boundp 'eda/ws-claudes) (gethash ws eda/ws-claudes)))
           (buf     (and role (cdr (assq role entries)))))
      (cond
       ((buffer-live-p buf)
        (pop-to-buffer buf)
        (message "Jumped to %s Claude for %s" role ws))
       ((and (file-directory-p wt) (fboundp 'eda/ws-claude--start))
        (eda/ws-claude--start ws (or role 'architect) sid))
       (t
        (let ((f (expand-file-name (or (bound-and-true-p eda/project-org-filename)
                                       "project.org")
                                   wt)))
          (if (file-readable-p f) (find-file f)
            (if (file-directory-p wt) (dired wt)
              (user-error "Worktree %s does not exist yet" wt)))))))))

;;;###autoload
(defun eda/task-copy-resume ()
  "Copy the resume command for the task at point to the kill-ring."
  (interactive)
  (let ((cmd (eda/task-resume-command (eda/task--marker))))
    (if cmd (progn (kill-new cmd) (message "Copied: %s" cmd))
      (user-error "No :CLAUDE_SESSION: on this task — run `eda/task-init' first"))))

;; --- Phase 9 · session binding (E4) ---------------------------------------
;;
;; Triggers (clock-in, TODO→active) funnel into `eda/task-start', which is
;; idempotent: if the session is already live it just raises it. On a first
;; start it (re)generates the task-context file, ensures the worktree CLAUDE.md
;; imports it, logs Session/Resume lines, and resumes-by-property.

(defun eda/task--eda-entry-p ()
  "Non-nil if the org entry at point is an EDA task (has schema / lives in wt/)."
  (or (org-entry-get nil "TASK_SLUG" t)
      (org-entry-get nil "WORKTREE" t)
      (let ((f (buffer-file-name)))
        (and f (string-prefix-p (expand-file-name eda/portable-worktree-root)
                                (expand-file-name f))))))

(defun eda/task-ensure-session-id (marker)
  "Return the task's session id, generating + storing one if absent."
  (or (eda/task-session-id marker)
      (let ((sid (eda/ws-claude--uuid)))
        (eda/task-set-prop marker "CLAUDE_SESSION" sid)
        sid)))

(defun eda/task--logbook-has-p (regexp)
  "Non-nil if REGEXP occurs within the entry at point (its LOGBOOK/body)."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point))))
      (re-search-forward regexp end t))))

(defun eda/task--write-context (marker wt)
  "Write <wt>/.claude/task-context.md capturing the task's intent + notes."
  (let* ((dir   (expand-file-name ".claude/" wt))
         (file  (expand-file-name "task-context.md" dir))
         (title (org-with-point-at marker (org-get-heading t t t t)))
         (slug  (or (eda/task-prop marker "TASK_SLUG") ""))
         (role  (or (eda/task-prop marker "CLAUDE_ROLE") ""))
         (client (or (eda/task-prop marker "CLIENT") ""))
         (body  (org-with-point-at marker
                  (save-excursion
                    (org-back-to-heading t)
                    (buffer-substring-no-properties
                     (point) (save-excursion (outline-next-heading) (point)))))))
    (make-directory dir t)
    (with-temp-file file
      (insert (format "# Task context — %s\n\n" title))
      (insert (format "- Slug: %s\n- Role: %s\n" slug role))
      (unless (string-empty-p client) (insert (format "- Client: %s\n" client)))
      (insert (format "- Generated: %s\n\n" (format-time-string "%Y-%m-%d %H:%M")))
      (insert "## Intent, notes & history (from the org task)\n\n")
      (insert "```org\n" (string-trim-right body) "\n```\n"))
    file))

(defun eda/task--ensure-claude-import (wt)
  "Ensure <wt>/CLAUDE.md `@'-imports the per-task context file (idempotent)."
  (let* ((claude-md (expand-file-name "CLAUDE.md" wt))
         (line "@.claude/task-context.md")
         (existing (and (file-readable-p claude-md)
                        (with-temp-buffer (insert-file-contents claude-md)
                                          (buffer-string)))))
    (unless (and existing (string-match-p (regexp-quote line) existing))
      (with-temp-buffer
        (when existing
          (insert existing)
          (unless (string-suffix-p "\n" existing) (insert "\n")))
        (insert "\n<!-- eda-task-engine: per-task context (auto) -->\n" line "\n")
        (write-region (point-min) (point-max) claude-md nil 'quiet)))))

(defun eda/task--log-session (marker role sid)
  "Prepend Session/Resume LOGBOOK lines for (ROLE, SID) once per session id."
  (org-with-point-at marker
    ;; Key the dedup on the Session marker+id, not the bare id — the id also
    ;; appears in the :CLAUDE_SESSION: property and would false-match there.
    (unless (eda/task--logbook-has-p (concat "Session ▶.*" (regexp-quote sid)))
      (let ((cmd (eda/task-resume-command marker)))
        (when cmd (eda/task--append-logbook (concat "Resume ▶ " cmd))))
      (eda/task--append-logbook (format "Session ▶ role=%s id=%s" role sid)))))

;;;###autoload
(defun eda/task-start (&optional marker)
  "Start or resume the Claude session for the task at MARKER (or point).
Idempotent: if the session is already live, just raises it. Otherwise stores
a session id + role if missing, writes the task-context file and CLAUDE.md
import, logs Session/Resume lines, switches to the workspace, and resumes the
session by its stored id (or starts fresh)."
  (interactive)
  (setq marker (or marker (eda/task--marker)))
  (let* ((wt   (eda/task-worktree marker))
         (ws   (eda/task-workspace marker))
         (role (or (eda/task-role marker) 'architect))
         (sid  (eda/task-ensure-session-id marker))
         (entries (and (boundp 'eda/ws-claudes) (gethash ws eda/ws-claudes)))
         (buf  (cdr (assq role entries))))
    (unless (eda/task-role marker)
      (eda/task-set-prop marker "CLAUDE_ROLE" (symbol-name role)))
    (cond
     ((buffer-live-p buf)
      (when (and (featurep 'persp-mode) (fboundp 'persp-switch)) (persp-switch ws))
      (pop-to-buffer buf)
      (message "Task %s already running (%s)" ws role))
     ((not (file-directory-p wt))
      (user-error "Worktree %s does not exist yet — create it, then start" wt))
     (t
      (eda/task--write-context marker wt)
      (eda/task--ensure-claude-import wt)
      ;; E8: make the worktree CLAUDE.md @-import the memory store(s) allowed
      ;; on this machine, so the resuming Claude reads collective memory too.
      (when (fboundp 'eda/mem-ensure-imports)
        (ignore-errors
          (eda/mem-ensure-imports wt (eda/task-prop marker "MEM_SCOPE" t))))
      (eda/task--log-session marker role sid)
      (when (and (featurep 'persp-mode) (fboundp 'persp-switch)) (persp-switch ws))
      (eda/ws-claude--start ws role sid)
      (message "%s Claude (%s) for %s"
               (if (eda/task-session-id marker) "Resumed/started" "Started") role ws)))))

;;;###autoload
(defun eda/task-stop-session (ws role)
  "Snapshot, cleanly exit, then (if needed) kill the Claude for (WS, ROLE).
Returns non-nil if a live session was stopped. Used by clock-out (MF1).

The clean-exit step (`eda/ws-claude--stop-buffer') gives Claude a bounded
window to flush its `<sid>.jsonl' transcript before the vterm is torn down, so
the next clock-in can actually `--resume' the conversation instead of opening a
fresh, empty one. If Claude does not exit within `eda/ws-claude-exit-timeout'
it is force-killed and we warn that the transcript may be stale."
  (let* ((entries (and (boundp 'eda/ws-claudes) (gethash ws eda/ws-claudes)))
         (buf (cdr (assq role entries))))
    (when (buffer-live-p buf)
      (ignore-errors (eda/ws-claude--snapshot-one ws role buf))
      (let ((exited (if (fboundp 'eda/ws-claude--stop-buffer)
                        (eda/ws-claude--stop-buffer buf)
                      ;; Fallback: old hard-kill behaviour.
                      (prog1 nil
                        (when (buffer-live-p buf)
                          (with-current-buffer buf
                            (let ((claude-code-confirm-kill nil))
                              (ignore-errors (claude-code-kill)))))))))
        (unless exited
          (message "Claude (%s) didn't exit cleanly in %ss — force-killed; transcript may be stale"
                   role (if (boundp 'eda/ws-claude-exit-timeout)
                            eda/ws-claude-exit-timeout "?"))))
      (puthash ws (cl-remove-if (lambda (e) (eq (car e) role)) entries)
               eda/ws-claudes)
      (when (boundp 'eda/ws-claude-sids)
        (remhash (cons ws role) eda/ws-claude-sids))
      t)))

;; --- Triggers --------------------------------------------------------------

(defun eda/task--on-state-change ()
  "Auto-start a session when an EDA entry enters an active state."
  (when (and eda/task-autostart-on-state-change
             (boundp 'org-state) org-state
             (member org-state eda/task-active-states)
             (eda/task--eda-entry-p))
    (condition-case err
        (eda/task-start (point-marker))
      (error (message "eda/task-start (state-change): %s"
                      (error-message-string err))))))

(defun eda/task--on-clock-in ()
  "Auto-start a session when clocking into an EDA task."
  (when (and eda/task-autostart-on-clock-in
             (markerp org-clock-hd-marker))
    (condition-case err
        (when (org-with-point-at org-clock-hd-marker (eda/task--eda-entry-p))
          (eda/task-start org-clock-hd-marker))
      (error (message "eda/task-start (clock-in): %s"
                      (error-message-string err))))))

(add-hook 'org-after-todo-state-change-hook #'eda/task--on-state-change)
(add-hook 'org-clock-in-hook #'eda/task--on-clock-in)

;; --- E4b · transcript viewer -----------------------------------------------
;;
;; Claude Code runs on the terminal ALTERNATE SCREEN, which has no scrollback —
;; so the live vterm pane cannot be scrolled back through earlier messages, and
;; forwarding wheel/keys to it does not scroll either. Instead we read the
;; session's own transcript (`~/.claude/projects/<flattened-wt>/<sid>.jsonl`)
;; and render it into an ordinary, fully-scrollable Emacs buffer.

(defvar eda/task-transcript-show-thinking nil
  "When non-nil, include Claude's `thinking' blocks in the transcript view.")

(defvar-local eda/task--transcript-jsonl nil
  "Path of the .jsonl this transcript buffer was rendered from (for refresh).")

(defun eda/task--jget (o k)
  "Value of key K (a string) in alist O from `json-parse-string'.
`json-parse-string' with :object-type \\='alist interns keys as SYMBOLS, so we
intern K to look it up."
  (and (listp o) (alist-get (intern k) o)))

(defun eda/task--content->text (content)
  "Render a Claude message CONTENT (string or list of blocks) to readable text."
  (cond
   ((stringp content) content)
   ((listp content)
    (string-join
     (delq nil
           (mapcar
            (lambda (b)
              (when (listp b)
                (let ((bt (eda/task--jget b "type")))
                  (cond
                   ((equal bt "text") (eda/task--jget b "text"))
                   ((equal bt "thinking")
                    (when eda/task-transcript-show-thinking
                      (concat "  💭 "
                              (replace-regexp-in-string
                               "\n" "\n  " (or (eda/task--jget b "thinking") "")))))
                   ((equal bt "tool_use")
                    (format "  ⚙ %s  %s" (eda/task--jget b "name")
                            (truncate-string-to-width
                             (replace-regexp-in-string
                              "[ \t\n]+" " " (format "%s" (eda/task--jget b "input")))
                             100 nil nil "…")))
                   ((equal bt "tool_result")
                    (format "  ↳ %s"
                            (truncate-string-to-width
                             (replace-regexp-in-string
                              "[ \t\n]+" " "
                              (eda/task--content->text (eda/task--jget b "content")))
                             120 nil nil "…")))
                   (t nil)))))
            content))
     "\n"))
   (t "")))

(defun eda/task--short-ts (ts)
  "Trim an ISO TS like 2026-07-06T16:25:… to \"2026-07-06 16:25\"."
  (if (and (stringp ts) (>= (length ts) 16))
      (concat (substring ts 0 10) " " (substring ts 11 16))
    (or ts "")))

(defun eda/task--transcript-string (jsonl)
  "Return a readable transcript rendered from the Claude JSONL file."
  (let ((parts '()))
    (dolist (ln (with-temp-buffer
                  (insert-file-contents jsonl)
                  (split-string (buffer-string) "\n" t)))
      ;; Cheap pre-filter: only user/assistant lines carry conversation; skip
      ;; the (often huge) snapshot/attachment/metadata lines without parsing.
      (when (string-match-p "\"type\": *\"\\(user\\|assistant\\)\"" ln)
        (let ((o (ignore-errors
                   (json-parse-string ln :object-type 'alist :array-type 'list
                                      :null-object nil :false-object nil))))
          (when o
            (let* ((type (eda/task--jget o "type"))
                   (msg  (eda/task--jget o "message"))
                   (ts   (eda/task--short-ts (eda/task--jget o "timestamp")))
                   (txt  (string-trim
                          (eda/task--content->text (eda/task--jget msg "content")))))
              (unless (string-empty-p txt)
                (push (format "\n\n%s  %s\n%s"
                              (if (equal type "user") "▶ You" "● Claude") ts txt)
                      parts)))))))
    (string-join (nreverse parts) "")))

(defun eda/task--jsonl-for (wt sid)
  "Transcript path for SID under worktree WT's Claude project dir, if readable."
  (let ((f (expand-file-name (concat sid ".jsonl") (eda/ws-claude--project-dir wt))))
    (and (file-readable-p f) f)))

(defun eda/task--role-md (wt role)
  "Worktree-local live transcript markdown for ROLE under WT, if readable.
Written turn-by-turn by the `eda-claude-transcript.py' hooks. This is the
reliable source for a *running* session: Claude 2.1.x keeps the live
conversation in memory and only flushes `<sid>.jsonl' on exit, so the hook's
`<role>.transcript.md' is the only thing on disk mid-session."
  (when (and wt role)
    (let ((f (expand-file-name (format "%s.transcript.md" role)
                               (expand-file-name ".claude/sessions/" wt))))
      (and (file-readable-p f) f))))

(defun eda/task--role-for-sid (wt sid)
  "Role whose `<role>.session-id' file under WT contains SID, or nil."
  (when (and wt sid)
    (let ((dir (expand-file-name ".claude/sessions/" wt)))
      (when (file-directory-p dir)
        (cl-loop for f in (directory-files dir t "\\.session-id\\'")
                 when (equal sid (string-trim
                                  (with-temp-buffer
                                    (ignore-errors (insert-file-contents f))
                                    (buffer-string))))
                 return (file-name-base f))))))

(defun eda/task--render-source (path)
  "Readable transcript text for PATH.
A `.md' hook snapshot is shown verbatim; a `.jsonl' is parsed via
`eda/task--transcript-string'."
  (cond ((null path) "")
        ((string-suffix-p ".md" path)
         (with-temp-buffer (insert-file-contents path) (buffer-string)))
        (t (eda/task--transcript-string path))))

(defun eda/task--project-latest-jsonl (dir)
  "Newest transcript .jsonl under DIR's Claude project dir, or nil."
  (let ((proj (ignore-errors (eda/ws-claude--project-dir dir))))
    (when (and proj (file-directory-p proj))
      (car (sort (directory-files proj t "\\.jsonl\\'") #'file-newer-than-file-p)))))

(defun eda/task--descendant-pids (pid)
  "PID and all its descendant PIDs (best-effort, via pgrep)."
  (let ((all (list pid)) (queue (list pid)))
    (when (executable-find "pgrep")
      (while queue
        (let ((p (pop queue)))
          (with-temp-buffer
            (when (eq 0 (call-process "pgrep" nil t nil "-P" (number-to-string p)))
              (dolist (k (split-string (buffer-string) nil t))
                (let ((kn (string-to-number k)))
                  (unless (memq kn all) (push kn all) (push kn queue)))))))))
    (nreverse all)))

(defun eda/task--vterm-pids ()
  "PIDs of the process tree behind the current vterm buffer, or nil."
  (let ((proc (and (derived-mode-p 'vterm-mode) (get-buffer-process (current-buffer)))))
    (when proc (eda/task--descendant-pids (process-id proc)))))

(defun eda/task--vterm-claude-jsonl ()
  "Transcript .jsonl the claude in THIS vterm currently has open, or nil.
This is the precise identity of the running session: the child process holds
its own `<sid>.jsonl' open, so we match it directly rather than guessing."
  (let ((pids (eda/task--vterm-pids)))
    (when (and pids (executable-find "lsof"))
      (with-temp-buffer
        (ignore-errors
          (call-process "lsof" nil t nil "-p" (mapconcat #'number-to-string pids ",")))
        (goto-char (point-min))
        (when (re-search-forward
               "\\(/[^ \t\n]*/\\.claude/projects/[^ \t\n]+\\.jsonl\\)" nil t)
          (match-string 1))))))

(defun eda/task--session-label (path)
  "A recognizable label for transcript PATH: time · project · title.
Handles both `<sid>.jsonl' files and worktree-local `<role>.transcript.md'
snapshots (labelled `<worktree>/<role>' and tagged as live)."
  (let* ((md (string-suffix-p ".transcript.md" path))
         (mt (ignore-errors
               (format-time-string
                "%Y-%m-%d %H:%M"
                (file-attribute-modification-time (file-attributes path)))))
         (proj (if md
                   (let* ((role (string-remove-suffix ".transcript" (file-name-base path)))
                          (sessions (directory-file-name (file-name-directory path)))
                          (dotclaude (directory-file-name (file-name-directory sessions)))
                          (wt (directory-file-name (file-name-directory dotclaude))))
                     (format "%s/%s" (file-name-nondirectory wt) role))
                 (file-name-nondirectory (directory-file-name (file-name-directory path)))))
         (title (if md "· live snapshot ·"
                  (or (and (fboundp 'eda/ws-claude--session-title)
                           (ignore-errors (eda/ws-claude--session-title path)))
                      ""))))
    (format "%s  %-26s  %s" (or mt "????-??-?? ??:??")
            (truncate-string-to-width proj 26 nil nil "…")
            (truncate-string-to-width (or title "") 60 nil nil "…"))))

(defun eda/task--pick-session ()
  "Prompt for one of the recent Claude conversations; return (PATH . LABEL).
Merges live worktree-local `<role>.transcript.md' snapshots (reliable for
running sessions) with completed `<sid>.jsonl' files under ~/.claude/projects/,
newest first."
  (let* ((root (expand-file-name "~/.claude/projects/"))
         (wt-root (and (boundp 'eda/ws-claude-worktree-root)
                       eda/ws-claude-worktree-root))
         (mds (and wt-root (file-directory-p wt-root)
                   (ignore-errors
                     (directory-files-recursively wt-root "\\.transcript\\.md\\'"))))
         (jsonls (and (file-directory-p root)
                      (directory-files-recursively root "\\.jsonl\\'")))
         (files (seq-take (sort (append mds jsonls) #'file-newer-than-file-p) 50)))
    (unless files (user-error "No Claude transcripts found"))
    (let* ((cands (mapcar (lambda (f) (cons (eda/task--session-label f) f)) files))
           (pick (completing-read
                  "Claude session (newest first): "
                  (if (fboundp 'eda/ws-claude--ordered-table)
                      (eda/ws-claude--ordered-table (mapcar #'car cands))
                    (mapcar #'car cands))
                  nil t)))
      (let ((f (cdr (assoc pick cands)))) (and f (cons f pick))))))

(defun eda/task--claude-source ()
  "Return (JSONL . LABEL) for the Claude conversation to show, or nil.
Tries, in order: the task-engine session bound to the current `*claude:*'
buffer; the EDA task at point; the Claude running in the current vterm (by its
directory); then the most recent Claude session anywhere (works while chatting)."
  (let (jsonl label)
    ;; 1. registered task-engine claude buffer
    (let (hit)
      (when (boundp 'eda/ws-claudes)
        (maphash (lambda (ws entries)
                   (dolist (e entries)
                     (when (eq (cdr e) (current-buffer)) (setq hit (cons ws (car e))))))
                 eda/ws-claudes))
      (when hit
        (let* ((ws (car hit)) (role (cdr hit))
               (wt (ignore-errors (eda/ws-claude--worktree ws)))
               (sid (or (and (boundp 'eda/ws-claude-sids)
                             (gethash (cons ws role) eda/ws-claude-sids))
                        (and (fboundp 'eda/ws-claude--read-sid) wt
                             (eda/ws-claude--read-sid wt role)))))
          (when (and wt (or (eda/task--role-md wt role)
                            (and sid (eda/task--jsonl-for wt sid))))
            (setq jsonl (or (eda/task--role-md wt role)
                            (eda/task--jsonl-for wt sid))
                  label (format "%s/%s"
                                (file-name-nondirectory (directory-file-name wt)) role))))))
    ;; 2. EDA task at point
    (unless jsonl
      (ignore-errors
        (let* ((m (eda/task--marker))
               (wt (eda/task-worktree m))
               (role (or (eda/task-role m) 'architect))
               (sid (or (eda/task-session-id m)
                        (and (fboundp 'eda/ws-claude--read-sid)
                             (eda/ws-claude--read-sid wt role)))))
          (when (and wt (or (eda/task--role-md wt role)
                            (and sid (eda/task--jsonl-for wt sid))))
            (setq jsonl (or (eda/task--role-md wt role)
                            (eda/task--jsonl-for wt sid))
                  label (format "%s/%s"
                                (file-name-nondirectory (directory-file-name wt)) role))))))
    ;; 3. the claude actually running in THIS vterm — precise: the transcript
    ;;    file its process currently has open (falls back to the vterm's dir).
    (when (and (not jsonl) (derived-mode-p 'vterm-mode))
      (let* ((j (or (eda/task--vterm-claude-jsonl)
                    (eda/task--project-latest-jsonl default-directory)))
             (wt default-directory)
             (role (and j (eda/task--role-for-sid wt (file-name-base j))))
             (md (eda/task--role-md wt role)))
        (cond
         (md (setq jsonl md
                   label (format "%s/%s (live)"
                                 (file-name-nondirectory (directory-file-name wt)) role)))
         (j (setq jsonl j
                  label (concat (file-name-nondirectory
                                 (directory-file-name (file-name-directory j)))
                                " (this vterm)"))))))
    ;; NOTE: deliberately NO global-latest guess here — if the session can't be
    ;; pinned, the command asks (picker) instead of opening the wrong transcript.
    (and jsonl (cons jsonl label))))

(defvar eda/task-transcript-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m "g" #'eda/task-transcript-refresh)
    m)
  "Keymap for `eda/task-transcript-mode'.")

(define-derived-mode eda/task-transcript-mode special-mode "Claude-Transcript"
  "Read-only, scrollable view of a Claude session transcript."
  (setq-local truncate-lines nil))

(defun eda/task-transcript-refresh ()
  "Re-read the transcript file and re-render this buffer."
  (interactive)
  (when eda/task--transcript-jsonl
    (let ((inhibit-read-only t) (jsonl eda/task--transcript-jsonl))
      (erase-buffer)
      (insert (eda/task--render-source jsonl))
      (goto-char (point-max))
      (message "Transcript refreshed"))))

;;;###autoload
(defun eda/task-view-transcript (&optional pick)
  "Open a Claude conversation's transcript in a scrollable buffer.
Auto-detects the session (see `eda/task--claude-source'): the Claude bound to
this buffer/task, or — in a vterm — the exact session its process has open.
When it can't be pinned, or with a prefix arg PICK (\\[universal-argument]),
choose from a list of recent conversations (shown with time · project · title).
Since the live pane runs on the alternate screen and can't be scrolled back,
this is how you read and search earlier conversation. `g' refreshes; `q' buries."
  (interactive "P")
  (let ((src (or (and (not pick) (eda/task--claude-source))
                 (eda/task--pick-session))))
    (unless src
      (user-error "No Claude transcript selected"))
    (let* ((jsonl (car src)) (label (or (cdr src) "claude"))
           (buf (get-buffer-create (format "*claude-transcript: %s*" label)))
           (body (eda/task--render-source jsonl)))
      (with-current-buffer buf
        (unless (derived-mode-p 'eda/task-transcript-mode)
          (eda/task-transcript-mode))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "# %s\n# %s   (g: refresh · q: bury)\n" label jsonl))
          (insert (if (string-empty-p body) "\n(no messages yet)\n" body))
          (goto-char (point-max)))
        (setq eda/task--transcript-jsonl jsonl))
      (pop-to-buffer buf)
      (message "Transcript: %s" label))))

;; --- Keybindings under SPC k o * (org task engine) -------------------------
;; NOTE: SPC k t is already `claude-code-toggle', so the task engine lives
;; under SPC k o to avoid clobbering it.

(map! :leader
      (:prefix-map ("k o" . "org task engine")
       :desc "Start / resume session" "s" #'eda/task-start
       :desc "Jump to task's Claude"  "j" #'eda/task-jump
       :desc "Init / stamp schema"    "i" #'eda/task-init
       :desc "Quick stamp (slug only)" "I" #'eda/task-init-quick
       :desc "Create worktree dir"    "w" #'eda/task-create-worktree
       :desc "Copy resume command"    "y" #'eda/task-copy-resume
       :desc "View transcript (scroll)" "t" #'eda/task-view-transcript
       :desc "Describe machine"       "?" #'eda/portable-describe))

;; Inside a Claude vterm the SPC leader is sent to the terminal (Claude), so
;; `SPC k o t' never reaches Emacs there. Bind `C-c t' — vterm keeps C-c for
;; Emacs (it's in `vterm-keymap-exceptions') — so the transcript is one chord
;; away from inside the session too. (`M-x eda/task-view-transcript' also works.)
(with-eval-after-load 'vterm
  (define-key vterm-mode-map (kbd "C-c t") #'eda/task-view-transcript))

;; Load the per-field entry history so the first `eda/task-init' of the session
;; already knows your past worktrees, clients, roles and source commands.
(eda/task--hist-load)

(provide 'eda-task-engine)
;;; eda-task-engine.el ends here
