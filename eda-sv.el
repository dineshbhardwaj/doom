;;; ~/.config/doom/eda-sv.el  -*- lexical-binding: t; -*-
;;;
;;; SystemVerilog stack: tree-sitter major mode, Verible LSP, verilog-ext.
;;; Loaded by config.el via (load! "eda-sv").
;;;
;;; Tools (all installed via Homebrew in Phase 2):
;;;   verible-verilog-{ls,lint,format}  -- LSP, lint, formatter
;;;   verilator, iverilog, yosys        -- simulators / synthesis
;;;   gtkwave                            -- waveform viewer
;;;
;;; Grammar:
;;;   tree-sitter-systemverilog          -- installed via
;;;                                         M-x verilog-ts-install-grammar

;; --- 1. Major-mode routing ---------------------------------------------------
;; Open all .sv/.svh/.v/.vh/.sva in verilog-ts-mode when tree-sitter is
;; available (Emacs 29+ ships with treesit built in).
(when (treesit-available-p)
  (add-to-list 'auto-mode-alist '("\\.s?vh?\\'" . verilog-ts-mode))
  (add-to-list 'auto-mode-alist '("\\.sva\\'"   . verilog-ts-mode)))

;; --- 2. verilog-ext ---------------------------------------------------------
;; The big bundle: xref, capf, hierarchy, eglot/lsp wiring, flycheck,
;; beautifier, navigation, templates, formatter, compilation, imenu, which-func,
;; hideshow, typedefs, time-stamp, block-end-comments, ports.
(use-package! verilog-ext
  :after verilog-mode
  :hook ((verilog-mode    . verilog-ext-mode)
         (verilog-ts-mode . verilog-ext-mode))
  :init
  (setq verilog-ext-feature-list
        '(font-lock
          xref
          capf
          hierarchy
          eglot                 ; opt into eglot for LSP wiring
          flycheck
          beautify
          navigation
          template
          formatter
          compilation
          imenu
          which-func
          hideshow
          typedefs
          time-stamp
          block-end-comments
          ports))
  :config
  (verilog-ext-mode-setup)
  ;; Wire Verible as the eglot LSP server for SystemVerilog.
  (when (fboundp 'verilog-ext-eglot-set-server)
    (verilog-ext-eglot-set-server 've-verible-ls)))

;; --- 3. Indentation defaults -----------------------------------------------
;; Verible default is 2; many shops use 4. Override per-project via
;; .dir-locals.el if needed.
(setq verilog-indent-level 2
      verilog-indent-level-module 2
      verilog-indent-level-declaration 2
      verilog-indent-level-behavioral 2
      verilog-indent-level-directive 0
      verilog-auto-newline nil
      verilog-tab-always-indent t
      verilog-case-fold nil
      verilog-highlight-modules t
      verilog-highlight-includes t
      verilog-auto-lineup 'declarations)

;; --- 4. Verible formatter wrapper -------------------------------------------
;; verilog-ext exposes verilog-ext-beautify-*; this is a direct
;; "format whole buffer in place" command for save hooks.
(defun eda/verible-format-buffer ()
  "Format current buffer with verible-verilog-format in place."
  (interactive)
  (when (and buffer-file-name
             (executable-find "verible-verilog-format"))
    (let ((tmp (make-temp-file "verible-fmt" nil ".sv")))
      (unwind-protect
          (progn
            (write-region (point-min) (point-max) tmp nil 'silent)
            (call-process "verible-verilog-format" nil nil nil
                          "--inplace" tmp)
            (let ((coding buffer-file-coding-system))
              (erase-buffer)
              (insert-file-contents tmp)))
        (delete-file tmp)))))

;; Opt-in format-on-save: add to a project's .dir-locals.el like:
;;
;;   ((verilog-ts-mode
;;     . ((eval . (add-hook 'before-save-hook
;;                          #'eda/verible-format-buffer nil t)))))

;; --- 5. compilation-error-regexp-alist additions ---------------------------
;; Make Verilator/Verible/Yosys/Icarus errors clickable in *compilation*.
(with-eval-after-load 'compile
  ;; Verilator: "%Error: file.sv:LINE:COL: message"
  (add-to-list 'compilation-error-regexp-alist 'verilator)
  (add-to-list 'compilation-error-regexp-alist-alist
               '(verilator
                 "^%\\(Error\\|Warning\\)[^:]*: \\([^ \n]+\\):\\([0-9]+\\):\\([0-9]+\\):"
                 2 3 4))

  ;; Verible lint: "file.sv:LINE:COL: message [rule]"
  (add-to-list 'compilation-error-regexp-alist 'verible)
  (add-to-list 'compilation-error-regexp-alist-alist
               '(verible
                 "^\\(/[^:\n]+\\.s?vh?\\):\\([0-9]+\\):\\([0-9]+\\): "
                 1 2 3))

  ;; Yosys: "ERROR: ... at file.sv:LINE"
  (add-to-list 'compilation-error-regexp-alist 'yosys)
  (add-to-list 'compilation-error-regexp-alist-alist
               '(yosys
                 "ERROR:.* at \\([^ \n]+\\.s?vh?\\):\\([0-9]+\\)" 1 2))

  ;; Icarus Verilog: "file.sv:LINE: error: message"
  (add-to-list 'compilation-error-regexp-alist 'iverilog)
  (add-to-list 'compilation-error-regexp-alist-alist
               '(iverilog
                 "^\\([^:\n]+\\.s?vh?\\):\\([0-9]+\\): \\(error\\|warning\\):"
                 1 2)))

;; --- 6. magit worktrees first-class ----------------------------------------
;; Surface git worktrees in the magit status buffer so we see all 40 at a glance.
(with-eval-after-load 'magit
  (add-hook 'magit-status-sections-hook #'magit-insert-worktrees t))

(provide 'eda-sv)
;;; eda-sv.el ends here
