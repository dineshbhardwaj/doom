;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; Place your private configuration here! Remember, you do not need to run 'doom
;; sync' after modifying this file!

;; Dinesh Archive
(setq package-archives '(("gnu" . "http://elpa.gnu.org/packages/")
                         ("org" . "http://orgmode.org/elpa/")
                         ("melpa" . "http://melpa.org/packages/")))

;;(package-refresh-contents)
;; Dinesh Over
;; Some functionality uses this to identify you, e.g. GPG configuration, email
;; clients, file templates and snippets. It is optional.
;; (setq user-full-name "John Doe"
;;       user-mail-address "john@doe.com")

;; Doom exposes five (optional) variables for controlling fonts in Doom:
;;
;; - `doom-font' -- the primary font to use
;; - `doom-variable-pitch-font' -- a non-monospace font (where applicable)
;; - `doom-big-font' -- used for `doom-big-font-mode'; use this for
;;   presentations or streaming.
;; - `doom-symbol-font' -- for symbols
;; - `doom-serif-font' -- for the `fixed-pitch-serif' face
;;
;; See 'C-h v doom-font' for documentation and more examples of what they
;; accept. For example:
;;
;;(setq doom-font (font-spec :family "Fira Code" :size 12 :weight 'semi-light)
;;      doom-variable-pitch-font (font-spec :family "Fira Sans" :size 13))
;;
;; If you or Emacs can't find your font, use 'M-x describe-font' to look them
;; up, `M-x eval-region' to execute elisp code, and 'M-x doom/reload-font' to
;; refresh your font settings. If Emacs still can't find your font, it likely
;; wasn't installed correctly. Font issues are rarely Doom issues!

;; There are two ways to load a theme. Both assume the theme is installed and
;; available. You can either set `doom-theme' or manually load a theme with the
;; `load-theme' function. This is the default:
(setq doom-theme 'doom-one)

;; This determines the style of line numbers in effect. If set to `nil', line
;; numbers are disabled. For relative line numbers, set this to `relative'.
(setq display-line-numbers-type t)

;; If you use `org' and don't want your org files in the default location below,
;; change `org-directory'. It must be set before org loads!
(setq org-directory "~/Dropbox/organist-dinesh/")                               
(setq org-roam-directory "~/Dropbox/org-roam/")

;; Index additional project-local knowledge bases beyond `org-roam-directory'.
;; org-roam natively scans only one root, so we advise its file lister to also
;; pull .org files from these extra dirs. Add more paths to the list as needed.
(defvar my/org-roam-extra-dirs '("~/eda/wt/feeds/kb/")
  "Extra directories org-roam should index in addition to `org-roam-directory'.")

(defun my/org-roam-list-files-extra (orig-fn &rest args)
  "Append .org files from `my/org-roam-extra-dirs' to org-roam's file list."
  (append (apply orig-fn args)
          (cl-loop for dir in my/org-roam-extra-dirs
                   for full = (expand-file-name dir)
                   when (file-directory-p full)
                   append (directory-files-recursively
                           full
                           (concat "\\.\\(?:" (mapconcat #'regexp-quote
                                                         org-roam-file-extensions "\\|")
                                   "\\)\\'")))))

(advice-add 'org-roam-list-files :around #'my/org-roam-list-files-extra)

;; Whenever you reconfigure a package, make sure to wrap your config in an
;; `after!' block, otherwise Doom's defaults may override your settings. E.g.
;;
;;   (after! PACKAGE
;;     (setq x y))
;;
;; The exceptions to this rule:
;;
;;   - Setting file/directory variables (like `org-directory')
;;   - Setting variables which explicitly tell you to set them before their
;;     package is loaded (see 'C-h v VARIABLE' to look up their documentation).
;;   - Setting doom variables (which start with 'doom-' or '+').
;;
;; Here are some additional functions/macros that will help you configure Doom.
;;
;; - `load!' for loading external *.el files relative to this one
;; - `use-package!' for configuring packages
;; - `after!' for running code after a package has loaded
;; - `add-load-path!' for adding directories to the `load-path', relative to
;;   this file. Emacs searches the `load-path' when you load packages with
;;   `require' or `use-package'.
;; - `map!' for binding new keys
;;
;; To get information about any of these functions/macros, move the cursor over
;; the highlighted symbol at press 'K' (non-evil users must press 'C-c c k').
;; This will open documentation for it, including demos of how they are used.
;; Alternatively, use `C-h o' to look up a symbol (functions, variables, faces,
;; etc).
;;
;; You can also try 'gd' (or 'C-c c d') to jump to their definition and see how
;; they are implemented.

