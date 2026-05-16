;;; ~/.config/doom/eda-workspace-claude.el  -*- lexical-binding: t; -*-
;;;
;;; Per-workspace Claude sessions, role-specialised.
;;;
;;; Concept:
;;;   Each Doom workspace (persp = one task = one worktree) can host
;;;   multiple Claude sessions. Each session is bound to a ROLE drawn from
;;;   `eda/ws-claude-roles` — architect, rtl-review, verification,
;;;   integration, debug — and uses the matching sub-agent template from
;;;   ~/.config/doom/agent-templates/<role>-agent.md.
;;;
;;; Workspace-name → worktree path is derived as:
;;;   ~/eda/wt/<workspace-name>/
;;;
;;; Persistence:
;;;   On snapshot (manual via SPC k w S, or auto on Emacs shutdown), each
;;;   live Claude buffer for the current workspace is dumped to:
;;;     <worktree>/.claude/sessions/<role>.md          -- human-readable transcript
;;;     <worktree>/.claude/sessions/<role>.session-id  -- UUID for `claude --resume`
;;;   Both are intended to be committed to git, so the conversation
;;;   history travels with the task branch.
;;;
;;; Resume:
;;;   `eda/ws-claude-new` checks for an existing <role>.session-id and, if
;;;   present, spawns Claude with `--resume <uuid>` instead of a fresh
;;;   session. `eda/ws-claude-resume-all` does this for every snapshotted
;;;   role in the workspace.

