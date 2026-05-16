# SoC top — CLAUDE context

## Stack
- SystemVerilog (IEEE 1800-2017+) RTL
- UVM-Lite via cocotb 2.x; constrained-random via cocotb-coverage
- Synthesis: Yosys (`read_systemverilog -formal`)
- Formal: SymbiYosys (bmc / prove / cover)
- Sim: Verilator 5.x (primary), Icarus 13 (sanity), cocotb (Python tests)
- Lint: Verible (`verible-verilog-lint`)
- Format: `verible-verilog-format --inplace --column_limit 100 --indentation_spaces 2`
- Waveforms: GTKWave (vcd/fst) or Surfer

## Bash commands (ALWAYS use these — do not improvise)
- `make -C sim verilator-run`  build+run
- `make -C sim cocotb SIM=verilator`
- `make -C sim clean`
- `sby -f formal/properties.sby <task>`
- `verible-verilog-lint --rules_config formal/verible.rules`
- `pytest -q tests/`

## Project rules
- 2-space indent. No tabs. 100-col line limit.
- Always `logic` (no `reg`/`wire` in new code).
- Reset is async-assert / sync-deassert on `rst_n`.
- Module-name == filename (one module per file).
- Suffix testbenches `tb_<dut>.sv`.
- All FSM enums in `<dut>_pkg.sv`; never inline.

## Verification rules
- Every public RTL change needs at least one cocotb directed test.
- Coverage closure target: 95% functional + 100% line.
- Formal-friendly: avoid `$random`; bound loops; gate `assert property` behind `formal` macro.

## What NOT to do
- Do not use commercial simulators (Synopsys/Cadence/Mentor) — open source only.
- Do not touch `~/Dropbox/organist-dinesh/life.org` from any tool here.
- Do not edit `~/.config/doom/config.el` autonomously; propose diffs.

## Files of interest
- `rtl/`         RTL sources
- `tb/`          SV testbenches
- `tests/`       cocotb Python tests
- `sim/`         Makefile + filelist.f
- `formal/`      .sby + verible.rules
- `doc/`         spec PDFs + arch.org
