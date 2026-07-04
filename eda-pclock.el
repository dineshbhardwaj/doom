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
  "Mode-line indicator string, e.g. \" ⏱×3\".")
(put 'eda/pclock-mode-line 'risky-local-variable t)

(defun eda/pclock--count ()
  (hash-table-count eda/pclock-active))

(defun eda/pclock--update-modeline ()
  (let ((n (eda/pclock--count)))
    (setq eda/pclock-mode-line (if (> n 0) (format " ⏱×%d" n) "")))
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
                 (plist-get pl :ws) (plist-get pl :role)
                 (fboundp 'eda/task-stop-session))
        (ignore-errors
          (eda/task-stop-session (plist-get pl :ws) (plist-get pl :role))))
      (eda/pclock--save)
      (eda/pclock--update-modeline)
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
  "Clock IN the task at point: start/resume its Claude AND start its timer."
  (interactive)
  (let ((marker (eda/task--marker)))
    (ignore-errors (eda/task-start marker))
    (eda/pclock-in marker)))

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
