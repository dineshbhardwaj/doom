;;; ~/.config/doom/eda-claude.el  -*- lexical-binding: t; -*-
;;;
;;; Claude workflow polish:
;;;   * Per-IP CLAUDE.md seeder (templates under CLAUDE-templates/)
;;;   * Per-worktree .claude/agents/ seeder (templates under agent-templates/)
;;;   * gptel inline-LLM wired to Anthropic (key from auth-source or env)
;;;   * SPC k a * — "agent on this file" commands
;;;
;;; Existing claude-code.el bindings under SPC k k/c/R/r/b/s/S/t/K/e/v/T/x
;;; and SPC k d * (eda-daemons) are untouched.

(require 'auth-source)
(require 'cl-lib)

;; --- 1. gptel (inline LLM) -------------------------------------------------

(use-package! gptel
  :defer t
  :config
  (setq gptel-default-mode 'org-mode)
  (let ((key (or (getenv "ANTHROPIC_API_KEY")
                 (ignore-errors
                   (auth-source-pick-first-password
                    :host "api.anthropic.com" :user "apikey")))))
    (when key
      (setq gptel-model   'claude-opus-4-7
            gptel-backend (gptel-make-anthropic "Claude"
                            :stream t
                            :key key)))))

;; ~/.authinfo format (chmod 600!):
;;   machine api.anthropic.com login apikey password sk-ant-XXXXXX

;; --- 2. Per-IP CLAUDE.md seeder -------------------------------------------

(defvar eda/claude-template-dir
  (expand-file-name "CLAUDE-templates/" doom-user-dir)
  "Directory of per-IP CLAUDE.md templates.")

(defvar eda/agent-template-dir
  (expand-file-name "agent-templates/" doom-user-dir)
  "Directory of .claude/agents/ template files.")

(defun eda/--available-ip-templates ()
  (when (file-directory-p eda/claude-template-dir)
    (mapcar #'file-name-base
            (directory-files eda/claude-template-dir t "\\.md\\'"))))

;;;###autoload
(defun eda/seed-claude-md (ip-family &optional dir)
  "Copy CLAUDE-templates/IP-FAMILY.md to DIR/CLAUDE.md."
  (interactive
   (list (completing-read "IP family: " (eda/--available-ip-templates) nil t)
         (read-directory-name
          "Target worktree: "
          (or (and (fboundp 'projectile-project-root) (projectile-project-root))
              "~/eda/wt/"))))
  (let ((src (expand-file-name (concat ip-family ".md") eda/claude-template-dir))
        (dst (expand-file-name "CLAUDE.md" dir)))
    (unless (file-exists-p src) (user-error "No template for %s" ip-family))
    (copy-file src dst t)
    (message "Seeded CLAUDE.md from %s -> %s" src dst)))

;;;###autoload
(defun eda/seed-claude-agents (&optional dir)
  "Drop the default subagents into DIR/.claude/agents/."
  (interactive
   (list (read-directory-name
          "Target worktree: "
          (or (and (fboundp 'projectile-project-root) (projectile-project-root))
              "~/eda/wt/"))))
  (let ((agents-dir (expand-file-name ".claude/agents/" dir))
        (count 0))
    (make-directory agents-dir t)
    (when (file-directory-p eda/agent-template-dir)
      (dolist (src (directory-files eda/agent-template-dir t "-agent\\.md\\'"))
        (let ((dst (expand-file-name (file-name-nondirectory src) agents-dir)))
          (copy-file src dst t)
          (cl-incf count))))
    (message "Seeded %d agent(s) under %s" count agents-dir)))

;; --- 3. SPC k a * — agent-on-this-file commands --------------------------
;;
;; These build a prompt that asks Claude Code to invoke a named sub-agent.
;; Requires claude-code.el (already configured in config.el).

(declare-function claude-code "claude-code")
(declare-function claude-code-send-command "claude-code")
(declare-function claude-code-toggle "claude-code")
(declare-function claude-code--get-buffer-name "claude-code")

(defun eda/--ensure-claude ()
  "Start a claude-code session if none exists."
  (unless (and (fboundp 'claude-code--get-buffer-name)
               (claude-code--get-buffer-name))
    (when (fboundp 'claude-code) (claude-code))))

;;;###autoload
(defun eda/claude-agent-review-buffer ()
  "Ask the rtl-review-agent to review the current buffer."
  (interactive)
  (let ((prompt (format
                 "Use the rtl-review-agent sub-agent to review %s. Output the checklist with file:line references."
                 (or (buffer-file-name) "<unsaved buffer>"))))
    (eda/--ensure-claude)
    (claude-code-send-command prompt)
    (claude-code-toggle)))

;;;###autoload
(defun eda/claude-agent-write-tb ()
  "Ask the verification-agent to expand cocotb tests for the current module."
  (interactive)
  (let ((prompt (format
                 "Use the verification-agent sub-agent to write/expand cocotb tests for %s. Run pytest afterwards."
                 (or (buffer-file-name) "<unsaved buffer>"))))
    (eda/--ensure-claude)
    (claude-code-send-command prompt)
    (claude-code-toggle)))

;;;###autoload
(defun eda/claude-agent-debug-fail ()
  "Triage the failure currently visible in *compilation* / *eda-*."
  (interactive)
  (let* ((log-buf (or (get-buffer "*compilation*")
                      (cl-find-if (lambda (b) (string-prefix-p "*eda-" (buffer-name b)))
                                  (buffer-list))))
         (snippet (and log-buf
                       (with-current-buffer log-buf
                         (buffer-substring-no-properties
                          (max (point-min) (- (point-max) 4000))
                          (point-max)))))
         (prompt (format
                  "Use the debug-agent sub-agent. Triage this simulation log. Identify the first symptom, list the 3 most-likely root causes, propose minimal experiments.\n\n%s"
                  (or snippet "<no log buffer found>"))))
    (eda/--ensure-claude)
    (claude-code-send-command prompt)
    (claude-code-toggle)))

;; --- 4. Keybindings — SPC k a * (no collision with SPC k d * or SPC k <letters>)

(map! :leader
      (:prefix-map ("k a" . "claude agents")
       :desc "RTL review (buffer)"    "r" #'eda/claude-agent-review-buffer
       :desc "Write/expand TB"        "t" #'eda/claude-agent-write-tb
       :desc "Debug failure"          "d" #'eda/claude-agent-debug-fail
       :desc "Seed CLAUDE.md"         "c" #'eda/seed-claude-md
       :desc "Seed .claude/agents/"   "a" #'eda/seed-claude-agents))

(provide 'eda-claude)
;;; eda-claude.el ends here
