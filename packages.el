;; -*- no-byte-compile: t; -*-
;;; $DOOMDIR/packages.el

;; To install a package with Doom you must declare them here and run 'doom sync'
;; on the command line, then restart Emacs for the changes to take effect -- or


;; To install SOME-PACKAGE from MELPA, ELPA or emacsmirror:
;; (package! some-package)

;; To install a package directly from a remote git repo, you must specify a
;; `:recipe'. You'll find documentation on what `:recipe' accepts here:
;; https://github.com/radian-software/straight.el#the-recipe-format
;; (package! another-package
;;   :recipe (:host github :repo "username/repo"))

;; If the package you are trying to install does not contain a PACKAGENAME.el
;; file, or is located in a subdirectory of the repo, you'll need to specify
;; `:files' in the `:recipe':
;; (package! this-package
;;   :recipe (:host github :repo "username/repo"
;;            :files ("some-file.el" "src/lisp/*.el")))

;; If you'd like to disable a package included with Doom, you can do so here
;; with the `:disable' property:
;; (package! builtin-package :disable t)

;; You can override the recipe of a built in package without having to specify
;; all the properties for `:recipe'. These will inherit the rest of its recipe
;; from Doom or MELPA/ELPA/Emacsmirror:
;; (package! builtin-package :recipe (:nonrecursive t))
;; (package! builtin-package-2 :recipe (:repo "myfork/package"))

;; Specify a `:branch' to install a package from a particular branch or tag.
;; This is required for some packages whose default branch isn't 'master' (which
;; our package manager can't deal with; see radian-software/straight.el#279)
;; (package! builtin-package :recipe (:branch "develop"))

;; Use `:pin' to specify a particular commit to install.
;; (package! builtin-package :pin "1a2b3c4d5e")


;; Doom's packages are pinned to a specific commit and updated from release to
;; release. The `unpin!' macro allows you to unpin single packages...
;; (unpin! pinned-package)
;; ...or multiple packages
;; (unpin! pinned-package another-pinned-package)
;; ...Or *all* packages (NOT RECOMMENDED; will likely break things)
;; (unpin! t)
;; Dinesh Org-Roam-ui
(package! elfeed-score)
(package! elfeed-tube)
(package! elfeed-tube-mpv)       ; optional: play videos via mpv with timestamp support
(package! elfeed-summary)
;; ───── Claude integration ─────
(package! claude-code
  :recipe (:host github :repo "stevemolitor/claude-code.el"))

;; ───── GitHub integration (Forge extends Magit) ─────
;; Magit ships with Doom's :magit module, so just add Forge
;; ───── Helper for shell PATH on macOS / GUI Emacs ─────
(package! exec-path-from-shell)
(package! eat)
(package! transient)       ;; required by claude-code menus (usually already pulled in by magit)

;; ─────────────────────────────────────────────────────────────────
;; EDA IDE additions (phase 1)
;; ─────────────────────────────────────────────────────────────────

;; SystemVerilog ecosystem
(package! verilog-ts-mode)
(package! verilog-ext)
(package! treesit-auto)              ; keep treesit grammars in sync

;; LLM second layer (claude-code.el already covers the agentic side)
(package! gptel)

;; Magit augmentation
(package! magit-todos)

;; Org-mode polish (used by per-task project.org workflow in phase 4)
(package! org-modern)
(package! org-super-agenda)

;; Misc QoL
(package! ws-butler)                 ; trim trailing whitespace on save (RTL hygiene)
(package! envrc)                     ; explicit pin even though :tools direnv pulls it
(package! consult-yasnippet)         ; vertico-friendly snippet picker
