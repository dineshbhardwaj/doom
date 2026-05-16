# PCIe Gen7 controller — CLAUDE context

## Scope
This worktree implements a PCIe Gen 7 Endpoint controller + PHY interface.
Reference spec: PCI-SIG PCIe Base Specification 7.0 + CEM 7.0.

## Stack
Same as ../soc.md, plus:
- Custom UVM-Lite components for TLP/DLLP traffic
- Eye-diagram analysis scripts in `phy/scripts/`
- LTSSM tracer in `tb/ltssm_trace.sv`

## Bash commands
Same as ../soc.md, plus:
- `make -C sim ltssm-trace`  run LTSSM-only regression
- `make -C sim gen7-link-test` full link-up test

## Key invariants
- Cross all clock domains via 2FF synchronizers + assertion macros (see `rtl/cdc/`).
- Replay timer = 32-bit counter, never gated.
- ECRC always present in TLPs unless suppressed via cfg_ecrc_dis.
- LTSSM legal transitions per the spec; enforce with formal properties in `formal/ltssm.sby`.

## Agents available (see .claude/agents/)
- rtl-review-agent      review RTL for synthesis + CDC issues
- verification-agent    write/expand cocotb tests + properties
- debug-agent           triage simulation failures

## What NOT to do
Same as ../soc.md. Additionally: do not commit any PCI-SIG spec PDFs to git.
