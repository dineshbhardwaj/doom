;;; ~/.config/doom/eda-daemons.el  -*- lexical-binding: t; -*-
;;;
;;; Dynamic Emacs-daemon orchestration for the EDA IDE workflow.
;;;
;;; Concepts:
;;;   * Each IP family (soc, pcie, ucie, ...) runs as one named daemon:
;;;       emacs --bg-daemon=<name>
;;;   * A persistent registry (`eda/daemons-alist`) tracks the friendly name
;;;     and default working root for each daemon.
;;;   * The registry is loaded from disk on startup and saved on every change.
;;;   * Per-daemon persp-mode state lives at `~/.config/doom/.persp-state-<name>.el`.
;;;
;;; User-facing commands (bound under `SPC k d`):
;;;   eda/new-daemon       (SPC k d n)  — interactively create + spawn a daemon
;;;   eda/list-daemons     (SPC k d l)  — tabulated view of running daemons
;;;   eda/switch-daemon    (SPC k d s)  — `emacsclient -s <name> -c` from inside Emacs
;;;   eda/kill-daemon      (SPC k d k)  — kill by name (asks twice)
;;;   eda/rename-daemon    (SPC k d r)  — rename in registry (cosmetic only)
;;;   eda/restart-daemon   (SPC k d R)  — kill + respawn, restore persp state
;;;   eda/seed-daemons     (SPC k d S)  — first-run helper: create soc/pcie/ucie

