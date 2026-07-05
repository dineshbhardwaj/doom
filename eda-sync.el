;;; ~/.config/doom/eda-sync.el  -*- lexical-binding: t; -*-
;;;
;;; Phase 14 · Layer 7 — the sync spine (E7 + E18 + E19).
;;;
;;; Three file classes, three reaches (arch §6). ONLY the one shared client
;;; task file and personal.org ever leave a machine; everything else (worktrees,
;;; session ids, persp/registry state) is machine-local.
;;;
;;;   ~/org/personal.org                     — your TODOs. Mac ↔ iPhone via
;;;                                            organice+Dropbox (E19). R/W.
;;;   ~/org/clients/<x>/tasks.org            — the ONE shared client file.
;;;   ~/org/clients/<x>/outbox.org           — append-only queued mutations
;;;                                            (new tasks + client-idle) made on
;;;                                            a machine that may NOT edit client
;;;                                            work-task state (Mac / mobile).
;;;
;;; ASYMMETRIC PERMISSIONS (E18). Changing a client work-task's STATE or
;;; clocking its work tasks is legal ONLY on the client box
;;; (`eda/portable-can-write-client-state-p'). Everywhere else the client file
;;; opens READ-ONLY; the only mutations you can make — add a task, clock the
;;; client Idle — are captured into the append-only outbox, never written to the
;;; mirror directly.
;;;
;;; TRANSPORT = email (`eda/client-sync-*`). No live network to the isolated,
;;; restricted client box is assumed. Your Mac emails the outbox delta; the
;;; client imports it and UNION-MERGES (`git merge-file --union` on a local
;;; base snapshot, so concurrent edits on both ends don't lose lines), then
;;; emails its full state back, which the Mac imports as the read-only mirror.
;;; A timestamped `.bak' is written on every load of a synced file so a
;;; last-writer-wins clobber (iCloud/Dropbox/organice) is always recoverable.

(require 'org)
(require 'org-id)
(require 'cl-lib)

;; From eda-portable / eda-pclock (loaded earlier).
(defvar eda/portable-org-root)
(defvar eda/portable-profile)
(declare-function eda/portable-client-p "eda-portable")
(declare-function eda/portable-client-name "eda-portable")
(declare-function eda/portable-can-write-client-state-p "eda-portable")
(declare-function eda/exe "eda-portable")
(declare-function eda/pclock--clock-line "eda-pclock")

;; --- Config ----------------------------------------------------------------

(defcustom eda/sync-drop-root nil
  "Per-profile drop location for sync payloads (shared cloud folder / USB).
When nil, defaults to `<org-root>/sync-drop/'. On the Mac this can point at a
Dropbox folder so payloads round-trip without touching email."
  :type '(choice (const nil) directory) :group 'eda)

(defvar eda/sync-client-emails nil
  "Alist (CLIENT . EMAIL) — where `eda/client-sync-export' addresses payloads.")

(defvar eda/sync-send-email t
  "When non-nil, `eda/client-sync-export' also composes an email of the payload.
Set nil for headless/testing (the payload is still written to the drop dir).")

(defvar eda/sync-compose-email-function #'eda/sync--compose-email
  "Function (CLIENT SUBJECT BODY) used to compose the sync email. Overridable.")

(defvar eda/sync-backup-on-load t
  "When non-nil, visiting a synced file first writes a timestamped `.bak'.")

(defvar eda/sync-backup-keep 10
  "How many timestamped `.bak' files to keep per synced file (older pruned).")

(defvar eda/sync--idle-starts (make-hash-table :test 'equal)
  "CLIENT → start-time for an in-progress queued client-idle clock.")

;; --- Paths ------------------------------------------------------------------

(defun eda/sync-clients-dir ()
  (file-name-as-directory (expand-file-name "clients" eda/portable-org-root)))

(defun eda/sync-client-dir (client)
  (file-name-as-directory (expand-file-name client (eda/sync-clients-dir))))

(defun eda/sync-client-file (client)
  "The one shared client task file (real on the client box; mirror on the Mac)."
  (expand-file-name "tasks.org" (eda/sync-client-dir client)))

(defun eda/sync-outbox-file (client)
  "Append-only queued-mutation file for CLIENT (Mac / mobile)."
  (expand-file-name "outbox.org" (eda/sync-client-dir client)))

(defun eda/sync-personal-file ()
  (expand-file-name "personal.org" eda/portable-org-root))

(defun eda/sync-drop-dir ()
  (file-name-as-directory
   (or eda/sync-drop-root (expand-file-name "sync-drop" eda/portable-org-root))))

(defun eda/sync-base-file (client)
  "Last-synced snapshot of CLIENT's file, for 3-way union merge (machine-local)."
  (expand-file-name (format "%s.base.org" client) (eda/sync-drop-dir)))

(defun eda/sync--known-clients ()
  "List client names discovered under the clients dir."
  (let ((dir (eda/sync-clients-dir)))
    (when (file-directory-p dir)
      (cl-remove-if-not
       (lambda (c) (file-directory-p (eda/sync-client-dir c)))
       (cl-remove-if (lambda (f) (member f '("." "..")))
                     (directory-files dir))))))

(defun eda/sync--read-file (file)
  (if (file-readable-p file)
      (with-temp-buffer (insert-file-contents file) (buffer-string))
    ""))

;; --- Backup guard (.bak on load) -------------------------------------------

(defun eda/sync--synced-file-p (file)
  "Non-nil when FILE is one that syncs off-box (personal.org / client files).
Paths are canonicalised with `file-truename' so a symlinked org/Dropbox root
\(or the macOS /var→/private/var link) still matches."
  (and file
       (let ((f (file-truename file)))
         (or (string= f (file-truename (eda/sync-personal-file)))
             (string-prefix-p (file-truename (eda/sync-clients-dir)) f)))))

(defun eda/sync--prune-backups (file)
  "Keep only the newest `eda/sync-backup-keep' `.bak' files for FILE."
  (let* ((base (concat (file-name-nondirectory file) "."))
         (dir  (file-name-directory file))
         (baks (sort (directory-files dir t
                                      (concat "\\`" (regexp-quote base) ".*\\.bak\\'"))
                     #'string<)))          ; oldest first (timestamped names)
    (when (> (length baks) eda/sync-backup-keep)
      (dolist (old (nbutlast baks eda/sync-backup-keep))
        (ignore-errors (delete-file old))))))

(defun eda/sync--backup (file)
  "Write a timestamped `.bak' of FILE (if it exists) and prune old ones."
  (when (and file (file-readable-p file))
    (let ((bak (format "%s.%s.bak" file (format-time-string "%Y%m%d-%H%M%S"))))
      (copy-file file bak t)
      (eda/sync--prune-backups file)
      bak)))

(defun eda/sync--maybe-backup ()
  "`find-file-hook': back up a synced file on load so a clobber is recoverable."
  (when (and eda/sync-backup-on-load
             (buffer-file-name)
             (eda/sync--synced-file-p (buffer-file-name)))
    (ignore-errors (eda/sync--backup (buffer-file-name)))))

;; --- Read-only overlay for the client file on non-client machines (E18) ----

(defun eda/sync--client-file-p (file)
  "Non-nil when FILE is a client `tasks.org' under the clients dir."
  (and file
       (string-prefix-p (file-truename (eda/sync-clients-dir))
                        (file-truename file))
       (string= (file-name-nondirectory file) "tasks.org")))

(defun eda/sync--client-of-file (file)
  "Return the client name owning client FILE, else nil."
  (when (eda/sync--client-file-p file)
    (let* ((rel (file-relative-name (file-truename file)
                                    (file-truename (eda/sync-clients-dir)))))
      (car (split-string rel "/")))))

(defun eda/sync--apply-client-policy ()
  "`find-file-hook': make the client file read-only unless we may edit its state.
On the client box the file is writable; elsewhere it is the read-only mirror and
mutations must go through `eda/client-add-task' / `eda/client-idle-clock'."
  (let ((f (buffer-file-name)))
    (when (eda/sync--client-file-p f)
      (if (eda/portable-can-write-client-state-p)
          (setq buffer-read-only nil)
        (setq buffer-read-only t)
        (setq header-line-format
              (concat " ⚠ CLIENT MIRROR (read-only) — "
                      "SPC k y a add-task · SPC k y i idle · queued to outbox"))
        (message "Client file is read-only here; use the outbox (SPC k y) to queue changes.")))))

;; --- Outbox (append-only queued mutations) ---------------------------------

(defun eda/sync--ensure-outbox (client)
  "Ensure CLIENT's outbox file exists with a header. Return its path."
  (let ((file (eda/sync-outbox-file client)))
    (make-directory (file-name-directory file) t)
    (unless (file-exists-p file)
      (with-temp-file file
        (insert (format "#+TITLE: Outbox — client %s (append-only, queued on %s)\n"
                        client eda/portable-profile)
                "#+FILETAGS: :outbox:\n\n")))
    file))

(defun eda/sync--outbox-append (client text)
  "Append TEXT (an org subtree) to CLIENT's outbox. Return the outbox path."
  (let ((file (eda/sync--ensure-outbox client)))
    (with-temp-buffer
      (insert (string-trim-right text) "\n")
      (write-region (point-min) (point-max) file t 'quiet))
    file))

;;;###autoload
(defun eda/client-add-task (client title)
  "Queue a NEW task for CLIENT (allowed anywhere; queued to the outbox).
On the client box, appends straight to the real `tasks.org' (writable there);
elsewhere it goes to the append-only outbox to be emailed and union-merged."
  (interactive
   (let ((c (completing-read "Client: " (eda/sync--known-clients) nil nil
                             (eda/portable-client-name))))
     (list c (read-string (format "New %s task: " c)))))
  (when (string-empty-p (string-trim title))
    (user-error "Task title is empty"))
  (let* ((slug (downcase (replace-regexp-in-string
                          "\\`-\\|-\\'" ""
                          (replace-regexp-in-string "[^A-Za-z0-9]+" "-" (string-trim title)))))
         (subtree
          (concat
           (format "* TODO %s\t:eda:%s:\n" title client)
           ":PROPERTIES:\n"
           (format ":ID:         %s\n" (org-id-new))
           (format ":TASK_SLUG:  %s\n" slug)
           (format ":CLIENT:     %s\n" client)
           (format ":WORKTREE:   %s\n" slug)
           (format ":MEM_SCOPE:  client-%s\n" client)
           (format ":SYNC_ORIGIN: %s %s\n" eda/portable-profile
                   (format-time-string "[%Y-%m-%d %a %H:%M]"))
           ":DELIVERY:   pending\n"
           ":END:\n")))
    (if (eda/portable-can-write-client-state-p)
        ;; client box: append directly to the real file
        (let ((file (eda/sync-client-file client)))
          (make-directory (file-name-directory file) t)
          (with-temp-buffer
            (when (file-readable-p file) (insert-file-contents file))
            (goto-char (point-max)) (unless (bolp) (insert "\n"))
            (insert "\n" subtree)
            (write-region (point-min) (point-max) file nil 'quiet))
          (message "Added %s task to %s" client (file-name-nondirectory file)))
      (eda/sync--outbox-append client subtree)
      (message "Queued new %s task to outbox (export with SPC k y e)" client))))

;;;###autoload
(defun eda/client-idle-clock (client)
  "Toggle a queued client-idle clock for CLIENT.
First call marks the start; the second appends a completed idle-span subtree
\(unique :ID:, tag :idle:) to the outbox — union-merge keeps every span."
  (interactive
   (list (completing-read "Client (idle): " (eda/sync--known-clients) nil nil
                          (eda/portable-client-name))))
  (let ((start (gethash client eda/sync--idle-starts)))
    (if (not start)
        (progn (puthash client (current-time) eda/sync--idle-starts)
               (message "Client-idle STARTED for %s (toggle again to queue the span)" client))
      (remhash client eda/sync--idle-starts)
      (let* ((end (current-time))
             (clock (if (fboundp 'eda/pclock--clock-line)
                        (eda/pclock--clock-line start end)
                      (let* ((secs (max 0 (floor (float-time (time-subtract end start)))))
                             (h (/ secs 3600)) (m (/ (% secs 3600) 60)))
                        (format "CLOCK: %s--%s =>  %d:%02d"
                                (format-time-string "[%Y-%m-%d %a %H:%M]" start)
                                (format-time-string "[%Y-%m-%d %a %H:%M]" end) h m))))
             (subtree
              (concat
               (format "* Idle span · client-%s\t:idle:\n" client)
               ":PROPERTIES:\n"
               (format ":ID:            %s\n" (org-id-new))
               (format ":EDA_IDLE_SPAN: client-%s\n" client)
               (format ":SYNC_ORIGIN:   %s\n" eda/portable-profile)
               ":END:\n"
               ":LOGBOOK:\n" clock "\n:END:\n")))
        (if (eda/portable-can-write-client-state-p)
            (eda/sync--outbox-append client subtree) ; still queue on client for symmetry
          (eda/sync--outbox-append client subtree))
        (message "Queued client-idle span for %s" client)))))

;; --- Union merge (3-way, --union) + ID dedup -------------------------------

(defun eda/sync--git-merge-file (ours base theirs)
  "Union-merge the base→theirs changes onto OURS. Return the merged string.
Uses `git merge-file -p --union'; with --union there are no conflict markers."
  (let ((fo (make-temp-file "sync-ours-"))
        (fb (make-temp-file "sync-base-"))
        (ft (make-temp-file "sync-theirs-")))
    (unwind-protect
        (progn
          (with-temp-file fo (insert ours))
          (with-temp-file fb (insert base))
          (with-temp-file ft (insert theirs))
          (with-temp-buffer
            (call-process (or (eda/exe "git") "git") nil t nil
                          "merge-file" "-p" "--union" fo fb ft)
            (buffer-string)))
      (mapc (lambda (f) (ignore-errors (delete-file f))) (list fo fb ft)))))

(defun eda/sync--dedup-by-id (text)
  "Drop duplicate LEVEL-1 subtrees sharing the same :ID: (keep the first)."
  (with-temp-buffer
    (insert text)
    (delay-mode-hooks (org-mode))
    (let ((seen (make-hash-table :test 'equal)) dups)
      (org-map-entries
       (lambda ()
         (let ((id (org-entry-get nil "ID")))
           (when id
             (if (gethash id seen)
                 (push (cons (point)
                             (save-excursion (org-end-of-subtree t t) (point)))
                       dups)
               (puthash id t seen)))))
       "LEVEL=1")
      (dolist (r (sort dups (lambda (a b) (> (car a) (car b)))))
        (delete-region (car r) (cdr r)))
      (buffer-string))))

(defun eda/sync-union-merge (ours-text base-text theirs-text)
  "3-way union merge then ID-dedup. Return merged org text."
  (eda/sync--dedup-by-id (eda/sync--git-merge-file ours-text base-text theirs-text)))

;; --- Integrity + drop + email ----------------------------------------------

(defun eda/sync--sha (text) (secure-hash 'sha256 text))

(defun eda/sync--drop-write (client kind text)
  "Write a payload (KIND = full|delta) to the drop dir with a SHA header.
Return the payload file path."
  (let* ((dir (eda/sync-drop-dir))
         (stamp (format-time-string "%Y%m%d-%H%M%S"))
         (file (expand-file-name
                (format "%s.%s.%s.org" client (symbol-name kind) stamp) dir))
         (sha (eda/sync--sha text)))
    (make-directory dir t)
    (with-temp-file file
      (insert (format "#+SYNC_CLIENT: %s\n#+SYNC_KIND: %s\n#+SYNC_ORIGIN: %s\n"
                      client kind eda/portable-profile)
              (format "#+SYNC_SHA256: %s\n\n" sha))
      (insert text))
    file))

(defun eda/sync--compose-email (client subject body)
  "Default transport: open a `compose-mail' buffer addressed to CLIENT."
  (let ((to (cdr (assoc client eda/sync-client-emails))))
    (compose-mail to subject)
    (goto-char (point-max))
    (insert "\n" body)
    (message "Compose the sync email to %s, then send (C-c C-c)." (or to "<set eda/sync-client-emails>"))))

;;;###autoload
(defun eda/client-sync-export (&optional client)
  "Package this machine's outgoing client payload and (optionally) email it.
On the client box the payload is the FULL `tasks.org' state; elsewhere it is the
queued outbox DELTA. Always written to the drop dir with a SHA; emailed too when
`eda/sync-send-email' is non-nil. Returns the payload file path."
  (interactive (list (completing-read "Export client: " (eda/sync--known-clients)
                                      nil nil (eda/portable-client-name))))
  (let* ((client (or client (user-error "No client")))
         (full (eda/portable-can-write-client-state-p))
         (kind (if full 'full 'delta))
         (src  (if full (eda/sync-client-file client) (eda/sync-outbox-file client)))
         (text (eda/sync--read-file src)))
    (when (and (eq kind 'delta) (string-empty-p (string-trim text)))
      (user-error "Outbox for %s is empty — nothing queued to export" client))
    (let* ((file (eda/sync--drop-write client kind text))
           (sha  (eda/sync--sha text)))
      (when eda/sync-send-email
        (ignore-errors
          (funcall eda/sync-compose-email-function
                   client
                   (format "[eda-sync] %s %s (%s)" client kind (substring sha 0 12))
                   text)))
      (message "Exported %s %s → %s" client kind (abbreviate-file-name file))
      file)))

;;;###autoload
(defun eda/client-sync-import (client incoming-file &optional mode)
  "Import a received payload for CLIENT from INCOMING-FILE.
MODE `delta' (client box default) union-merges the incoming outbox into the real
`tasks.org' over a base snapshot; MODE `full' (Mac default) replaces the
read-only mirror wholesale. In both cases the target is backed up first and the
base snapshot is refreshed. Returns the target file path."
  (interactive
   (list (completing-read "Import client: " (eda/sync--known-clients) nil nil
                          (eda/portable-client-name))
         (read-file-name "Payload file: " (eda/sync-drop-dir))))
  (let* ((mode (or mode (if (eda/portable-can-write-client-state-p) 'delta 'full)))
         (incoming (eda/sync--strip-sync-headers (eda/sync--read-file incoming-file)))
         (target (eda/sync-client-file client))
         (base   (eda/sync-base-file client)))
    (make-directory (file-name-directory target) t)
    (make-directory (eda/sync-drop-dir) t)
    (eda/sync--backup target)
    (let ((result
           (pcase mode
             ('full incoming)
             ('delta (eda/sync-union-merge
                      (eda/sync--read-file target)
                      (eda/sync--read-file base)
                      incoming))
             (_ (user-error "Unknown import mode: %s" mode)))))
      (with-temp-file target (insert result))
      (with-temp-file base (insert result))    ; refresh 3-way base
      ;; On the Mac, a full import means the client already applied our queued
      ;; outbox — archive it so we don't re-send stale deltas.
      (when (and (eq mode 'full) (file-exists-p (eda/sync-outbox-file client)))
        (let ((ob (eda/sync-outbox-file client)))
          (rename-file ob (format "%s.%s.applied" ob
                                  (format-time-string "%Y%m%d-%H%M%S"))
                       t)))
      (message "Imported %s (%s) → %s" client mode (abbreviate-file-name target))
      target)))

(defun eda/sync--strip-sync-headers (text)
  "Remove leading `#+SYNC_*' header lines a payload was wrapped with."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (looking-at-p "^#\\+SYNC_")
      (delete-region (point) (min (point-max) (1+ (line-end-position)))))
    ;; drop a single blank separator line
    (when (looking-at-p "^[ \t]*$")
      (delete-region (point) (min (point-max) (1+ (line-end-position)))))
    (buffer-string)))

;; --- Hooks + keys -----------------------------------------------------------

(add-hook 'find-file-hook #'eda/sync--maybe-backup)
(add-hook 'find-file-hook #'eda/sync--apply-client-policy)

(map! :leader
      (:prefix-map ("k y" . "eda sync")
       :desc "Add client task (queue)"   "a" #'eda/client-add-task
       :desc "Client idle clock (queue)" "i" #'eda/client-idle-clock
       :desc "Export payload (email)"    "e" #'eda/client-sync-export
       :desc "Import payload (merge)"    "m" #'eda/client-sync-import))

(provide 'eda-sync)
;;; eda-sync.el ends here
