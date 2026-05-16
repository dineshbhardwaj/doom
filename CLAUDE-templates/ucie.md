# UCIe sideband + retimer — CLAUDE context

## Scope
UCIe 2.0 Standard package: sideband + main-band + D2D adapter.

## Stack
Same as ../soc.md, plus:
- D2D adapter modeled in cocotb with bus_func extensions
- Retimer mode: TX-RX EQ adaptation in `phy/eq/`

## Bash commands
- `make -C sim d2d-bringup`   D2D bringup sequence
- `make -C sim sb-retimer`    sideband retimer regression
- `make -C sim mainband-cov`  main-band coverage close

## Key invariants
- Sideband uses 800 MT/s redundant signalling per UCIe 2.0 §8.
- Retimer must keep packet ordering across all 64 lanes.
- D2D adapter handshake on `link_init_req`/`link_init_ack`.

## Agents available (see .claude/agents/)
- protocol-agent  cross-check RTL against UCIe spec sections
- timing-agent    review timing-critical paths
