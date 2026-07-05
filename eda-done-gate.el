;;; ~/.config/doom/eda-done-gate.el  -*- lexical-binding: t; -*-
;;;
;;; Phase 12 · Layer 6 — the DONE-gate: a delivery ritual (E6).
;;;
;;; Marking an EDA task DONE is not free. It must be *delivered*. This module
;;; intercepts the `→ DONE' transition (org-after-todo-state-change-hook) and
;;; runs a four-check ritual, advancing the task's `:DELIVERY:' state machine
;;;
;;;     pending → committed → reviewed → memory → done
;;;
;;; The four checks (decision D6 — ALL required):
;;;   1. Worktree committed   — `git status --porcelain' clean. VOIDED (marked
;;;                             N/A) when the worktree is not a git repo; the
;;;                             other three still apply (open Q4 / offline).
;;;   2. Review prompt        — you answer: delivered / tested / follow-ups.
;;;                             Answers appended to LOGBOOK.
;;;   3. Claude self-review   — headless `claude -p --bare' over the branch diff;
;;;                             terse summary logged; you confirm. Waiver-with-log
;;;                             fallback when `claude' is unavailable (Q4).
;;;   4. Memory updated       — a memory entry keyed by :TASK_SLUG: must exist in
;;;                             the task's `:MEM_SCOPE:' store (personal|client-x).
;;;                             If absent, a stub is opened for you to fill in.
;;;
;;; On all-pass: kill+snapshot the Claude session (E4), commit the transcript to
;;; the worktree branch (git-checkable delivery), clock the task out (E3/MF1),
;;; set `:DELIVERY: done', and allow DONE. On any failure: reset the task to
;;; REVIEW and report what is missing (so the veto is visible, not silent).
;;;
;;; Mechanism note: we do NOT use `org-blocker-hook' to forbid DONE while
;;; :DELIVERY: ≠ done — that would deadlock, since the gate itself is what sets
;;; :DELIVERY: done during the very transition a blocker would refuse. Instead
;;; the after-change hook runs the gate and resets state on veto (per arch §E6).