(require 'cl-lib)
(require 'persp-mode nil 'noerror)

;; --- Config ----------------------------------------------------------------

(defvar eda/ws-claude-roles
  '(architect rtl-review verification integration debug)
  "Roles available for workspace-bound Claude sessions.
Each role must have a matching <role>-agent.md in
`eda/agent-template-dir` (from eda-claude.el).")

(defvar eda/ws-claude-worktree-root
  (expand-file-name "~/eda/wt/")
  "Where each workspace name resolves to a worktree on disk.")

(defvar eda/ws-claudes (make-hash-table :test 'equal)
  "Hash table: workspace-name → alist ((ROLE . BUFFER) ...).
Tracks live workspace-bound Claude sessions.")

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

(defun eda/ws-claude--read-sid (wt role)
  "Return the stored session-id for (WT, ROLE), or nil."
  (let ((f (eda/ws-claude--sid-file wt role)))
    (when (file-readable-p f)
      (string-trim
       (with-temp-buffer
         (insert-file-contents f)
         (buffer-string))))))

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

;; --- claude-code.el integration --------------------------------------------

(declare-function claude-code--start "claude-code")
(declare-function claude-code-send-command "claude-code")
(declare-function claude-code-kill "claude-code")
(declare-function claude-code--buffer-name "claude-code")

(defun eda/ws-claude--spawn (wt role &optional resume-sid)
  "Spawn a claude-code instance for ROLE under worktree WT.
With RESUME-SID, attaches `--resume <sid>' so Claude rejoins that
specific past session.  Returns the new buffer."
  (let* ((wt-truename (file-truename wt))
         (instance-name (symbol-name role))
         (extra-switches (when resume-sid (list "--resume" resume-sid))))
    ;; Override claude-code's directory + instance-name probes for this call.
    (cl-letf (((symbol-function 'claude-code--directory)
               (lambda () wt-truename))
              ((symbol-function 'claude-code--prompt-for-instance-name)
               (lambda (&rest _) instance-name)))
      (claude-code--start nil extra-switches t nil))
    ;; Look up the buffer claude-code just created (named per its convention).
    (let ((buf-name (format "*claude:%s:%s*"
                            (abbreviate-file-name wt-truename)
                            instance-name)))
      (or (get-buffer buf-name)
          (error "Spawned Claude but cannot find buffer %s" buf-name)))))

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

;; --- Session-id discovery (best-effort) -----------------------------------

(defun eda/ws-claude--flatten-dir (cwd)
  "Mirror Claude CLI's project-dir flattening of CWD.
`/Users/dinesh/eda/wt/foo' → `-Users-dinesh-eda-wt-foo'."
  (let ((abs (directory-file-name (file-truename (expand-file-name cwd)))))
    (replace-regexp-in-string "/" "-" abs)))

(defun eda/ws-claude--latest-session-id (cwd)
  "Return the most-recently-modified Claude session id for CWD, or nil.
Reads ~/.claude/projects/<flattened-cwd>/*.jsonl."
  (let* ((proj-dir (expand-file-name (eda/ws-claude--flatten-dir cwd)
                                     (expand-file-name "~/.claude/projects/"))))
    (when (file-directory-p proj-dir)
      (let* ((files (directory-files proj-dir t "\\.jsonl\\'"))
             (sorted (sort files
                           (lambda (a b) (file-newer-than-file-p a b)))))
        (and sorted (file-name-base (car sorted)))))))

;; --- Public commands -------------------------------------------------------

;;;###autoload
(defun eda/ws-claude-new (role)
  "Start (or resume) a Claude session for ROLE in the current workspace.

If `<worktree>/.claude/sessions/<role>.session-id' exists, the saved
session is resumed via `claude --resume <id>'.  Otherwise a fresh
session is started and seeded with a role-bootstrap prompt that points
it at the matching sub-agent file in `.claude/agents/'."
  (interactive
   (list (intern (completing-read
                  "Role: "
                  (mapcar #'symbol-name eda/ws-claude-roles)
                  nil t))))
  (let* ((ws (or (eda/ws-claude--current-ws)
                 (user-error "No active workspace (persp-mode not loaded or default persp)")))
         (wt (eda/ws-claude--worktree ws))
         (sid (eda/ws-claude--read-sid wt role)))
    (unless (file-directory-p wt)
      (user-error "Worktree %s does not exist" wt))
    (eda/ws-claude--ensure-agents wt)
    (let ((buf (eda/ws-claude--spawn wt role sid)))
      (eda/ws-claude--register ws role buf)
      (unless sid
        ;; Bootstrap role on a fresh session.
        (with-current-buffer buf
          (claude-code-send-command
           (format
            "You are the %s for the workspace `%s` rooted at %s. Use the `%s-agent` sub-agent from .claude/agents/ for any role-specific action. Stay in role: defer cross-role work (RTL writing, verification, integration) to peer Claudes in this workspace by naming the sub-agent that should handle it."
            role ws wt role))))
      (pop-to-buffer buf)
      (message "%s Claude (%s) for workspace %s"
               (if sid "Resumed" "Started") role ws))))

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
        (with-current-buffer buf
          (let ((claude-code-confirm-kill nil))
            (ignore-errors (claude-code-kill)))))
      (puthash ws (cl-remove-if (lambda (e) (eq (car e) role)) entries)
               eda/ws-claudes)
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
Returns the list of files written."
  (let* ((wt (eda/ws-claude--worktree ws))
         (sessions-dir (eda/ws-claude--sessions-dir wt))
         (md (eda/ws-claude--md-file wt role))
         (sid-file (eda/ws-claude--sid-file wt role))
         (sid (eda/ws-claude--latest-session-id wt))
         (written '()))
    (make-directory sessions-dir t)
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
    (when sid
      (with-temp-file sid-file (insert sid) (insert "\n"))
      (push sid-file written))
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
  "Resume every snapshotted Claude in the current workspace.
Iterates `<worktree>/.claude/sessions/<role>.session-id' and spawns one
Claude per role with `--resume <id>'."
  (interactive)
  (let* ((ws (or (eda/ws-claude--current-ws)
                 (user-error "No active workspace")))
         (wt (eda/ws-claude--worktree ws))
         (sessions-dir (eda/ws-claude--sessions-dir wt)))
    (unless (file-directory-p sessions-dir)
      (user-error "No sessions dir at %s" sessions-dir))
    (let ((count 0))
      (dolist (sid-file (directory-files sessions-dir t "\\.session-id\\'"))
        (let* ((base (file-name-base sid-file))
               (role (intern (replace-regexp-in-string "\\.session-id\\'" "" base))))
          (when (memq role eda/ws-claude-roles)
            (eda/ws-claude-new role)
            (cl-incf count))))
      (message "Resumed %d Claude(s) for %s" count ws))))

;; --- Hooks -----------------------------------------------------------------

(defun eda/ws-claude--snapshot-all-on-shutdown ()
  "Best-effort snapshot of every workspace's Claudes at shutdown."
  (maphash
   (lambda (ws entries)
     (dolist (e entries)
       (ignore-errors
         (eda/ws-claude--snapshot-one ws (car e) (cdr e)))))
   eda/ws-claudes))

(add-hook 'kill-emacs-hook #'eda/ws-claude--snapshot-all-on-shutdown)

;; --- Keybindings under SPC k w * ------------------------------------------

(map! :leader
      (:prefix-map ("k w" . "workspace claudes")
       :desc "New / resume (role)"  "n" #'eda/ws-claude-new
       :desc "List all"             "l" #'eda/ws-claude-list
       :desc "Switch (role)"        "s" #'eda/ws-claude-switch
       :desc "Kill (role)"          "k" #'eda/ws-claude-kill
       :desc "Toggle primary"       "t" #'eda/ws-claude-toggle
       :desc "Snapshot all"         "S" #'eda/ws-claude-snapshot
       :desc "Resume all from disk" "R" #'eda/ws-claude-resume-all))

(provide 'eda-workspace-claude)
;;; eda-workspace-claude.el ends here
