;;; ~/.config/doom/eda-tasks.el  -*- lexical-binding: t; -*-
;;;
;;; Per-task project.org + org-agenda auto-discovery.
;;;
;;; Layout assumption:
;;;   ~/eda/wt/<task>/project.org   (one per worktree)
;;;
;;; The existing life.org Eisenhower-matrix capture (keys i/u/d/w/x) is
;;; NOT touched. Project captures live under a new top-level key "p".

(require 'org)
(require 'org-capture)
(require 'cl-lib)

(defvar eda/worktree-root (expand-file-name "~/eda/wt/")
  "Where all per-task worktrees live.")

(defvar eda/project-org-filename "project.org"
  "Name of the per-task org file inside each worktree.")

;; --- 1. agenda auto-discovery ----------------------------------------------

(defun eda/all-project-org-files ()
  "Return every project.org under eda/worktree-root (depth 2)."
  (when (file-directory-p eda/worktree-root)
    (let (acc)
      (dolist (wt (directory-files eda/worktree-root t "\\`[^.]"))
        (when (file-directory-p wt)
          (let ((f (expand-file-name eda/project-org-filename wt)))
            (when (file-readable-p f) (push f acc)))))
      acc)))

(defun eda/refresh-agenda-files ()
  "Re-scan worktrees + append project.org files to org-agenda-files.
Preserves any non-EDA files already in the list (e.g. life.org)."
  (interactive)
  (let* ((existing (cl-remove-if
                    (lambda (f) (string-prefix-p eda/worktree-root f))
                    (or org-agenda-files '())))
         (eda     (eda/all-project-org-files))
         (life    (list (expand-file-name "life.org" (or org-directory "~/")))))
    (setq org-agenda-files (delete-dups (append life existing eda)))))

;; Refresh on startup and whenever we save a project.org
(add-hook 'emacs-startup-hook #'eda/refresh-agenda-files)
(add-hook 'after-save-hook
          (lambda ()
            (when (and buffer-file-name
                       (string= (file-name-nondirectory buffer-file-name)
                                eda/project-org-filename))
              (eda/refresh-agenda-files))))

;; --- 2. project.org template (created on demand) ---------------------------

(defun eda/project-org-template (task)
  "Return string contents for a fresh project.org for TASK."
  (format
   "#+TITLE: %s
#+AUTHOR: Dinesh Bhardwaj
#+DATE: %s
#+CATEGORY: %s
#+FILETAGS: :eda:%s:
#+STARTUP: overview
#+TODO: TODO IN-PROGRESS BLOCKED REVIEW | DONE WONTDO

* Goal
  - One-line statement of what \"done\" means for this task.

* Context links
  - RTL roots: [[file:rtl/]]
  - Testbench: [[file:tb/]]
  - Sim build:  [[file:sim/]]
  - Spec / IP-XACT: TODO

* TODOs
** TODO Investigate / scoping
** TODO RTL implementation
** TODO Verification (UVM / cocotb / formal)
** TODO Coverage closure
** TODO Lint clean
** TODO PR + Forge review

* Debug log
  Append-only; timestamped entries.

* Decisions
  Capture the why, not the what. Cross-link to org-roam nodes.

* Open questions
  Things blocking forward progress; mention the human / link to chat.
"
   task
   (format-time-string "%Y-%m-%d")
   task task))

(defun eda/ensure-project-org (&optional dir)
  "Create project.org in DIR (default: current project root) if missing."
  (interactive)
  (let* ((root (or dir
                   (and (fboundp 'projectile-project-root) (projectile-project-root))
                   default-directory))
         (file (expand-file-name eda/project-org-filename root))
         (task (file-name-nondirectory (directory-file-name root))))
    (unless (file-exists-p file)
      (with-temp-file file
        (insert (eda/project-org-template task)))
      (message "Wrote %s" file))
    (find-file file)
    (eda/refresh-agenda-files)))

;; --- 3. New capture templates (NEW keys p* — do not collide with i/u/d/w/x)
;; Existing keys in config.el: i, u, d, w, x (all under top-level).
;; We use a new top-level key "p" for project-task capture so no collision.

(with-eval-after-load 'org
  (add-to-list 'org-capture-templates
               '("p" "Project task captures (per-worktree project.org)"))
  (add-to-list 'org-capture-templates
               `("pt" "Project TODO" entry
                 (function eda/-capture-target-todos)
                 "* TODO %?  %^g\n  CREATED: %U\n  %a\n"
                 :empty-lines 1))
  (add-to-list 'org-capture-templates
               `("pd" "Project debug log" entry
                 (function eda/-capture-target-debug)
                 "* %U  %?\n  %a\n"
                 :empty-lines 1))
  (add-to-list 'org-capture-templates
               `("pq" "Project quick note" item
                 (function eda/-capture-target-questions)
                 "- %?  %U\n"
                 :empty-lines 0)))

(defun eda/-current-project-org ()
  "Find the project.org for the current buffer/project."
  (let ((root (or (and (fboundp 'projectile-project-p)
                       (projectile-project-p)
                       (projectile-project-root))
                  default-directory)))
    (expand-file-name eda/project-org-filename root)))

(defun eda/-capture-target-todos ()
  (find-file (eda/-current-project-org))
  (goto-char (point-min))
  (re-search-forward "^\\* TODOs" nil t))

(defun eda/-capture-target-debug ()
  (find-file (eda/-current-project-org))
  (goto-char (point-min))
  (re-search-forward "^\\* Debug log" nil t))

(defun eda/-capture-target-questions ()
  (find-file (eda/-current-project-org))
  (goto-char (point-min))
  (re-search-forward "^\\* Open questions" nil t))

;; --- 4. Keybindings under SPC p e * (eda subset of projectile prefix) ------
;; Doom binds SPC p to project (projectile). We add EDA-specific commands
;; under "p e" so no collision with built-in projectile keys.

(map! :leader
      (:prefix-map ("p e" . "eda project")
       :desc "Open project.org"            "o" #'eda/ensure-project-org
       :desc "Refresh agenda from wt/"     "r" #'eda/refresh-agenda-files
       :desc "Capture TODO -> project"     "t" (lambda () (interactive) (org-capture nil "pt"))
       :desc "Capture debug -> project"    "d" (lambda () (interactive) (org-capture nil "pd"))
       :desc "Capture question -> project" "q" (lambda () (interactive) (org-capture nil "pq"))))

(provide 'eda-tasks)
;;; eda-tasks.el ends here
