;;; ~/.config/doom/eda-repeat.el  -*- lexical-binding: t; -*-
;;;
;;; Catch-up for overdue REPEATING org tasks (daily/weekly ones that piled up).
;;;
;;; Problem: a `+1w' repeater shifts only ONE interval per DONE, so a weekly
;;; task overdue by N weeks needs N DONEs to catch up (and a daily one, N days).
;;; `eda/org-catchup-repeaters' (SPC k o u) fast-forwards each overdue repeating
;;; SCHEDULED/DEADLINE straight to its next future occurrence — WITHOUT touching
;;; the TODO state, tags, or body, and without firing fake completions. It
;;; optionally rewrites a bare `+' repeater to `.+' (so a future DONE catches up
;;; in one shot), shows a dry-run you confirm, and logs old->new into each
;;; changed entry's LOGBOOK so the edit is auditable and revertible-by-eye.

(require 'cl-lib)

(declare-function eda/task--append-logbook "eda-task-engine")
(declare-function org-map-entries "org")
(declare-function org-get-heading "org")
(declare-function org-back-to-heading "org")
(declare-function org-time-string-to-time "org")
(declare-function outline-next-heading "outline")

(defvar eda/org-catchup-convert-plus t
  "When non-nil, `eda/org-catchup-repeaters' also rewrites a bare `+N' repeater
to `eda/org-catchup-repeater-mark' so a future DONE catches up in one shot
instead of shifting a single interval.  `++'/`.+' repeaters are left unchanged.")

(defvar eda/org-catchup-repeater-mark ".+"
  "Mark a bare `+' repeater is converted to (when `eda/org-catchup-convert-plus').
`.+' → the next occurrence is one interval from the DONE date (simple, may drift
weekday); `++' → keeps the original weekday and catches up to the future.")

(defconst eda/org--repeater-re
  "\\(\\.\\+\\|\\+\\+\\|\\+\\)\\([0-9]+\\)\\([hdwmy]\\)"
  "Org repeater cookie: group 1 = mark, 2 = count, 3 = unit.")

(defconst eda/org--ts-date-re
  "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\(?: +[[:alpha:]]+\\.?\\)?"
  "The date (with optional weekday) inside an org timestamp.")

;; --- Date math (calendar-correct, DST-safe) --------------------------------

(defun eda/org--daynum (time)
  "Return TIME's calendar date as a comparable integer YYYYMMDD."
  (let ((d (decode-time time)))
    (+ (* 10000 (nth 5 d)) (* 100 (nth 4 d)) (nth 3 d))))

(defun eda/org--noon (time)
  "TIME moved to 12:00 local, so DST/midnight can't flip the calendar date."
  (let ((d (decode-time time)))
    (setf (nth 0 d) 0 (nth 1 d) 0 (nth 2 d) 12)
    (encode-time d)))

(defun eda/org--add-interval (time n unit)
  "Return TIME advanced by N of repeater UNIT (a char in h d w m y).
`encode-time' normalises overflow, so month/year steps stay calendar-correct."
  (let ((d (decode-time time)))
    (pcase unit
      (?h (cl-incf (nth 2 d) n))
      (?d (cl-incf (nth 3 d) n))
      (?w (cl-incf (nth 3 d) (* 7 n)))
      (?m (cl-incf (nth 4 d) n))
      (?y (cl-incf (nth 5 d) n)))
    (encode-time d)))

(defun eda/org--next-future (ts-string n unit today)
  "Next occurrence time of repeating TS-STRING that is on/after TODAY (YYYYMMDD).
Advances from the original date by whole N/UNIT steps, so the weekday/phase of a
weekly task is preserved (it lands on its true upcoming slot)."
  (let ((tnew (eda/org--noon (org-time-string-to-time ts-string)))
        (guard 0))
    (while (< (eda/org--daynum tnew) today)
      ;; Defensive: a non-advancing step (e.g. an unrecognised unit) would spin
      ;; forever; 100000 daily steps is ~273 years, far past any real overdue.
      (when (> (cl-incf guard) 100000)
        (error "eda/org-catchup: repeater %d%c is not advancing the date" n unit))
      (setq tnew (eda/org--add-interval tnew n unit)))
    tnew))

(defun eda/org--rebuild-ts (ts-string tnew)
  "Return TS-STRING with its date set to TNEW (and a bare `+' mark converted).
Only the date+weekday token and, when `eda/org-catchup-convert-plus', a bare
`+' repeater mark change — time of day, repeater interval, and warning cookies
are preserved verbatim."
  (let ((new (replace-regexp-in-string
              eda/org--ts-date-re
              (format-time-string "%Y-%m-%d %a" tnew)
              ts-string t t)))
    (when (and eda/org-catchup-convert-plus
               (string-match eda/org--repeater-re new)
               (equal (match-string 1 new) "+"))
      (setq new (replace-match
                 (concat eda/org-catchup-repeater-mark
                         (match-string 2 new) (match-string 3 new))
                 t t new)))
    new))

;; --- Scan (pure) / confirm / apply -----------------------------------------

(defun eda/org--collect-catchups ()
  "Scan `org-agenda-files' for overdue REPEATING scheduled/deadline stamps.
Return a list of plists (:marker :file :head :kw :old :new), marker at the `<'
of the timestamp.  No buffers are modified."
  (let ((today (eda/org--daynum (current-time)))
        (plan '()))
    (org-map-entries
     (lambda ()
       (let ((bound (save-excursion (or (outline-next-heading) (point-max))))
             (head  (org-get-heading t t t t)))
         (save-excursion
           (while (re-search-forward
                   "\\(SCHEDULED\\|DEADLINE\\):[ \t]*\\(<[^>\n]+>\\)" bound t)
             (let ((kw     (match-string-no-properties 1))
                   (ts     (match-string-no-properties 2))
                   (ts-beg (match-beginning 2)))
               ;; Read the repeater N/UNIT off the match IMMEDIATELY — the
               ;; `org-time-string-to-time' overdue check below clobbers the
               ;; match data, so extracting after it would give garbage (and a
               ;; bad unit spins `eda/org--next-future' forever).
               (when (string-match eda/org--repeater-re ts)
                 (let ((n    (string-to-number (match-string 2 ts)))
                       (unit (aref (match-string 3 ts) 0)))
                   (when (< (eda/org--daynum (org-time-string-to-time ts)) today)
                     (let ((new (eda/org--rebuild-ts
                                 ts (eda/org--next-future ts n unit today))))
                       (unless (equal new ts)
                         (push (list :marker (copy-marker ts-beg)
                                     :file (buffer-file-name)
                                     :head head :kw kw :old ts :new new)
                               plan)))))))))))
     t 'agenda)
    (nreverse plan)))

(defun eda/org--catchup-confirm (plan)
  "Show PLAN in a dry-run buffer and ask whether to proceed.  Return non-nil to."
  (let ((n (length plan)))
    (with-output-to-temp-buffer "*eda catch-up (dry run)*"
      (princ (format "%d overdue repeating task%s will be fast-forwarded:\n\n"
                     n (if (= n 1) "" "s")))
      (dolist (it plan)
        (princ (format "• %s  [%s]\n    %-9s %s  →  %s\n\n"
                       (plist-get it :head)
                       (file-name-nondirectory (or (plist-get it :file) "?"))
                       (concat (plist-get it :kw) ":")
                       (plist-get it :old) (plist-get it :new)))))
    (yes-or-no-p (format "Fast-forward these %d task%s? " n (if (= n 1) "" "s")))))

;;;###autoload
(defun eda/org-catchup-repeaters (&optional no-confirm)
  "Fast-forward overdue REPEATING org tasks to their next occurrence.
For every SCHEDULED/DEADLINE in `org-agenda-files' that has a repeater
\(+N / ++N / .+N) whose date is in the past, move the date straight to the next
occurrence today-or-later — without touching the TODO state, tags, or body, and
without firing fake DONEs.  With `eda/org-catchup-convert-plus' (default on) a
bare `+' repeater is also rewritten to `eda/org-catchup-repeater-mark' so a
future DONE catches up in one shot.  Shows a dry-run you confirm; a prefix arg
\(\\[universal-argument]) skips the prompt.  Logs `REPEATER_CATCHUP ▶ old → new'
into each changed entry's LOGBOOK, so the edit is auditable and revertible."
  (interactive "P")
  (let ((plan (eda/org--collect-catchups)))
    (cond
     ((null plan)
      (message "eda/org-catchup: no overdue repeating tasks — all caught up."))
     ((and (not no-confirm) (not (eda/org--catchup-confirm plan)))
      (message "eda/org-catchup: aborted — nothing changed (%d would have)."
               (length plan)))
     (t
      (let ((n 0) (bufs '()))
        (dolist (it plan)
          (let ((m (plist-get it :marker)))
            (when (buffer-live-p (marker-buffer m))
              (with-current-buffer (marker-buffer m)
                (save-excursion
                  (goto-char m)
                  (when (looking-at (regexp-quote (plist-get it :old)))
                    (replace-match (plist-get it :new) t t)
                    (cl-incf n)
                    (cl-pushnew (current-buffer) bufs)
                    (when (fboundp 'eda/task--append-logbook)
                      (save-excursion
                        (org-back-to-heading t)
                        (ignore-errors
                          (eda/task--append-logbook
                           (format "REPEATER_CATCHUP ▶ %s → %s"
                                   (plist-get it :old) (plist-get it :new))))))))))))
        (dolist (b bufs) (with-current-buffer b (save-buffer)))
        (message "eda/org-catchup: fast-forwarded %d repeating task%s."
                 n (if (= n 1) "" "s")))))))

(map! :leader
      (:prefix-map ("k o" . "org task engine")
       :desc "Catch up repeating tasks" "u" #'eda/org-catchup-repeaters))

(provide 'eda-repeat)
;;; eda-repeat.el ends here
