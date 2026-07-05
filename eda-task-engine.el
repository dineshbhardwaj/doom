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
(declare-function claude-code-kill "claude-code")
(defvar eda/ws-claude-sids)
(defvar claude-code-confirm-kill)

;; Phase 9 — session-binding config.
(defvar eda/task-active-states '("IN-PROGRESS" "REVIEW")
  "TODO states that auto-start/resume an entry's Claude session (E4).")
(defvar eda/task-autostart-on-state-change t
  "When non-nil, entering an `eda/task-active-states' state starts the session.")
(defvar eda/task-autostart-on-clock-in t
  "When non-nil, clocking into an EDA task starts/resumes its Claude session.")

;; --- Org clock/log storage: keep notes and clocks in a LOGBOOK drawer ------

(with-eval-after-load 'org
  (setq org-log-into-drawer t)          ; state-change notes → :LOGBOOK:
  (setq org-clock-into-drawer "LOGBOOK")) ; CLOCK: lines → :LOGBOOK: too

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
  "Return a copy-pasteable shell command to resume the task's Claude session."
  (let ((wt  (eda/task-worktree marker))
        (src (eda/task-client-src marker))
        (sid (eda/task-session-id marker)))
    (when sid
      (format "(cd %s && %sclaude --resume %s)"
              (shell-quote-argument (directory-file-name wt))
              (if src (format "source %s && " src) "")
              sid))))

;; --- Commands --------------------------------------------------------------

(defun eda/task--suggest-slug ()
  "Suggest a kebab-case slug from the heading at point."
  (let ((h (or (org-get-heading t t t t) "task")))
    (downcase (replace-regexp-in-string
               "\\`-\\|-\\'" ""
               (replace-regexp-in-string "[^A-Za-z0-9]+" "-" (string-trim h))))))

;;;###autoload
(defun eda/task-init ()
  "Stamp (or refresh) the EDA task schema on the org heading at point.
Prompts for slug, client, role, worktree and (for client tasks) the bash
source command; generates a deterministic Claude session id; and writes a
`Resume ▶' comment into the task's LOGBOOK."
  (interactive)
  (org-with-point-at (eda/task--marker)
    (org-id-get-create)
    (let* ((slug   (read-string "Task slug: "
                                (or (org-entry-get nil "TASK_SLUG")
                                    (eda/task--suggest-slug))))
           (client (string-trim
                    (read-string "Client (blank = personal): "
                                 (or (org-entry-get nil "CLIENT") ""))))
           (role   (completing-read
                    "Role: " (mapcar #'symbol-name eda/ws-claude-roles) nil nil
                    (or (org-entry-get nil "CLAUDE_ROLE") "architect")))
           (wt     (read-string "Worktree (rel to worktree-root, or absolute): "
                                (or (org-entry-get nil "WORKTREE") slug)))
           (src    (unless (string-empty-p client)
                     (string-trim
                      (read-string "Client bash source (before claude): "
                                   (or (org-entry-get nil "CLIENT_SRC") "")))))
           (mem    (if (string-empty-p client) "personal" (concat "client-" client)))
           (sid    (or (and (let ((s (org-entry-get nil "CLAUDE_SESSION")))
                              (and s (not (string-empty-p s)) s)))
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
      (message "Task `%s' stamped · role=%s · session %s" slug role sid))))

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
  "Snapshot and kill the Claude session for (WS, ROLE) if it is live.
Returns non-nil if a live session was killed. Used by clock-out (MF1)."
  (let* ((entries (and (boundp 'eda/ws-claudes) (gethash ws eda/ws-claudes)))
         (buf (cdr (assq role entries))))
    (when (buffer-live-p buf)
      (ignore-errors (eda/ws-claude--snapshot-one ws role buf))
      (with-current-buffer buf
        (let ((claude-code-confirm-kill nil))
          (ignore-errors (claude-code-kill))))
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

;; --- Keybindings under SPC k o * (org task engine) -------------------------
;; NOTE: SPC k t is already `claude-code-toggle', so the task engine lives
;; under SPC k o to avoid clobbering it.

(map! :leader
      (:prefix-map ("k o" . "org task engine")
       :desc "Start / resume session" "s" #'eda/task-start
       :desc "Jump to task's Claude"  "j" #'eda/task-jump
       :desc "Init / stamp schema"    "i" #'eda/task-init
       :desc "Copy resume command"    "y" #'eda/task-copy-resume
       :desc "Describe machine"       "?" #'eda/portable-describe))

(provide 'eda-task-engine)
;;; eda-task-engine.el ends here
