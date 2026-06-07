# FICSIT Foreman

A [FicsIt-Networks](https://docs.ficsit.app/ficsit-networks/latest/index.html) (FIN)
Lua **factory-control framework** for [Satisfactory](https://www.satisfactorygame.com/).
It runs on a Computer Case EEPROM and turns your codeable splitters/mergers into a
self-managing logistics + production controller:

- **Paste-and-go auto-discovery** — leave the topology blank and Foreman crawls the
  belt graph itself (`getFactoryConnectors → getConnected → owner`, a link-state crawl)
  and reads every container's role/item/target straight from its nick. No topology
  table to maintain; you *can* still declare one if you prefer.
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
- **Demand-driven auto-buffers** — name a container `auto_buffer` / `auto_output` and
  the system picks what it should hold: the next item the machines can make that
  isn't buffered yet (iron plate + wire covered → it becomes `Iron_Rod_Buffer_1`).
  Once everything is covered, further auto-buffers reinforce the highest **transitive
  demand** item — iron plate's demand counts everything that consumes reinforced iron
  plate, which consumes iron plate, and so on up the recipe tree.

It aims to grow into a full A→Z factory controller (power, trains, dashboards) — the
core is a small kernel + pluggable modules.

## Two distributions — separate, independently versioned, no auto-upgrade

LITE and FULL are **distinct products**. LITE never upgrades itself; you choose FULL
deliberately by pasting its loader once you have an Internet Card. Each has its own
version (see the `VERSION` file: `lite=` / `full=`), and they can differ.

| | Artifact(s) | What | When |
|---|---|---|---|
| **LITE** | `dist/foreman-lite.lua` | A single **self-contained** EEPROM — no Internet Card, no hard drive, **no fetch logic at all**. Drives single-recipe Smelter/Constructor/Assembler chains with gated buffers + room-aware delivery. | From the moment you can run a Computer Case (HUB Tier 3 *Basics Networks*). The Assembler is already unlocked by then. |
| **FULL** | `dist/foreman-loader.lua` + `dist/foreman.lua` | Paste the small **loader** EEPROM; it requires an Internet Card and fetches the FULL bundle (`foreman.lua`) from the pinned release tag, then runs it: multi-recipe selection, scaled auto-discovery, full reroute, auto-naming. | Once the **Internet Card** is unlocked (a late MAM node behind the SAM Fluctuator). You install it on purpose — nothing happens automatically. |

All artifacts are generated from the same `lib/` source by `tools/bundle.py` — one
source of truth.

## Quick start

**LITE (early game):**
1. Build a Computer Case + Lua CPU + RAM + EEPROM, and **Codeable Splitters / Mergers**
   (the controller drives those — the LITE hardware floor).
2. Paste `dist/foreman-lite.lua` into the EEPROM.
3. **Nick your containers** by convention and you're done — no topology table:
   - source: `<Item>_input_<n>` (or a bare `input` — it adopts whatever item it holds)
   - buffer/output: `<Item>_buffer_<n>` / `<Item>_output_<n>`, optional fill target
     suffix `<Item>_buffer_<n>_<target>` (e.g. `iron_plate_buffer_1_500` keeps 500;
     no suffix = fill to capacity)
   - catch-all for unrouteable items: `DEFAULT_OUT_<n>` (a container or an A.W.E.S.O.M.E. Sink)
   - demand-driven: `auto_buffer` / `auto_output` picks what to hold for you
4. *(optional)* Declare the topology by hand instead — leave the nicks, fill the
   `TOPOLOGY` table (see [`examples/topology.example.lua`](examples/topology.example.lua)).

**FULL (after the Internet Card):** paste `dist/foreman-loader.lua` instead. It fetches
the pinned FULL bundle and runs it — same nick conventions, same paste-and-go discovery.
Switching is a deliberate re-paste — LITE keeps running untouched until you do.

## Build from source

```sh
python3 tools/bundle.py     # regenerates dist/{foreman.lua, foreman-lite.lua, foreman-loader.lua}
```

`dist/` is committed so the loader can fetch `dist/foreman.lua` raw and you can paste
`dist/foreman-lite.lua` / `dist/foreman-loader.lua` directly. The loader pins a
**release tag** (never `main`) and verifies an end-of-file marker against truncated fetches.

## Architecture notes

- **Pure FIN APIs only** (`component` / `event` / `computer` / `filesystem` / `future` /
  `classes` / `structs`). `print` works (FIN re-adds it; logs with a space-join).
- **Topology can be auto-discovered.** A `FactoryConnection` is an `ActorComponent`, so
  it has `.owner` (the building); `connector:getConnected().owner` reaches the neighbour.
  `lib/discover.lua` crawls `getFactoryConnectors → getConnected → owner` to rebuild the
  belt graph (nodes + ports) automatically — a link-state crawl. You can still *declare*
  a topology if you prefer; roles/items come from container nicks + recipes either way.
- Limits to respect (FIN): ~2500 Lua instructions/tick (then it yields), a 250-entry
  signal queue, NetworkCard messages ≤ 7 params.

## License

MIT — see [LICENSE](LICENSE).
