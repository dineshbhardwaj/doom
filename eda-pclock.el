;;; ~/.config/doom/eda-pclock.el  -*- lexical-binding: t; -*-
;;;
;;; Phase 10 · Layer 3 — parallel-clock engine (E3) + idle task (E17).
;;;
;;; Org supports exactly ONE live clock (org-clock-in clocks out the previous
;;; task by design). Our model needs the opposite: several tasks "clocked" at
;;; once (a Claude working on each), overlap allowed, full time counted to each
;;; (decision D5). So this engine tracks N independent start-times in memory
;;; and, on clock-out, writes a real `CLOCK:' line straight into that task's
;;; LOGBOOK — which clocktable sums like any other clock, and which agenda `v c'
;;; flags as overlapping (the "report flags overlap" behaviour we want).
;;;
;;; Clock-out also KILLS the task's Claude session (MF1): re-clocking spawns a
;;; fresh `claude --resume <id>' from the stored session id.
;;;
;;; Idle (E17): a per-environment `Idle · <env>' task (tag :idle:) is clocked
;;; like anything else; its overlap is subtracted from work tasks at REPORT
;;; time (MF2, phase 15). At idle clock-out we drop a non-destructive audit
;;; note onto the tasks that were running, so the overlap is visible.

(require 'org)
(require 'org-id)
(require 'cl-lib)

(defvar eda/portable-worktree-root)
(defvar eda/portable-org-root)
(defvar eda/ws-claudes)
(declare-function eda/task--marker "eda-task-engine")
(declare-function eda/task-worktree "eda-task-engine")
(declare-function eda/task-workspace "eda-task-engine")
(declare-function eda/task-role "eda-task-engine")
(declare-function eda/task-start "eda-task-engine")
(declare-function eda/task-stop-session "eda-task-engine")
(declare-function eda/task--logbook-prepend "eda-task-engine")
(declare-function eda/task--append-logbook "eda-task-engine")
(declare-function eda/portable-client-name "eda-portable")

;; --- Config ----------------------------------------------------------------

(defvar eda/pclock-kill-session-on-out t
  "When non-nil, clocking a task out kills its Claude session (MF1).")

(defvar eda/pclock-changed-hook nil
  "Run after any clock in/out. The window-grid (phase 11) uses this to
auto-relayout when the number of active clocks changes.")

(defvar eda/pclock-state-file
  (expand-file-name "eda-pclock-state.el"
                    (or (bound-and-true-p doom-cache-dir) temporary-file-directory))
  "Machine-local file that persists running clocks across restart.")

(defvar eda/pclock-active (make-hash-table :test 'equal)
  "org-id → plist (:start TIME :ws WS :role ROLE :title STR :file PATH :idle BOOL).
The set of tasks currently clocked in (may overlap).")

;; --- Persistence -----------------------------------------------------------

(defun eda/pclock--save ()
  "Persist `eda/pclock-active' (markers dropped) to `eda/pclock-state-file'."
  (let (alist)
    (maphash (lambda (id pl)
               (push (cons id (list :start (plist-get pl :start)
                                    :ws (plist-get pl :ws)
                                    :role (plist-get pl :role)
                                    :title (plist-get pl :title)
                                    :file (plist-get pl :file)
                                    :idle (plist-get pl :idle)))
                     alist))
             eda/pclock-active)
    (with-temp-file eda/pclock-state-file
      (let ((print-length nil) (print-level nil))
        (prin1 alist (current-buffer))))))

(defun eda/pclock--load ()
  "Restore running clocks from `eda/pclock-state-file', if present."
  (when (file-readable-p eda/pclock-state-file)
    (ignore-errors
      (let ((alist (with-temp-buffer
                     (insert-file-contents eda/pclock-state-file)
                     (goto-char (point-min))
                     (read (current-buffer)))))
        (clrhash eda/pclock-active)
        (dolist (cell alist)
          (puthash (car cell) (cdr cell) eda/pclock-active))))))

;; --- Mode line -------------------------------------------------------------

(defvar eda/pclock-mode-line ""
  "Mode-line indicator string naming the clocked tasks (or the idle task).")
(put 'eda/pclock-mode-line 'risky-local-variable t)

(defvar eda/pclock-mode-line-words 2
  "How many leading words of each task title to show in the mode line.")

(defvar eda/pclock-mode-line-max-tasks 4
  "Max clocked tasks to name in the mode line before collapsing to a `+N' tail.")

(defun eda/pclock--count ()
  (hash-table-count eda/pclock-active))

(defun eda/pclock--short-title (title &optional n)
  "First N words (default `eda/pclock-mode-line-words') of TITLE."
  (string-join (seq-take (split-string (or title "") "[ \t]+" t)
                         (or n eda/pclock-mode-line-words))
               " "))

(defun eda/pclock--active-sorted (&optional idle)
  "Active clock plists, oldest clock-in first.  IDLE non-nil → only idle ones,
nil → only work (non-idle) ones."
  (let (out)
    (maphash (lambda (_id pl)
               (when (eq (and (plist-get pl :idle) t) (and idle t))
                 (push pl out)))
             eda/pclock-active)
    (sort out (lambda (a b) (time-less-p (plist-get a :start)
                                         (plist-get b :start))))))

(defun eda/pclock--mode-line-string ()
  "Build the mode-line text from `eda/pclock-active'.
While an idle clock is active it wins the display (a break is in progress) and
notes how many work tasks are still held; otherwise the clocked work tasks are
listed, numbered in clock order, each shown as its first few words."
  (let ((idles (eda/pclock--active-sorted t))
        (works (eda/pclock--active-sorted nil)))
    (cond
     (idles
      (concat " ⏸ "
              (mapconcat (lambda (pl) (plist-get pl :title)) idles " · ")
              (when works (format " (⏱×%d held)" (length works)))))
     ((null works) "")
     (t
      (let* ((n (length works))
             (shown (seq-take works eda/pclock-mode-line-max-tasks))
             (segs (seq-map-indexed
                    (lambda (pl i)
                      (format "%d.%s" (1+ i)
                              (eda/pclock--short-title (plist-get pl :title))))
                    shown))
             (tail (- n (length shown))))
        (concat (format " ⏱×%d " n)
                (string-join segs " ")
                (when (> tail 0) (format " +%d" tail))))))))

(defun eda/pclock--mode-line-help ()
  "Full clocked list, for the mode-line tooltip (help-echo)."
  (let (lines)
    (dolist (pl (append (eda/pclock--active-sorted nil)
                        (eda/pclock--active-sorted t)))
      (push (format "%s %s"
                    (if (plist-get pl :idle) "⏸" "⏱")
                    (plist-get pl :title))
            lines))
    (concat "Clocked (" (number-to-string (eda/pclock--count)) "):\n"
            (string-join (nreverse lines) "\n"))))

(defun eda/pclock--update-modeline ()
  (setq eda/pclock-mode-line
        (let ((s (eda/pclock--mode-line-string)))
          (if (string-empty-p s) ""
            (propertize s 'help-echo (eda/pclock--mode-line-help)))))
  (unless (memq 'eda/pclock-mode-line global-mode-string)
    (setq global-mode-string
          (append (or global-mode-string '("")) '(eda/pclock-mode-line))))
  (force-mode-line-update t))

;; --- CLOCK line helper -----------------------------------------------------

(defun eda/pclock--clock-line (start end)
  "Return a canonical `CLOCK:' line string for the interval START..END."
  (let* ((secs (max 0 (floor (float-time (time-subtract end start)))))
         (mins (/ secs 60)) (h (/ mins 60)) (m (% mins 60)))
    (format "CLOCK: %s--%s =>  %d:%02d"
            (format-time-string "[%Y-%m-%d %a %H:%M]" start)
            (format-time-string "[%Y-%m-%d %a %H:%M]" end)
            h m)))

(defun eda/pclock--find-marker (id file &optional live-marker)
  "Return a marker to the entry ID (relocating via LIVE-MARKER, id-db, or FILE)."
  (or (and (markerp live-marker) (buffer-live-p (marker-buffer live-marker))
           live-marker)
      (ignore-errors (org-id-find id 'marker))
      (and file (file-readable-p file)
           (with-current-buffer (find-file-noselect file)
             (save-excursion
               (goto-char (point-min))
               (when (re-search-forward
                      (format "^[ \t]*:ID:[ \t]+%s[ \t]*$" (regexp-quote id)) nil t)
                 (org-back-to-heading t) (point-marker)))))))

;; --- Core in / out ---------------------------------------------------------

(defun eda/pclock-in (marker &optional idle)
  "Start a parallel clock for the entry at MARKER. IDLE marks it the idle task.
No-op (with a message) if that entry is already clocked in."
  (let* ((id (org-with-point-at marker (org-id-get-create)))
         (file (buffer-file-name (marker-buffer marker))))
    (if (gethash id eda/pclock-active)
        (message "Already clocked in: %s"
                 (or (org-with-point-at marker (org-get-heading t t t t)) id))
      (puthash id
               (list :start (current-time)
                     :ws (ignore-errors (eda/task-workspace marker))
                     :role (ignore-errors (eda/task-role marker))
                     :title (org-with-point-at marker (org-get-heading t t t t))
                     :file file
                     :marker (copy-marker marker)
                     :idle idle)
               eda/pclock-active)
      (eda/pclock--save)
      (eda/pclock--update-modeline)
      (run-hooks 'eda/pclock-changed-hook)
      (message "Clocked IN (%d active): %s"
               (eda/pclock--count)
               (org-with-point-at marker (org-get-heading t t t t))))))

(defun eda/pclock--out-1 (id)
  "Write the CLOCK line for active clock ID and remove it. Returns its plist."
  (let* ((pl (gethash id eda/pclock-active)))
    (when pl
      (let* ((start (plist-get pl :start))
             (end (current-time))
             (m (eda/pclock--find-marker id (plist-get pl :file)
                                         (plist-get pl :marker))))
        (when m
          (org-with-point-at m
            (eda/task--logbook-prepend (eda/pclock--clock-line start end)))
          (when (buffer-live-p (marker-buffer m))
            (with-current-buffer (marker-buffer m)
              (when buffer-file-name (save-buffer)))))
        (remhash id eda/pclock-active)
        pl))))

(defun eda/pclock-out (marker)
  "Clock the entry at MARKER out: write its CLOCK line and (MF1) kill its Claude."
  (let* ((id (org-with-point-at marker (org-id-get-create)))
         (pl (eda/pclock--out-1 id)))
    (if (not pl)
        (message "Not clocked in.")
      (when (and eda/pclock-kill-session-on-out
                 (not (plist-get pl :idle))
                 (fboundp 'eda/task-stop-session))
        ;; Locate the session as forgivingly as the grid's read path does, so a
        ;; clock-out reliably CLOSES the Claude buffer (it stays resumable — the
        ;; graceful exit flushes the transcript and the stamped session id lets
        ;; the next clock-in `--resume').  Two snapshot hazards used to make the
        ;; kill silently no-op, leaving the buffer open:
        ;;   * :role nil (no :CLAUDE_ROLE:) — default to `architect', matching
        ;;     `eda/grid--task-buffer', so the guard no longer blocks the kill.
        ;;   * :ws mis-resolved (task clocked before its :WORKTREE:/:TASK_SLUG:
        ;;     were stamped, so it snapshotted the org file's own folder) — the
        ;;     buffer is registered under the REAL worktree, not that snapshot,
        ;;     so re-derive the workspace from the marker and retry when the
        ;;     recorded :ws has no live session.
        (let* ((role (or (plist-get pl :role) 'architect))
               (ws1  (plist-get pl :ws))
               (m    (plist-get pl :marker))
               (ws2  (and m (ignore-errors (eda/task-workspace m)))))
          (unless (ignore-errors (eda/task-stop-session ws1 role))
            (when (and ws2 (not (equal ws2 ws1)))
              (ignore-errors (eda/task-stop-session ws2 role))))))
      (eda/pclock--save)
      (eda/pclock--update-modeline)
      (run-hooks 'eda/pclock-changed-hook)
      (message "Clocked OUT (%d active): %s"
               (eda/pclock--count) (plist-get pl :title)))))

;; --- Idle task (E17) -------------------------------------------------------

(defun eda/pclock--env ()
  "This machine's environment string for the idle task: personal | client-<x>."
  (let ((c (ignore-errors (eda/portable-client-name))))
    (if c (concat "client-" c) "personal")))

(defun eda/pclock--idle-file ()
  (expand-file-name "idle.org" (or (bound-and-true-p eda/portable-org-root)
                                   org-directory "~/")))

(defun eda/pclock--idle-marker (env)
  "Return a marker to the `Idle · ENV' heading, creating file/heading if needed."
  (let* ((file (eda/pclock--idle-file))
         (buf (find-file-noselect file)))
    (with-current-buffer buf
      (unless (derived-mode-p 'org-mode) (org-mode))
      (goto-char (point-min))
      (if (re-search-forward
           (format "^[ \t]*:EDA_IDLE:[ \t]+%s[ \t]*$" (regexp-quote env)) nil t)
          (progn (org-back-to-heading t) (point-marker))
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "* Idle · %s  :idle:\n" env))
        (org-back-to-heading t)
        (org-id-get-create)
        (org-entry-put nil "EDA_IDLE" env)
        (when buffer-file-name (save-buffer))
        (org-back-to-heading t) (point-marker)))))

;;;###autoload
(defun eda/pclock-idle-toggle (&optional env)
  "Toggle the idle clock for ENV (default: this machine's environment).
On clock-out, drop a non-destructive audit note onto every work task that was
running, recording the overlapped idle span (net time is applied at report)."
  (interactive)
  (let* ((env (or env (eda/pclock--env)))
         (m (eda/pclock--idle-marker env))
         (id (org-with-point-at m (org-id-get-create))))
    (if (gethash id eda/pclock-active)
        (let* ((start (plist-get (gethash id eda/pclock-active) :start))
               (span-beg (format-time-string "[%Y-%m-%d %a %H:%M]" start)))
          (eda/pclock-out m)
          (let ((span (format "%s--%s" span-beg
                              (format-time-string "[%Y-%m-%d %a %H:%M]"))))
            (maphash
             (lambda (_id pl)
               (unless (plist-get pl :idle)
                 (let ((wm (eda/pclock--find-marker _id (plist-get pl :file)
                                                    (plist-get pl :marker))))
                   (when wm
                     (org-with-point-at wm
                       (eda/task--append-logbook
                        (format "IDLE_ADJ ▶ overlapped %s (net at report)" span)))))))
             eda/pclock-active))
          (message "Idle OUT · noted overlap on active tasks"))
      (eda/pclock-in m t)
      (message "Idle IN (%s)" env))))

;; --- User-facing clock commands (bridge session + timer) -------------------

;;;###autoload
(defun eda/task-clock-in ()
  "Clock IN the task at point: start/resume its Claude AND start its timer.
Rebuilds the default grid so the newly-clocked task gets its own Claude window:
`eda/task-start' spawns/registers the session, then `eda/pclock-in' fires
`eda/pclock-changed-hook' → the grid relayout. A prior `C-x 1' zoom leaves the
grid suspended, which would silently block that relayout, so clear it first."
  (interactive)
  (let ((marker (eda/task--marker)))
    (ignore-errors (eda/task-start marker))
    ;; Suppress the changed-hook's relayout during the clock-in so we rebuild
    ;; exactly once below (no double refresh / flicker), then force one full
    ;; grid rebuild. `eda/grid-refresh' clears any `C-x 1' zoom-suspend itself,
    ;; so the newly-clocked task always gets its Claude window — even when the
    ;; task was already clocked or the grid was zoomed.
    (let ((eda/grid-auto-refresh nil))
      (eda/pclock-in marker))
    (when (fboundp 'eda/grid-refresh) (ignore-errors (eda/grid-refresh)))))

;;;###autoload
(defun eda/task-clock-out ()
  "Clock OUT the task at point: write its CLOCK line and kill its Claude (MF1)."
  (interactive)
  (eda/pclock-out (eda/task--marker)))

;;;###autoload
(defun eda/pclock-list ()
  "List the currently-clocked tasks with elapsed time."
  (interactive)
  (if (zerop (eda/pclock--count))
      (message "No active clocks.")
    (let (lines)
      (maphash
       (lambda (_id pl)
         (let* ((secs (floor (float-time (time-subtract (current-time)
                                                        (plist-get pl :start)))))
                (m (/ secs 60)))
           (push (format "  %s%-40s %d:%02d"
                         (if (plist-get pl :idle) "⏸ " "⏱ ")
                         (truncate-string-to-width
                          (or (plist-get pl :title) "?") 40 nil nil "…")
                         (/ m 60) (% m 60))
                 lines)))
       eda/pclock-active)
      (message "Active clocks (%d):\n%s" (eda/pclock--count)
               (mapconcat #'identity (nreverse lines) "\n")))))

;;;###autoload
(defun eda/pclock-out-all ()
  "Clock out every active task (idle included)."
  (interactive)
  (let ((ids '()))
    (maphash (lambda (id _pl) (push id ids)) eda/pclock-active)
    (dolist (id ids)
      (let ((pl (gethash id eda/pclock-active)))
        (when pl
          (let ((m (eda/pclock--find-marker id (plist-get pl :file)
                                            (plist-get pl :marker))))
            (when m (eda/pclock-out m))))))
    (message "All clocks stopped.")))

;; --- Boot + shutdown -------------------------------------------------------

(eda/pclock--load)
(eda/pclock--update-modeline)
(add-hook 'kill-emacs-hook #'eda/pclock--save)

;; --- Keys: extend SPC k o ---------------------------------------------------

(map! :leader
      (:prefix-map ("k o" . "org task engine")
       :desc "Clock IN (session + timer)"  "c" #'eda/task-clock-in
       :desc "Clock OUT (+ kill session)"  "C" #'eda/task-clock-out
       :desc "Idle toggle"                 "z" #'eda/pclock-idle-toggle
       :desc "List active clocks"          "l" #'eda/pclock-list
       :desc "Clock out ALL"               "0" #'eda/pclock-out-all))

(provide 'eda-pclock)
;;; eda-pclock.el ends here
