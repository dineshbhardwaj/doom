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

(provide 'eda-portable)
;;; eda-portable.el ends here
