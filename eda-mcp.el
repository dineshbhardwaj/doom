;;; ~/.config/doom/eda-mcp.el  -*- lexical-binding: t; -*-
;;;
;;; Phase 17 · (OPTIONAL power-up) — MCP bridge (E12).
;;;
;;; Layers `claude-code-ide.el' PURELY for its MCP server, which exposes Emacs
;;; to a Claude session — Flycheck/Flymake diagnostics, xref, and `ediff' on
;;; Claude's own edits (a natural fit for the DONE-gate review step, E6).
;;;
;;; THREE hard rules, straight from the arch (E12):
;;;   1. OPTIONAL — off by default (`eda/mcp-enabled' nil).
;;;   2. NEVER LOAD-BEARING — if the package is absent or its API differs or it
;;;      errors, the config still boots clean; every call here is guarded.
;;;   3. `claude-code.el' (stevemolitor) stays the PRIMARY driver. We only start
;;;      the MCP *server* so existing sessions gain Emacs tools; we never let
;;;      claude-code-ide take over session spawning.
;;;
;;; Research flags claude-code-ide as early-development with MCP reachability
;;; bugs, hence the belt-and-braces guarding. To try it:
;;;   1. uncomment the `claude-code-ide' package in packages.el, `doom sync',
;;;      restart;
;;;   2. `M-x eda/mcp-enable' (or set `eda/mcp-enabled' t in .eda-local.el).
;;; If the package's entry-point names differ from the candidates below, point
;;; `eda/mcp-enable-function' / `-disable-function' at the right symbols in
;;; .eda-local.el — no tracked-config edit needed.

(require 'cl-lib)

;; --- Config / flags ---------------------------------------------------------

(defvar eda/mcp-enabled nil
  "Master switch. When non-nil AND the package is present, the MCP bridge is
enabled at load. Default nil ⇒ this module is a complete no-op at startup.")

(defvar eda/mcp-library "claude-code-ide"
  "Library/feature that provides the MCP server.")

(defvar eda/mcp-enable-candidates
  '(claude-code-ide-mcp-start
    claude-code-ide-mcp-server-start
    claude-code-ide-mcp-server
    claude-code-ide-mode)
  "Entry points tried (first `fboundp' wins) to START the MCP server.
Deliberately a candidate list — the package is early and its API may shift.")

(defvar eda/mcp-disable-candidates
  '(claude-code-ide-mcp-stop
    claude-code-ide-mcp-server-stop)
  "Entry points tried (first `fboundp' wins) to STOP the MCP server.")

(defvar eda/mcp-enable-function nil
  "Explicit 0-arg enable function. Overrides `eda/mcp-enable-candidates'.
Set in .eda-local.el if the installed package's API differs.")

(defvar eda/mcp-disable-function nil
  "Explicit 0-arg disable function. Overrides `eda/mcp-disable-candidates'.")

(defvar eda/mcp--active nil
  "Non-nil when the bridge is currently enabled (best-effort).")

;; --- Helpers ----------------------------------------------------------------

(defun eda/mcp-available-p ()
  "Non-nil when the MCP package is installed and loadable."
  (and (locate-library eda/mcp-library) t))

(defun eda/mcp--first-fbound (candidates)
  (cl-find-if #'fboundp candidates))

;; --- Commands ---------------------------------------------------------------

;;;###autoload
(defun eda/mcp-enable ()
  "Enable the MCP bridge (start the server) — non-fatal on any failure.
`claude-code.el' remains the primary driver; this only exposes Emacs tools."
  (interactive)
  (unless (eda/mcp-available-p)
    (user-error
     "`%s' not installed — uncomment it in packages.el, run `doom sync', restart"
     eda/mcp-library))
  (ignore-errors (require (intern eda/mcp-library) nil 'noerror))
  (let ((fn (or eda/mcp-enable-function
                (eda/mcp--first-fbound eda/mcp-enable-candidates))))
    (if (not (functionp fn))
        (user-error
         "No known enable entry point in `%s'; set `eda/mcp-enable-function'"
         eda/mcp-library)
      (condition-case err
          (progn
            (funcall fn)
            (setq eda/mcp--active t)
            (message "MCP bridge ENABLED via `%s' (claude-code.el stays primary driver)" fn))
        (error
         (setq eda/mcp--active nil)
         (message "MCP bridge enable failed (non-fatal): %s"
                  (error-message-string err)))))))

;;;###autoload
(defun eda/mcp-disable ()
  "Disable the MCP bridge (stop the server) if a stop entry point exists."
  (interactive)
  (let ((fn (or eda/mcp-disable-function
                (eda/mcp--first-fbound eda/mcp-disable-candidates))))
    (if (functionp fn)
        (progn (ignore-errors (funcall fn))
               (setq eda/mcp--active nil)
               (message "MCP bridge disabled via `%s'" fn))
      (setq eda/mcp--active nil)
      (message "No stop entry point known; marked inactive (set `eda/mcp-disable-function')"))))

;;;###autoload
(defun eda/mcp-toggle ()
  "Toggle the MCP bridge."
  (interactive)
  (if eda/mcp--active (eda/mcp-disable) (eda/mcp-enable)))

;;;###autoload
(defun eda/mcp-status ()
  "Report the MCP bridge state, package availability, and flag."
  (interactive)
  (message "MCP bridge: %s | package `%s': %s | flag eda/mcp-enabled: %s"
           (if eda/mcp--active "ACTIVE" "inactive")
           eda/mcp-library
           (if (eda/mcp-available-p) "installed" "MISSING")
           (if eda/mcp-enabled "on" "off")))

;; --- Opt-in auto-enable at load (never load-bearing) -----------------------

(when (and eda/mcp-enabled (eda/mcp-available-p))
  (ignore-errors (eda/mcp-enable)))

;; --- Keys: extend SPC k o ---------------------------------------------------

(map! :leader
      (:prefix-map ("k o" . "org task engine")
       :desc "MCP bridge toggle (opt)" "M" #'eda/mcp-toggle))

(provide 'eda-mcp)
;;; eda-mcp.el ends here
