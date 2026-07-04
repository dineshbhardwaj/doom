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
;;; Clock-in/state-change triggers, the DONE-gate, grids and sync arrive in
;;; later phases and build on these helpers.

(require 'org)
(require 'cl-lib)

;; From eda-portable / eda-tasks / eda-workspace-claude (loaded earlier).
(defvar eda/portable-worktree-root)
(defvar eda/project-org-filename)
(defvar eda/ws-claude-roles)
(defvar eda/ws-claudes)
(declare-function eda/ws-claude--start "eda-workspace-claude")
(declare-function eda/ws-claude--uuid "eda-workspace-claude")

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

(defun eda/task--append-logbook (text)
  "Prepend a timestamped note TEXT into the LOGBOOK of the entry at point.
Creates the drawer (after any PROPERTIES drawer / planning line) if absent."
  (save-excursion
    (org-back-to-heading t)
    (let* ((hbeg (point))
           (hend (save-excursion (outline-next-heading) (point)))
           (note (format "- %s %s\n"
                         (format-time-string "[%Y-%m-%d %a %H:%M]") text)))
      (goto-char hbeg)
      (if (re-search-forward "^[ \t]*:LOGBOOK:[ \t]*$" hend t)
          (progn (forward-line 1) (beginning-of-line) (insert note))
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
        (insert ":LOGBOOK:\n" note ":END:\n")))))

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

;; --- Keybindings under SPC k o * (org task engine) -------------------------
;; NOTE: SPC k t is already `claude-code-toggle', so the task engine lives
;; under SPC k o to avoid clobbering it.

(map! :leader
      (:prefix-map ("k o" . "org task engine")
       :desc "Jump to task's Claude" "j" #'eda/task-jump
       :desc "Init / stamp schema"   "i" #'eda/task-init
       :desc "Copy resume command"   "y" #'eda/task-copy-resume
       :desc "Describe machine"      "?" #'eda/portable-describe))

(provide 'eda-task-engine)
;;; eda-task-engine.el ends here
