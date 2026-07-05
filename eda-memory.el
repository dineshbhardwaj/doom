;;; ~/.config/doom/eda-memory.el  -*- lexical-binding: t; -*-
;;;
;;; Phase 13 · Layer 8 — two isolated memory stores (E8).
;;;
;;; Collective memory that compounds across sessions, split into TWO stores
;;; with different reaches (decision D8):
;;;
;;;   personal   ~/.claude/memory/personal/      — how you work, general EDA
;;;              skills, tool gotchas. SYNCS EVERYWHERE (chezmoi/git). Its
;;;              INDEX.md is @-imported by every worktree CLAUDE.md.
;;;   client-<x> ~/.claude/memory/clients/<x>/    — confidential, per-client.
;;;              Exists ONLY on that client's machine, NEVER synced off. Its
;;;              INDEX.md is @-imported by a worktree CLAUDE.md *only when this
;;;              machine's profile is that client* (the L0 gate — see
;;;              `eda/mem-imports-for').
;;;
;;; Because Claude Code auto-loads CLAUDE.md at session start and follows
;;; `@path' imports, a session automatically reads the right memory the moment
;;; it starts — no custom injection needed beyond generating the correct import
;;; lines per worktree (`eda/mem-ensure-imports', called from `eda/task-start').
;;;
;;; The DONE-gate's step 4 (E6) requires a memory entry keyed by :TASK_SLUG: in
;;; the task's :MEM_SCOPE: store; this module owns that store — the entry file,
;;; the INDEX pointer, the non-trivial-body predicate, and an optional
;;; `claude -p --bare' distill that drafts the lesson from the task + its diff
;;; (Q6: distill per-DONE; client lessons are distilled locally and never leave
;;; the box).

(require 'cl-lib)

;; From eda-portable / eda-task-engine (loaded earlier).
(defvar eda/portable-memory-root)
(declare-function eda/portable-client-name "eda-portable")
(declare-function eda/portable-claude-available-p "eda-portable")
(declare-function eda/exe "eda-portable")
(declare-function eda/task--marker "eda-task-engine")
(declare-function eda/task-prop "eda-task-engine")
(declare-function eda/task-worktree "eda-task-engine")
(declare-function eda/done-gate--diff "eda-done-gate")

;; --- Config ----------------------------------------------------------------

(defvar eda/mem-index-filename "INDEX.md"
  "Basename of the per-store index that worktree CLAUDE.md files @-import.")

(defvar eda/mem-min-body-chars 15
  "A memory entry counts as \"present\" only if its body (minus HTML-comment
scaffolding and whitespace) has at least this many characters.")

(defvar eda/mem-distill-args '("-p" "--bare" "--output-format" "json")
  "Args passed to `claude' when distilling a lesson (context piped on stdin).")

(defvar eda/mem-distill-prompt
  (concat "From the task context and diff below, distill ONE durable, reusable "
          "lesson for future work — a gotcha, a non-obvious constraint, or a "
          "technique worth remembering next time. Output ONLY the lesson as 2–4 "
          "sentences of Markdown prose. No preamble, no heading, no restating "
          "the task.")
  "Prompt handed to `claude' to draft a memory entry from a finished task.")

;; --- Scope + store resolution ----------------------------------------------

(defun eda/mem-normalize-scope (scope)
  "Return a canonical scope string: nil/\"\"/\"personal\" → \"personal\"."
  (if (or (null scope) (string-empty-p scope)) "personal" scope))

(defun eda/mem-client-of-scope (scope)
  "Return the client name in SCOPE (\"client-acme\" → \"acme\"), else nil."
  (let ((s (eda/mem-normalize-scope scope)))
    (and (string-prefix-p "client-" s) (substring s (length "client-")))))

(defun eda/mem-store-dir (scope)
  "Resolve the memory store directory for SCOPE (personal | client-<x>)."
  (let ((client (eda/mem-client-of-scope scope)))
    (file-name-as-directory
     (if client
         (expand-file-name (format "clients/%s" client) eda/portable-memory-root)
       (expand-file-name "personal" eda/portable-memory-root)))))

(defun eda/mem-syncable-p (scope)
  "Non-nil when SCOPE's store may be synced off-box (personal only)."
  (null (eda/mem-client-of-scope scope)))

(defun eda/mem-index-file (scope)
  "Absolute path of SCOPE's INDEX file."
  (expand-file-name eda/mem-index-filename (eda/mem-store-dir scope)))

(defun eda/mem-entry-file (scope slug)
  "Absolute path of the memory entry for SLUG in SCOPE's store."
  (expand-file-name (concat slug ".md") (eda/mem-store-dir scope)))

;; --- Store bootstrap --------------------------------------------------------

(defun eda/mem-ensure-store (scope)
  "Create SCOPE's store dir and seed its INDEX.md header if absent. Return dir."
  (let* ((dir   (eda/mem-store-dir scope))
         (index (expand-file-name eda/mem-index-filename dir)))
    (make-directory dir t)
    (unless (file-exists-p index)
      (with-temp-file index
        (insert (format "# %s memory index\n\n" (eda/mem-normalize-scope scope)))
        (insert (if (eda/mem-syncable-p scope)
                    "Personal store — syncs to every machine.\n"
                  "Client store — LOCAL to this machine, never synced off-box.\n"))
        (insert "One pointer per entry; Claude reads this at session start "
                "(via each worktree CLAUDE.md @-import).\n\n")))
    dir))

;; --- Entry predicate + stub -------------------------------------------------

(defun eda/mem--body-after-frontmatter ()
  "In the current buffer, return the text after a leading YAML frontmatter."
  (goto-char (point-min))
  (when (looking-at-p "^---[ \t]*$")
    (forward-line 1)
    (when (re-search-forward "^---[ \t]*$" nil t) (forward-line 1)))
  (buffer-substring-no-properties (point) (point-max)))

(defun eda/mem-entry-nontrivial-p (file)
  "Non-nil when memory FILE exists and carries a non-trivial body.
HTML-comment scaffolding and whitespace do not count toward the body."
  (and (file-readable-p file)
       (let ((body (with-temp-buffer
                     (insert-file-contents file)
                     (eda/mem--body-after-frontmatter))))
         (>= (length (string-trim
                      (replace-regexp-in-string "<!--\\(.\\|\n\\)*?-->" "" body)))
             eda/mem-min-body-chars))))

(defun eda/mem-write-entry (scope slug title body)
  "Write BODY as SCOPE's memory entry for SLUG (with frontmatter). Return path."
  (eda/mem-ensure-store scope)
  (let ((file (eda/mem-entry-file scope slug)))
    (with-temp-file file
      (insert "---\n")
      (insert (format "name: %s\n" slug))
      (insert (format "description: %s\n" title))
      (insert "metadata:\n  type: project\n")
      (insert (format "  scope: %s\n" (eda/mem-normalize-scope scope)))
      (insert "---\n\n")
      (insert (string-trim body) "\n"))
    file))

(defun eda/mem-entry-stub (scope slug title)
  "Create an empty fill-in memory entry for SLUG in SCOPE. Return path."
  (eda/mem-write-entry
   scope slug title
   (concat "<!-- Write the durable lesson from this task before closing.\n"
           "     What was non-obvious? What should future-you (or Claude) know\n"
           "     next time? Replace this comment, save, then re-mark DONE. -->")))

;; --- INDEX registry ---------------------------------------------------------

(defun eda/mem-index-add (scope slug title)
  "Add a one-line pointer for (SLUG, TITLE) to SCOPE's INDEX (idempotent)."
  (eda/mem-ensure-store scope)
  (let* ((index (eda/mem-index-file scope))
         (ref   (format "(%s.md)" slug))
         (line  (format "- [%s](%s.md) — %s"
                        title slug (format-time-string "%Y-%m-%d")))
         (text  (and (file-readable-p index)
                     (with-temp-buffer (insert-file-contents index)
                                       (buffer-string)))))
    (unless (and text (string-match-p (regexp-quote ref) text))
      (with-temp-buffer
        (when text
          (insert text)
          (unless (string-suffix-p "\n" text) (insert "\n")))
        (insert line "\n")
        (write-region (point-min) (point-max) index nil 'quiet)))))

;; --- CLAUDE.md import generation (the machine-gated boundary) --------------

(defun eda/mem--import-line (file)
  "Return the CLAUDE.md `@'-import line for FILE (home-relative when possible)."
  (concat "@" (abbreviate-file-name file)))

(defun eda/mem-imports-for (scope)
  "Return the @-import lines valid on THIS machine for a task in SCOPE.
Personal INDEX is always imported. A client store's INDEX is imported ONLY
when this machine's profile is that client — so a personal Mac never imports
\(nonexistent, confidential) client memory. This is the L0 gate."
  (let ((lines (list (eda/mem--import-line (eda/mem-index-file "personal"))))
        (client (eda/mem-client-of-scope scope)))
    (when (and client (equal client (ignore-errors (eda/portable-client-name))))
      (eda/mem-ensure-store scope)
      (push (eda/mem--import-line (eda/mem-index-file scope)) lines))
    (eda/mem-ensure-store "personal")
    (nreverse lines)))

;;;###autoload
(defun eda/mem-ensure-imports (wt &optional scope)
  "Ensure <WT>/CLAUDE.md @-imports the memory stores allowed on this machine.
Idempotent — only missing import lines are appended, under a marked block."
  (let* ((scope   (eda/mem-normalize-scope scope))
         (imports (eda/mem-imports-for scope))
         (claude-md (expand-file-name "CLAUDE.md" wt))
         (existing (and (file-readable-p claude-md)
                        (with-temp-buffer (insert-file-contents claude-md)
                                          (buffer-string))))
         (missing (cl-remove-if
                   (lambda (l) (and existing (string-match-p (regexp-quote l) existing)))
                   imports)))
    (when missing
      (make-directory wt t)
      (with-temp-buffer
        (when existing
          (insert existing)
          (unless (string-suffix-p "\n" existing) (insert "\n")))
        (insert "\n<!-- eda-memory: collective memory imports (auto) -->\n")
        (dolist (l missing) (insert l "\n"))
        (write-region (point-min) (point-max) claude-md nil 'quiet)))
    claude-md))

;; --- Distill (claude -p --bare) --------------------------------------------

(defun eda/mem--extract-result (json-or-text)
  "Return the `result' field of claude JSON output, else the raw text."
  (condition-case nil
      (let ((obj (json-parse-string json-or-text :object-type 'alist)))
        (or (alist-get 'result obj) json-or-text))
    (error json-or-text)))

(defun eda/mem--task-context (marker)
  "Assemble distill context (task heading/body + branch diff) for MARKER."
  (let* ((wt   (ignore-errors (eda/task-worktree marker)))
         (body (org-with-point-at marker
                 (save-excursion
                   (org-back-to-heading t)
                   (buffer-substring-no-properties
                    (point) (save-excursion (outline-next-heading) (point))))))
         (diff (and wt (fboundp 'eda/done-gate--diff)
                    (ignore-errors (eda/done-gate--diff wt)))))
    (concat "## Task\n\n```org\n" (string-trim body) "\n```\n"
            (if (and diff (not (string-empty-p diff)))
                (concat "\n## Diff\n\n```diff\n"
                        (truncate-string-to-width diff 40000 nil nil "\n…[truncated]")
                        "\n```\n")
              ""))))

(defun eda/mem--distill-text (context)
  "Run `claude' to distill a lesson from CONTEXT. Return the text, or nil."
  (when (eda/portable-claude-available-p)
    (let ((tmp (make-temp-file "eda-distill-" nil ".md")))
      (unwind-protect
          (progn
            (with-temp-file tmp (insert context))
            (with-temp-buffer
              (let ((code (apply #'call-process (eda/exe "claude") tmp t nil
                                 (append eda/mem-distill-args
                                         (list eda/mem-distill-prompt)))))
                (when (= 0 code)
                  (let ((r (string-trim (eda/mem--extract-result
                                         (string-trim (buffer-string))))))
                    (and (not (string-empty-p r)) r))))))
        (ignore-errors (delete-file tmp))))))

;;;###autoload
(defun eda/mem-distill-for-task (marker &optional open)
  "Distill and write a memory entry for the task at MARKER.
Runs `claude -p --bare' over the task context + diff; on success writes the
lesson to the :MEM_SCOPE: store and registers it in that store's INDEX. With
OPEN non-nil (interactive), visits the entry. Returns the entry path or nil."
  (interactive (list (eda/task--marker) t))
  (let* ((scope (eda/mem-normalize-scope (eda/task-prop marker "MEM_SCOPE" t)))
         (slug  (or (eda/task-prop marker "TASK_SLUG" t)
                    (user-error "Task has no :TASK_SLUG: — run `eda/task-init' first")))
         (title (org-with-point-at marker (org-get-heading t t t t)))
         (_ (when (called-interactively-p 'any)
              (message "Distilling lesson with Claude…")))
         (lesson (eda/mem--distill-text (eda/mem--task-context marker))))
    (if (not lesson)
        (progn
          (when (called-interactively-p 'any)
            (message "Distill failed (claude unavailable or errored) — writing a stub"))
          (let ((f (eda/mem-entry-stub scope slug title)))
            (when open (find-file f))
            nil))
      (let ((file (eda/mem-write-entry
                   scope slug title
                   (concat lesson
                           "\n\n<!-- distilled by claude on DONE; edit freely -->"))))
        (eda/mem-index-add scope slug title)
        (when open (find-file file))
        (message "Distilled lesson → %s" (abbreviate-file-name file))
        file))))

;; --- Keys: extend SPC k o ---------------------------------------------------

(map! :leader
      (:prefix-map ("k o" . "org task engine")
       :desc "Distill task memory (Claude)" "m" #'eda/mem-distill-for-task))

(provide 'eda-memory)
;;; eda-memory.el ends here