(require 'org)
(require 'cl-lib)

;; From eda-portable / eda-task-engine / eda-pclock / eda-workspace-claude.
(defvar eda/ws-claudes)
(defvar eda/pclock-active)
(declare-function eda/exe "eda-portable")
(declare-function eda/portable-git-available-p "eda-portable")
(declare-function eda/portable-claude-available-p "eda-portable")
(declare-function eda/portable-personal-memory-dir "eda-portable")
(declare-function eda/portable-memory-root "eda-portable")
(declare-function eda/task--marker "eda-task-engine")
(declare-function eda/task--eda-entry-p "eda-task-engine")
(declare-function eda/task-prop "eda-task-engine")
(declare-function eda/task-set-prop "eda-task-engine")
(declare-function eda/task-worktree "eda-task-engine")
(declare-function eda/task-workspace "eda-task-engine")
(declare-function eda/task-role "eda-task-engine")
(declare-function eda/task-stop-session "eda-task-engine")
(declare-function eda/task--append-logbook "eda-task-engine")
(declare-function eda/ws-claude--snapshot-one "eda-workspace-claude")
(declare-function eda/pclock-out "eda-pclock")
;; Memory store (E8 / eda-memory.el) — the canonical owner of :MEM_SCOPE:.
(declare-function eda/mem-normalize-scope "eda-memory")
(declare-function eda/mem-entry-file "eda-memory")
(declare-function eda/mem-entry-nontrivial-p "eda-memory")
(declare-function eda/mem-entry-stub "eda-memory")
(declare-function eda/mem-index-add "eda-memory")
(declare-function eda/mem-distill-for-task "eda-memory")

;; --- Config ----------------------------------------------------------------

(defvar eda/done-gate-states '("DONE")
  "TODO states whose entry triggers the DONE-gate ritual.")

(defvar eda/done-gate-reset-state "REVIEW"
  "TODO state a task is reset to when the gate vetoes the DONE transition.")

(defvar eda/done-gate-run-self-review t
  "When non-nil, run the headless `claude' self-review (check 3).")

(defvar eda/done-gate-claude-args '("-p" "--bare" "--output-format" "json")
  "Args passed to `claude' for the self-review (diff is piped on stdin).")

(defvar eda/done-gate-review-prompt
  (concat "Review this git diff for correctness and risks. Be terse: list only "
          "concrete issues, one per line. If nothing stands out, reply LGTM.")
  "Prompt handed to `claude' for the self-review of the branch diff.")

(defvar eda/done-gate-max-diff-chars 60000
  "Diff longer than this (chars) is truncated before the self-review.")

(defvar eda/done-gate--running nil
  "Bound non-nil while the gate runs, to stop the state reset from re-entering.")

;; --- git helper ------------------------------------------------------------

(defun eda/done-gate--git (wt &rest args)
  "Run git ARGS inside worktree WT. Return (EXIT-CODE . OUTPUT-STRING)."
  (if (not (eda/portable-git-available-p))
      (cons 1 "")
    (with-temp-buffer
      (let ((code (apply #'call-process (or (eda/exe "git") "git")
                         nil t nil "-C" (directory-file-name wt) args)))
        (cons code (buffer-string))))))

(defun eda/done-gate--git-repo-p (wt)
  "Non-nil when WT is inside a git work tree."
  (and (eda/portable-git-available-p)
       (file-directory-p wt)
       (= 0 (car (eda/done-gate--git wt "rev-parse" "--is-inside-work-tree")))))

;; --- DELIVERY state machine + audit trail ----------------------------------

(defun eda/done-gate--set (marker state)
  "Set the task's :DELIVERY: to STATE, logging the transition once."
  (let ((cur (eda/task-prop marker "DELIVERY")))
    (unless (equal cur state)
      (eda/task-set-prop marker "DELIVERY" state)
      (org-with-point-at marker
        (eda/task--append-logbook (format "Delivery ▶ %s" state))))))

;; --- Check 1: worktree committed -------------------------------------------

(defun eda/done-gate--check-commit (wt marker)
  "Check that WT is committed. Return (OK . DETAIL). VOID when not a git repo."
  (if (not (eda/done-gate--git-repo-p wt))
      (progn
        (org-with-point-at marker
          (eda/task--append-logbook "Delivery ▶ commit VOID — not a git repo (N/A)"))
        (cons t "N/A (not a git repo)"))
    (let ((porcelain (string-trim (cdr (eda/done-gate--git wt "status" "--porcelain")))))
      (if (string-empty-p porcelain)
          (cons t "clean")
        (if (y-or-n-p (format "Worktree has uncommitted changes:\n%s\n\nAuto-commit now? "
                              porcelain))
            (let* ((slug  (or (eda/task-prop marker "TASK_SLUG") "task"))
                   (title (org-with-point-at marker (org-get-heading t t t t)))
                   (msg   (format "task %s: deliver — %s" slug title)))
              (eda/done-gate--git wt "add" "-A")
              (let ((r (eda/done-gate--git wt "commit" "-m" msg)))
                (if (= 0 (car r))
                    (progn
                      (org-with-point-at marker
                        (eda/task--append-logbook (format "Delivery ▶ auto-committed: %s" msg)))
                      (cons t "auto-committed"))
                  (cons nil (format "auto-commit failed: %s" (string-trim (cdr r)))))))
          (cons nil (format "worktree dirty — commit or stash first:\n%s" porcelain)))))))

;; --- Check 2: review prompt answered ---------------------------------------

(defun eda/done-gate--logbook-has-p (marker regexp)
  "Non-nil if REGEXP occurs in the LOGBOOK/body of the entry at MARKER."
  (org-with-point-at marker
    (save-excursion
      (org-back-to-heading t)
      (re-search-forward regexp (save-excursion (outline-next-heading) (point)) t))))

(defun eda/done-gate--check-review (marker)
  "Ask what was delivered/tested/pending; log to LOGBOOK. Return (OK . DETAIL).
Idempotent: a prior `Review ▶' entry satisfies the check without re-asking."
  (if (eda/done-gate--logbook-has-p marker "Review ▶")
      (cons t "already answered")
    (let ((delivered (string-trim (read-string "Review · what was delivered? ")))
          (tested     (string-trim (read-string "Review · what was tested? ")))
          (follow     (string-trim (read-string "Review · follow-ups (blank = none)? "))))
      (if (string-empty-p delivered)
          (cons nil "review answers required (\"what was delivered?\" was blank)")
        (org-with-point-at marker
          (eda/task--append-logbook
           (format "Review ▶ delivered: %s · tested: %s · follow-ups: %s"
                   delivered
                   (if (string-empty-p tested) "—" tested)
                   (if (string-empty-p follow) "none" follow))))
        (cons t "answered")))))

;; --- Check 3: Claude self-review of the branch diff ------------------------

(defun eda/done-gate--base-ref (wt)
  "Best guess at the branch WT diverged from: origin/HEAD, else main/master."
  (let ((r (eda/done-gate--git wt "symbolic-ref" "--quiet" "--short"
                               "refs/remotes/origin/HEAD")))
    (if (and (= 0 (car r)) (not (string-empty-p (string-trim (cdr r)))))
        (string-trim (cdr r))
      (cl-some (lambda (ref)
                 (and (= 0 (car (eda/done-gate--git wt "rev-parse" "--verify" "--quiet" ref)))
                      ref))
               '("main" "master" "origin/main" "origin/master")))))

(defun eda/done-gate--diff (wt)
  "Return the branch diff string for WT (base..HEAD), or \"\" if none."
  (let* ((ref  (eda/done-gate--base-ref wt))
         (base (and ref
                    (let ((r (eda/done-gate--git wt "merge-base" "HEAD" ref)))
                      (and (= 0 (car r)) (string-trim (cdr r)))))))
    (string-trim
     (cdr (if base
              (eda/done-gate--git wt "diff" (concat base "..HEAD"))
            ;; No base to compare against — review the tip commit alone.
            (eda/done-gate--git wt "show" "--format=medium" "HEAD"))))))

(defun eda/done-gate--extract-result (json-or-text)
  "Return the `result' field from claude JSON output, else the raw text."
  (condition-case nil
      (let ((obj (json-parse-string json-or-text :object-type 'alist)))
        (or (alist-get 'result obj) json-or-text))
    (error json-or-text)))

(defun eda/done-gate--claude-review (wt diff)
  "Run the headless self-review of DIFF in WT. Return the summary, or nil."
  (let ((tmp (make-temp-file "eda-diff-" nil ".txt")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert (if (> (length diff) eda/done-gate-max-diff-chars)
                        (concat (substring diff 0 eda/done-gate-max-diff-chars)
                                "\n…[diff truncated for review]")
                      diff)))
          (with-temp-buffer
            (let* ((default-directory (file-name-as-directory wt))
                   (code (apply #'call-process (eda/exe "claude") tmp t nil
                                (append eda/done-gate-claude-args
                                        (list eda/done-gate-review-prompt)))))
              (when (= 0 code)
                (eda/done-gate--extract-result (string-trim (buffer-string)))))))
      (ignore-errors (delete-file tmp)))))

(defun eda/done-gate--check-self-review (wt marker)
  "Claude self-review of the diff (check 3). Return (OK . DETAIL)."
  (cond
   ((not eda/done-gate-run-self-review) (cons t "disabled"))
   ((eda/done-gate--logbook-has-p marker "Self-review ▶") (cons t "already reviewed"))
   ((not (eda/done-gate--git-repo-p wt))
    (org-with-point-at marker
      (eda/task--append-logbook "Self-review ▶ N/A — not a git repo"))
    (cons t "N/A (not a git repo)"))
   (t
    (let ((diff (eda/done-gate--diff wt)))
      (cond
       ((string-empty-p diff)
        (org-with-point-at marker
          (eda/task--append-logbook "Self-review ▶ N/A — no changes vs base"))
        (cons t "N/A (empty diff)"))
       ((not (eda/portable-claude-available-p))
        (if (y-or-n-p "`claude' unavailable — waive self-review with a logged note? ")
            (progn
              (org-with-point-at marker
                (eda/task--append-logbook "Self-review ▶ WAIVED — claude unavailable"))
              (cons t "waived (claude unavailable)"))
          (cons nil "self-review required but `claude' is unavailable")))
       (t
        (message "DONE-gate: running Claude self-review…")
        (let ((summary (eda/done-gate--claude-review wt diff)))
          (if (not summary)
              (if (y-or-n-p "Self-review failed to run — waive with a logged note? ")
                  (progn
                    (org-with-point-at marker
                      (eda/task--append-logbook "Self-review ▶ WAIVED — review command failed"))
                    (cons t "waived (review failed)"))
                (cons nil "self-review command failed"))
            (let ((one-line (replace-regexp-in-string "[ \t\n]+" " " (string-trim summary))))
              (org-with-point-at marker
                (eda/task--append-logbook
                 (concat "Self-review ▶ "
                         (truncate-string-to-width one-line 400 nil nil "…"))))
              (if (y-or-n-p (format "Claude self-review:\n\n%s\n\nAccept and proceed? "
                                    (truncate-string-to-width summary 1000 nil nil "…")))
                  (cons t "reviewed")
                (cons nil "self-review not accepted — address findings, then re-run")))))))))))

;; --- Check 4: memory entry present (delegates to the E8 store) -------------

(defvar eda/done-gate--open-after nil
  "Path to open (find-file) after the gate resolves, e.g. a memory stub.")

(defun eda/done-gate--check-memory (marker)
  "Require a memory entry keyed by :TASK_SLUG: in the :MEM_SCOPE: store (E8).
When satisfied, register it in the store INDEX and pass. On a miss, offer to
distill the lesson with Claude (else drop a stub), queue the entry to open,
and fail — so the memory is always reviewed by a human before DONE."
  (let* ((scope (eda/mem-normalize-scope (eda/task-prop marker "MEM_SCOPE" t)))
         (slug  (or (eda/task-prop marker "TASK_SLUG" t)
                    (user-error "Task has no :TASK_SLUG: — run `eda/task-init' first")))
         (title (org-with-point-at marker (org-get-heading t t t t)))
         (file  (eda/mem-entry-file scope slug)))
    (if (eda/mem-entry-nontrivial-p file)
        (progn
          (eda/mem-index-add scope slug title)
          (cons t (format "present (%s)" (abbreviate-file-name file))))
      (if (and (eda/portable-claude-available-p)
               (y-or-n-p "No memory entry yet — draft the lesson with Claude now? "))
          (progn
            (message "DONE-gate: distilling the task's lesson…")
            (eda/mem-distill-for-task marker nil))
        (unless (file-exists-p file)
          (eda/mem-entry-stub scope slug title)))
      (setq eda/done-gate--open-after file)
      (cons nil (format "review/complete the memory entry: %s"
                        (abbreviate-file-name file))))))

;; --- The gate + finalizer ---------------------------------------------------

(defun eda/done-gate--run (marker)
  "Run the four checks in order for the task at MARKER.
Advances :DELIVERY: as stages pass. Returns nil on all-pass, else a plist
\(:stage STAGE :msg MSG) describing the first failure (see `--open-after')."
  (setq eda/done-gate--open-after nil)
  (let ((wt (eda/task-worktree marker)))
    (catch 'fail
      ;; 1 — committed
      (let ((r (eda/done-gate--check-commit wt marker)))
        (if (car r) (eda/done-gate--set marker "committed")
          (throw 'fail (list :stage "committed" :msg (cdr r)))))
      ;; 2 + 3 — reviewed (human review, then Claude self-review)
      (let ((r (eda/done-gate--check-review marker)))
        (unless (car r) (throw 'fail (list :stage "reviewed" :msg (cdr r)))))
      (let ((r (eda/done-gate--check-self-review wt marker)))
        (if (car r) (eda/done-gate--set marker "reviewed")
          (throw 'fail (list :stage "reviewed" :msg (cdr r)))))
      ;; 4 — memory
      (let ((r (eda/done-gate--check-memory marker)))
        (if (car r) (eda/done-gate--set marker "memory")
          (throw 'fail (list :stage "memory" :msg (cdr r)))))
      nil)))

(defun eda/done-gate--finalize (marker)
  "All checks passed: snapshot+commit the session, clock out, kill it, mark done."
  (let* ((wt   (eda/task-worktree marker))
         (ws   (eda/task-workspace marker))
         (role (or (eda/task-role marker) 'architect))
         (slug (or (eda/task-prop marker "TASK_SLUG") "task"))
         (id   (org-with-point-at marker (org-id-get))))
    ;; Kill the session (snapshots the transcript .md as a side effect, E4).
    ;; If the task is clocked, route through pclock-out so a CLOCK line is
    ;; written and MF1 kills the session; otherwise stop it directly.
    (if (and (boundp 'eda/pclock-active) id (gethash id eda/pclock-active))
        (ignore-errors (eda/pclock-out marker))
      (ignore-errors (eda/task-stop-session ws role)))
    ;; Commit the freshly-written session transcript so "what Claude did" is
    ;; reviewable in the branch history (git-checkable delivery).
    (when (eda/done-gate--git-repo-p wt)
      (eda/done-gate--git wt "add" ".claude/sessions")
      (let ((r (eda/done-gate--git wt "commit" "-m"
                                   (format "task %s: session transcript" slug))))
        (when (= 0 (car r))
          (org-with-point-at marker
            (eda/task--append-logbook "Delivery ▶ session transcript committed")))))
    (eda/done-gate--set marker "done")
    (org-with-point-at marker
      (when buffer-file-name (save-buffer)))))

;;;###autoload
(defun eda/task-done (&optional marker)
  "Run the DONE-gate ritual for the task at point (or MARKER).
On all-pass: finalize (snapshot/commit/clock-out/kill) and set the task DONE.
On veto: reset the task to `eda/done-gate-reset-state' and report what's missing."
  (interactive)
  (setq marker (or marker (eda/task--marker)))
  (unless (org-with-point-at marker (eda/task--eda-entry-p))
    (user-error "Not an EDA task (no schema) — run `eda/task-init' first"))
  (let ((eda/done-gate--running t))
    (let ((fail (eda/done-gate--run marker)))
      (cond
       (fail
        (org-with-point-at marker
          (unless (equal (org-get-todo-state) eda/done-gate-reset-state)
            (org-todo eda/done-gate-reset-state)))
        (when eda/done-gate--open-after
          (find-file eda/done-gate--open-after))
        (message "DONE blocked at `%s': %s"
                 (plist-get fail :stage) (plist-get fail :msg)))
       (t
        (eda/done-gate--finalize marker)
        (org-with-point-at marker (org-todo "DONE"))
        (message "✓ Delivered — task DONE, session closed"))))))

;; --- Trigger: intercept `→ DONE' on the state-change hook ------------------

(defun eda/done-gate--on-state-change ()
  "When an EDA entry enters a DONE state, run the gate; reset to REVIEW on veto."
  (when (and (not eda/done-gate--running)
             (boundp 'org-state) org-state
             (member org-state eda/done-gate-states)
             (eda/task--eda-entry-p))
    (let ((eda/done-gate--running t)
          (marker (point-marker)))
      (condition-case err
          (let ((fail (eda/done-gate--run marker)))
            (if fail
                (progn
                  (org-with-point-at marker (org-todo eda/done-gate-reset-state))
                  (when eda/done-gate--open-after
                    (find-file eda/done-gate--open-after))
                  (message "DONE blocked at `%s': %s — reset to %s"
                           (plist-get fail :stage) (plist-get fail :msg)
                           eda/done-gate-reset-state))
              (eda/done-gate--finalize marker)
              (message "✓ Delivered — task DONE, session closed")))
        (error
         (org-with-point-at marker (org-todo eda/done-gate-reset-state))
         (message "DONE-gate error (reset to %s): %s"
                  eda/done-gate-reset-state (error-message-string err)))))))

;; Run AFTER the task engine's own state-change hook (session autostart), so a
;; reset-to-REVIEW leaves a live/resumable session to finish the work in.
(add-hook 'org-after-todo-state-change-hook #'eda/done-gate--on-state-change t)

;; --- Keys: extend SPC k o ---------------------------------------------------

(map! :leader
      (:prefix-map ("k o" . "org task engine")
       :desc "Done-gate (deliver + close)" "d" #'eda/task-done))

(provide 'eda-done-gate)
;;; eda-done-gate.el ends here
