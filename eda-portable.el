;;; ~/.config/doom/eda-portable.el  -*- lexical-binding: t; -*-
;;;
;;; Phase 8 · Layer 0 — portability / host profile / tool discovery.
;;;
;;; Purpose:
;;;   One config that boots on BOTH the personal Mac and the (restricted,
;;;   user-space-only) client Linux box. Everything that differs per machine
;;;   is resolved through this layer instead of being hardcoded:
;;;     - a machine PROFILE  (personal-mac | client-<name> | linux-<host>)
;;;     - path roots         (worktrees, org, memory) as single sources of truth
;;;     - tool discovery      via `executable-find' (never a hardcoded /opt/...)
;;;     - a client-write predicate that later phases use to make the client
;;;       task file read-only on non-client machines (E18).
;;;
;;; Load order:
;;;   This file is loaded FIRST among the eda-* modules (see config.el), so the
;;;   root defvars below become the canonical values that eda-tasks.el and
;;;   eda-workspace-claude.el inherit (their own `defvar's are then no-ops).
;;;   All defaults equal the pre-existing hardcoded values, so this is a pure
;;;   refactor on the Mac — nothing changes there.

(require 'cl-lib)

;; --- Machine profile -------------------------------------------------------

(defcustom eda/portable-profile-file (expand-file-name "~/.eda-profile")
  "Optional file whose first line names this machine's EDA profile.
Write e.g. `client-acme' into ~/.eda-profile on a client box. When absent,
the profile is inferred from the OS / hostname."
  :type 'file :group 'eda)

(defun eda/portable--detect-profile ()
  "Compute this machine's profile string."
  (cond
   ((file-readable-p eda/portable-profile-file)
    (string-trim
     (with-temp-buffer (insert-file-contents eda/portable-profile-file)
                       (buffer-string))))
   ((eq system-type 'darwin) "personal-mac")
   (t (format "linux-%s"
              (or (car (split-string (or (system-name) "host") "\\.")) "host")))))

(defvar eda/portable-profile (eda/portable--detect-profile)
  "This machine's EDA profile string, e.g. \"personal-mac\" or \"client-acme\".")

(defun eda/portable-client-p ()
  "Non-nil when this machine is a client environment (profile `client-*')."
  (string-prefix-p "client-" eda/portable-profile))

(defun eda/portable-client-name ()
  "Return the client name if this is a client machine, else nil.
`client-acme' → \"acme\"."
  (when (eda/portable-client-p)
    (substring eda/portable-profile (length "client-"))))

(defun eda/portable-can-write-client-state-p ()
  "Non-nil only where it is legal to change client work-task STATE (E18).
True on the client machine; false on the personal Mac and mobile. New-task
creation and client-idle clocking are allowed elsewhere and gated separately."
  (eda/portable-client-p))

;; --- Path roots (single source of truth; inherited by later modules) -------

(defvar eda/portable-worktree-root (expand-file-name "~/eda/wt/")
  "Root under which every per-task worktree lives, on THIS machine.")

;; Canonicalise the roots the later modules also define. Because this file
;; loads first, these `defvar's win and eda-tasks / eda-workspace-claude
;; inherit them (their identical `defvar's become no-ops).
(defvar eda/worktree-root eda/portable-worktree-root)
(defvar eda/ws-claude-worktree-root eda/portable-worktree-root)

(defvar eda/portable-org-root
  (expand-file-name (or (bound-and-true-p org-directory) "~/org/"))
  "Root for org files on this machine (set from `org-directory').")

(defvar eda/portable-memory-root (expand-file-name "~/.claude/memory/")
  "Root of the local Claude memory stores.
`personal/' syncs everywhere; `clients/<name>/' stays on the client box (E8).")

(defun eda/portable-personal-memory-dir ()
  (file-name-as-directory (expand-file-name "personal" eda/portable-memory-root)))

(defun eda/portable-client-memory-dir (&optional client)
  "Memory dir for CLIENT (default: this machine's client). Nil if not a client."
  (let ((c (or client (eda/portable-client-name))))
    (when c
      (file-name-as-directory
       (expand-file-name (format "clients/%s" c) eda/portable-memory-root)))))

;; --- Tool discovery (graceful degradation on the restricted client) --------

(defun eda/exe (name &rest fallbacks)
  "Return the path to executable NAME, trying FALLBACKS in order, else nil.
Never hardcodes an install prefix — resolves via PATH so the same config
works on Mac (Homebrew) and locked-down Linux (user-space installs)."
  (cl-some #'executable-find (cons name fallbacks)))

(defun eda/portable-claude-available-p ()
  "Non-nil when the `claude' CLI is on PATH here."
  (and (eda/exe "claude") t))

(defun eda/portable-git-available-p ()
  (and (eda/exe "git") t))

;;;###autoload
(defun eda/portable-describe ()
  "Echo the resolved profile + roots + key tool availability."
  (interactive)
  (message
   (concat "EDA profile: %s | client-write: %s\n"
           "  worktrees: %s\n  org: %s\n  memory: %s\n"
           "  claude: %s | git: %s")
   eda/portable-profile
   (if (eda/portable-can-write-client-state-p) "yes" "no")
   eda/portable-worktree-root eda/portable-org-root eda/portable-memory-root
   (or (eda/exe "claude") "MISSING") (or (eda/exe "git") "MISSING")))

;; --- Phase 16 · portability hardening (E11) --------------------------------
;;
;; The whole point of L0 is that this identical config boots on the personal
;; Mac AND on the restricted, user-space-only client Linux box. The predicates
;; and helpers below make the machine differences explicit and let the heavy
;; stacks (daemon fleet, launchd scheduling) self-disable where they can't or
;; shouldn't run, so a fresh client "boots clean and simply offers less".

(defvar eda/portable-allow-daemon-fleet nil
  "Escape hatch: when non-nil, permit the multi-daemon fleet even on a client.
Default nil ⇒ the fleet is gated by profile (see `eda/portable-daemon-stack-enabled-p').")

(defun eda/portable-daemon-stack-enabled-p ()
  "Non-nil where spawning the multi-daemon fleet is appropriate.
Decision: the restricted client runs a SINGLE Emacs — no fleet there
\(the org task, not the daemon, is the organizing axis). Everywhere else the
fleet remains available. Override with `eda/portable-allow-daemon-fleet'."
  (or eda/portable-allow-daemon-fleet
      (not (eda/portable-client-p))))

(defun eda/portable-launchd-enabled-p ()
  "Non-nil only where the launchd/at-boot scheduling stack applies (Mac, non-client)."
  (and (eq system-type 'darwin) (not (eda/portable-client-p))))

(defun eda/portable-ensure-roots ()
  "Create the worktree / org / memory roots for this machine if missing.
Returns the list of directories that were created. Never auto-run at load —
call it (or `eda/portable-doctor' offers to) when bootstrapping a fresh box."
  (interactive)
  (let (created)
    (dolist (dir (list eda/portable-worktree-root
                       eda/portable-org-root
                       eda/portable-memory-root
                       (eda/portable-personal-memory-dir)
                       (eda/portable-client-memory-dir)))
      (when (and dir (not (file-directory-p dir)))
        (make-directory dir t)
        (push dir created)))
    (when (called-interactively-p 'any)
      (message "Ensured roots%s"
               (if created (format " (created %d)" (length created)) " (all present)")))
    (nreverse created)))

;; Per-machine overrides (git-ignored) — secrets, paths, profile, sync emails.
;; chezmoi manages the tracked config across machines; `.eda-local.el' holds
;; whatever must NOT be tracked. Loaded at the end of L0 so its overrides land
;; before the later eda-* modules read the roots/profile.
(defvar eda/portable-local-file
  (expand-file-name ".eda-local.el"
                    (or (bound-and-true-p doom-user-dir)
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))))
  "Optional git-ignored per-machine override file, loaded at L0 end.")

(defun eda/portable-load-local ()
  "Load `eda/portable-local-file' if present (per-machine overrides)."
  (when (file-readable-p eda/portable-local-file)
    (load (expand-file-name eda/portable-local-file) nil 'nomessage)
    t))

;;;###autoload
(defun eda/portable-doctor (&optional quiet)
  "Preflight / graceful-degradation audit for this machine.
Reports the profile, resolved roots (exist/writable), tool availability, which
heavy stacks are enabled, and which features are degraded here. Returns a plist
\(also echoed unless QUIET) so it is scriptable and testable."
  (interactive)
  (let* ((tools (mapcar (lambda (n) (cons n (eda/exe n)))
                        '("claude" "git" "emacs" "verilator" "vivado")))
         (roots (mapcar
                 (lambda (cell)
                   (let ((dir (cdr cell)))
                     (list (car cell) dir
                           (file-directory-p dir)
                           (file-writable-p
                            (if (file-directory-p dir) dir
                              (file-name-directory (directory-file-name dir)))))))
                 (list (cons 'worktrees eda/portable-worktree-root)
                       (cons 'org       eda/portable-org-root)
                       (cons 'memory    eda/portable-memory-root))))
         (degraded '()))
    (unless (cdr (assoc "claude" tools))
      (push "no claude → DONE-gate self-review + memory distill self-disable (waiver-with-log)" degraded))
    (unless (cdr (assoc "git" tools))
      (push "no git → worktree-commit check voided (N/A), sync union-merge unavailable" degraded))
    (unless (eda/portable-daemon-stack-enabled-p)
      (push "daemon fleet disabled → single Emacs (org task is the axis)" degraded))
    (unless (eda/portable-launchd-enabled-p)
      (push "launchd scheduling off → run reports/sync manually or via cron" degraded))
    (when (eda/portable-client-p)
      (push "client box → client memory is local-only; client tasks read-only elsewhere" degraded))
    (dolist (r roots)
      (unless (nth 2 r)
        (push (format "root %s missing: %s (run eda/portable-ensure-roots)" (nth 0 r) (nth 1 r))
              degraded)))
    (let ((result
           (list :profile eda/portable-profile
                 :client-write (eda/portable-can-write-client-state-p)
                 :daemon-fleet (eda/portable-daemon-stack-enabled-p)
                 :launchd (eda/portable-launchd-enabled-p)
                 :tools tools
                 :roots roots
                 :degraded (nreverse degraded))))
      (unless quiet
        (message
         (concat "EDA doctor — profile %s (client-write %s)\n"
                 "  stacks: daemon-fleet %s · launchd %s\n"
                 "  tools:  %s\n"
                 "  roots:  %s\n"
                 "  degraded: %s")
         eda/portable-profile
         (if (plist-get result :client-write) "yes" "no")
         (if (plist-get result :daemon-fleet) "on" "OFF")
         (if (plist-get result :launchd) "on" "OFF")
         (mapconcat (lambda (tp) (format "%s=%s" (car tp) (if (cdr tp) "ok" "MISSING"))) tools "  ")
         (mapconcat (lambda (r) (format "%s[%s%s]" (nth 0 r)
                                        (if (nth 2 r) "✓" "✗missing")
                                        (if (nth 3 r) "" " ro")))
                    roots "  ")
         (if (plist-get result :degraded)
             (concat "\n    - " (mapconcat #'identity (plist-get result :degraded) "\n    - "))
           "none — full capability here")))
      result)))

(map! :leader
      (:prefix-map ("k o" . "org task engine")
       :desc "Portability doctor" "P" #'eda/portable-doctor))

;; Apply per-machine overrides last, so later modules inherit the final roots.
(eda/portable-load-local)

(provide 'eda-portable)
;;; eda-portable.el ends here
