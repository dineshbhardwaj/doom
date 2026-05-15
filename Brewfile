# ~/.config/doom/Brewfile
# Staged list of macOS dependencies for the EDA IDE plan.
# DO NOT bulk-install with `brew bundle` yet — phases 1, 2, 5 install
# subsets at the right time. This file is committed so the install
# surface is reviewable and reproducible.

# Phase 1 — general dev support
brew "direnv"
brew "ripgrep"
brew "fd"
brew "graphviz"

# Phase 2 — SystemVerilog language tooling
tap "chipsalliance/verible"
brew "verible"           # Verible LSP, lint, format
brew "verilator"         # OSS simulator with --coverage / --trace
brew "icarus-verilog"    # iverilog / vvp
brew "yosys"             # synthesis / formal frontend

# Phase 5 — waveform / formal
cask "gtkwave"           # GTKWave (cask on macOS)
# surfer — installed via cargo in Phase 5 (no stable Homebrew formula)
# symbiyosys (sby) — pip / source build in Phase 5
# cocotb — pip in Phase 5

# Note: OpenROAD / OpenLane2 are intentionally OUT of scope on Mac
# per the plan; physical design happens on the Linux farm.
