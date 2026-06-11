-- router.lua — topology-aware item routing framework for FicsIt-Networks.
--
-- This is PRODUCT code: it runs in-game on a Computer Case as well as under the
-- devbox emulator. The topology can be auto-discovered (lib/discover.lua crawls the
-- belt graph via getFactoryConnectors -> getConnected -> owner) or DECLARED as data;
-- either way the router DISCOVERS routes through it with breadth-first search:
--
--     order("iron ingot", 100, "OUT_IRON")
--
-- finds the path from the container that provides the item to the target container
-- and programs every CodeableSplitter along the way to send that item type out the
-- correct port. CodeableMergers just pass through. Works for any topology.
--
-- Topology shape:
--   {
--     containers = { {id=, provides=?, buffer=?, output=?, target=?, isDefault=?}, ... },
--                  -- provides: item this source emits; buffer/output: dest item;
--                  -- target: fill cap; isDefault: a DEFAULT_OUT catch-all sink
--     splitters  = { "S1", ... },                          -- CodeableSplitter ids/nicks
--     mergers    = { "M1", ... },                          -- CodeableMerger ids/nicks
--     belts      = { {from=, to=, fromOutput=?, toInput=?}, ... },  -- directed, port-aware
--   }
--
-- Resolution of an id to a live component proxy is pluggable (default component.proxy)
-- so the same code drives the emulator and a real network.

local Router = {}
Router.__index = Router

-- Capped diagnostic logger: the FIRST N routing decisions (splitter choices, overflow,
-- sink) so a busy factory's routing is visible without flooding the console. Short 6-char
-- ids match the netdump labels. Disable by leaving _dn at the cap.
Router._dn = 0
Router.DEBUG = false          -- App.run sets this from opts.debug / a computer nicked "debug"
function Router._dlog(msg)
  if not Router.DEBUG then return end
  if Router._dn < 60 and computer and computer.log then
    Router._dn = Router._dn + 1
    computer.log(1, "[Foreman] " .. msg)
  end
end

-- Case-insensitive item names: FIN reflection returns canonical (Title) case
-- ("Iron Plate"), nicks give lowercase. Normalize everything to lowercase so keys
-- and comparisons match regardless of source.
local function lc(s) return s and tostring(s):lower() or nil end
-- Name of an item from a FIN ItemRequest payload / getInput() result. The item is an
-- FInventoryItem whose `.type` is an ItemType OBJECT with `.name`.
-- CRITICAL: in-game a FIN struct is NOT a Lua table — type(it) is a FIN struct type, NOT
-- "table". The old `type(it)~="table"` gate therefore made EVERY real item fall through to
-- tostring = "struct<item>", which matched no order, so every item sank (the in-game bug).
-- FIN structs DO support member access (exactly how the planner reads recipe items), so read
-- `.type` / `.type.name` directly, nil-guarded so an EMPTY input struct (no .type) -> nil.
local function itemName(it)
  if it == nil then return nil end
  if type(it) == "string" then return lc(it) end       -- plain name (legacy)
  local okt, t = pcall(function() return it.type end)
  if not okt or t == nil then return nil end            -- empty input struct / not an item
  local okn, nm = pcall(function() return t.name end)   -- ItemType.name (struct member access)
  if okn and nm ~= nil then return lc(nm) end
  if type(t) == "string" then return lc(t) end          -- legacy/emulator {type="<name>"} shape
  return nil
end
Router._itemName = itemName    -- exposed for unit tests

-- Resolve a container's destination item + ordinal + optional fill target, from an
-- explicit c.buffer / c.output item field or its name <Item>_(Buffer|Output)_<n>[_<target>]
-- (case-insensitive). Returns item, n, target — or nil if not a destination.
function Router.destItem(c)
  if c.buffer then return tostring(c.buffer):lower(), c.n end
  if c.output then return tostring(c.output):lower(), c.n end
  -- with explicit target suffix: <prefix>_<kw>_<index>_<target>
  local prefix, kw, n, tgt = tostring(c.id):match("^(.-)_(%a+)_(%d+)_(%d+)$")
  if not (prefix and (kw:lower() == "buffer" or kw:lower() == "output")) then
    prefix, kw, n = tostring(c.id):match("^(.-)_(%a+)_(%d+)$"); tgt = nil
  end
  if prefix and (kw:lower() == "buffer" or kw:lower() == "output") then
    return prefix:gsub("_", " "):lower(), tonumber(n), tgt and tonumber(tgt) or nil
  end
  return nil
end

