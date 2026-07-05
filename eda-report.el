;;; ~/.config/doom/eda-report.el  -*- lexical-binding: t; -*-
;;;
;;; Phase 15 · Layer 9 — reporting (E10) + idle net-math (MF2 / E17).
;;;
;;; The parallel-clock engine (E3) writes honest, overlapping `CLOCK:' lines:
;;; every task that had a Claude session up accrues full time, overlaps allowed
;;; (D5). This module turns those raw lines into a weekly report WITHOUT
;;; mutating them (MF2 is non-destructive — raw CLOCK lines stay intact and the
;;; overlap remains auditable via agenda `v c'):
;;;
;;;   - Collective    — total effort (overlap-honest) + a native clocktable.
;;;   - By tag        — one row per tag (:eda: :pcie: <client> :billable: …);
;;;                     a task with N tags counts in each (true grouping, which
;;;                     native clocktable cannot do).
;;;   - By client     — grouped by :CLIENT: (empty ⇒ personal) for invoicing.
;;;   - By task       — per-heading gross + net.
;;;   - Idle net      — net = Σ work CLOCK − Σ (work ∩ idle) overlap. Idle spans
;;;                     are :idle:-tagged entries (the E17 `Idle · <env>' task
;;;                     and the E18 queued client-idle spans). Overlap with a
;;;                     task's own intervals is deducted from that task.
;;;   - Delivered     — entries that reached `:DELIVERY: done' this week, with
;;;                     their `Review ▶' summary — a "what shipped" digest.
;;;
;;; All aggregation is computed in elisp (not native clocktable dblocks) so the
;;; idle-net math and true per-tag grouping are exact and testable. A native
;;; clocktable dblock is still emitted for the familiar raw view.

(require 'org)
(require 'org-clock)
(require 'cl-lib)

(defvar eda/portable-org-root)
(defvar eda/portable-profile)

;; --- Config ----------------------------------------------------------------

(defvar eda/report-dir nil
  "Directory for generated reports. Nil ⇒ `<org-root>/reports/'.")

(defvar eda/report-files nil
  "Org files scanned for CLOCK lines. Nil ⇒ `org-agenda-files'.")

(defvar eda/report-clock-re
  "CLOCK:[ \t]+\\(\\[[^]]*\\]\\)--\\(\\[[^]]*\\]\\)"
  "Matches a closed `CLOCK:' line, capturing its start and end timestamps.")

(defun eda/report--dir ()
  (file-name-as-directory
   (or eda/report-dir (expand-file-name "reports" eda/portable-org-root))))

(defun eda/report--files ()
  (or eda/report-files
      (and (boundp 'org-agenda-files) (org-agenda-files t))
      nil))

;; --- Time helpers -----------------------------------------------------------

(defun eda/report-week-bounds (&optional time)
  "Return (START . END) float-times for the ISO week (Mon 00:00) around TIME."
  (let* ((time (or time (current-time)))
         (dec  (decode-time time))
         (dow  (string-to-number (format-time-string "%u" time))) ; 1=Mon..7=Sun
         (midnight (float-time
                    (encode-time 0 0 0 (nth 3 dec) (nth 4 dec) (nth 5 dec))))
         (monday (- midnight (* (1- dow) 86400))))
    (cons monday (+ monday (* 7 86400)))))

(defun eda/report--fmt-hm (secs)
  "Format SECS (a number) as H:MM."
  (let* ((s (max 0 (round secs))) (m (/ s 60)))
    (format "%d:%02d" (/ m 60) (% m 60))))

(defun eda/report--overlap (a1 a2 b1 b2)
  "Seconds of overlap between intervals [A1,A2] and [B1,B2]."
  (max 0 (- (min a2 b2) (max a1 b1))))

(defun eda/report--merge-intervals (ivs)
  "Merge a list of (S . E) intervals into a disjoint, sorted list."
  (let ((sorted (sort (copy-sequence ivs) (lambda (a b) (< (car a) (car b)))))
        merged)
    (dolist (iv sorted (nreverse merged))
      (if (and merged (<= (car iv) (cdr (car merged))))
          (setcdr (car merged) (max (cdr (car merged)) (cdr iv)))
        (push (cons (car iv) (cdr iv)) merged)))))

;; --- Collection -------------------------------------------------------------

(defun eda/report--entry-clocks (period-start period-end)
  "At a heading, return (S . E) clock intervals clipped to the period.
Scans only this entry's own body (up to the next heading)."
  (save-excursion
    (let ((end (save-excursion (outline-next-heading) (point)))
          res)
      (while (re-search-forward eda/report-clock-re end t)
        ;; Grab BOTH timestamps before parsing — `org-time-string-to-seconds'
        ;; runs its own regexp search and would clobber the match data.
        (let* ((m1 (match-string 1)) (m2 (match-string 2))
               (s (org-time-string-to-seconds m1))
               (e (org-time-string-to-seconds m2)))
          (when (and (numberp s) (numberp e) (> e s)
                     (> (eda/report--overlap s e period-start period-end) 0))
            (push (cons (max s period-start) (min e period-end)) res))))
      (nreverse res))))

(defun eda/report--idle-entry-p (tags)
  (or (member "idle" tags)
      (org-entry-get nil "EDA_IDLE" t)
      (org-entry-get nil "EDA_IDLE_SPAN" t)))

(defun eda/report-collect (&optional time files)
  "Scan FILES for the ISO week around TIME. Return a plist:
  :period (S . E)  :work (list of records)  :idle (merged idle intervals)
Each work record is a plist (:start :end :dur :tags :client :title :file)."
  (let* ((bounds (eda/report-week-bounds time))
         (ps (car bounds)) (pe (cdr bounds))
         (files (or files (eda/report--files)))
         work idle)
    (dolist (file files)
      (when (file-readable-p file)
        (with-current-buffer (find-file-noselect file)
          (org-with-wide-buffer
           (goto-char (point-min))
           (org-map-entries
            (lambda ()
              (let* ((tags   (org-get-tags))
                     (idlep  (eda/report--idle-entry-p tags))
                     (client (org-entry-get nil "CLIENT" t))
                     (title  (org-get-heading t t t t))
                     (ivs    (eda/report--entry-clocks ps pe)))
                (dolist (iv ivs)
                  (if idlep
                      (push iv idle)
                    (push (list :start (car iv) :end (cdr iv)
                                :dur (- (cdr iv) (car iv))
                                :tags (cl-remove "idle" tags :test #'equal)
                                :client (if (or (null client) (string-empty-p client))
                                            "personal" client)
                                :title title :file file)
                          work)))))
            t 'file)))))
    (list :period bounds
          :work (nreverse work)
          :idle (eda/report--merge-intervals idle))))

;; --- Aggregation (gross / idle-overlap / net) ------------------------------

(defun eda/report--gross (records)
  (apply #'+ 0.0 (mapcar (lambda (r) (plist-get r :dur)) records)))

(defun eda/report--idle-overlap (records idle-union)
  "Total overlap (secs) between RECORDS' intervals and the merged IDLE-UNION."
  (apply #'+ 0.0
         (mapcar
          (lambda (r)
            (apply #'+ 0.0
                   (mapcar (lambda (iv)
                             (eda/report--overlap (plist-get r :start) (plist-get r :end)
                                                  (car iv) (cdr iv)))
                           idle-union)))
          records)))

(defun eda/report--net (records idle-union)
  (- (eda/report--gross records) (eda/report--idle-overlap records idle-union)))

(defun eda/report--group (records keyfn)
  "Group RECORDS into an alist KEY→records. KEYFN returns a key or list of keys."
  (let ((tbl (make-hash-table :test 'equal)) order)
    (dolist (r records)
      (let ((keys (funcall keyfn r)))
        (dolist (k (if (listp keys) keys (list keys)))
          (unless (gethash k tbl) (push k order))
          (push r (gethash k tbl)))))
    (mapcar (lambda (k) (cons k (nreverse (gethash k tbl)))) (nreverse order))))

;; --- Org table emission -----------------------------------------------------

(defun eda/report--table (header rows)
  "Return an org table string from HEADER (list) and ROWS (list of lists)."
  (concat
   "| " (mapconcat #'identity header " | ") " |\n"
   "|" (mapconcat (lambda (_) "---") header "+") "|\n"
   (mapconcat (lambda (row)
                (concat "| " (mapconcat (lambda (c) (format "%s" c)) row " | ") " |"))
              rows "\n")
   "\n"))

(defun eda/report--net-table (title groups idle-union &optional key-header extra)
  "Build a GROUPS table (KEY, Gross, Idle, Net) sorted by net desc.
EXTRA, when non-nil, is (fn r)→string for a leading per-group column value
taken from the first record."
  (let ((rows
         (sort
          (mapcar
           (lambda (g)
             (let* ((recs (cdr g))
                    (gross (eda/report--gross recs))
                    (over  (eda/report--idle-overlap recs idle-union))
                    (net   (- gross over)))
               (list net
                     (append
                      (list (car g))
                      (when extra (list (funcall extra (car recs))))
                      (list (eda/report--fmt-hm gross)
                            (eda/report--fmt-hm over)
                            (eda/report--fmt-hm net))))))
           groups)
          (lambda (a b) (> (car a) (car b))))))
    (concat "** " title "\n\n"
            (eda/report--table
             (append (list (or key-header "Key"))
                     (when extra (list "…"))
                     (list "Gross" "Idle" "Net"))
             (mapcar #'cadr rows))
            "\n")))

;; --- Delivery digest --------------------------------------------------------

(defun eda/report--note-time (regexp end)
  "Return the float-time of the newest `- [ts] …REGEXP…' note before END, or nil."
  (save-excursion
    (let (best)
      (while (re-search-forward
              (concat "^[ \t]*- \\(\\[[^]]*\\]\\).*" regexp) end t)
        (let ((tt (org-time-string-to-seconds (match-string 1))))
          (when (and tt (or (null best) (> tt best))) (setq best tt))))
      best)))

(defun eda/report--entry-line (regexp end)
  "Return the text following REGEXP within the entry (up to END), or nil."
  (save-excursion
    (when (re-search-forward regexp end t)
      (string-trim (buffer-substring-no-properties (point) (line-end-position))))))

(defun eda/report-delivered (&optional time files)
  "Return a list of (TITLE . REVIEW-SUMMARY) delivered in the ISO week of TIME."
  (let* ((bounds (eda/report-week-bounds time))
         (ps (car bounds)) (pe (cdr bounds))
         (files (or files (eda/report--files)))
         out)
    (dolist (file files)
      (when (file-readable-p file)
        (with-current-buffer (find-file-noselect file)
          (org-with-wide-buffer
           (goto-char (point-min))
           (org-map-entries
            (lambda ()
              (when (equal (org-entry-get nil "DELIVERY") "done")
                (let* ((end (save-excursion (org-end-of-subtree t t) (point)))
                       (dt  (eda/report--note-time "Delivery ▶ done" end)))
                  (when (and dt (>= dt ps) (< dt pe))
                    (push (cons (org-get-heading t t t t)
                                (or (eda/report--entry-line "Review ▶ " end) "—"))
                          out)))))
            t 'file)))))
    (nreverse out)))

;; --- Report generation ------------------------------------------------------

(defun eda/report--body (data delivered time)
  "Render the report body string from collected DATA + DELIVERED list."
  (let* ((work (plist-get data :work))
         (idle (plist-get data :idle))
         (bounds (plist-get data :period))
         (gross (eda/report--gross work))
         (over  (eda/report--idle-overlap work idle))
         (idle-total (apply #'+ 0.0 (mapcar (lambda (iv) (- (cdr iv) (car iv))) idle))))
    (concat
     (format "#+TITLE: Weekly report — %s\n" (format-time-string "%G-W%V" time))
     "#+STARTUP: overview\n"
     (format "Generated %s · profile %s · %s → %s\n\n"
             (format-time-string "[%Y-%m-%d %a %H:%M]" time)
             eda/portable-profile
             (format-time-string "[%Y-%m-%d]" (seconds-to-time (car bounds)))
             (format-time-string "[%Y-%m-%d]" (seconds-to-time (1- (cdr bounds)))))
     ;; Collective
     "* Collective\n\n"
     (eda/report--table
      '("Metric" "Value")
      (list (list "Gross effort (overlap-honest)" (eda/report--fmt-hm gross))
            (list "Idle overlap" (eda/report--fmt-hm over))
            (list "Net effort" (eda/report--fmt-hm (- gross over)))
            (list "Idle logged" (eda/report--fmt-hm idle-total))
            (list "Work intervals" (number-to-string (length work)))))
     "\nOverlaps are intentional (D5) — several tasks may clock the same wall-clock\n"
     "minute. Audit overlaps with `v c' in the agenda. Idle is subtracted at\n"
     "report time only (MF2); raw CLOCK lines are left untouched.\n\n"
     "#+BEGIN: clocktable :scope agenda-with-archives :block thisweek :maxlevel 3 :wstart 1 :compact t\n#+END:\n\n"
     ;; By tag
     (eda/report--net-table
      "By tag (net of idle)"
      (eda/report--group work (lambda (r) (or (plist-get r :tags) '("(untagged)"))))
      idle "Tag")
     ;; By client
     (eda/report--net-table
      "By client (net of idle)"
      (eda/report--group work (lambda (r) (plist-get r :client)))
      idle "Client")
     ;; By task
     (eda/report--net-table
      "By task (net of idle)"
      (eda/report--group work (lambda (r) (plist-get r :title)))
      idle "Task"
      (lambda (r) (plist-get r :client)))
     ;; Delivered
     "** Delivered this week\n\n"
     (if delivered
         (mapconcat (lambda (d) (format "- *%s* — %s" (car d) (cdr d))) delivered "\n")
       "- (nothing reached :DELIVERY: done this week)")
     "\n")))

;;;###autoload
(defun eda/report-weekly (&optional time)
  "Generate `<reports>/weekly-<isoweek>.org' for the ISO week around TIME.
Reads the raw CLOCK lines, computes per-tag/client/task effort net of idle
overlap (MF2), lists what was delivered, and opens the report."
  (interactive)
  (let* ((time (or time (current-time)))
         (data (eda/report-collect time))
         (delivered (eda/report-delivered time))
         (dir (eda/report--dir))
         (file (expand-file-name (format "weekly-%s.org"
                                         (format-time-string "%G-W%V" time)) dir)))
    (make-directory dir t)
    (with-temp-file file (insert (eda/report--body data delivered time)))
    ;; Best-effort refresh of the native clocktable dblock (needs agenda files).
    (when (called-interactively-p 'any)
      (let ((buf (find-file file)))
        (with-current-buffer buf
          (ignore-errors (org-update-all-dblocks) (save-buffer)))
        (message "Weekly report → %s" (abbreviate-file-name file))))
    file))

;;;###autoload
(defun eda/report-weekly-batch ()
  "Headless entry point for launchd/cron: build this week's report, print path."
  (require 'org-agenda)
  (let ((file (eda/report-weekly)))
    (princ (format "eda-report: wrote %s\n" file))
    file))

;; --- Keys: extend SPC k o ---------------------------------------------------

(map! :leader
      (:prefix-map ("k o" . "org task engine")
       :desc "Weekly report (per-tag/net)" "r" #'eda/report-weekly))

(provide 'eda-report)
;;; eda-report.el ends here
