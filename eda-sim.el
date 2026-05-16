;;; ~/.config/doom/eda-sim.el  -*- lexical-binding: t; -*-
;;;
;;; Compile / sim / wave / formal wrappers.
;;;
;;; All commands run under projectile-project-root and use compile-mode so
;;; the error regexes from eda-sv.el make them clickable in *compilation*.

(require 'compile)

;; --- Helpers --------------------------------------------------------------

(defun eda/-root ()
  "Return the current project root (projectile if available, else default-directory)."
  (or (and (fboundp 'projectile-project-root) (projectile-project-root))
      default-directory))

(defun eda/-run (label cmd)
  "Run CMD in a *compilation* buffer named after LABEL, rooted at project."
  (let ((default-directory (eda/-root))
        (compilation-buffer-name-function (lambda (_m) (format "*eda-%s*" label))))
    (compile cmd)))

;; --- Verilator -----------------------------------------------------------

(defcustom eda/verilator-extra ""
  "Extra args passed to verilator (project-wide; override per-dir in .dir-locals)."
  :type 'string
  :group 'eda)

;;;###autoload
(defun eda/verilator-lint ()
  "Verilator lint-only on the current buffer + project filelist."
  (interactive)
  (eda/-run "verilator-lint"
            (format "verilator --lint-only -Wall %s %s"
                    eda/verilator-extra
                    (shell-quote-argument (buffer-file-name)))))

;;;###autoload
(defun eda/verilator-build ()
  "Verilator build-and-run via 'make -C sim verilator-run'."
  (interactive)
  (eda/-run "verilator-build"
            "make -C sim verilator-run"))

;;;###autoload
(defun eda/verilator-coverage ()
  "Aggregate coverage with verilator_coverage; HTML-style annotated output."
  (interactive)
  (eda/-run "verilator-coverage"
            "verilator_coverage --annotate logs/annotated logs/coverage.dat && \
echo 'Coverage annotated under logs/annotated/'"))

;; --- Icarus Verilog ------------------------------------------------------

;;;###autoload
(defun eda/iverilog-build ()
  "Compile + run an Icarus Verilog testbench via 'make iverilog'."
  (interactive)
  (eda/-run "iverilog" "make -C sim iverilog"))

;; --- cocotb -------------------------------------------------------------

;;;###autoload
(defun eda/cocotb-pytest ()
  "Run cocotb tests via pytest under the active venv."
  (interactive)
  (eda/-run "cocotb-pytest"
            "pytest -q --tb=short tests/"))

;;;###autoload
(defun eda/cocotb-make (sim)
  "Run cocotb the Makefile way; SIM is icarus or verilator."
  (interactive (list (completing-read "SIM: " '("icarus" "verilator") nil t)))
  (eda/-run (format "cocotb-%s" sim)
            (format "make -C sim cocotb SIM=%s" sim)))

;; --- Yosys --------------------------------------------------------------

;;;###autoload
(defun eda/yosys-elaborate ()
  "Yosys read + hierarchy + check on filelist."
  (interactive)
  (eda/-run "yosys"
            "yosys -p 'read_systemverilog -formal -f sim/filelist.f; hierarchy -check; stat; check'"))

;;;###autoload
(defun eda/yosys-show ()
  "Yosys show + xdot graph for current module."
  (interactive)
  (let ((mod (read-string "Module to show: ")))
    (eda/-run "yosys-show"
              (format "yosys -p 'read_systemverilog -f sim/filelist.f; hierarchy -top %s; proc; opt; show -format dot -prefix logs/%s' && xdot logs/%s.dot"
                      mod mod mod))))

;; --- SymbiYosys (sby) ----------------------------------------------------
;; Assumes OSS CAD Suite at ~/oss-cad-suite/ (sourced lazily per command).

;;;###autoload
(defun eda/sby-run (task)
  "Run a SymbiYosys task. TASK is read interactively (e.g. bmc, prove, cover)."
  (interactive (list (read-string "sby task: " "bmc")))
  (eda/-run (format "sby-%s" task)
            (format "source ~/oss-cad-suite/environment && sby -f formal/properties.sby %s"
                    task)))

;; --- Waveform launchers --------------------------------------------------

;;;###autoload
(defun eda/open-trace-gtkwave (&optional vcd)
  "Open VCD/FST in GTKWave."
  (interactive)
  (let ((f (or vcd (read-file-name "Trace: " "logs/" nil t))))
    (start-process "gtkwave" nil "gtkwave" f)))

;;;###autoload
(defun eda/open-trace-surfer (&optional vcd)
  "Open VCD/FST in Surfer."
  (interactive)
  (let ((f (or vcd (read-file-name "Trace: " "logs/" nil t))))
    (start-process "surfer" nil "surfer" f)))

;; --- Keybindings under SPC c e * (eda subset of SPC c "code" prefix) -----

(map! :leader
      (:prefix-map ("c e" . "eda compile/sim/formal")
       :desc "Verilator lint"           "l" #'eda/verilator-lint
       :desc "Verilator build+run"      "v" #'eda/verilator-build
       :desc "Verilator coverage"       "C" #'eda/verilator-coverage
       :desc "Icarus build+run"         "i" #'eda/iverilog-build
       :desc "cocotb pytest"            "p" #'eda/cocotb-pytest
       :desc "cocotb make"              "P" #'eda/cocotb-make
       :desc "Yosys elaborate"          "y" #'eda/yosys-elaborate
       :desc "Yosys show module"        "Y" #'eda/yosys-show
       :desc "SymbiYosys run task"      "f" #'eda/sby-run
       :desc "Open trace in GTKWave"    "w" #'eda/open-trace-gtkwave
       :desc "Open trace in Surfer"     "s" #'eda/open-trace-surfer))

(provide 'eda-sim)
;;; eda-sim.el ends here