(after! elfeed
  ;; --- Basic elfeed ---
  ;; Show a 📺 prefix on YouTube entries in the search buffer
  (defface elfeed-youtube
    '((t :inherit elfeed-search-title-face :foreground "#ff4444"))
    "Face for YouTube entries in elfeed-search.")

  (push '(youtube elfeed-youtube) elfeed-search-face-alist)
  (setq elfeed-search-filter "@1-month-ago +unread"
        rmh-elfeed-org-files (list "~/Dropbox/elfeed-feed/elfeed2.org")
        elfeed-goodies/entry-pane-position 'bottom)

  ;; --- elfeed-score ---
  (require 'elfeed-score)
  (elfeed-score-enable)
  (setq elfeed-score-score-file (expand-file-name "elfeed.score" doom-user-dir)
        elfeed-search-sort-function #'elfeed-score-sort)

  ;; --- elfeed-tube: YouTube transcripts & metadata ---
  (require 'elfeed-tube)
  (elfeed-tube-setup)
  (setq elfeed-tube-auto-save-p nil       ; don't auto-save transcripts to DB
        elfeed-tube-auto-fetch-p t)        ; auto-fetch when entry is opened

  ;; --- elfeed-tube-mpv: play YouTube with timestamp jumps ---
  (require 'elfeed-tube-mpv)

  ;; --- Keybindings (Doom-style) ---
  (map! :map elfeed-search-mode-map
        "="   #'elfeed-score-load-score-file
        "C-=" #'elfeed-score-explain
        "F"   #'elfeed-tube-fetch         ; force-fetch transcript for entry
        [remap save-buffer] #'elfeed-tube-save)

  (map! :map elfeed-show-mode-map
        "F"   #'elfeed-tube-fetch
        "C-c C-f" #'elfeed-tube-mpv-follow-mode   ; scroll transcript as video plays
        "C-c C-w" #'elfeed-tube-mpv-where         ; jump transcript to current video time
        [remap save-buffer] #'elfeed-tube-save))

;; --- elfeed-summary: dashboard view ---
;; ══════════════════════════════════════════════════════════════════════
;; elfeed-summary dashboard configuration
;; Matches the three-tier feed structure from elfeed2.org
;; Place this inside your config.el, replacing the old use-package! block
;; ══════════════════════════════════════════════════════════════════════

(use-package! elfeed-summary
  :after elfeed
  :commands (elfeed-summary)
  :config
  (setq elfeed-summary-settings
        '(;; ───────────────────────────────────────────────────────────
          ;; TIER 1 — PRIMARY WORK DOMAIN
          ;; ───────────────────────────────────────────────────────────
          (group (:title . "━━━ PRIMARY: Semiconductor Work Domain ━━━")
                 (:face . (:foreground "#ff6b35" :weight bold))
                 (:elements
                  (group (:title . "🚀 OpenROAD / Open-Silicon Progress")
                         (:elements (query . opensilicon)))
                  (group (:title . "🤖 AI in Semiconductor")
                         (:elements (query . ai-semi)))
                  (group (:title . "💰 Semi Startups & Funding (Global)")
                         (:elements (query . (and (or startup funding)
                                                  (not india)))))
                  (group (:title . "🇮🇳 India — Semiconductor & Deep-tech")
                         (:elements (query . india)))
                  (group (:title . "🏭 Core Semiconductor Industry")
                         (:elements (query . (and semi
                                                  (not india)
                                                  (not ai-semi)
                                                  (not opensilicon)))))
                  (group (:title . "⚙️ VLSI / EDA / Chip Design")
                         (:elements (query . (and vlsi (not youtube)))))
                  (group (:title . "🔌 Embedded Systems / MCU / SBC")
                         (:elements (query . (and embedded (not linux)))))
                  (group (:title . "🐧 Embedded Linux")
                         (:elements (query . (and embedded linux))))
                  (group (:title . "🔧 PCB / Manufacturing / SMT")
                         (:elements (query . (or pcb mfg))))
                  (group (:title . "🏗️ Fabs / Lithography / Equipment")
                         (:elements (query . (or fabs lithography equipment))))
                  (group (:title . "📺 YouTube — Chip Design & Analysis")
                         (:elements (query . youtube)))
                  (group (:title . "📡 Hacker News — Semi Radar")
                         (:elements (query . (and hn
                                                  (not opensilicon)
                                                  (not ai-semi)
                                                  (not funding)))))
                  (group (:title . "🔬 Research (arXiv / Nature / Open Silicon)")
                         (:elements (query . research)))
                  (group (:title . "📉 Specialty (Photonics / Power / Compound)")
                         (:elements (query . specialty)))
                  (group (:title . "💹 Finance & Markets (Semi lens)")
                         (:elements (query . finance)))))

          ;; ───────────────────────────────────────────────────────────
          ;; TIER 2 — ACTIVE SECONDARY INTERESTS
          ;; ───────────────────────────────────────────────────────────
          (group (:title . "━━━ SECONDARY: Active Reading ━━━")
                 (:face . (:foreground "#4a90e2" :weight bold))
                 (:elements
                  (group (:title . "⭐ Must-read Tech")
                         (:elements (query . mustread)))
                  (group (:title . "📰 General News")
                         (:elements (query . (and news (not mustread)))))
                  (group (:title . "💻 Technology (General)")
                         (:elements (query . (and technology (not mustread)))))
                  (group (:title . "📚 Magazines / Long-form")
                         (:elements (query . magazine)))))

          ;; ───────────────────────────────────────────────────────────
          ;; META — catches anything untagged or uncategorized
          ;; ───────────────────────────────────────────────────────────
          (group (:title . "━━━ META ━━━")
                 (:face . (:foreground "#888888"))
                 (:elements
                  (group (:title . "⚠️ Uncategorized (check tagging)")
                         (:elements (query . (not (or opensilicon ai-semi india
                                                      semi vlsi embedded pcb mfg
                                                      fabs lithography equipment
                                                      youtube hn specialty
                                                      research finance startup
                                                      funding news technology
                                                      magazine mustread)))))
                  (search (:filter . "@6-months-ago +unread")
                          (:title . "📬 All unread (last 6 months)"))
                  (search (:filter . "@1-week-ago")
                          (:title . "🗓️ Everything this week"))
                  (search (:filter . "+starred")
                          (:title . "⭐ Starred items"))))))

  ;; Other useful summary options
  (setq elfeed-summary-look-back (* 60 60 24 30)  ; last 30 days in summary
        elfeed-summary-refresh-on-each-update t   ; refresh dashboard on update
        elfeed-summary-default-filter "@1-month-ago "))

;; Keybinding — opens the dashboard
(map! :leader
      :desc "Elfeed Summary Dashboard" "o R" #'elfeed-summary)

;; Bind dashboard to SPC o R (capital R to distinguish from plain elfeed SPC o r)
(map! :leader
      :desc "Elfeed Summary Dashboard" "o R" #'elfeed-summary)

;; slime
(after! slime
  (load (expand-file-name "~/quicklisp/slime-helper.el"))
  (setq inferior-lisp-program "/opt/homebrew/bin/sbcl")
  :config ; runs this when slime loads
  (set-repl-handler! 'lisp-mode #'sly-mrepl)
  (set-eval-handler! 'lisp-mode #'sly-eval-region)
  (set-lookup-handlers! 'lisp-mode
    :definition #'sly-edit-definition
    :documentation #'sly-describe-symbol)
  (require 'slime-autoloads)
  (setq slime-lisp-implementations
           '((sbcl ("/opt/homebrew/bin/sbcl"))))
           ;; not in brew '((sbcl ("/opt/homebrew/bin/sbcl" "--core" "sbcl.core-for-slime"))))
  (add-hook 'lisp-mode-hook #'rainbow-delimiters-mode))
(setq projectile-project-search-path '("~/projects/" "~/code/" ("~/github" . 1)))

(after! org
  (add-to-list 'org-capture-templates
             '("i" "Important-Urgent" entry
               (file+headline "~/Dropbox/organist-dinesh/life.org" "IMPORTANT_URGENT")
               "* TODO %? %^g\nSCHEDULED: %^{Scheduled}t DEADLINE: %^{Deadline}t\n"
               :kill-buffer t))
  (add-to-list 'org-capture-templates
               '("u" "UnImportant-Urgent" entry
              (file+headline "~/Dropbox/organist-dinesh/life.org" "UNIMPORTANT_URGENT")

               "* TODO %? %^g\nSCHEDULED: %^{Scheduled}t DEADLINE: %^{Deadline}t\n"
               :kill-buffer t))
  (add-to-list 'org-capture-templates
               '("d" "Important-UnUrgent" entry
               (file+headline "~/Dropbox/organist-dinesh/life.org" "IMPORTANT_UNURGENT")
               "* TODO %? %^g\nSCHEDULED: %^{Scheduled}t DEADLINE: %^{Deadline}t\n"
               :kill-buffer t))
  (add-to-list 'org-capture-templates
               '("w" "UnImportant-Urgent" entry
               (file+headline "~/Dropbox/organist-dinesh/life.org" "UNIMPORTANT_UNURGENT")
               "* TODO %? %^g\nSCHEDULED: %^{Scheduled}t DEADLINE: %^{Deadline}t\n"
               :kill-buffer t))
  (add-to-list 'org-capture-templates
               '("x" "Raw" entry
               (file+headline "~/Dropbox/organist-dinesh/life.org" "UNIMPORTANT_UNURGENT")
               "* TODO %? %^g\nSCHEDULED: %^{Scheduled}t DEADLINE: %^{Deadline}t\n"
               :kill-buffer t))

  ;; Doom's built-in project-todo templates ("pt" project-local, "ot"
  ;; centralized) ship without any date prompt. Rewrite them in place to prompt
  ;; for real SCHEDULED/DEADLINE planning dates (a planning line right after the
  ;; heading — not a property, so the agenda actually treats them as such).
  (dolist (key '("pt" "ot"))
    (when-let ((tmpl (assoc key org-capture-templates)))
      (setf (nth 4 tmpl)
            "* TODO %?\nSCHEDULED: %^{Scheduled}t DEADLINE: %^{Deadline}t\n%i\n%a")))

  ;; --- Central project-task capture (choose project -> projects.org) --------
  ;; All project tasks live in ONE central file under `org-directory' (which the
  ;; agenda already scans), nested under a per-project heading. Always prompts
  ;; for the project/worktree AND for SCHEDULED/DEADLINE, so a new task is picked
  ;; up by the agenda immediately -- no scattered todo.org files per worktree.
  (defvar my/org-capture-projects-file "projects.org"
    "Central projects file (relative to `org-directory') for the `P' capture.")

  (defun my/org--project-headings (file)
    "Level-1 heading titles already present in FILE, for completion."
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let (heads)
          (goto-char (point-min))
          (while (re-search-forward "^\\* +\\(.+?\\)[ \t]*$" nil t)
            (push (match-string-no-properties 1) heads))
          (nreverse heads)))))

  (defun my/org-capture-project-todo-target ()
    "Prompt for a project/worktree and locate the capture point under its
heading in the central projects file, creating the heading if needed. The
candidate list is every worktree under the EDA root plus any project heading
that already exists in the file (free text also accepted)."
    (let* ((file (expand-file-name my/org-capture-projects-file org-directory))
           (choices (delete-dups
                     (append (and (fboundp 'eda/task--worktree-dirs)
                                  (ignore-errors (eda/task--worktree-dirs)))
                             (my/org--project-headings file))))
           (project (completing-read "Project/worktree: " choices nil nil)))
      (set-buffer (org-capture-target-buffer file))
      (org-capture-put-target-region-and-position)
      (widen)
      (goto-char (point-min))
      (+org--capture-ensure-heading (list project))))

  (add-to-list 'org-capture-templates
               '("P" "Project task (choose project -> central projects.org)" entry
                 (function my/org-capture-project-todo-target)
                 "* TODO %? %^g\nSCHEDULED: %^{Scheduled}t DEADLINE: %^{Deadline}t\n"
                 :prepend t))
)

;; temp (use-package! org-super-agenda
;; temp   :after org-agenda
;; temp   :init
;; temp   (setq org-agenda-skip-scheduled-if-done t
;; temp       org-agenda-skip-deadline-if-done t
;; temp       org-agenda-include-deadlines t
;; temp       org-agenda-block-separator nil
;; temp       org-agenda-compact-blocks t
;; temp       org-agenda-start-day nil ;; i.e. today
;; temp       org-agenda-span 1
;; temp       org-agenda-start-on-weekday nil)
;; temp   (setq org-agenda-custom-commands
;; temp         '(("c" "Super view"
;; temp            (
;; temp             (alltodo "" ((org-agenda-overriding-header "")
;; temp                          (org-super-agenda-groups
;; temp                           '((:log t)
;; temp                             (:name "Highest Priority"
;; temp                                    :and (:priority "A" :tag ("Important" "Urgent"))
;; temp                                    :todo "STRT"
;; temp                                    :order 1)
;; temp                             (:name "Urgent-Important"
;; temp                                    :and (:tag "Urgent" :tag "Important" :deadline (today past))
;; temp                                    :and (:tag "Urgent" :tag "Important" :scheduled (today past))
;; temp                                    :order 2)
;; temp                             (:name "Urgent-UnImportant"
;; temp                                    :and (:tag "Urgent" :not (:tag "Important") :deadline (today past))
;; temp                                    :and (:tag "Urgent" :not (:tag "Important") :scheduled (today past))
;; temp                                    :order 3)
;; temp                             (:name "Important-UnUrgent"
;; temp                                    :and (:tag "Important" :not (:tag "Urgent") :deadline (today past))
;; temp                                    :and (:tag "Important" :not (:tag "Urgent") :scheduled (today past))
;; temp                                    :order 4)
;; temp                             (:name "UnImportant-UnUrgent"
;; temp                                    :and (:not (:tag "Important") :not (:tag "Urgent") :deadline (today past))
;; temp                                    :and (:not (:tag "Important") :not (:tag "Urgent") :scheduled (today past))
;; temp                                    :order 5)
;; temp                             (:name "Scheduled Soon"
;; temp                                    :scheduled future
;; temp                                    :order 6)
;; temp                             (:name "Meetings"
;; temp                                    :and (:todo "MEET" :scheduled future)
;; temp                                    :order 7)
;; temp                             (:discard (:not (:todo "TODO")))))))
;; temp             (agenda "" ((org-agenda-overriding-header "")
;; temp                         (org-super-agenda-groups
;; temp                          '((:name "Today"
;; temp                                   :time-grid t
;; temp                                   :date today
;; temp                                   :order 1)))))
;; temp
;; temp                         ))))
;; temp   :config
;; temp   (org-super-agenda-mode))
(after! hy-mode
  (setq hy-jedhy--enable? nil))
;; claud recommendation started from here
;;
;; ════════════════════════════════════════════════════════════════════
;; PATH SETUP — ensure Emacs sees node/npm/claude binaries
;; ════════════════════════════════════════════════════════════════════
(use-package! exec-path-from-shell
  :config
  (when (or (memq window-system '(mac ns x)) (daemonp))
    (exec-path-from-shell-initialize)))


;; vterm — make sure the module compiles cleanly
(use-package! vterm
  :defer t
  ;; Compile the native module automatically on first load instead of
  ;; prompting. In a headless daemon (the Linux faraday box) the compile
  ;; prompt can't be answered, so `(require 'vterm)' fails, `:after vterm'
  ;; below never fires, and claude-code silently keeps its `eat' default.
  ;; Auto-compiling makes vterm actually load there. Needs cmake + a C
  ;; compiler + libtool present on the box.
  :init
  (setq vterm-always-compile-module t)
  :config
  (setq vterm-max-scrollback 10000
        ;; Use the box's real login shell rather than hardcoding zsh. The old
        ;; `(or (executable-find "zsh") "/bin/bash")' launched *any* zsh found
        ;; on the daemon's exec-path even when it wasn't the login shell — on
        ;; faraday that picked up a broken/stray zsh that segfaulted on start
        ;; ("zsh: segmentation fault"). $SHELL is populated by
        ;; exec-path-from-shell above, so this resolves to zsh on the Mac and
        ;; bash on faraday, with a hard fallback if $SHELL is somehow unset.
        vterm-shell (or (getenv "SHELL") (executable-find "bash") "/bin/bash")
        ;; Snappier redraw — helps with Claude Code's interactive prompts
        ;; (default 0.1 s leaves cursor / selection visibly lagging).
        vterm-timer-delay 0.02)

  ;; --- C-\ : toggle a scroll / copy mode over the terminal ----------------
  ;; From live interaction, C-\ enters `vterm-copy-mode' in evil NORMAL state
  ;; so the scrollback becomes a normal editable-feeling buffer: scroll with
  ;; C-u/C-d/j/k, `v' to visually select, `y' to copy to the kill-ring, `p'
  ;; to paste the kill-ring straight into the terminal (which drops you back
  ;; into interaction). C-\ again — with nothing to paste — also returns to
  ;; live Claude interaction. C-\ is the ONLY deliberate way out of the
  ;; terminal, which is what lets ESC stay reserved for Claude (below).
  (defun +eda/vterm-toggle-copy-mode ()
    "Toggle vterm scroll/copy mode; return to live interaction when leaving."
    (interactive)
    (if (bound-and-true-p vterm-copy-mode)
        (progn (vterm-copy-mode -1)
               (when (fboundp 'evil-emacs-state) (evil-emacs-state)))
      (vterm-copy-mode 1)
      (when (fboundp 'evil-normal-state) (evil-normal-state))))

  (defun +eda/vterm-copy-mode-paste ()
    "Leave scroll/copy mode and paste the kill-ring into the terminal."
    (interactive)
    (when (bound-and-true-p vterm-copy-mode) (vterm-copy-mode -1))
    (when (fboundp 'evil-emacs-state) (evil-emacs-state))
    (vterm-yank))

  ;; ESC must reach the TUI inside vterm (Claude Code interrupt, popup
  ;; cancel, /clear, etc.). Without this, evil swallows the first ESC to
  ;; switch state and the child process never sees it. C-\ is the toggle in.
  (map! :map vterm-mode-map
        :ie "<escape>" #'vterm-send-escape
        :ie "C-\\"     #'+eda/vterm-toggle-copy-mode)

  ;; Inside scroll/copy mode: C-\ (any state) returns to interaction; `p'
  ;; pastes into the terminal; `v'/`y' are evil's own visual-select + yank.
  (map! :map vterm-copy-mode-map
        "C-\\"    #'+eda/vterm-toggle-copy-mode
        :n "C-\\" #'+eda/vterm-toggle-copy-mode
        :v "C-\\" #'+eda/vterm-toggle-copy-mode
        :n "p"    #'+eda/vterm-copy-mode-paste))

;; A finished Claude/shell leaves its vterm buffer ALIVE but with a dead
;; process; any key-send then throws "Process vterm<N> not running: finished"
;; (from our ESC/RET bindings AND claude-code's own send commands). Guard the
;; low-level senders so a dead terminal gives a friendly hint — for a Claude
;; buffer, how to resume — instead of a raw error. Only the already-broken
;; dead-process case changes; a live process (or a non-vterm buffer) is passed
;; straight through. Named advice ⇒ idempotent across `doom/reload'.
(after! vterm
  (defun +eda/vterm-guard-send (orig &rest args)
    "Around-advice: skip a vterm send (with a hint) when the process has finished."
    (if (and (derived-mode-p 'vterm-mode)
             (not (process-live-p (get-buffer-process (current-buffer)))))
        (message "Terminal process has finished — nothing to send.%s"
                 (if (string-match-p "\\*claude" (buffer-name))
                     " Resume with SPC k o j (or q to bury, C-x k to kill)."
                   " Press q to bury / C-x k to kill this buffer."))
      (apply orig args)))
  (dolist (fn '(vterm-send-key vterm-send-string vterm-yank))
    (when (fboundp fn) (advice-add fn :around #'+eda/vterm-guard-send))))

;; Belt-and-suspenders: ensure new vterm buffers start in evil emacs
;; state (no key interception) regardless of what claude-code or other
;; packages try to do.
(after! evil
  (evil-set-initial-state 'vterm-mode 'emacs))


;; ════════════════════════════════════════════════════════════════════
;; CLAUDE CODE
;; ════════════════════════════════════════════════════════════════════
;; claude-code defaults to the pure-elisp `eat' terminal backend, which
;; renders TUI prompts (the question popups, selection lists, etc.) with
;; visible drift: cursor positioned before the prompt, selection drawn
;; below, occasional overwrite of the visible region. The libvterm-based
;; `vterm' backend handles the alternate-screen + rapid redraw cleanly.
;; After changing this, kill any existing *claude:*<eat> buffer and start
;; a fresh session with SPC k k — backend choice is buffer-creation-time.
;; Force the vterm backend on EVERY platform. This is set at top level — NOT
;; only inside the `:after vterm' block below — so the choice holds even if
;; vterm hasn't loaded yet. Previously the backend was set only in `:config',
;; so on any box where vterm failed to load (the Linux daemon, whose vterm
;; module wasn't compiled) the `:config' never ran and claude-code silently
;; kept its `eat' default. That's why the same config gave the Mac vterm and
;; Linux eat. With vterm now auto-compiling (above) it loads on Linux too, and
;; this top-level setq guarantees we never silently degrade to eat again.
(setq claude-code-terminal-backend 'vterm)
(use-package! claude-code
  :after vterm
  :config
  (setq claude-code-terminal-backend 'vterm)
  (claude-code-mode 1))

;; ════════════════════════════════════════════════════════════════════
;; FORGE — GitHub integration
;; ════════════════════════════════════════════════════════════════════
(use-package! forge
  :after magit
  :config
  (setq forge-topic-list-limit '(60 . 0)))

;; ════════════════════════════════════════════════════════════════════
;; CLAUDE + ELFEED HELPERS
;; ════════════════════════════════════════════════════════════════════

(defun my/claude-summarize-entry ()
  "Send the current elfeed entry to Claude for summarization."
  (interactive)
  (unless (eq major-mode 'elfeed-show-mode)
    (user-error "Run this from an elfeed entry buffer"))
  (let* ((entry elfeed-show-entry)
         (title (elfeed-entry-title entry))
         (link (elfeed-entry-link entry))
         (content (elfeed-deref (elfeed-entry-content entry)))
         (prompt (format
                  "Summarize this article in 4-5 bullet points, focused on what's relevant to a semiconductor/VLSI engineer. Then list any specific companies, technologies, or papers mentioned that are worth following up on.\n\nTitle: %s\nURL: %s\n\nContent:\n%s"
                  title link content)))
    (unless (claude-code--get-buffer-name)
      (claude-code))
    (claude-code-send-command prompt)
    (claude-code-toggle)))

(defun my/claude-extract-action-items ()
  "Ask Claude to extract action items from the current elfeed entry."
  (interactive)
  (unless (eq major-mode 'elfeed-show-mode)
    (user-error "Run this from an elfeed entry buffer"))
  (let* ((entry elfeed-show-entry)
         (content (elfeed-deref (elfeed-entry-content entry)))
         (prompt (format
                  "Read this article. Extract any concrete action items I should take as a VLSI/semiconductor engineer — papers to read, tools to try, GitHub repos to star, conferences to attend, deadlines to note. Be specific. If there are none, say so.\n\n%s"
                  content)))
    (unless (claude-code--get-buffer-name)
      (claude-code))
    (claude-code-send-command prompt)
    (claude-code-toggle)))

(defun my/claude-cross-reference-feeds (filter)
  "Ask Claude to find patterns across recent feed entries matching FILTER."
  (interactive (list (read-string "Elfeed filter: " "+opensilicon @1-week-ago")))
  (let ((entries-text ""))
    (with-current-buffer (get-buffer-create "*elfeed-search*")
      (elfeed-search-set-filter filter)
      (sit-for 1)
      (setq entries-text (buffer-substring-no-properties (point-min) (point-max))))
    (let ((prompt (format
                   "Below is a list of article titles from my RSS feeds matching the filter '%s'. Identify recurring themes, surprising developments, and connections. Highlight 3-5 takeaways most useful for a semiconductor/VLSI engineer.\n\n%s"
                   filter entries-text)))
      (unless (claude-code--get-buffer-name)
        (claude-code))
      (claude-code-send-command prompt)
      (claude-code-toggle))))

;; ════════════════════════════════════════════════════════════════════
;; CLAUDE + CODE HELPERS
;; ════════════════════════════════════════════════════════════════════

(defun my/claude-explain-code ()
  "Send selected code (or current function) to Claude with explain prompt."
  (interactive)
  (let* ((code (if (use-region-p)
                   (buffer-substring-no-properties (region-beginning) (region-end))
                 (thing-at-point 'defun)))
         (prompt (format
                  "Explain this code. Focus on: (1) what it does at a high level, (2) any non-obvious tricks, (3) potential bugs or edge cases. Be concise.\n\n```\n%s\n```"
                  code)))
    (unless (claude-code--get-buffer-name)
      (claude-code))
    (claude-code-send-command prompt)
    (claude-code-toggle)))

(defun my/claude-review-verilog ()
  "Send selected region or buffer to Claude for Verilog review."
  (interactive)
  (let* ((code (if (use-region-p)
                   (buffer-substring-no-properties (region-beginning) (region-end))
                 (buffer-substring-no-properties (point-min) (point-max))))
         (prompt (format
                  "Review this Verilog/SystemVerilog code as an experienced VLSI engineer. Check for: synthesizability issues, clock domain crossings, race conditions, lint violations (unused signals, latches, blocking vs non-blocking misuse), and style consistency. Suggest concrete improvements.\n\n```verilog\n%s\n```"
                  code)))
    (unless (claude-code--get-buffer-name)
      (claude-code))
    (claude-code-send-command prompt)
    (claude-code-toggle)))

(defun my/claude-write-testbench ()
  "Ask Claude to write a testbench for the current Verilog module."
  (interactive)
  (let* ((code (buffer-substring-no-properties (point-min) (point-max)))
         (prompt (format
                  "Write a SystemVerilog testbench for this module. Include: (1) clock and reset generation, (2) stimulus that exercises corner cases, (3) self-checking via assertions, (4) coverage points for important behaviors. Make it synthesizable for simulation only — no UVM unless I ask.\n\n```verilog\n%s\n```"
                  code)))
    (unless (claude-code--get-buffer-name)
      (claude-code))
    (claude-code-send-command prompt)
    (claude-code-toggle)))

(defun my/claude-explain-error ()
  "Send the error message at point to Claude."
  (interactive)
  (let* ((err-text (thing-at-point 'paragraph t))
         (prompt (format
                  "I'm getting this error/log output. Explain what it means and the most likely fix:\n\n%s"
                  err-text)))
    (unless (claude-code--get-buffer-name)
      (claude-code))
    (claude-code-send-command prompt)
    (claude-code-toggle)))

;; ════════════════════════════════════════════════════════════════════
;; KEYBINDINGS — Using safer leader prefixes
;; SPC k = Claude (think "kAI"/"chat with kClaude")
;; SPC g = git/forge (Doom default — augmenting it)
;; SPC m = my LLM/feed helpers
;; ════════════════════════════════════════════════════════════════════

;; Claude commands under SPC k
(map! :leader
      (:prefix-map ("k" . "claude")
       :desc "Start Claude Code"        "k" #'claude-code
       :desc "Continue last session"    "c" #'claude-code-continue
       :desc "Resume past session"      "R" #'claude-code-resume
       :desc "Send region"              "r" #'claude-code-send-region
       :desc "Send buffer"              "b" #'claude-code-send-buffer
       :desc "Send command"             "s" #'claude-code-send-command
       :desc "Switch session"           "S" #'claude-code-switch-to-buffer
       :desc "Toggle window"            "t" #'claude-code-toggle
       :desc "Kill session"             "K" #'claude-code-kill
       :desc "Explain code"             "e" #'my/claude-explain-code
       :desc "Review Verilog"           "v" #'my/claude-review-verilog
       :desc "Write testbench"          "T" #'my/claude-write-testbench
       :desc "Explain error"            "x" #'my/claude-explain-error))

;; My LLM/feed helpers under SPC m
(map! :leader
      (:prefix-map ("m" . "my-tools/feeds")
       :desc "Summarize entry"          "s" #'my/claude-summarize-entry
       :desc "Extract action items"     "a" #'my/claude-extract-action-items
       :desc "Cross-reference feeds"    "f" #'my/claude-cross-reference-feeds))

;; Forge bindings — use Doom's existing SPC g prefix without conflicting
;; Doom already has SPC g as a prefix; we add Forge commands under SPC g f
(after! magit
  (map! :leader
        :desc "Forge dispatch"      "g f" #'forge-dispatch
        :desc "List PRs"            "g R" #'forge-list-pullreqs   ; capital R to avoid Doom defaults
        :desc "List issues"         "g I" #'forge-list-issues
        :desc "Create PR"           "g N" #'forge-create-pullreq))
;; eat programming with keys working
(after! eat
  ;; Let eat-yank handle pastes properly inside the terminal buffer
  (setq eat-enable-yank-to-terminal t)

  ;; Route Cmd+V (macOS) and Ctrl+Shift+V (Linux) through eat-yank
  (define-key eat-semi-char-mode-map [?\s-v]    #'eat-yank)   ; macOS Cmd+V
  (define-key eat-char-mode-map      [?\s-v]    #'eat-yank)
  (define-key eat-semi-char-mode-map (kbd "C-S-v") #'eat-yank) ; Linux
  (define-key eat-char-mode-map      (kbd "C-S-v") #'eat-yank))

;; ════════════════════════════════════════════════════════════════════
;; EDA — Portability / host profile / tool discovery (phase 8, layer 0)
;; Loaded FIRST so its path roots become the canonical values the later
;; eda-* modules inherit. Pure refactor on the Mac (defaults unchanged).
;; ════════════════════════════════════════════════════════════════════
(load! "eda-portable")

;; ════════════════════════════════════════════════════════════════════
;; EDA — SystemVerilog stack (phase 2)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-sv")

;; ════════════════════════════════════════════════════════════════════
;; EDA — Dynamic daemon orchestration (phase 3)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-daemons")

;; ════════════════════════════════════════════════════════════════════
;; EDA — Per-task project.org + agenda auto-discovery (phase 4)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-tasks")

;; ════════════════════════════════════════════════════════════════════
;; EDA — Compile / sim / wave / formal wrappers (phase 5)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-sim")

;; ════════════════════════════════════════════════════════════════════
;; EDA — Claude polish: per-IP CLAUDE.md, agents, gptel (phase 6)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-claude")

;; ════════════════════════════════════════════════════════════════════
;; EDA — Per-workspace role-specialised Claude sessions (phase 7)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-workspace-claude")

;; ════════════════════════════════════════════════════════════════════
;; EDA — Org task engine: schema + task-jump (phase 8, layers 1–2)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-task-engine")

;; ════════════════════════════════════════════════════════════════════
;; EDA — Parallel-clock engine + idle task (phase 10, layer 3)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-pclock")

;; ════════════════════════════════════════════════════════════════════
;; EDA — Window grid + buffer ergonomics (phase 11, layer 5)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-grid")

;; ════════════════════════════════════════════════════════════════════
;; EDA — Two isolated memory stores (phase 13, layer 8)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-memory")

;; ════════════════════════════════════════════════════════════════════
;; EDA — DONE-gate: delivery ritual (phase 12, layer 6)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-done-gate")

;; ════════════════════════════════════════════════════════════════════
;; EDA — Sync spine: client email bridge + mobile (phase 14, layer 7)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-sync")

;; ════════════════════════════════════════════════════════════════════
;; EDA — Reporting: per-tag/client + idle net-math (phase 15, layer 9)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-report")

;; ════════════════════════════════════════════════════════════════════
;; EDA — MCP bridge (phase 17, OPTIONAL E12; off + non-load-bearing)
;; ════════════════════════════════════════════════════════════════════
(load! "eda-mcp")
(load! "eda-repeat")

;; ════════════════════════════════════════════════════════════════════
;; Terminal (emacs -nw) clipboard — macOS / Terminal.app
;; ════════════════════════════════════════════════════════════════════
;; Terminal.app does NOT speak OSC 52, so clipetty / (tty +osc) do nothing.
;; Since `emacs -nw' runs locally, route the kill-ring straight through
;; pbcopy/pbpaste. This makes evil yank/paste (yy, p, C-y / M-w) talk to the
;; macOS clipboard in BOTH directions. The GUI build already does this
;; natively, so only wire it up on a text terminal frame.
(when (and (eq system-type 'darwin)
           (not (display-graphic-p)))
  (defun +my/pbcopy (text &optional _push)
    "Copy TEXT to the macOS clipboard via pbcopy."
    (let ((process-connection-type nil))
      (let ((proc (start-process "pbcopy" nil "pbcopy")))
        (process-send-string proc text)
        (process-send-eof proc))))

  (defun +my/pbpaste ()
    "Return the macOS clipboard contents via pbpaste."
    (shell-command-to-string "pbpaste -Prefer txt"))

  (setq interprogram-cut-function   #'+my/pbcopy
        interprogram-paste-function #'+my/pbpaste)

  ;; Cmd+V (handled by Terminal.app, not Emacs) pastes by "typing" the text,
  ;; which triggers electric/auto-indent and produces cascading indentation.
  ;; Bracketed paste wraps the pasted run in ESC[200~ … ESC[201~ so Emacs
  ;; inserts it verbatim. Emacs enables this on xterm-like terminals; force it
  ;; on per-frame in case TERM detection misses it.
  (defun +my/enable-bracketed-paste (&optional frame)
    (with-selected-frame (or frame (selected-frame))
      (when (and (not (display-graphic-p))
                 (fboundp 'xterm--init-bracketed-paste))
        (xterm--init-bracketed-paste))))
  (add-hook 'after-make-frame-functions #'+my/enable-bracketed-paste)
  (+my/enable-bracketed-paste)

  ;; Guaranteed-clean paste: insert the macOS clipboard verbatim, bypassing
  ;; the terminal's keystroke replay and electric/auto-indent entirely.
  (defun +my/insert-pbpaste ()
    "Insert the macOS clipboard contents verbatim at point."
    (interactive)
    (insert (+my/pbpaste)))
  (map! :leader
        :desc "Paste from macOS clipboard" "i v" #'+my/insert-pbpaste))