function Router.new(topology, getProxy)
  local self = setmetatable({}, Router)
  self.topo = topology
  self.getProxy = getProxy or function(id) return component.proxy(id) end
  Router._roomCount = {}          -- per-epoch buffer room cache (a new Router == a new ~2s epoch); see hasRoom
  self.isSplitter, self.isMerger = {}, {}
  for _, id in ipairs(topology.splitters or {}) do self.isSplitter[id] = true end
  for _, id in ipairs(topology.mergers or {}) do self.isMerger[id] = true end
  -- MACHINE set + port pins (published by the planner per epoch). A splitter must never hand a
  -- constructor an item its LIVE recipe doesn't pull (machineLive, the one admission rule), and a
  -- pinned multi-ingredient port takes its ingredient and NOTHING else (portItem).
  self.isMachine, self.portItem = {}, {}
  for _, id in ipairs(topology.constructors or {}) do self.isMachine[id] = true end
  -- adjacency: node -> list of belts leaving it
  self.adj = {}
  for _, b in ipairs(topology.belts or {}) do
    self.adj[b.from] = self.adj[b.from] or {}
    table.insert(self.adj[b.from], b)
  end
  -- DEMAND-PULL STATE (published by the planner each epoch via setDemand):
  --   demand[item]  = { {id=consumerId, need=n, port=toInput|nil, machine=bool}, ... }
  --   nextHop[node][item] = ordered belt list toward the nearest demander(s) (buildNextHop)
  self.demand, self.nextHop = {}, {}
  -- Source gating happens at the source container's OWN OUTPUT CONNECTOR (blocked +
  -- addUnblockedTransfers), NOT by holding codeables mid-line — so an idle source stops
  -- itself without ever stalling a shared belt. sourceItem[id]=item identifies sources.
  self.sourceItem = {}
  for _, c in ipairs(topology.containers or {}) do
    if c.provides then self.sourceItem[c.id] = lc(c.provides) end
  end
  -- containers named DEFAULT_OUT_<n> are the catch-all sinks for unroutable items.
  self.defaults = {}
  for _, c in ipairs(topology.containers or {}) do
    -- by name in declared mode, or the c.isDefault flag in auto-discovered mode
    if c.isDefault or tostring(c.id):match("^DEFAULT_OUT_%d+$") then table.insert(self.defaults, c.id) end
  end
  -- buffer/output destinations: an explicit c.buffer / c.output item (e.g. set by
  -- the namer's auto-assignment) OR a name <Item>_(Buffer|Output)_<n>. item +
  -- capacity, grouped per item, numerically ordered.
  self.bufferItem = {}            -- destId -> item
  self.capacity = {}              -- destId -> max units (defaults to its target)
  self.buffersForItem = {}        -- item -> { destId... } ordered by <n>
  local order_n = {}
  for _, c in ipairs(topology.containers or {}) do
    local item, n, tgt = Router.destItem(c)
    if item then
      self.bufferItem[c.id] = item
      self.capacity[c.id] = c.capacity or c.target or tgt
      self.buffersForItem[item] = self.buffersForItem[item] or {}
      table.insert(self.buffersForItem[item], c.id)
      order_n[c.id] = n or 1
    end
  end
  for _, list in pairs(self.buffersForItem) do
    table.sort(list, function(x, y) return order_n[x] < order_n[y] end)
  end
  self._fh = {}                   -- firstHop cache: [from][dst] = belt | false
  self._mrr = {}                  -- per-merger round-robin input cursor (fair input draining)
  -- RAW INPUT ITEMS (copper ingot, iron ingot, concrete, ...): the items a physical input
  -- container provides. At a merger these are drained at LOWEST priority and ROUND-ROBINED among
  -- themselves — so the belt is emptied of products-in-transit before more raw material is injected
  -- (back-pressure), AND the raw inputs MIX fairly instead of serializing copper->concrete->iron by
  -- manifold position. Classifying by ITEM (not by port) is what makes this work no matter how far
  -- down the manifold a given input merged in. Provides-based only; hub draws are not deprioritised.
  self._rawItem = {}
  for _, c in ipairs(topology.containers or {}) do
    if c.provides then self._rawItem[lc(c.provides)] = true end
  end
  -- INPUT BELTS PER MACHINE: the physical conveyor ports of a constructor/assembler/manufacturer,
  -- one belt per port. A multi-ingredient machine must get each ingredient on its OWN port (one item
  -- type per belt) or the abundant ingredient floods the shared belt and the scarce one never reaches
  -- the machine. inputBelts[machineId] = { { belt, port = toInput, feeder = belt.from }, ... }.
  self.inputBelts = {}
  do
    local isCtor = {}; for _, id in ipairs(topology.constructors or {}) do isCtor[id] = true end
    local used = {}   -- machineId -> { port -> true }: dedupe colliding connector indices
    for _, b in ipairs(topology.belts or {}) do
      if isCtor[b.to] then
        self.inputBelts[b.to] = self.inputBelts[b.to] or {}
        -- PORT IDENTITY = THE PHYSICAL BELT, not the game's connector index. In-game, an
        -- assembler's two input connectors can BOTH report toInput=0; trusting that collapses the
        -- two ports into one, _assignPorts sees "<2 ports" and silently skips pinning, and the
        -- port-exclusivity guard never arms (the plates-on-both-assembler-legs bug, round 2 —
        -- the debug dump's fed[..@0 ..@0] was the giveaway). Each belt into a machine is a
        -- distinct physical port, so disambiguate colliding indices and stamp the belt (b._port);
        -- _beltAccepts reads the stamp. Works for N machines with N input belts.
        used[b.to] = used[b.to] or {}
        local p = b.toInput or 0
        while used[b.to][p] do p = p + 1 end
        used[b.to][p] = true
        b._port = p
        table.insert(self.inputBelts[b.to], { belt = b, port = p, feeder = b.from })
      end
    end
  end
  return self
end

-- Find the container that emits `item` (declared via `provides`).
function Router:sourceOf(item)
  item = lc(item)
  for _, c in ipairs(self.topo.containers or {}) do
    if lc(c.provides) == item then return c.id end
  end
end

-- Breadth-first search src -> dst over the belt graph. Returns the ordered list of
-- belts forming the path, or nil if unreachable.
function Router:findPath(src, dst)
  -- TWO-PHASE BFS. Phase 1 does NOT transit a declared buffer (storage for a specific item is not a
  -- relay — a different item cannot pass through it). This is the normal case and is what stops an
  -- unrelated order's shortest path from running THROUGH a buffer and mis-marking it pass-through
  -- (the wire self-loop). Phase 2 is a fallback: if dst is reachable ONLY through a relay buffer
  -- (a storage container deliberately wired belt-in/belt-out as the sole route), allow buffer
  -- transit so the destination is not silently orphaned. The common manifold always has a
  -- splitter/merger route, so phase 1 succeeds and no buffer is ever transited there.
  local function bfs(allowBuffer)
    local prev, seen, queue, head = {}, { [src] = true }, { src }, 1
    while head <= #queue do
      local node = queue[head]; head = head + 1
      if node == dst then break end
      local isBuffer = self.bufferItem[node] ~= nil and node ~= dst
      if node == src or self.isSplitter[node] or self.isMerger[node] or not isBuffer or allowBuffer then
        for _, b in ipairs(self.adj[node] or {}) do
          if not seen[b.to] then
            seen[b.to] = true
            prev[b.to] = b
            queue[#queue + 1] = b.to
          end
        end
      end
    end
    if not prev[dst] and src ~= dst then return nil end
    local path, node = {}, dst
    while prev[node] do
      table.insert(path, 1, prev[node])
      node = prev[node].from
    end
    return path
  end
  return bfs(false) or bfs(true)
end

-- the input belt of a machine wired to a specific port (toInput), or nil.
function Router:_beltToPort(machine, port)
  for _, e in ipairs(self.inputBelts[machine] or {}) do if e.port == port then return e end end
  return nil
end

--- DEMAND-PULL CORE. The planner publishes WHO NEEDS WHAT each epoch (setDemand); the router
--- derives a per-item next-hop table toward the nearest demander (buildNextHop). Items are then
--- routed one event at a time: ItemRequest at a codeable -> look up the head item's next hop ->
--- transferItem. No orders, no quotas, no in-flight ledgers: machine/buffer inventory is the
--- ground truth, re-read by the planner every epoch.
---
--- demand[item] = list of { id = consumerId, need = units, port = toInput|nil, machine = bool }
--- portItem (multi-ingredient port pins) is published alongside; machineLive is the admission rule.
function Router:setDemand(demand, portItem)
  self.demand = demand or {}
  self.portItem = portItem or {}
end

-- Per-item multi-source BFS from every demander BACKWARD over the belt graph.
-- nextHop[node][item] = ordered list of outgoing belts (nearest demander first, max 3) so a full
-- leg can divert to the next-nearest. Distance ties rotate with the epoch clock for fair splits.
-- Traversal mirrors findPath: buffers are not transited (phase-1); machines are endpoints.
function Router:buildNextHop()
  Router._epochN = (Router._epochN or 0) + 1     -- the re-plan epoch clock (jam-mark freshness)
  self.nextHop = {}
  -- reverse adjacency once
  local radj = {}
  for _, belts in pairs(self.adj) do
    for _, b in ipairs(belts) do
      radj[b.to] = radj[b.to] or {}
      table.insert(radj[b.to], b)
    end
  end
  for item, consumers in pairs(self.demand) do
    -- seed: distance 0 at each demander node; a port-pinned machine seeds ONLY via its pinned
    -- port's belt (the pin is enforced again at push time by _beltAccepts).
    local dist = {}      -- nodeId -> hops to nearest demander
    local queue, head = {}, 1
    for _, c in ipairs(consumers) do
      if dist[c.id] == nil then dist[c.id] = 0; queue[#queue + 1] = c.id end
    end
    while head <= #queue do
      local node = queue[head]; head = head + 1
      local d = dist[node]
      for _, b in ipairs(radj[node] or {}) do
        local up = b.from
        -- an item may flow OUT of: a source/provider container, a splitter, a merger. It does not
        -- transit other machines or foreign buffers (same rule as findPath phase 1). The upstream
        -- node still gets a next-hop entry even when terminal (a provider container needs none).
        if dist[up] == nil then
          dist[up] = d + 1
          local transit = self.isSplitter[up] or self.isMerger[up]
          if transit then queue[#queue + 1] = up end
        end
      end
    end
    -- per transit node: outgoing belts that lead CLOSER, nearest-first; rotate ties by epoch
    for node in pairs(dist) do
      if self.isSplitter[node] or self.isMerger[node] then
        local cands = {}
        for _, b in ipairs(self.adj[node] or {}) do
          local dd = dist[b.to]
          if dd ~= nil and dd < dist[node] then cands[#cands + 1] = { b = b, d = dd } end
        end
        table.sort(cands, function(x, y)
          if x.d ~= y.d then return x.d < y.d end
          return (x.b.fromOutput or 0) < (y.b.fromOutput or 0)
        end)
        if #cands > 1 then   -- rotate equal-nearest ties so parallel demanders share fairly
          local r = (Router._epochN or 0) % #cands
          for _ = 1, r do table.insert(cands, table.remove(cands, 1)) end
        end
        local legs = {}
        for i = 1, math.min(#cands, 3) do legs[i] = { b = cands[i].b, d = cands[i].d } end
        if #legs > 0 then
          self.nextHop[node] = self.nextHop[node] or {}
          self.nextHop[node][item] = legs
        end
      end
    end
  end
end

-- May a node hand `item` to next-node `to`? ONE admission rule (the user's): a machine leg only
-- ever receives what the machine's LIVE recipe will pull RIGHT NOW. machineLive is published by
-- the planner at the end of every fillAll (EMPTY set for a draining machine — its temp recipe
-- clears the lane, it must not vacuum more in). A machine the planner has never described stays
-- permissive (pre-plan grace). Non-machines always accept (codeables/buffers/sinks are room- and
-- pin-checked elsewhere).
function Router:_machineAccepts(to, item)
  if not self.isMachine[to] then return true end
  local live = self.machineLive and self.machineLive[to]
  if live then return live[item] == true end
  return true
end

-- May `item` ride `belt` into belt.to? Adds PORT EXCLUSIVITY on top of _machineAccepts: a machine
-- input port pinned to an ingredient (portItem, set by a port-pinned order) takes that ingredient
-- and NOTHING else — EVER. One foreign head item on a dedicated port's belt kills the port forever
-- (the machine's slot for it is full, so it is never pulled, and the real ingredient can never get
-- past it — the assembler both-ports-blocked-by-plate bug). This binds EVERY push path, including
-- the _overflow recovery that re-pathfinds "any way to the machine" and used to land plates on the
-- screws port.
function Router:_beltAccepts(belt, item)
  if not belt then return false end
  if not self:_machineAccepts(belt.to, item) then return false end
  local pm = self.portItem and self.portItem[belt.to]
  if pm then
    local want = pm[belt._port or belt.toInput or 0]   -- _port: belt-identity port (toInput collides in-game)
    if want ~= nil and want ~= item then return false end
  end
  return true
end

-- First belt on a path from `from` to `dst` (cached). Used by the no-demand fallback
-- (buffer/sink hops) — demand routing itself uses the precomputed nextHop table.
function Router:firstHopTo(from, dst)
  self._fh[from] = self._fh[from] or {}
  local hit = self._fh[from][dst]
  if hit ~= nil then return hit or nil end
  local path = self:findPath(from, dst)
  local belt = (path and path[1]) or false
  self._fh[from][dst] = belt
  return belt or nil
end

-- Current units of `item` in a destination (FIN-faithful inventory read).
-- PERF: every getStack() is a game-thread sync, and a storage container has 24-48 slots — scanning
-- them all per call (and hasRoom does it on every routing decision) is what makes a big factory stall.
-- Two cheap shortcuts, both single-sync: (1) skip an inventory whose itemCount is 0; (2) when `item`
-- is exactly the destination's DECLARED buffered item, the buffer holds only that item, so its
-- itemCount IS the count — no slot scan. Only a mixed container falls back to the per-slot scan.
function Router:_count(dst, item)
  local p = self.getProxy(dst)
  if not p or not p.getInventories then return 0 end
  item = lc(item)
  local single = self.capacity[dst] ~= nil and self.bufferItem[dst] == item
  local total = 0
  for _, inv in ipairs(p:getInventories()) do
    local n = 0; pcall(function() n = inv.itemCount or 0 end)
    if n > 0 then
      if single then
        total = total + n                              -- whole inventory is this item: 1 read, no slot scan
      else
        for i = 0, (inv.size or 0) - 1 do
          local s = inv:getStack(i)
          if s and (s.count or 0) > 0 and s.item and s.item.type and lc(s.item.type.name) == item then
            total = total + s.count
          end
        end
      end
    end
  end
  return total
end

-- Does a destination have room for one more of `item`? Non-buffer dests
-- (constructor, sink) always accept.
--
-- PER-EPOCH ROOM CACHE: _count is getInventories+itemCount (game-thread syncs). _routeAtSplitter calls
-- hasRoom for EVERY buffer-bound item, and on a looped manifold each item crosses many splitters — so a
-- live _count per crossing was a continuous throughput cap. Instead, seed the count ONCE per buffer per
-- epoch and add 1 each time we route an item toward it (Router:_creditRoom). The estimate only ever
-- OVER-counts (it ignores the buffer draining mid-epoch), so it diverts CONSERVATIVELY (never overfills);
-- the next ~2s epoch (a fresh Router) re-seeds from the live count. Router._roomCount is cleared in Router.new.
function Router:hasRoom(dst, item)
  local cap = self.capacity[dst]
  if not cap then return true end
  local key = tostring(dst) .. "|" .. lc(item)
  local c = Router._roomCount[key]
  if c == nil then c = self:_count(dst, item); Router._roomCount[key] = c end
  return c < cap
end
-- bump the cached room usage of a buffer we just routed an item toward (keeps hasRoom sync-free after
-- the first read this epoch). No-op if the buffer was never seeded (hasRoom will read it live on demand).
function Router:_creditRoom(dst, item)
  local key = tostring(dst) .. "|" .. lc(item)
  if Router._roomCount[key] ~= nil then Router._roomCount[key] = Router._roomCount[key] + 1 end
end

--- Handle one ItemRequest. Separated from install() so a long-lived listener can
--- delegate to the CURRENT router after a live re-discovery (App swaps the router
--- instance without re-registering — avoids stacking duplicate listeners).
--- FIN signal payload is an FInventoryItem; the item name is item.type.name
--- (item.type is the ItemType OBJECT, not a string). itemName() normalizes to
--- lowercase so matching is case-insensitive vs reflection's canonical (Title) case.
-- ACTIVE SET of codeable nodes that may still hold an item to route. Routing is EVENT-DRIVEN: an
-- ItemRequest fires when an item ARRIVES, _dispatch routes it. But a route that FAILS (output full)
-- leaves the item with no new signal, so we remember the node here and retry it (cheaply) until its
-- input clears — instead of polling all ~120 ports every loop (the game-thread-sync freeze). Module-
-- level so it survives the in-loop router rebuilds; stale ids self-clean (an empty/dead node is dropped).
Router._retry = Router._retry or {}

function Router:_dispatch(sender, a, b)
  local id = sender.id
  local moved = true                                   -- empty/unhandled signal: nothing to retry
  if self.isSplitter[id] then
    local nm = itemName(a)                             -- splitter sig: (item)
    if nm then moved = self:_routeAtSplitter(sender, id, nm) end
  elseif self.isMerger[id] then
    local nm = itemName(b)                             -- merger sig: (input, item)
    if nm then moved = self:_mergerPush(sender, id, a, nm) end
  end
  if not moved then Router._retry[id] = true end       -- output full / held: no new signal will come, retry it
end

-- Re-attempt the small ACTIVE SET (nodes that recently signaled / held an item); drop a node only once
-- its input is confirmed EMPTY (or it is dead). O(active), NOT O(all nodes) — this is what replaces the
-- poll-everything pump in the live loop. A downstream node freeing space is what lets a held item move;
-- we just retry each loop. A node is KEPT if a read throws (transient) so a stray reflection error never
-- abandons a held item. Mergers forward PRODUCT before RAW (same 2-phase priority as pump), round-robined.
function Router:_drainRetry()
  local r = Router._retry
  local raw = self._rawItem or {}
  for id in pairs(r) do
    local keep = false
    if self.isSplitter[id] then
      local s = self.getProxy(id)
      if s and s.getInput then
        local ok, it = pcall(function() return s:getInput() end)
        if not ok then keep = true                       -- transient read error: keep, retry next loop
        else
          local nm = itemName(it)
          if nm then keep = true; self:_routeAtSplitter(s, id, nm) end   -- has item: route + keep
        end                                              -- ok+empty -> keep stays false -> drop
      end                                                -- dead proxy -> drop
    elseif self.isMerger[id] then
      local m = self.getProxy(id)
      if m and m.getInput then
        local items, any, err = {}, false, false
        for i = 0, 2 do
          local ok, it = pcall(function() return m:getInput(i) end)
          if not ok then err = true else local nm = itemName(it); if nm then items[i] = nm; any = true end end
        end
        if any then                                      -- forward ONE item, PRODUCT (phase 1) before RAW (phase 2)
          keep = true
          local start = self._mrr[id] or 0
          for phase = 1, 2 do
            local moved = false
            for k = 0, 2 do
              local i = (start + k) % 3
              local nm = items[i]
              if nm and ((phase == 2) == (raw[nm] or false)) then
                if self:_mergerPush(m, id, i, nm) then self._mrr[id] = (i + 1) % 3 end
                moved = true; break
              end
            end
            if moved then break end
          end
        elseif err then keep = true end                  -- couldn't read any port: keep, retry next loop
      end
    end
    if not keep then r[id] = nil end                     -- input confirmed clear (or dead) -> drop from the set
  end
end

--- Start listening to every splitter/merger so their ItemRequest signals actually
--- reach this computer. CRITICAL: in FIN, event.registerListener only sets a callback
--- filter — you must ALSO event.listen(component) for each signal source, or NOTHING
--- arrives (the "items stuck at the first merger" symptom).
---
--- LISTEN-ONCE, RE-SYNC ON CHANGE. Two in-game costs make naive listening leak FPS:
---  (1) event.listen(component) -> HookSubsystem::AttachHooks = ClearHooks + NewObject<UFIRHook>
---      EVERY call, so re-listening all components on every ~2s rebuild churns hook UObjects
---      (the original "lags more over time" v0.7.1 symptom) — so we must NOT re-listen a stable set.
---  (2) WORSE, and the real progressive-FPS leak: FIN's AFINSignalSubsystem keeps a per-SENDER
---      entry FOREVER for the session (only removed by event.ignore / save). When a player
---      repairs/re-snaps/rebuilds a belt/splitter/merger/container it gets a NEW FGuid, so the
---      ~4s re-discovery listens the new id and ORPHANS the old id's sender+hooks permanently.
---      The orphan set grows with distinct-ids-seen; the game thread then pays on every UE GC
---      pass (walks every sender's traces) and every item grab (IsSender over the growing map)
---      => steady decline that vanishes the instant the computer halts (Reset -> IgnoreAll).
--- Fix: only TOUCH the listeners when the live codeable id-set actually CHANGES; then prune
--- EVERYTHING (event.ignoreAll drops the orphans we can no longer reference) and re-listen the
--- current set. A stable factory still listens exactly once (no churn); a rebuild costs one
--- bounded re-sync instead of an immortal orphan. Reset per App.run session.
Router._listened = Router._listened or {}
function Router:listenAll()
  if not (event and event.listen) then return end
  local want = {}
  for _, id in ipairs(self.topo.splitters or {}) do want[id] = true end
  for _, id in ipairs(self.topo.mergers or {}) do want[id] = true end
  -- changed iff some wanted id is not yet listened, or some listened id is gone from the topology
  local changed = false
  for id in pairs(want) do if not Router._listened[id] then changed = true; break end end
  if not changed then
    for id in pairs(Router._listened) do if not want[id] then changed = true; break end end
  end
  if not changed then return end                 -- stable set: nothing to do (no re-listen churn)
  local prev = 0; for _ in pairs(Router._listened) do prev = prev + 1 end
  if event.ignoreAll then pcall(function() event.ignoreAll() end) end   -- drop ALL incl orphaned senders
  Router._listened = {}
  local n = 0
  for id in pairs(want) do
    local p = self.getProxy(id)
    if p then pcall(function() event.listen(p) end); Router._listened[id] = true; n = n + 1 end
  end
  if Router.DEBUG and computer and computer.log then
    computer.log(1, ("[Foreman] listeners re-synced %d -> %d (pruned orphaned senders)"):format(prev, n))
  end
end

--- Register the signal handler that executes routing AND listen to all codeable nodes.
--- Call once, then pump the event loop (e.g. Router:run() or your own event.pull loop).
-- DEFAULT-DENY: block every container's output. The controller asserts "nothing emits" the
-- instant it takes over; applyGates (end of the first fillAll) then OPENS exactly the providers
-- whose items are demanded. Idempotent, so it's also a safe assertion on every rebuild.
function Router:blockAllOutputs()
  for _, c in ipairs(self.topo.containers or {}) do
    for _, conn in ipairs(self:_connFor(c.id).conns) do self:_setBlocked(conn, true) end
  end
end

function Router:install()
  self:blockAllOutputs()        -- close everything first; applyGates re-opens only what flows
  self:listenAll()
  event.registerListener(event.filter{ event = "ItemRequest" },
    function(_, sender, a, b) self:_dispatch(sender, a, b) end)
end

-- back-compat alias — pump() (level-triggered) drains every codeable input each call.
function Router:pumpGated() return self:pump() end

-- (Re)compute per-edge quota: for every order, walk its stored PATH and add the order's
-- remaining demand (count - delivered) onto each belt for that item. quota[belt][item] =
-- "how many of item still need to cross this belt". This is the single source of truth
-- for balanced routing — it is NODE-AGNOSTIC: a belt out of a splitter and a belt out of
-- a merger are quota'd and decremented identically, so it does not matter whether the
-- last hop into a constructor/container is a splitter or a merger. Call after orders are
-- placed and on every rebuild (paths are recomputed there, so a deleted node re-quotas).
-- count of `item` currently held at a destination. A machine dst is read via getInputInv (its
-- input inventory); a container dst via getInventories. pcall-guarded; 0 on any failure.
function Router:_countAt(dst, item, isMachine)
  item = lc(item)
  local p = self.getProxy(dst); if not p then return 0 end
  -- container branch for a declared buffer's OWN item: itemCount, no per-slot scan (see _count PERF note)
  if not isMachine and self.capacity[dst] ~= nil and self.bufferItem[dst] == item then
    local total = 0
    local ok, invs = pcall(function() return p:getInventories() end)
    if ok then for _, inv in ipairs(invs or {}) do local n = 0; pcall(function() n = inv.itemCount or 0 end); total = total + n end end
    return total
  end
  local total = 0
  local function tally(inv)
    if not inv or not inv.getStack then return end
    local n = 0; pcall(function() n = inv.itemCount or 0 end); if n == 0 then return end  -- skip empty inventory
    local sz = 0; pcall(function() sz = inv.size or 0 end)
    for i = 0, sz - 1 do
      local s = inv:getStack(i)
      if s and (s.count or 0) > 0 and s.item and s.item.type and lc(s.item.type.name) == item then
        total = total + s.count
      end
    end
  end
  if isMachine then
    local ok, inv = pcall(function() return p:getInputInv() end); if ok then tally(inv) end
  else
    local ok, invs = pcall(function() return p:getInventories() end)
    if ok then for _, inv in ipairs(invs or {}) do tally(inv) end end
  end
  return total
end

-- Debug-only delivery credit: count an item crossing the FINAL belt into one of its demanders
-- (machine or buffer). No ledger consumes this — machine/buffer inventory is the ground truth —
-- it only feeds the 'dbg flow' forensics line.
Router._deliv = Router._deliv or {}   -- "<dstId>|<item>" -> cumulative delivered this session
function Router:_credit(belt, item)
  for _, c in ipairs(self.demand[item] or {}) do
    if c.id == belt.to then
      local k = tostring(belt.to) .. "|" .. item
      Router._deliv[k] = (Router._deliv[k] or 0) + 1
      return
    end
  end
end

-- Fallback for an item with NO next hop at this node (nothing demands it, or its demander is
-- unreachable from here). HOLD-OVER-MISDELIVER policy (user rule: "it's better to block at the
-- splitter than block towards the constructors"):
--   1. REROUTE to a buffer for the item that has room (preserve it in storage, off the belt);
--   2. else if NO machine demands it anywhere: SINK it (true over-supply — clears the lane);
--   3. else HOLD at this node — a machine-demanded item is never wasted into the sink; it waits
--      HERE, where the level-triggered retry re-routes it the moment a hop opens. The lane
--      backing up to the source is intentional back-pressure. Hold patience (below) bounds a
--      permanent dead-end so it cannot gridlock the lane forever.
-- `fromOutput` is the transferItem arg for the hop out of this node.
function Router:_overflow(sender, id, item)
  local hkey = tostring(id) .. "|" .. item       -- hold-patience key (see Router.holdPatience)
  -- 1. REROUTE to a buffer for the item that has room — preserves it (it waits in storage,
  -- available when demand returns) instead of blocking the belt behind it.
  for _, D in ipairs(self.buffersForItem[item] or {}) do
    if self:hasRoom(D, item) then
      local belt = self:firstHopTo(id, D)
      if belt and sender:transferItem(belt.fromOutput or 0) then
        -- Credit room ONLY on the DIRECT hop into D (same gate as _credit). An intermediate hop must
        -- NOT credit — the item continues and is credited at the final splitter before D (best.to == D),
        -- so crediting here too would double-count and falsely fill the cache (the reroute under-fill bug).
        if belt.to == D then self:_credit(belt, item); self:_creditRoom(D, item) end
        Router._holdN[hkey] = nil
        Router._flowBy[item] = Router._flowBy[item] or {}
        Router._flowBy[item].rer = (Router._flowBy[item].rer or 0) + 1
        Router._dlog(("REROUTE %s '%s' >out[%d] %s"):format(tostring(id):sub(1,6), item, belt.fromOutput or 0, tostring(D):sub(1,6)))
        return true
      end
    end
  end
  -- 3. SINK — but NEVER an item a MACHINE is waiting for: sinking a live consumer's feedstock is
  -- wasted resources (the live 424 sunk copper ingots while the copper sheet machines starved).
  -- Buffer-fill surplus with every buffer full IS sinkable — that is genuine over-supply and the
  -- lane must clear. Try EVERY DEFAULT_OUT: the first sink may be unreachable from this node
  -- while another is reachable on a looped manifold.
  local machineDemand = false
  for _, c in ipairs(self.demand[item] or {}) do if c.machine then machineDemand = true; break end end
  -- HOLD PATIENCE: a demanded item that has been held HERE for holdPatience consecutive attempts
  -- is going nowhere (a dead-end lane, an unreachable consumer) — gridlocking every flow behind
  -- it. Let it sink: bounded waste beats a frozen factory.
  local impatient = (Router._holdN[hkey] or 0) > (Router.holdPatience or 400)
  if not machineDemand or impatient then
    for _, sink in ipairs(self.defaults or {}) do
      local belt = self:firstHopTo(id, sink)
      if belt and sender:transferItem(belt.fromOutput or 0) then
        Router._nSunk = (Router._nSunk or 0) + 1          -- always-counted; the perf line reports the rate
        Router._holdN[hkey] = nil
        Router._flowBy[item] = Router._flowBy[item] or {}
        Router._flowBy[item].sunk = (Router._flowBy[item].sunk or 0) + 1
        Router._dlog(("SINK %s '%s' (overflow, %s)"):format(tostring(id):sub(1,6), item, impatient and "hold patience expired" or "no machine demand"))
        return true
      end
    end
  end
  -- 4. HOLD at this node (user rule: block at the SPLITTER, never toward a constructor). An item
  -- a machine is waiting for waits HERE — the level-triggered retry resumes it the moment a leg
  -- opens — and the lane backing up to the source is intentional back-pressure (the gate must
  -- not pour more into a jammed chain). An UNDEMANDED item only lands here when no sink is
  -- reachable; that one is a wiring gap worth the warning. NEVER panic: a crash kills the whole
  -- controller over a single stray item.
  Router._nStuck = (Router._nStuck or 0) + 1             -- always-counted; the perf line reports the rate
  Router._holdN[hkey] = (Router._holdN[hkey] or 0) + 1
  Router._flowBy[item] = Router._flowBy[item] or {}
  Router._flowBy[item].stuck = (Router._flowBy[item].stuck or 0) + 1
  if impatient then
    -- patience expired and the sink loop above found no exit: if this node feeds a machine,
    -- hand the cork to the planner for a TARGETED feed-drain (it knows the exact item)
    for _, b in ipairs(self.adj[id] or {}) do
      if self.isMachine[b.to] then Router._corked[b.to] = item; break end
    end
  end
  if machineDemand then
    Router._dlog(("HOLD %s '%s' (a machine is waiting for it)"):format(tostring(id):sub(1,6), item))
  elseif Router.DEBUG and computer and computer.log then
    Router._holdLog = Router._holdLog or 0
    if Router._holdLog < 8 then
      Router._holdLog = Router._holdLog + 1
      computer.log(2, ("[Foreman] STUCK: '%s' at %s — no demand and no sink reachable from here; holding. Wire a DEFAULT_OUT_%d near this node, or a buffer for '%s'.")
        :format(tostring(item), tostring(id), #self.defaults + 1, tostring(item)))
    end
  end
  return false
end

-- Route the item at a SPLITTER input: send it down the next-hop leg toward its nearest demander
-- (precomputed by buildNextHop; up to 3 candidate legs, nearest first, so a physically full leg
-- diverts to the next-nearest). No hop accepts -> the no-demand fallback (buffer/sink/hold).
function Router:_routeAtSplitter(sender, id, item)
  -- Authoritative: route the item ACTUALLY at the input now. ItemRequest is edge-triggered
  -- and can arrive stale (the retry may have already moved it) — trusting the signal's item
  -- would route a phantom.
  if sender.getInput then
    local cur = itemName(sender:getInput())
    if not cur then return false end                 -- input empty: stale signal, no-op
    item = cur
  end
  local legs = (self.nextHop[id] or {})[item]
  for li = 1, (legs and #legs or 0) do
    local best = legs[li].b
    local terminal = not self.bufferItem[best.to]
    if not self:_beltAccepts(best, item) then
      Router._dlog(("MISROUTE %s '%s' >out[%d] %s — machine/port doesn't take it; skipping leg")
        :format(tostring(id):sub(1, 6), item, best.fromOutput or 0, tostring(best.to):sub(1, 6)))
    elseif terminal or self:hasRoom(best.to, item) then
      if sender:transferItem(best.fromOutput or 0) then
        self:_credit(best, item)
        if not terminal then self:_creditRoom(best.to, item) end   -- routed toward a buffer: bump its cached room
        if self.isMachine[best.to] and Router._legFullMach then Router._legFullMach[best.to] = nil end   -- entrance accepted: jam (if any) cleared
        -- FAIR SPLIT within an epoch: rotate the used leg to the back of its equal-distance
        -- group, so two demanders at the same distance alternate item-by-item (the 8/8 split)
        local grpEnd = li
        while grpEnd < #legs and legs[grpEnd + 1].d == legs[li].d do grpEnd = grpEnd + 1 end
        if grpEnd > li or li > 1 then
          local used = table.remove(legs, li)
          table.insert(legs, grpEnd, used)
        end
        Router._dlog(("SPL %s '%s' >out[%d] %s"):format(tostring(id):sub(1,6), item, best.fromOutput or 0, tostring(best.to):sub(1,6)))
        return true
      end
      -- chosen leg physically full right now: a starved consumer whose leg never accepts = its
      -- input belt is backed up (output blocked, or a foreign head item the machine won't pull).
      -- Mark machine entrances (module-durable, epoch-stamped: the planner's feed-drain reads it;
      -- cleared on a successful push) and try the next-nearest demander's leg.
      if self.isMachine[best.to] then Router._legFullMach = Router._legFullMach or {}; Router._legFullMach[best.to] = Router._epochN or 0 end
      Router._dlog(("SPLFULL %s '%s' >out[%d] %s — leg full, diverting"):format(tostring(id):sub(1, 6), item, best.fromOutput or 0, tostring(best.to):sub(1, 6)))
    end
  end
  return self:_overflow(sender, id, item)
end

-- the foreign item sitting on a machine's FEED (the head item on a belt whose `to` is this machine,
-- read at the feeding splitter/merger). A merger has up to 3 input ports — scan ALL of them (a
-- splitter has one input). nil if nothing / unreadable.
function Router:_feedItem(cid)
  for _, belts in pairs(self.adj) do
    for _, b in ipairs(belts) do
      if b.to == cid and (self.isSplitter[b.from] or self.isMerger[b.from]) then
        local p = self.getProxy(b.from); if p and p.getInput then
          if self.isMerger[b.from] then
            for i = 0, 2 do
              local ok, it = pcall(function() return p:getInput(i) end)
              local nm = ok and itemName(it); if nm then return nm end
            end
          else
            local ok, it = pcall(function() return p:getInput() end)
            local nm = ok and itemName(it); if nm then return nm end
          end
        end
      end
    end
  end
  return nil
end

-- total items currently in a machine's input inventory (any item). 0 if empty/unreadable.
function Router:_inputTotal(cid)
  local p = self.getProxy(cid); if not p then return 0 end
  local ok, inv = pcall(function() return p:getInputInv() end); if not (ok and inv and inv.getStack) then return 0 end
  local total, sz = 0, 0; pcall(function() sz = inv.size or 0 end)
  for i = 0, sz - 1 do local s = inv:getStack(i); if s and (s.count or 0) > 0 then total = total + s.count end end
  return total
end

-- the ITEMS in a machine's input, as "item:n,item:n" (debug) — so a foreign item (iron rod in an
-- iron-ingot machine) is visible at a glance. "" if empty/unreadable.
function Router:_inputItems(cid)
  local p = self.getProxy(cid); if not p then return "" end
  local ok, inv = pcall(function() return p:getInputInv() end); if not (ok and inv and inv.getStack) then return "" end
  local agg, sz = {}, 0; pcall(function() sz = inv.size or 0 end)
  for i = 0, sz - 1 do
    local s = inv:getStack(i)
    if s and (s.count or 0) > 0 and s.item and s.item.type then
      local nm = lc(s.item.type.name); agg[nm] = (agg[nm] or 0) + s.count
    end
  end
  local parts = {}; for nm, n in pairs(agg) do parts[#parts + 1] = nm .. ":" .. n end
  return table.concat(parts, ",")
end

-- DEBUG: each DISCOVERED feeding belt into a machine, as "<feeder6>@<port>:<item at the feeder's input>".
-- A foreign item BLOCKING a machine sits on the belt / backs up to the feeder (the machine won't pull an
-- item its recipe rejects), so getInputInv reads empty while the entrance is jammed — this shows it. It
-- ALSO prints the discovered feeder+port, so the operator can verify it against the PHYSICAL wiring: if a
-- port recorded as feeding this machine is physically wired to a different one, items route "correctly"
-- yet land at the wrong machine (a splitter port mis-discovery = the item CROSS).
function Router:_feedDump(cid)
  local parts = {}
  for _, belts in pairs(self.adj) do
    for _, b in ipairs(belts) do
      if b.to == cid then
        local nm = "-"
        if self.isSplitter[b.from] or self.isMerger[b.from] then
          local p = self.getProxy(b.from)
          if p and p.getInput then
            if self.isMerger[b.from] then
              for i = 0, 2 do local ok, x = pcall(function() return p:getInput(i) end); local n = ok and itemName(x); if n then nm = n; break end end
            else
              local ok, x = pcall(function() return p:getInput() end); nm = (ok and itemName(x)) or "-"
            end
          end
        end
        parts[#parts + 1] = ("%s@%d:%s"):format(tostring(b.from):sub(1, 6), b.fromOutput or 0, nm)
      end
    end
  end
  return table.concat(parts, " ")
end

-- RECOVERY (spec §6): a machine starved (input empty) for >= stuckEpochs with a FOREIGN item on its
-- feed that its assigned recipe can't consume -> temp-switch to the most-needed recipe that DOES
-- consume it, drain, and (once the feed AND input clear) revert. State is MODULE-LEVEL (Router._draining
-- / Router._idleEpochs) so it survives the ~2s App.run router rebuilds; App.run resets it per session.
function Router:_stuckScan(planner)
  Router._idleEpochs = Router._idleEpochs or {}
  Router._draining = Router._draining or {}          -- cid -> { revert = assigned recipe NAME, foreign = item }
  for _, cid in ipairs(self.topo.constructors or {}) do
    local d = Router._draining[cid]
    if d then
      -- REVERT only when the feed foreign item is gone AND the machine input is empty, so setRecipe
      -- (which ejects the whole input) ejects nothing — the FIN-safe invariant.
      if self:_feedItem(cid) == nil and self:_inputTotal(cid) == 0 then
        local p = self.getProxy(cid)
        for _, r in ipairs((p and p.getRecipes and p:getRecipes()) or {}) do
          if tostring(r.name) == d.revert then pcall(function() p:setRecipe(r) end) end
        end
        Router._draining[cid] = nil
      end
    else
      local have, a, wantIng = 0, planner._assign and planner._assign[cid], {}
      if a and a.opt and a.opt.ingredients then
        for _, ing in ipairs(a.opt.ingredients) do wantIng[ing.name] = true; have = have + self:_countAt(cid, ing.name, true) end
      end
      Router._idleEpochs[cid] = (have == 0) and ((Router._idleEpochs[cid] or 0) + 1) or 0
      if a and (Router._idleEpochs[cid] or 0) >= self.stuckEpochs then
        local feed = self:_feedItem(cid)
        if feed and not wantIng[feed] then self:_drainStuck(cid, feed, planner) end
      end
    end
  end
end

-- temp-switch `cid` to its most-needed recipe consuming `foreign`; remember the assigned recipe NAME
-- to revert to. Caller guarantees the input is empty (starved) so setRecipe ejects nothing.
function Router:_drainStuck(cid, foreign, planner)
  local p = self.getProxy(cid); if not (p and p.getRecipes) then return end
  local best, bestNeed
  for _, r in ipairs(p:getRecipes() or {}) do
    local consumes = false
    local oki, ings = pcall(function() return r:getIngredients() end)
    if oki then for _, ia in ipairs(ings or {}) do if lc(ia.type.name) == lc(foreign) then consumes = true end end end
    if consumes then
      local prod
      local okp, prods = pcall(function() return r:getProducts() end)
      if okp and prods and prods[1] then prod = lc(prods[1].type.name) end
      local need = (planner.need and prod and planner.need[prod]) or 0
      if not bestNeed or need > bestNeed then best, bestNeed = r, need end
    end
  end
  if best then
    local a = planner._assign and planner._assign[cid]
    -- _assign.recipe is the recipe NAME (a string), not a table — store it directly for revert.
    Router._draining[cid] = { revert = a and a.recipe or nil, foreign = lc(foreign) }
    pcall(function() p:setRecipe(best) end)
    Router._idleEpochs[cid] = 0
    Router._dlog(("DRAIN-STUCK %s consume '%s' via '%s'"):format(tostring(cid):sub(1,6), foreign, tostring(best.name)))
  end
end

-- Route the item at one MERGER input: a merger has a single output, so there is no leg to
-- choose — forward it (back-pressure stops it if the output is full). Decrement the output
-- leg's quota and credit if that output feeds a destination. An item with no quota on the
-- output is still forwarded (it flows on to the next splitter, or eventually a sink). The
-- `input` is the merger's logic id, exactly what transferItem expects.
function Router:_mergerPush(sender, id, input, nm)
  -- Authoritative: read the item ACTUALLY at this input now. An ItemRequest is edge-
  -- triggered and can arrive stale (pump() may have moved the head already), so the
  -- signal's nm can name a different item than the one transferItem will actually move —
  -- which would decrement/credit the wrong order. Re-read like _routeAtSplitter does.
  if sender.getInput then
    local cur = itemName(sender:getInput(input))
    if not cur then return false end                 -- input empty: stale signal, no-op
    nm = cur
  end
  local out = (self.adj[id] or {})[1]                -- merger's single output belt
  if out and not self:_beltAccepts(out, nm) then     -- never push a foreign item into a machine OR a pinned port
    Router._dlog(("MISROUTE %s '%s' >merge %s — machine/port doesn't take it; holding"):format(tostring(id):sub(1, 6), nm, tostring(out.to):sub(1, 6)))
    return false
  end
  if not sender:transferItem(input) then
    -- push failed: the merger's output belt is full. If it feeds a machine, mark the entrance jam
    -- (same signal as _routeAtSplitter's SPLFULL) for the planner's feed-drain.
    if out and self.isMachine[out.to] then Router._legFullMach = Router._legFullMach or {}; Router._legFullMach[out.to] = Router._epochN or 0 end
    return false
  end
  if out then
    self:_credit(out, nm)
    if self.isMachine[out.to] and Router._legFullMach then Router._legFullMach[out.to] = nil end   -- entrance accepted: jam cleared
  end
  return true
end

-- ALL output FactoryConnections of a building (direction 1). A real container exposes
-- one connector PER PHYSICAL conveyor port — an Industrial Storage Container has TWO
-- outputs — and getFactoryConnectors returns every one. The old code blocked only the
-- FIRST, so a source kept emitting out its second (un-gated) port in-game: the copper
-- source dribbling onto the belt with nothing to consume it. The emulator never caught
-- this because it only materialises the belted connectors. Always gate EVERY output.
function Router:_outputConnectors(p)
  if not (p and p.getFactoryConnectors) then return {} end
  local ok, conns = pcall(function() return p:getFactoryConnectors() end)
  if not ok then return {} end
  local outs = {}
  for _, conn in ipairs(conns or {}) do if conn.direction == 1 then outs[#outs + 1] = conn end end
  return outs
end

-- STATIC connector cache (module-level, cleared on re-discover — same lifecycle as the proxy cache).
-- A container's output FactoryConnection objects, and each one's `isConnected` (belted?) flag, do NOT
-- change between full re-crawls; getFactoryConnectors + isConnected are game-thread syncs, and gateSources
-- read them for EVERY container EVERY ~2s re-plan (~2/3 of its sync cost). `_connFor` reads them once per
-- container per discover and reuses the SAME connector objects, so `_setBlocked` can also shadow each
-- connector's last-written `blocked` and skip the redundant write (a container's block verdict is almost
-- always identical epoch-to-epoch). conns: every output; fund: the belted subset (fallback: all).
-- Keyed by the PROXY OBJECT, not the cid: getProxy caches a stable proxy per cid in-game (so this hits
-- across the ~2s rebuilds), but a re-discover (or a fresh test world) yields a NEW proxy object, which
-- naturally MISSES and re-reads — so a stale connector from a torn-down network can never be reused
-- (cids are reused across test worlds; FGuids are not, but proxy-keying is correct for both).
Router._connCache = Router._connCache or {}        -- proxy -> { conns = {...}, fund = {...} }
Router._blockShadow = Router._blockShadow or {}     -- connector object -> last-written blocked bool
function Router:_connFor(cid)
  local p = self.getProxy(cid)
  if not p then return { conns = {}, fund = {} } end
  local e = Router._connCache[p]
  if e then return e end
  local conns = self:_outputConnectors(p)
  local fund = {}
  for _, conn in ipairs(conns) do
    local cc = false; pcall(function() cc = conn.isConnected or false end)
    if cc then fund[#fund + 1] = conn end
  end
  e = { conns = conns, fund = (#fund > 0) and fund or conns }
  Router._connCache[p] = e
  return e
end
-- Write conn.blocked only when it differs from the last value we wrote — the actual game-thread write
-- is the cost; the verdict rarely changes. (Nothing OUTSIDE gateSources/blockAllOutputs writes .blocked,
-- and both go through here; the shadow is cleared on re-discover with the connector cache, so a rebuilt
-- connector starts fresh and gets its first write.)
function Router:_setBlocked(conn, b)
  if Router._blockShadow[conn] ~= b then
    pcall(function() conn.blocked = b end)
    Router._blockShadow[conn] = b
  end
end

-- PER-ITEM FLOW LEDGER (debug forensics): where overflow handling put items that lost their
-- route (rerouted to a buffer / sunk / stuck-held). Module-durable; dumped by debugDump.
Router._flowBy = Router._flowBy or {}             -- item -> { rer=, sunk=, stuck= }
-- machine entrances whose feed leg push FAILED: cid -> the epoch it failed (stale marks must not
-- trigger drains). Set by _routeAtSplitter/_mergerPush, cleared on a successful push.
Router._legFullMach = Router._legFullMach or {}
Router.jamFresh = Router.jamFresh or 2            -- a jam mark older than this many epochs is stale
-- Is `cid`'s entrance jam mark FRESH? Under hold-at-splitter, pushes may simply STOP being
-- attempted, leaving a stale mark that re-triggered the feed-drain forever (the v0.16.5 freeze
-- loop). A mark only counts within jamFresh epochs; legacy boolean marks (tests) always count.
function Router:legJammed(cid)
  local st = Router._legFullMach and Router._legFullMach[cid]
  if st == nil then return false end
  if st == true then return true end
  return ((Router._epochN or 0) - st) <= (Router.jamFresh or 2)
end
-- HOLD PATIENCE: a machine-demanded item held at the same node for this many consecutive overflow
-- attempts finally gets the sink — bounded waste beats a frozen factory.
Router._holdN = Router._holdN or {}               -- "node|item" -> consecutive hold attempts
Router.holdPatience = Router.holdPatience or 400
-- CORKS: an item held past patience with NO sink reachable at a node that FEEDS a machine. The
-- live-recipe gate rightly refuses to misdeliver it, so no push toward the machine ever fails —
-- the feed-drain's jam trigger never arms and the cork blocks the lane forever (the v0.17.0
-- freeze). Since the corked item is READABLE at the node input, the planner can drain it
-- PRECISELY: temp recipe that consumes exactly this item, admit it, eat it, restore.
Router._corked = Router._corked or {}             -- machineId -> corked item awaiting a targeted drain
Router.stuckEpochs = Router.stuckEpochs or 3      -- empty-input epochs before temp-consumer-drain may fire

-- FEEDBACK GATING (demand-pull). Every container's output is closed by default; each epoch the
-- planner computes per-provider GRANTS (a refill batch sized from its demanders' live shortfall —
-- machine inputs and buffer levels are re-read every epoch, so there is no cross-epoch release
-- ledger to corrupt: over-release self-corrects because the next epoch sees fuller inventories
-- and grants less/nothing). grants[containerId] = units to ALLOW out this epoch (absolute target
-- for the connector budget, not an increment).
function Router:applyGates(grants)
  grants = grants or {}
  for _, c in ipairs(self.topo.containers or {}) do
    local e = self:_connFor(c.id)
    local want = grants[c.id]
    if want and want > 0 then
      -- top the connector budget UP TO the grant (never duplicate what is still unreleased):
      -- leftover budget from the previous epoch counts against this epoch's grant.
      local have = 0
      for _, conn in ipairs(e.conns) do
        local cur = 0; pcall(function() cur = conn.unblockedTransfers or 0 end); have = have + cur
      end
      local add = want - have
      if add > 0 and #e.fund > 0 then
        local outs = e.fund
        local base, extra = math.floor(add / #outs), add % #outs
        for k, conn in ipairs(outs) do
          local s = base + (k <= extra and 1 or 0)
          if s > 0 then pcall(function() conn:addUnblockedTransfers(s) end) end
        end
      end
      -- FIN metering semantics: the connector stays BLOCKED; unblockedTransfers is the budget
      -- it may release despite the block. Unblocking would release without bound.
      for _, conn in ipairs(e.conns) do self:_setBlocked(conn, true) end
    else
      -- no grant: close the gate AND zero any leftover budget so the container stops dead and
      -- its stock stays IN STORAGE rather than dribbling onto the manifold.
      for _, conn in ipairs(e.conns) do
        local cur = 0; pcall(function() cur = conn.unblockedTransfers or 0 end)
        if cur > 0 then pcall(function() conn:addUnblockedTransfers(-cur) end) end
        self:_setBlocked(conn, true)
      end
    end
  end
end

function Router:pump()
  local total = 0
  local present = 0
  local progressed, guard = true, 0
  while progressed and guard < 10000 do
    progressed = false; guard = guard + 1
    present = 0
    for _, id in ipairs(self.topo.splitters or {}) do
      local s = self.getProxy(id)
      if s and s.getInput then
        local ok, it = pcall(function() return s:getInput() end)
        local nm = ok and itemName(it)               -- nil for an empty input (FIN empty struct)
        if nm then
          present = present + 1
          if self:_routeAtSplitter(s, id, nm) then total = total + 1; progressed = true end
        end
      end
    end
    for _, id in ipairs(self.topo.mergers or {}) do
      local m = self.getProxy(id)
      if m and m.getInput then
        local hasItem = false
        -- ALTERNATE inputs fairly. A merger's output holds only 2 items, so always draining
        -- inputs 0,1,2 in fixed order lets the early inputs grab the freed slots and STARVE
        -- the rest (uneven, drifting ratios). Forward exactly ONE item per pass, from the next
        -- non-empty input at/after the cursor, then advance the cursor PAST it — so consecutive
        -- forwards rotate evenly across the active inputs (1:1:1). The while-loop re-runs to
        -- forward the rest in that rotated order.
        -- PRIORITY by ITEM, not by port. Phase 1 forwards a PRODUCT/intermediate (anything NOT a
        -- raw input item — e.g. iron plates arriving from a buffer); phase 2 forwards a RAW INPUT
        -- item (copper/iron ingot/concrete) only when no product was waiting this pass. So the
        -- merger drains products-in-transit off the belt FIRST, and injects raw material only into
        -- the gaps — while round-robining (the _mrr cursor) keeps the raw inputs MIXED among
        -- themselves instead of serialising copper->concrete->iron by manifold position. Item-based
        -- is what makes a raw item low-priority no matter how far down the manifold it merged in.
        local raw = self._rawItem
        local start = self._mrr[id] or 0
        local moved = false
        for phase = 1, 2 do
          for k = 0, 2 do
            local i = (start + k) % 3
            local ok, it = pcall(function() return m:getInput(i) end)
            local nm = ok and itemName(it)
            if nm then
              hasItem = true
              local isRaw = raw[nm] or false
              if ((phase == 2) == isRaw) and self:_mergerPush(m, id, i, nm) then
                total = total + 1; progressed = true; moved = true
                self._mrr[id] = (i + 1) % 3          -- next forward serves the input after this one
                break
              end
            end
          end
          if moved then break end                    -- forwarded one; don't also pull a raw input this pass
        end
        if hasItem then present = present + 1 end
      end
    end
  end
  return total, present
end

--- DEBUG state dump (only when nick "debug" / opts.debug). One block per call so the operator can
--- watch supply/demand live: every storage buffer's fill, every source's lifetime release + live
--- leftover budget, every machine's recipe + input level. This is what shows an OVER-SUPPLY (a buffer
--- pinned full + its source still releasing) or a STARVED machine (recipe set, input 0) at a glance.
function Router:debugDump()
  if not (Router.DEBUG and computer and computer.log) then return end
  local function s6(x) return tostring(x):sub(1, 6) end
  for _, c in ipairs(self.topo.containers or {}) do
    local item = self.bufferItem[c.id]
    if item and self.capacity[c.id] then
      computer.log(1, ("[Foreman] dbg buf %s '%s' %d/%d"):format(s6(c.id), item, self:_count(c.id, item), self.capacity[c.id]))
    end
  end
  for _, c in ipairs(self.topo.containers or {}) do
    local item = self.sourceItem[c.id]
    if item then
      local ub = 0
      for _, conn in ipairs(self:_connFor(c.id).conns) do local cur = 0; pcall(function() cur = conn.unblockedTransfers or 0 end); ub = ub + cur end
      computer.log(1, ("[Foreman] dbg src %s '%s' gate=%s ub=%d"):format(s6(c.id), item,
        ub > 0 and "open" or "shut", ub))
    end
  end
  -- the live demand sets: who needs what, how much (the entire routing truth under demand-pull)
  for item, consumers in pairs(self.demand or {}) do
    local total, who = 0, {}
    for _, cn in ipairs(consumers) do total = total + (cn.need or 0); who[#who + 1] = s6(cn.id) .. (cn.machine and "" or "*") end
    computer.log(1, ("[Foreman] dbg demand '%s' need=%d <- %s"):format(item, total, table.concat(who, ",")))
  end
  for _, cid in ipairs(self.topo.constructors or {}) do
    local p = self.getProxy(cid)
    local rec = "?"; if p then pcall(function() local r = p:getRecipe(); rec = (r and r.name) or "none" end) end
    local wants = {}
    for it, consumers in pairs(self.demand or {}) do
      for _, cn in ipairs(consumers) do if cn.id == cid then wants[#wants + 1] = it; break end end
    end
    computer.log(1, ("[Foreman] dbg mac %s recipe=%s in=%d [%s] wants[%s] fed[%s]")
      :format(s6(cid), rec, self:_inputTotal(cid), self:_inputItems(cid), table.concat(wants, ","), self:_feedDump(cid)))
  end
  -- per-item flow forensics: lifetime authorized vs delivered, and where overflow handling put the
  -- rest (recovered to a destination / rerouted to a buffer / sunk / stuck-held). auth-deliv with
  -- all four ~0 = the item is parked ON BELTS somewhere (a dam — look for a STUCK item upstream).
  local items = {}
  for it in pairs(self.demand or {}) do items[it] = true end
  for it in pairs(Router._flowBy) do items[it] = true end
  for item in pairs(items) do
    local f = Router._flowBy[item] or {}
    local deliv = 0
    for k, v in pairs(Router._deliv or {}) do if k:sub(-#item - 1) == "|" .. item then deliv = deliv + v end end
    computer.log(1, ("[Foreman] dbg flow '%s' deliv=%d rer=%d sunk=%d stuck=%d")
      :format(item, deliv, f.rer or 0, f.sunk or 0, f.stuck or 0))
  end
end

--- Demand-pull has no order ledger; "done" is run()'s quiescence streak. Kept for API compat.
function Router:allDone() return true end

--- Drive routing until quiescent (batch/test). Each iteration: level-triggered pump()
--- (drain all codeable inputs) + one event.pull(0) (which, under the emulator, advances
--- the conveyor sim and dispatches any signals).
--- Quiescence is a STREAK, not a single quiet tick: a conveyor hop that ends in a
--- constructor or a container (merger->constructor, constructor->container) moves an item
--- but fires NO ItemRequest, so a single pull(0) can return nil while the sim is still
--- draining a multi-hop chain (the assembler/manufacturer case). Only stop after several
--- consecutive cycles move nothing AND deliver no signal.
function Router:run(maxLoops)
  local idle = 0
  for _ = 1, maxLoops or 5000000 do
    local moved = self:pump()
    local sig = event.pull(0)
    if moved > 0 or sig ~= nil then idle = 0 else idle = idle + 1 end
    if idle >= 6 then return true end
  end
  return false
end

return Router
