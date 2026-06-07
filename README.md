# FICSIT Foreman

A [FicsIt-Networks](https://docs.ficsit.app/ficsit-networks/latest/index.html) (FIN)
Lua **factory-control framework** for [Satisfactory](https://www.satisfactorygame.com/).
It runs on a Computer Case EEPROM and turns your codeable splitters/mergers into a
self-managing logistics + production controller:

- **Topology-aware item routing** over a belt **loop** — BFS pathfinding, so any
  splitter can reach any destination.
- **Gated container release** — networked containers output *only what is ordered*,
  when ordered (no belt flooding).
- **Room-aware delivery + reroute** — a full destination buffer reroutes to another
  buffer for the same item, or, last resort, an A.W.E.S.O.M.E. Sink (`DEFAULT_OUT_<n>`).
- **Production planning** — auto-detects constructors/assemblers and their recipes via
  reflection, picks a recipe by throughput when stock is plentiful (else max yield),
  and auto-orders ingredients → machine → buffer to keep `<Item>_<Keyword>_<N>` buffers full.
- **Auto-naming** — name a container `input` / `output` / `buffer`; its first single
  item type renames it to `Iron_Plate_Buffer_1`, etc.

It aims to grow into a full A→Z factory controller (power, trains, dashboards) — the
core is a small kernel + pluggable modules.

## Two distributions

| | What | When |
|---|---|---|
| **LITE** | `dist/foreman-lite.lua` — a single self-contained EEPROM (no Internet Card, no hard drive). | From the moment you can run a Computer Case (HUB Tier 3 *Basics Networks*). By then you already have Smelter / Constructor / **Assembler**, so LITE drives those single-recipe chains with gated buffers. |
| **FULL** | `dist/foreman.lua` — the complete framework, fetched over HTTP. | Once the **Internet Card** is unlocked (a late MAM node behind the SAM Fluctuator). The LITE EEPROM **auto-detects the card and fetches FULL**, adding multi-recipe selection, scaled auto-discovery, full reroute and auto-naming. |

Both are generated from the same `lib/` source by `tools/bundle.py` — one source of truth.

## Quick start (LITE)

1. Build a Computer Case + Lua CPU + RAM + EEPROM, and **Codeable Splitters / Mergers**
   (the controller drives those; they're the LITE hardware floor).
2. Paste `dist/foreman-lite.lua` into the EEPROM.
3. Declare your factory in the `TOPOLOGY` table at the top (see
   [`examples/topology.example.lua`](examples/topology.example.lua)) — FIN can't sense
   belt wiring, so you declare it once.
4. Nick your containers `input` / `output` / `buffer` (FULL auto-renames them;
   under LITE name them `<Item>_<Keyword>_<N>` by hand).

When you later unlock the Internet Card, nothing to re-do — the EEPROM detects it and
upgrades itself to FULL (pinned to this release tag).

## Build from source

```sh
python3 tools/bundle.py     # regenerates dist/foreman.lua + dist/foreman-lite.lua from lib/
```

`dist/` is committed so the Internet Card can fetch `dist/foreman.lua` raw and you can
paste `dist/foreman-lite.lua` directly. The bootstrap pins a **release tag** (never
`main`) and verifies an end-of-file marker against truncated fetches.

## Architecture notes

- **Pure FIN APIs only** (`component` / `event` / `computer` / `filesystem` / `future` /
  `classes` / `structs`). No `print` (FIN nils it — use `computer.log`).
- **Topology is declared data**, not sensed: `FactoryConnection` exposes no owner, so a
  program can't walk the belt graph in-game. You declare nodes + port-aware belts; the
  framework discovers *paths*.
- Limits to respect (FIN): ~2500 Lua instructions/tick (then it yields), a 250-entry
  signal queue, NetworkCard messages ≤ 7 params.

## License

MIT — see [LICENSE](LICENSE).
