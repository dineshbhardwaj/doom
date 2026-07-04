;;; ~/.config/doom/eda-grid.el  -*- lexical-binding: t; -*-
;;;
;;; Phase 11 · Layer 5 — window grid + buffer ergonomics (E5/E13/E14/E15/E16).
;;;
;;; The default working layout: slot 0 = the org (weekly) agenda; slots 1..n =
;;; one Claude pane per CLOCKED task, in clock order. The grid shape is chosen
;;; by how many tasks are clocked and re-rendered automatically on every clock
;;; in/out (via `eda/pclock-changed-hook'):
;;;
;;;   0 clocked → agenda only        1 → 1×2      2–3 → 2×2
;;;   4–5 → 2×3                       6–7 → 2×4  (caps at 8 windows)
;;;
;;;   C-x 1  zoom the current pane (suspends auto-relayout)
;;;   C-x 0  restore the grid        M-o  jump to a window (ace-window)
;;;   s-1..s-9  jump to window N (winum)
;;;
;;; Also: opening a file (SPC p f) resolves inside the FOCUSED pane's worktree
;;; (E13), and file buffers under a worktree are named "<file> · <task>" (E14).

(require 'cl-lib)

(defvar eda/portable-worktree-root)
(defvar eda/pclock-active)
(defvar eda/pclock-changed-hook)
(defvar eda/ws-claudes)
(declare-function eda/task--marker "eda-task-engine")

;; --- Layout decision (pure) ------------------------------------------------

(defun eda/grid-layout-for-count (n)
  "Return plist (:windows W :rows R :cols C :shown S) for N clocked tasks.
Window 0 holds the agenda; the remaining W-1 hold Claude sessions. Caps at 8
windows; SHOWN is how many task panes are available (never silently more)."
  (cond
   ((<= n 0) (list :windows 1 :rows 1 :cols 1 :shown 0))
   ((=  n 1) (list :windows 2 :rows 1 :cols 2 :shown 1))
   ((<= n 3) (list :windows 4 :rows 2 :cols 2 :shown 3))
   ((<= n 5) (list :windows 6 :rows 2 :cols 3 :shown 5))
   (t        (list :windows 8 :rows 2 :cols 4 :shown 7))))

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

(defun eda/grid--task-buffer (id)
  "Live Claude buffer for clocked task ID, or nil."
  (let* ((pl (gethash id eda/pclock-active))
         (ws (plist-get pl :ws)) (role (plist-get pl :role))
         (entries (and ws (boundp 'eda/ws-claudes) (gethash ws eda/ws-claudes)))
         (buf (and role (cdr (assq role entries)))))
    (and (buffer-live-p buf) buf)))

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
         (shown (plist-get spec :shown)))
    (condition-case err
        (let ((wins (eda/grid--build (plist-get spec :rows)
                                     (plist-get spec :cols))))
          (set-window-buffer (nth 0 wins) (eda/grid--agenda-buffer))
          (cl-loop for i from 0 below (min shown n)
                   for id in order
                   for w = (nth (1+ i) wins)
                   when w do
                   (let ((buf (eda/grid--task-buffer id)))
                     (when buf
                       (set-window-buffer w buf)
                       (set-window-dedicated-p w t))))
          ;; leftover panes → scratch (so an off-breakpoint count looks clean)
          (cl-loop for i from (1+ (min shown n)) below (length wins)
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

(defun eda/grid--maybe-refresh ()
  "Auto-relayout unless disabled or zoom-suspended."
  (when (and eda/grid-auto-refresh (not eda/grid--suspended))
    (condition-case _ (eda/grid-refresh) (error nil))))

(add-hook 'eda/pclock-changed-hook #'eda/grid--maybe-refresh)

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
       :desc "Refresh / restore grid" "g" #'eda/grid-refresh))

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