(require 'cl-lib)
(require 'persp-mode nil 'noerror)
(require 'json)

;; --- Registry --------------------------------------------------------------

(defvar eda/registry-file
  (expand-file-name "eda-registry.el" doom-user-dir)
  "Where the daemon registry is persisted (machine-local).")

(defvar eda/daemons-alist nil
  "Registry of EDA daemons.
Each entry: (NAME . PLIST) where PLIST has keys:
  :root      -> default working directory for the daemon
  :ip-family -> short symbol, e.g. 'pcie
  :repo      -> git remote URL bound to this daemon, or nil
  :created   -> ISO timestamp string
  :notes     -> free-form string.")

(defun eda/registry-load ()
  "Load the daemon registry from disk."
  (when (file-readable-p eda/registry-file)
    (with-temp-buffer
      (insert-file-contents eda/registry-file)
      (setq eda/daemons-alist (read (current-buffer))))))

(defun eda/registry-save ()
  "Persist the registry to disk."
  (with-temp-file eda/registry-file
    (let ((print-level nil) (print-length nil))
      (insert ";; eda-registry.el — auto-generated, edit with care.\n")
      (prin1 eda/daemons-alist (current-buffer)))))

(eda/registry-load)

;; --- persp-mode state per daemon -------------------------------------------

(defun eda/persp-state-file (&optional name)
  "Return path to the persp-state file for the current (or NAME) daemon."
  (expand-file-name
   (format ".persp-state-%s.el"
           (or name (daemonp) "default"))
   doom-user-dir))

(defun eda/persp-save-on-shutdown ()
  "Save persp-mode workspaces on Emacs shutdown, namespaced by daemon."
  (when (and (featurep 'persp-mode) (daemonp))
    (let ((persp-auto-save-fname (file-name-nondirectory (eda/persp-state-file)))
          (persp-save-dir        (file-name-directory   (eda/persp-state-file))))
      (ignore-errors (persp-save-state-to-file persp-auto-save-fname)))))

(defun eda/persp-load-on-startup ()
  "Load this daemon's persp-mode state at startup."
  (when (and (featurep 'persp-mode) (daemonp)
             (file-readable-p (eda/persp-state-file)))
    (ignore-errors
      (persp-load-state-from-file (eda/persp-state-file)))))

(add-hook 'kill-emacs-hook       #'eda/persp-save-on-shutdown)
(add-hook 'emacs-startup-hook    #'eda/persp-load-on-startup)

;; --- Probing running daemons (system view, not registry) -------------------

(defun eda/--socket-dir ()
  "Return the per-user Emacs socket directory.
On macOS this resolves to $TMPDIR/emacs<uid>/; on Linux usually /tmp/emacs<uid>/."
  (let ((tmp (or (getenv "TMPDIR") "/tmp/")))
    (expand-file-name (format "emacs%d/" (user-uid))
                      (file-name-as-directory tmp))))

(defun eda/running-daemons ()
  "Return a list of daemon names currently running on this machine.
Discovers via socket files (more reliable than pgrep on macOS, where the
post-fork emacs-plus daemon rewrites argv and `--bg-daemon=<name>' no longer
appears in the command line). Excludes the default unnamed `server' socket."
  (let ((dir (eda/--socket-dir)))
    (when (file-directory-p dir)
      (cl-remove-if (lambda (n) (string= n "server"))
                    (directory-files dir nil "\\`[^.]")))))

(defun eda/daemon-running-p (name)
  "Return non-nil if a daemon named NAME is alive."
  (member name (eda/running-daemons)))

;; --- Spawning a new daemon --------------------------------------------------

(defun eda/--validate-name (name)
  "Sanity-check NAME (alnum + dashes only, 1-32 chars)."
  (unless (string-match-p "\\`[a-z0-9][a-z0-9-]\\{0,31\\}\\'" name)
    (user-error "Daemon name must match [a-z0-9][a-z0-9-]{0,31}: %s" name)))

(defun eda/spawn-daemon (name root)
  "Spawn `emacs --bg-daemon=NAME` with default-directory ROOT."
  (eda/--validate-name name)
  ;; Phase 16 (E11): the restricted client runs a SINGLE Emacs — no fleet.
  (when (and (fboundp 'eda/portable-daemon-stack-enabled-p)
             (not (eda/portable-daemon-stack-enabled-p)))
    (user-error
     "Daemon fleet disabled on profile `%s' (single Emacs only); set `eda/portable-allow-daemon-fleet' to override"
     (bound-and-true-p eda/portable-profile)))
  (when (eda/daemon-running-p name)
    (user-error "Daemon %s is already running" name))
  (unless (executable-find "emacs")
    (user-error "No `emacs' on PATH to spawn a daemon here"))
  (let ((default-directory (file-name-as-directory root)))
    (start-process (format "eda-spawn-%s" name) nil
                   (executable-find "emacs")
                   (format "--bg-daemon=%s" name))))

;;;###autoload
(defun eda/new-daemon (name root &optional ip-family notes repo)
  "Interactively create and spawn a new EDA daemon.
NAME is a short token; ROOT is its default working directory.
REPO, if non-nil and non-empty, is the git remote URL bound to this daemon.
When REPO is given and ROOT is empty/missing, ROOT will be cloned from REPO."
  (interactive
   (let* ((n (read-string "Daemon name (e.g. cxl, hbm-phy): "))
          (r (read-directory-name (format "Default root for %s: " n)
                                  "~/eda/wt/"))
          (f (intern (read-string "IP family symbol (e.g. cxl): " n)))
          (rp (read-string "Repo URL (blank = none): "))
          (notes (read-string "Notes (optional): ")))
     (list n r f notes (and (not (string-empty-p rp)) rp))))
  (eda/--validate-name name)
  (when (assoc name eda/daemons-alist)
    (user-error "%s already in registry; pick another name" name))
  (let ((root-abs (expand-file-name root)))
    ;; Repo binding: validate or clone before spawning.
    (when (and repo (not (string-empty-p repo)))
      (cond
       ((file-directory-p (expand-file-name ".git" root-abs))
        (let ((existing (string-trim
                         (shell-command-to-string
                          (format "git -C %s remote get-url origin 2>/dev/null"
                                  (shell-quote-argument root-abs))))))
          (cond
           ((string-empty-p existing)
            (user-error "%s is a git repo without an 'origin' remote; refusing to bind" root-abs))
           ((not (string= existing repo))
            (user-error "origin mismatch in %s: '%s' != '%s'" root-abs existing repo))
           (t (message "Path %s already a checkout of %s — reusing" root-abs repo)))))
       ((and (file-exists-p root-abs)
             (directory-files root-abs nil "\\`[^.]" t 1))
        (user-error "%s is non-empty and not a git repo; refusing to clone into it" root-abs))
       (t
        (make-directory (file-name-directory (directory-file-name root-abs)) t)
        (message "Cloning %s -> %s ..." repo root-abs)
        (unless (zerop (call-process "git" nil "*eda-clone*" t
                                     "clone" repo root-abs))
          (user-error "git clone failed; see *eda-clone* buffer")))))
    (push (cons name (list :root      root-abs
                           :ip-family ip-family
                           :repo      repo
                           :created   (format-time-string "%Y-%m-%dT%H:%M:%S")
                           :notes     notes))
          eda/daemons-alist)
    (eda/registry-save)
    (eda/spawn-daemon name root-abs)
    (message "Spawned daemon %s @ %s%s" name root-abs
             (if repo (format " (repo: %s)" repo) ""))))

;;;###autoload
(defun eda/seed-daemons ()
  "First-run helper: create the initial soc / pcie / ucie daemons."
  (interactive)
  (dolist (spec '(("soc"  "~/eda/wt/" soc  "SoC integration top-level")
                  ("pcie" "~/eda/wt/" pcie "PCIe Gen7 controller + PHY")
                  ("ucie" "~/eda/wt/" ucie "UCIe sideband + retimer + D2D")))
    (cl-destructuring-bind (name root family notes) spec
      (unless (assoc name eda/daemons-alist)
        (push (cons name (list :root      (expand-file-name root)
                               :ip-family family
                               :created   (format-time-string "%Y-%m-%dT%H:%M:%S")
                               :notes     notes))
              eda/daemons-alist))
      (unless (eda/daemon-running-p name)
        (eda/spawn-daemon name root))))
  (eda/registry-save)
  (message "Seeded daemons: soc, pcie, ucie"))

;; --- Listing ---------------------------------------------------------------

(define-derived-mode eda/daemons-mode tabulated-list-mode "EDA-Daemons"
  "Tabulated view of EDA daemons."
  (setq tabulated-list-format
        [("Name"     12 t)
         ("Running?"  8 t)
         ("Family"   10 t)
         ("Root"     30 t)
         ("Repo"     40 t)
         ("Notes"    30 nil)])
  (tabulated-list-init-header))

;;;###autoload
(defun eda/list-daemons ()
  "Pop up a buffer listing all EDA daemons + their status."
  (interactive)
  (let ((buf (get-buffer-create "*EDA Daemons*"))
        (running (eda/running-daemons)))
    (with-current-buffer buf
      (eda/daemons-mode)
      (setq tabulated-list-entries
            (cl-loop for (name . plist) in eda/daemons-alist
                     collect
                     (list name
                           (vector name
                                   (if (member name running) "yes" "no")
                                   (format "%s" (or (plist-get plist :ip-family) ""))
                                   (or (plist-get plist :root) "")
                                   (or (plist-get plist :repo) "")
                                   (or (plist-get plist :notes) "")))))
      (tabulated-list-print)
      (pop-to-buffer buf))))

;; --- Switching (attach) ----------------------------------------------------

;;;###autoload
(defun eda/switch-daemon (name)
  "Attach a new GUI frame to daemon NAME (or spawn it if dead)."
  (interactive
   (list (completing-read "Daemon: "
                          (mapcar #'car eda/daemons-alist) nil t)))
  (unless (eda/daemon-running-p name)
    (when-let ((root (plist-get (cdr (assoc name eda/daemons-alist)) :root)))
      (eda/spawn-daemon name root)
      (sleep-for 1)))
  (start-process (format "eda-attach-%s" name) nil
                 (executable-find "emacsclient")
                 "-s" name "-c" "-n"))

;; --- Kill ------------------------------------------------------------------

;;;###autoload
(defun eda/kill-daemon (name)
  "Kill daemon NAME. Asks twice to avoid accidents."
  (interactive
   (list (completing-read "Kill daemon: "
                          (eda/running-daemons) nil t)))
  (when (yes-or-no-p (format "Really kill daemon %s? " name))
    (when (yes-or-no-p (format "REALLY really? This may lose unsaved buffers in %s. " name))
      (call-process (executable-find "emacsclient") nil nil nil
                    "-s" name "-e" "(kill-emacs)")
      (message "Sent kill to %s" name))))

;;;###autoload
(defun eda/rename-daemon (old new)
  "Rename a daemon in the registry. Does NOT touch the running process.
Use only between sessions of OLD, or run eda/restart-daemon after."
  (interactive
   (let ((o (completing-read "Old name: " (mapcar #'car eda/daemons-alist) nil t)))
     (list o (read-string (format "Rename %s to: " o)))))
  (eda/--validate-name new)
  (when-let ((cell (assoc old eda/daemons-alist)))
    (setf (car cell) new)
    (eda/registry-save))
  (message "Renamed %s -> %s (registry only)" old new))

;;;###autoload
(defun eda/restart-daemon (name)
  "Kill + respawn daemon NAME, preserving its registry entry + persp state."
  (interactive
   (list (completing-read "Restart: " (mapcar #'car eda/daemons-alist) nil t)))
  (when (eda/daemon-running-p name)
    (call-process (executable-find "emacsclient") nil nil nil
                  "-s" name "-e" "(kill-emacs)")
    (sleep-for 2))
  (when-let ((root (plist-get (cdr (assoc name eda/daemons-alist)) :root)))
    (eda/spawn-daemon name root)
    (message "Restarted %s" name)))

;; --- Worktree pairing -----------------------------------------------------

;;;###autoload
(defun eda/new-worktree-for-task (repo branch task)
  "Convenience: create a worktree at ~/eda/wt/<task>/ off REPO/BRANCH.
When invoked inside an EDA daemon whose registry entry has :root set
to a checkout of its bound :repo, that path is used as the default for
the REPO prompt."
  (interactive
   (let* ((bound (and (daemonp)
                      (plist-get (cdr (assoc (daemonp) eda/daemons-alist)) :root)))
          (r (read-directory-name "Repo (main checkout): "
                                  (or bound "~/eda/")))
          (b (read-string "Branch / ref: " "main"))
          (ts (read-string "Task slug (e.g. pcie-gen7-link-init): ")))
     (list r b ts)))
  (let* ((wt (expand-file-name task (expand-file-name "~/eda/wt/"))))
    (call-process "git" nil "*eda-worktree*" t
                  "-C" repo "worktree" "add" "-b" task wt branch)
    (message "Worktree ready at %s" wt)
    (find-file (expand-file-name "." wt))))

;; --- Keybindings under SPC k d * ------------------------------------------
;; (existing SPC k bindings — k/c/R/r/b/s/S/t/K/e/v/T/x — are untouched;
;; we add a `d` sub-prefix below them).

(map! :leader
      (:prefix-map ("k d" . "eda daemons")
       :desc "New daemon"        "n" #'eda/new-daemon
       :desc "List daemons"      "l" #'eda/list-daemons
       :desc "Switch daemon"     "s" #'eda/switch-daemon
       :desc "Kill daemon"       "k" #'eda/kill-daemon
       :desc "Restart daemon"    "R" #'eda/restart-daemon
       :desc "Rename in registry" "r" #'eda/rename-daemon
       :desc "Seed soc/pcie/ucie" "S" #'eda/seed-daemons
       :desc "New worktree+task" "w" #'eda/new-worktree-for-task))

(provide 'eda-daemons)
;;; eda-daemons.el ends here
