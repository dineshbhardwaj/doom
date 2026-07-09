;;; ~/.config/doom/eda-grid.el  -*- lexical-binding: t; -*-
;;;
;;; Phase 11 · Layer 5 — window grid + buffer ergonomics (E5/E13/E14/E15/E16).
;;;
;;; The default working layout puts the org (weekly) agenda in slot 0. When
;;; `eda/grid-show-elfeed' is on (the default) slot 1 = elfeed search (the
;;; one-line entry list) and slot 2 = the elfeed article (`*elfeed-entry*');
;;; Claude panes then start at slot 3 and cap at 5. Toggle elfeed OUT of the
;;; grid with `SPC k o e' (`eda/grid-toggle-elfeed') to free those two slots —
;;; Claude panes then start at slot 1 and cap at 7, for more parallel sessions.
;;; The grid shape is chosen from the front-slot count plus how many tasks are
;;; clocked, and re-rendered automatically on every clock in/out and on toggle
;;; (via `eda/pclock-changed-hook'). E.g. with elfeed on:
;;;
;;;   0 clocked → agenda+search+article (1×3)   1 → 2×2
;;;   2–3 → 2×3                                  4+ → 2×4  (caps at 8 windows)
;;;
;;;   C-x 1  zoom the current pane (suspends auto-relayout)
;;;   C-x 0  restore the grid        M-o  jump to a window (ace-window)
;;;   s-1..s-9  jump to window N (winum)
;;;   SPC k o e  toggle elfeed in/out of the grid (reflows the layout)
;;;
;;; Also: opening a file (SPC p f) resolves inside the FOCUSED pane's worktree
;;; (E13), and file buffers under a worktree are named "<file> · <task>" (E14).

(require 'cl-lib)

(defvar eda/portable-worktree-root)
(defvar eda/pclock-active)
(defvar eda/pclock-changed-hook)
(defvar eda/ws-claudes)
(declare-function eda/task--marker "eda-task-engine")
(declare-function eda/task-worktree "eda-task-engine")
(declare-function eda/task-session-id "eda-task-engine")
(declare-function eda/ws-claude--start "eda-workspace-claude")

;; --- Layout decision (pure) ------------------------------------------------

(defvar eda/grid-show-elfeed t
  "When non-nil, the grid reserves two front slots (after the agenda in slot 0)
for the elfeed search list and article, so Claude panes start at slot 3 and
cap at 5.  When nil, elfeed is dropped from the grid and Claude panes start
right after the agenda (slot 1), giving up to 7 panes for parallel sessions.
Toggle live with `eda/grid-toggle-elfeed' (\\[eda/grid-toggle-elfeed], `SPC k o e');
set this here (or in per-machine config) to change the startup default.")

(defun eda/grid--front-slots ()
  "Number of fixed non-Claude slots at the front of the grid.
Slot 0 is always the agenda; when `eda/grid-show-elfeed' is non-nil slots 1
and 2 additionally hold the elfeed search list and article."
  (if eda/grid-show-elfeed 3 1))

(defun eda/grid--shape-for (total)
  "Return (ROWS COLS WINDOWS) for the tightest tidy grid holding TOTAL panes.
WINDOWS (= ROWS*COLS) may exceed TOTAL when TOTAL isn't a clean grid size;
the caller fills the leftover panes with *scratch*.  Caps at 8 windows."
  (cond
   ((<= total 1) '(1 1 1))
   ((<= total 2) '(1 2 2))
   ((<= total 3) '(1 3 3))
   ((<= total 4) '(2 2 4))
   ((<= total 6) '(2 3 6))
   (t            '(2 4 8))))

(defun eda/grid-layout-for-count (n)
  "Return plist (:windows W :rows R :cols C :shown S :front F) for N clocked tasks.
Slot 0 holds the agenda; when `eda/grid-show-elfeed' is non-nil slots 1-2 hold
the elfeed list + article (F=3), otherwise elfeed is omitted (F=1).  The
remaining slots hold Claude sessions, in clock order.  Caps at 8 windows; SHOWN
Claude panes = min(N, 8-F) — 5 with elfeed on, 7 with it off — never silently
more.  The grid shape adapts to F+SHOWN so dropping elfeed reflows the grid."
  (let* ((front      (eda/grid--front-slots))
         (max-claude (- 8 front))
         (shown      (max 0 (min n max-claude)))
         (total      (+ front shown))
         (shape      (eda/grid--shape-for total)))
    (list :windows (nth 2 shape)
          :rows    (nth 0 shape)
          :cols    (nth 1 shape)
          :shown   shown
          :front   front)))

;; --- Window builder --------------------------------------------------------

(defun eda/grid--build (rows cols)
  "Split the selected window into ROWS×COLS; return the windows row-major."
  (delete-other-windows)
  (let ((row-wins (list (selected-window))))
    (dotimes (_ (1- rows))
      (setq row-wins
            (append row-wins
                    (list (split-window (car (last row-wins)) nil 'below)))))
    (let ((all '()))
      (dolist (rw row-wins)
        (let ((col-wins (list rw)))
          (dotimes (_ (1- cols))
            (setq col-wins
                  (append col-wins
                          (list (split-window (car (last col-wins)) nil 'right)))))
          (setq all (append all col-wins))))
      (balance-windows)
      all)))

;; --- Clock order → buffers -------------------------------------------------

(defun eda/grid--clock-order ()
  "org-ids of currently-clocked NON-idle tasks, oldest clock first."
  (let (items)
    (maphash (lambda (id pl)
               (unless (plist-get pl :idle)
                 (push (cons id (plist-get pl :start)) items)))
             eda/pclock-active)
    (mapcar #'car (sort items (lambda (a b) (time-less-p (cdr a) (cdr b)))))))

(defvar eda/grid-resume-dead-sessions t
  "When non-nil, a still-clocked task whose Claude buffer is gone is resumed
in place as the grid builds, instead of leaving the pane on an empty *scratch*.
This is the common case after an Emacs/daemon restart (which empties the
in-memory `eda/ws-claudes') or after the session was killed while the task
stayed clocked — e.g. a REVIEW task you switch back to.  Bounded to CLOCKED
tasks only, so glancing at a workspace whose task is not clocked spawns
nothing; set to nil to restore the old scratch-fallback behaviour.")

(defun eda/grid--resume-task (pl ws role)
  "Resume the Claude session described by pclock plist PL for (WS, ROLE).
Uses the marker stored at clock-in to read the task's worktree + session id,
then resumes via `eda/ws-claude--start' (which `--resume's an existing
transcript or creates the id fresh).  The spawn's `pop-to-buffer' is contained
in a `save-window-excursion' so it does not disturb the grid relayout — the
caller places the registered buffer into its pane afterwards.  Best-effort."
  (when (and pl role (fboundp 'eda/ws-claude--start))
    (with-demoted-errors "eda/grid resume: %S"
      (let* ((marker (plist-get pl :marker))
             (wt  (and marker (ignore-errors (eda/task-worktree marker))))
             (sid (and marker (ignore-errors (eda/task-session-id marker)))))
        (when (and wt (file-directory-p wt))
          (save-window-excursion
            (eda/ws-claude--start ws role sid)))))))

(defun eda/grid--task-buffer (id)
  "Live Claude buffer for clocked task ID, or nil.
When the task is still clocked but has no live buffer (the session was killed
or lost to a restart) and `eda/grid-resume-dead-sessions' is non-nil, resume it
in place rather than returning nil (which would leave the pane on *scratch*)."
  (let* ((pl (gethash id eda/pclock-active))
         (ws (plist-get pl :ws))
         (role (or (plist-get pl :role) 'architect))
         (entries (and ws (boundp 'eda/ws-claudes) (gethash ws eda/ws-claudes)))
         (buf (and role (cdr (assq role entries)))))
    (cond
     ((buffer-live-p buf) buf)
     ((and eda/grid-resume-dead-sessions ws pl)
      (eda/grid--resume-task pl ws role)
      ;; `eda/ws-claude--start' registered the (now-live) buffer; re-read it.
      (let* ((e2 (and ws (gethash ws eda/ws-claudes)))
             (b2 (and role (cdr (assq role e2)))))
        (and (buffer-live-p b2) b2)))
     (t nil))))

(defun eda/grid--agenda-buffer ()
  "Return an org agenda buffer to occupy slot 0 (best-effort)."
  (or (get-buffer "*Org Agenda*")
      (and (boundp 'org-agenda-buffer) (buffer-live-p org-agenda-buffer)
           org-agenda-buffer)
      (save-window-excursion
        (ignore-errors
          (let ((org-agenda-window-setup 'current-window))
            (org-agenda-list nil nil 7)))
        (get-buffer "*Org Agenda*"))
      (get-buffer-create "*scratch*")))

(defun eda/grid--elfeed-buffer ()
  "Return the elfeed search buffer for slot 1 (best-effort, no focus steal).
Falls back to *scratch* if elfeed is unavailable so the grid never breaks.
The whole body is demoted to a message: loading elfeed pulls in gnus faces,
whose inheritance can be transiently cyclic under doom-one during cold daemon
start (\"Face inheritance results in inheritance cycle\"); that must degrade to
scratch, never abort the layout."
  (or (get-buffer "*elfeed-search*")
      (with-demoted-errors "eda/grid elfeed slot: %S"
        (when (or (featurep 'elfeed) (require 'elfeed nil t) (fboundp 'elfeed))
          (save-window-excursion
            (ignore-errors (elfeed))
            (get-buffer "*elfeed-search*"))))
      (get-buffer-create "*scratch*")))

(defun eda/grid--elfeed-entry-buffer ()
  "Return the elfeed article buffer for slot 2 (best-effort, no focus steal).
This is elfeed's `*elfeed-entry*' show buffer, which only exists after an
article has been opened from the list; falls back to *scratch* until then."
  (or (get-buffer "*elfeed-entry*")
      (get-buffer-create "*scratch*")))

;; --- Refresh / restore / zoom ----------------------------------------------

(defvar eda/grid-auto-refresh t
  "When non-nil, relayout the grid automatically on clock in/out.")
(defvar eda/grid--suspended nil
  "Non-nil after `C-x 1' zoom; suppresses auto-relayout until `C-x 0'.")

;;;###autoload
(defun eda/grid-refresh ()
  "Rebuild the default grid from the currently-clocked tasks (clock order)."
  (interactive)
  (setq eda/grid--suspended nil)
  (let* ((order (eda/grid--clock-order))
         (n     (length order))
         (spec  (eda/grid-layout-for-count n))
         (shown (plist-get spec :shown))
         (front (plist-get spec :front)))
    (condition-case err
        (let ((wins (eda/grid--build (plist-get spec :rows)
                                     (plist-get spec :cols))))
          ;; Fixed front slots: 0 = agenda; when `eda/grid-show-elfeed', 1 =
          ;; elfeed list, 2 = elfeed article. Each slot is isolated: a buffer
          ;; that misbehaves (e.g. a transient gnus face-inheritance cycle when
          ;; elfeed first loads) leaves that one pane on *scratch* rather than
          ;; aborting the whole layout into the single-window fallback below.
          (with-demoted-errors "eda/grid agenda slot: %S"
            (set-window-buffer (nth 0 wins) (eda/grid--agenda-buffer)))
          (when eda/grid-show-elfeed
            (when (nth 1 wins)
              (with-demoted-errors "eda/grid elfeed slot: %S"
                (set-window-buffer (nth 1 wins) (eda/grid--elfeed-buffer))))
            (when (nth 2 wins)
              (with-demoted-errors "eda/grid article slot: %S"
                (set-window-buffer (nth 2 wins) (eda/grid--elfeed-entry-buffer)))))
          ;; Claude panes start at slot FRONT (3 with elfeed, 1 without), in
          ;; clock order.
          (cl-loop for i from 0 below (min shown n)
                   for id in order
                   for w = (nth (+ front i) wins)
                   when w do
                   (let ((buf (eda/grid--task-buffer id)))
                     (when buf
                       (set-window-buffer w buf)
                       (set-window-dedicated-p w t))))
          ;; leftover panes → scratch (so an off-breakpoint count looks clean)
          (cl-loop for i from (+ front (min shown n)) below (length wins)
                   for w = (nth i wins)
                   when w do (set-window-buffer w (get-buffer-create "*scratch*")))
          (when (> n shown)
            (message "eda/grid: %d clocked, showing %d (cap); rest hidden." n shown))
          (select-window (nth 0 wins)))
      (error
       (delete-other-windows)
       (message "eda/grid: layout failed (%s); showing single window."
                (error-message-string err))))))

;;;###autoload
(defun eda/grid-restore ()
  "Restore the default grid (bound to `C-x 0')."
  (interactive)
  (eda/grid-refresh))

;;;###autoload
(defun eda/grid-zoom ()
  "Zoom the current pane and suspend auto-relayout (bound to `C-x 1')."
  (interactive)
  (setq eda/grid--suspended t)
  (delete-other-windows))

;;;###autoload
(defun eda/grid-toggle-elfeed ()
  "Toggle whether elfeed occupies grid slots, then relayout.
With elfeed on, slots 1-2 are the elfeed list + article and Claude caps at 5
panes; with it off those slots are freed and Claude gets up to 7 panes for
more parallel sessions.  The grid shape reflows to match.  Bound to `SPC k o e'."
  (interactive)
  (setq eda/grid-show-elfeed (not eda/grid-show-elfeed))
  (setq eda/grid--suspended nil)
  (eda/grid-refresh)
  (message "eda/grid: elfeed %s the grid (Claude panes cap at %d)"
           (if eda/grid-show-elfeed "IN" "OUT of")
           (- 8 (eda/grid--front-slots))))

(defun eda/grid--maybe-refresh ()
  "Auto-relayout unless disabled or zoom-suspended."
  (when (and eda/grid-auto-refresh (not eda/grid--suspended))
    (condition-case _ (eda/grid-refresh) (error nil))))

(add-hook 'eda/pclock-changed-hook #'eda/grid--maybe-refresh)

;; --- Startup render (once, on the first usable frame) ----------------------
;;
;; The grid is otherwise only built on demand (`SPC k o g') or on clock in/out.
;; This renders the default layout automatically when Emacs comes up. In a
;; daemon there is NO usable frame at `emacs-startup-hook' time (window
;; splitting would fail), so we wait for the first `emacsclient' frame via
;; `server-after-make-frame-hook'; a plain GUI Emacs uses `emacs-startup-hook'.
;; Clocked-task panes come from whatever `eda/pclock-active' restored on load.

(defvar eda/grid-render-on-startup t
  "When non-nil, render the default grid once at startup.")
(defvar eda/grid--startup-done nil
  "Non-nil once the startup grid render has run (guards re-fire on new frames).")

(defun eda/grid--prewarm-faces ()
  "Absorb the transient gnus/elfeed face-inheritance cycle once, harmlessly.
Loading elfeed pulls in gnus faces whose :inherit is transiently cyclic on
their FIRST realization under doom-one (an Emacs realization-order bug); the
second realization is clean. Force that first realization here, demoted to a
message, so it happens at startup rather than mid-grid on the user's screen."
  (with-demoted-errors "eda/grid prewarm: %S"
    (when (or (featurep 'elfeed) (require 'elfeed nil t))
      (dolist (f '(gnus-group-news-low-empty gnus-group-news-low
                   gnus-group-mail-1 gnus-group-mail-1-empty))
        (when (facep f)
          (ignore-errors (face-attribute f :foreground nil t)))))))

(defun eda/grid--startup-render (&optional frame)
  "Render the default grid once, in FRAME (or the selected frame).
No-op on the daemon's frameless init and after the first successful render."
  (let ((frame (or frame (selected-frame))))
    (when (and eda/grid-render-on-startup
               (not eda/grid--startup-done)
               (not noninteractive)
               (frame-live-p frame))
      (setq eda/grid--startup-done t)
      (with-selected-frame frame
        (eda/grid--prewarm-faces)
        (condition-case _ (eda/grid-refresh) (error nil))))))

(if (daemonp)
    ;; Fires after persp/pclock have loaded at daemon init, on the first client.
    (add-hook 'server-after-make-frame-hook #'eda/grid--startup-render)
  (add-hook 'emacs-startup-hook #'eda/grid--startup-render))

;; --- E13 · worktree-follows-focus for file finding -------------------------

(defun eda/grid--current-worktree ()
  "Worktree directory implied by the focused window's buffer, or nil."
  (let* ((root (expand-file-name eda/portable-worktree-root))
         (f (buffer-file-name))
         (bn (buffer-name)))
    (cond
     ((and f (string-prefix-p root (expand-file-name f)))
      (let ((top (car (split-string (file-relative-name (expand-file-name f) root)
                                    "/"))))
        (file-name-as-directory (expand-file-name top root))))
     ((and bn (string-match "\\*claude:\\(.*\\):[^:]*\\*" bn))
      (file-name-as-directory (expand-file-name (match-string 1 bn))))
     (t nil))))

(define-advice projectile-find-file
    (:around (orig &rest args) eda/grid-worktree-scope)
  "Scope project file-finding to the focused pane's worktree (E13)."
  (let ((wt (eda/grid--current-worktree)))
    (if (and wt (file-directory-p wt))
        (let ((default-directory wt)) (apply orig args))
      (apply orig args))))

;; --- E14 · task-annotated buffer names -------------------------------------

(defvar eda/grid-annotate-buffers t
  "When non-nil, name file buffers under a worktree \"<file> · <task>\".")

(defun eda/grid--annotate-buffer ()
  "Rename the current file buffer to include its task, once (E14)."
  (when (and eda/grid-annotate-buffers buffer-file-name)
    (let* ((root (expand-file-name eda/portable-worktree-root))
           (f (expand-file-name buffer-file-name)))
      (when (string-prefix-p root f)
        (let ((ws (car (split-string (file-relative-name f root) "/"))))
          (unless (or (string-empty-p ws)
                      (string-match-p (concat " · " (regexp-quote ws) "\\'")
                                      (buffer-name)))
            (ignore-errors
              (rename-buffer (format "%s · %s" (buffer-name) ws) t))))))))

(add-hook 'find-file-hook #'eda/grid--annotate-buffer)

;; --- Fast window switching (graceful if packages absent) -------------------

(when (require 'ace-window nil t)
  (setq aw-scope 'frame)
  (global-set-key [remap other-window] #'ace-window)
  (map! "M-o" #'ace-window))

(when (require 'winum nil t)
  (winum-mode 1)
  (map! "s-1" #'winum-select-window-1
        "s-2" #'winum-select-window-2
        "s-3" #'winum-select-window-3
        "s-4" #'winum-select-window-4
        "s-5" #'winum-select-window-5
        "s-6" #'winum-select-window-6
        "s-7" #'winum-select-window-7
        "s-8" #'winum-select-window-8
        "s-9" #'winum-select-window-9))

;; --- Zoom / restore keys + agenda single-key clocking ----------------------

(map! "C-x 1" #'eda/grid-zoom
      "C-x 0" #'eda/grid-restore)

(map! :leader
      (:prefix-map ("k o" . "org task engine")
       :desc "Refresh / restore grid" "g" #'eda/grid-refresh
       :desc "Toggle elfeed in grid"  "e" #'eda/grid-toggle-elfeed))

;; Single-key clock from the agenda (overrides the native single-clock I/O —
;; we don't use org's one live clock; the parallel engine handles timing).
(map! :after org-agenda
      :map org-agenda-mode-map
      :n "I" #'eda/task-clock-in
      :n "O" #'eda/task-clock-out
      :n "z" #'eda/pclock-idle-toggle
      :n "gj" #'eda/task-jump)

(provide 'eda-grid)
;;; eda-grid.el ends here
