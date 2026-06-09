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
  -- MACHINE set + per-machine CONSUMED items (populated by order(): an order to a constructor means it
  -- consumes that item). Used to GUARD a delivery — a splitter must never hand a constructor an item its
  -- recipe doesn't take (iron rod into an iron-ingot machine, etc.) — and to dump the input item.
  self.isMachine, self.consumes, self.portItem = {}, {}, {}
  for _, id in ipairs(topology.constructors or {}) do self.isMachine[id] = true end
  -- adjacency: node -> list of belts leaving it
  self.adj = {}
  for _, b in ipairs(topology.belts or {}) do
    self.adj[b.from] = self.adj[b.from] or {}
    table.insert(self.adj[b.from], b)
  end
  -- route[splitterId][itemType] = { output=portIndex, order=orderRef, terminal=bool }
  self.route = {}
  self.orders = {}
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
  self.ordersByItem = {}          -- item -> order (latest placed; back-compat)
  self.ordersForItem = {}         -- item -> { all orders } (multi-destination routing)
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
    for _, b in ipairs(topology.belts or {}) do
      if isCtor[b.to] then
        self.inputBelts[b.to] = self.inputBelts[b.to] or {}
        table.insert(self.inputBelts[b.to], { belt = b, port = b.toInput or 0, feeder = b.from })
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

--- Route `count` of `item` to `dst`. Discovers the path and programs every
--- splitter on it. `src` is optional — if omitted, the container declared to
--- `provide` the item is used (the double-pass production case passes the
--- constructor as the explicit src for the crafted product). `toInput` (optional) pins delivery to a
--- SPECIFIC input port of `dst`: the path is forced to END on that port's belt, so a multi-ingredient
--- machine gets each ingredient on its own belt. Returns true, or false + reason if no path/source.
function Router:order(item, count, dst, src, toInput)
  item = lc(item)
  src = src or self:sourceOf(item)
  if not src then return false, "no source provides " .. item end
  local path
  if toInput ~= nil then
    local pb = self:_beltToPort(dst, toInput)
    if pb then
      local pre = self:findPath(src, pb.feeder)       -- route to the port's feeder, then its final belt
      if pre then path = pre; path[#path + 1] = pb.belt end
    end
    if not path then   -- pinning failed (port belt missing / feeder unreachable from this src): observable,
      Router._dlog(("PORT-UNPIN %s '%s' ->%s port %s — falling back to any-port"):format(tostring(src):sub(1,6), item, tostring(dst):sub(1,6), tostring(toInput)))
    end
  end
  path = path or self:findPath(src, dst)              -- fallback: any path to the machine
  if not path then return false, ("no path %s -> %s"):format(src, dst) end
  -- the order REMEMBERS its full path (the ordered list of belts src->dst). Edge quota
  -- is summed from these paths (see buildQuota); on a rebuild the path is recomputed, so
  -- a deleted splitter/merger makes the order re-route or fall back automatically.
  -- `term` points at the order that delivers this flow's TERMINAL product into the actual
  -- buffer (an ingredient order's term is the product->buffer order; a direct/terminal
  -- order is its own term). gateSources gates an ingredient source against the terminal's
  -- delivery so a deep craft chain doesn't over-release (see the planner + gateSources).
  local order = { item = item, count = count, dst = dst, src = src, delivered = 0, path = path }
  order.term = order
  table.insert(self.orders, order)
  self.ordersByItem[item] = order                 -- latest (back-compat)
  self.ordersForItem[item] = self.ordersForItem[item] or {}
  table.insert(self.ordersForItem[item], order)   -- ALL orders for this item (multi-destination)
  if self.isMachine[dst] then self.consumes[dst] = self.consumes[dst] or {}; self.consumes[dst][item] = true end
  if toInput ~= nil and self.isMachine[dst] and path[#path] and (path[#path].toInput or 0) == toInput then
    -- the pin DEDICATES the port: this epoch, port `toInput` of `dst` carries `item` and NOTHING else
    -- (see _beltAccepts — one foreign head item on a dedicated port's belt kills the port forever).
    self.portItem[dst] = self.portItem[dst] or {}
    self.portItem[dst][toInput] = item
  end
  return true
end

-- May a splitter hand `item` to next-node `to`? Always yes UNLESS `to` is a constructor that does NOT
-- consume `item` this epoch — a machine must never be fed a foreign item (it can't craft it, and it jams
-- the input). `consumes[to]` is built from the orders to `to`; if a machine has NO orders yet we don't
-- guard (avoid a false block before the plan reaches it).
function Router:_machineAccepts(to, item)
  if not self.isMachine[to] then return true end
  local c = self.consumes[to]
  if not c or not next(c) then return true end
  return c[item] == true
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
    local want = pm[belt.toInput or 0]
    if want ~= nil and want ~= item then return false end
  end
  return true
end

--- Remove orders placed after index `n` (the planner's atomic rollback: if a craft plan
--- turns out infeasible, drop the partial ingredient orders it already placed so their
--- sources aren't gated to release an ingredient nothing will consume). Orders are appended
--- in placement order, so the last per-item is at the tail of ordersForItem — pop in reverse.
function Router:_truncateOrders(n)
  while #self.orders > n do
    local o = table.remove(self.orders)
    local list = self.ordersForItem[o.item]
    if list and list[#list] == o then table.remove(list) end
    self.ordersByItem[o.item] = (list and list[#list]) or nil
  end
end

-- Cached first belt of a shortest path from -> dst (nil if unreachable). Works on
-- the belt LOOP because findPath's BFS handles cycles.
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
-- instant it takes over; gateSources (end of the first fillAll) then OPENS exactly the sources it
-- funds and the pass-through relays. Idempotent, so it's also a safe assertion on every rebuild.
function Router:blockAllOutputs()
  for _, c in ipairs(self.topo.containers or {}) do
    for _, conn in ipairs(self:_connFor(c.id).conns) do self:_setBlocked(conn, true) end
  end
end

function Router:install()
  self:blockAllOutputs()        -- close everything first; gateSources re-opens only what flows
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

-- free room for an ORDER's delivery into its consumer = cap - have.
--
-- DESTINATION BUFFER: room = target - have. A buffer at/over target contributes 0 quota, so the
-- splitter feeding it diverts the item to a sibling buffer with room or to the bottleneck (load-
-- balances a same-item buffer pool, stops over-filling).
--
-- Room a destination has for an order's item RIGHT NOW. A storage buffer is capped by its capacity.
--
-- MULTI-INGREDIENT MACHINE — BALANCED DELIVERY: never hand a machine more of one ingredient than the
-- SCARCEST other ingredient it holds (+ a small margin). A reinforced-iron-plate machine that is
-- drowning in 200 iron plate but has only 1 screw can't craft — the plate just HOARDS, and (the killer)
-- the plate machine keeps eating iron ingot to make that hoarded plate, which floods the shared manifold
-- and starves the rod->screws chain. Capping plate to ~screws stops the hoard, lets the plate buffer
-- fill, throttles the plate machine, and frees the feedstock for the scarce branch. (This is the
-- per-ingredient cap done RIGHT: ratio-/scarcity-aware, not the too-low fixed portCap=12 that starved a
-- healthy machine.) A single-input machine and a sink are uncapped (full demand).
Router.balanceMargin = Router.balanceMargin or 24       -- per-ingredient lookahead buffer over the scarcest (tunable)
function Router:_orderRoom(o)
  local cap = self.capacity[o.dst]
  if cap then                                            -- destination buffer: room = capacity - have
    local have = self:_countAt(o.dst, o.item, false)
    return math.max(0, cap - have)
  end
  local cons = self.isMachine[o.dst] and self.consumes[o.dst]
  if cons then
    local n = 0; for _ in pairs(cons) do n = n + 1 end
    if n >= 2 then                                       -- multi-ingredient machine: balance to the scarcest
      local have = self:_countAt(o.dst, o.item, true)
      local minOther = math.huge
      for it in pairs(cons) do if it ~= o.item then minOther = math.min(minOther, self:_countAt(o.dst, it, true)) end end
      return math.max(0, (minOther + (Router.balanceMargin or 24)) - have)
    end
  end
  return o.count - o.delivered                           -- single-input machine / sink: full per-epoch demand
end

function Router:buildQuota()
  for _, belts in pairs(self.adj) do for _, b in ipairs(belts) do b._q = {} end end
  local left = {}                                   -- "dst|item" -> room remaining to allocate this pass
  for _, o in ipairs(self.orders) do
    local key = tostring(o.dst) .. "|" .. o.item
    if left[key] == nil then left[key] = self:_orderRoom(o) end
    local contrib = math.min(o.count - o.delivered, left[key])
    if contrib > 0 then
      left[key] = left[key] - contrib               -- SHARE one consumer's room across all its orders
      if o.path then for _, b in ipairs(o.path) do b._q[o.item] = (b._q[o.item] or 0) + contrib end end
    end
  end
end

-- Among a node's OUTGOING belts, the one carrying the most remaining quota for `item`
-- that also has room downstream (a non-buffer dst — constructor/codeable/sink — always
-- accepts; a buffer dst is room-checked). Decrement-on-dispatch makes two equal legs
-- alternate, so N items down each of two legs land exactly N/N — "10 down each leg".
function Router:_bestEdge(id, item)
  local best, bestq = nil, 0
  for _, b in ipairs(self.adj[id] or {}) do
    local q = (b._q and b._q[item]) or 0
    if q > bestq and self:_beltAccepts(b, item) then
      local terminal = not self.bufferItem[b.to]
      if terminal or self:hasRoom(b.to, item) then best, bestq = b, q end
    end
  end
  return best
end

-- Credit one delivery when an item crosses the FINAL belt into an order's destination
-- (belt.to == o.dst). Works regardless of whether the final node is a splitter or a merger
-- (both call this on the same belt objects). Drives allDone() + the in-epoch SINK
-- diagnostic, and accumulates a DURABLE per-source lifetime count (Router._deliv) that
-- survives the App.run rebuild — gateSources needs it to size cross-epoch authorization,
-- and it is the ONLY way to track flow whose destination is a constructor (which consumes
-- immediately, so it has no observable landed inventory to read back).
Router._deliv = Router._deliv or {}   -- "<srcId>|<item>" -> cumulative delivered this session
function Router:_credit(belt, item)
  for _, o in ipairs(self.orders) do
    if o.dst == belt.to and o.item == item and o.delivered < o.count then
      o.delivered = o.delivered + 1
      local k = tostring(o.src) .. "|" .. item
      Router._deliv[k] = (Router._deliv[k] or 0) + 1
      return
    end
  end
end

-- Fallback for an item with NO remaining quota leg at this node (its quota is spent, or it is
-- overflow/unmanaged). NEVER-HOLD policy (user rule: "reroute overflow — to a buffer, or if that's
-- full, to the sink"): a held item blocks the belt behind it (head-of-line — the abundant ingredient
-- stalls the shared splitter and starves the scarce one). So we always CLEAR the item off this node:
--   1. DELIVER to an active order's destination (most-behind first) if a hop accepts it — the ideal;
--   2. else REROUTE to a buffer for the item that has room (preserve it in storage, off the belt);
--   3. else SINK it (over-supply / no room anywhere) — clears the belt so others pass;
--   4. only if there is NO sink at all do we HOLD (can't drop it into nowhere) or panic (unknown item).
-- Each step tries a DIFFERENT output leg, so a full destination leg is bypassed via the buffer/sink
-- leg instead of stalling. `fromOutput` is the transferItem arg for the hop out of this node.
function Router:_overflow(sender, id, item)
  local active = {}
  for _, o in ipairs(self.ordersForItem[item] or {}) do
    if o.delivered < o.count then active[#active + 1] = o end
  end
  -- 1. DELIVER to an active destination (re-pathfind from HERE, most-behind first). If the hop is
  -- full/unreachable, DON'T hold — fall through to the buffer/sink so the belt keeps moving.
  table.sort(active, function(a, b) return (a.count - a.delivered) > (b.count - b.delivered) end)
  for _, o in ipairs(active) do
    local terminal = not self.bufferItem[o.dst]
    if terminal or self:hasRoom(o.dst, item) then
      local belt = self:firstHopTo(id, o.dst)
      -- _beltAccepts: the recovery hop must honor PORT PINS — re-pathfinding "any way to the
      -- machine" used to land iron plate on the SCREWS port's belt, where the machine (plate slot
      -- full) never pulls it and the port is dead forever. A dedicated port takes its item ONLY.
      if belt and self:_beltAccepts(belt, item) and sender:transferItem(belt.fromOutput or 0) then
        -- credit delivery + (on the DIRECT hop into a buffer dst) the room cache, so a chain of recovery
        -- deliveries to the same buffer caps at capacity instead of flooding past the stale cached count.
        if belt.to == o.dst then
          self:_credit(belt, item)
          if self.bufferItem[o.dst] then self:_creditRoom(o.dst, item) end
        end
        Router._dlog(("RECOVER %s '%s' >out[%d] %s ->%s"):format(tostring(id):sub(1,6), item, belt.fromOutput or 0, tostring(belt.to):sub(1,6), tostring(o.dst):sub(1,6)))
        return true
      end
    end
  end
  -- 2. REROUTE to a buffer for the item that has room — preserves it (it waits in storage, available
  -- when demand returns) instead of holding on the belt and blocking everything behind it.
  for _, D in ipairs(self.buffersForItem[item] or {}) do
    if self:hasRoom(D, item) then
      local belt = self:firstHopTo(id, D)
      if belt and sender:transferItem(belt.fromOutput or 0) then
        -- Credit room ONLY on the DIRECT hop into D (same gate as _credit). An intermediate hop must
        -- NOT credit — the item continues and is credited at the final splitter before D (best.to == D),
        -- so crediting here too would double-count and falsely fill the cache (the reroute under-fill bug).
        if belt.to == D then self:_credit(belt, item); self:_creditRoom(D, item) end
        Router._dlog(("REROUTE %s '%s' >out[%d] %s"):format(tostring(id):sub(1,6), item, belt.fromOutput or 0, tostring(D):sub(1,6)))
        return true
      end
    end
  end
  -- 3. SINK: buffers full / no buffer — clear the belt rather than HOLD (head-of-line). Try EVERY
  -- DEFAULT_OUT (a factory can have several): the first sink may be unreachable from this node while
  -- another is reachable, especially on a looped manifold — so iterate, don't give up after defaults[1].
  for _, sink in ipairs(self.defaults or {}) do
    local belt = self:firstHopTo(id, sink)
    if belt and sender:transferItem(belt.fromOutput or 0) then
      Router._nSunk = (Router._nSunk or 0) + 1            -- always-counted; the perf line reports the rate
      if Router.DEBUG and #active > 0 and computer and computer.log then
        Router._sinkLog = (Router._sinkLog or 0)
        if Router._sinkLog < 16 then
          Router._sinkLog = Router._sinkLog + 1
          computer.log(2, ("[Foreman] SINK: '%s' overflow at %s — no room at its destination/buffer")
            :format(item, tostring(id)))
        end
      end
      Router._dlog(("SINK %s '%s' (overflow, no room)"):format(tostring(id):sub(1,6), item))
      return true
    end
  end
  -- 4. LAST RESORT — nowhere reachable from here (no destination, no buffer with room, no sink path).
  -- HOLD the item and warn (capped). NEVER panic: crashing computer.panic kills the WHOLE controller
  -- over a single stray item — far worse than one item waiting on a belt. The held item resumes the
  -- instant a path opens (a buffer drains, a sink is wired, a belt is repaired) with no restart.
  Router._nStuck = (Router._nStuck or 0) + 1             -- always-counted; the perf line reports the rate
  if Router.DEBUG and computer and computer.log then
    Router._holdLog = Router._holdLog or 0
    if Router._holdLog < 8 then
      Router._holdLog = Router._holdLog + 1
      computer.log(2, ("[Foreman] STUCK: '%s' at %s — no destination, buffer, or sink reachable from here; holding. Wire a DEFAULT_OUT_%d near this node, or a buffer for '%s'.")
        :format(tostring(item), tostring(id), #self.defaults + 1, tostring(item)))
    end
  end
  return false
end

-- Route the item at a SPLITTER input: send it out the highest-remaining-quota output leg
-- (balanced), decrement that leg, credit if it reaches a destination; else fall back.
function Router:_routeAtSplitter(sender, id, item)
  -- Authoritative: route the item ACTUALLY at the input now. ItemRequest is edge-triggered
  -- and can arrive stale (pump() may have already moved it) — trusting the signal's item
  -- would route a phantom.
  if sender.getInput then
    local cur = itemName(sender:getInput())
    if not cur then return false end                 -- input empty: stale signal, no-op
    item = cur
  end
  -- candidate legs carrying quota for `item`, sorted by remaining quota (desc). Divert-on-full:
  -- try each in turn; the first that physically accepts wins, so a full leg never stalls the belt.
  local legs = {}
  for _, b in ipairs(self.adj[id] or {}) do
    local q = (b._q and b._q[item]) or 0
    if q > 0 then legs[#legs + 1] = b end
  end
  table.sort(legs, function(a, b)
    local qa, qb = (a._q and a._q[item]) or 0, (b._q and b._q[item]) or 0
    if qa ~= qb then return qa > qb end
    return (a.fromOutput or 0) < (b.fromOutput or 0)  -- tiebreak: equal-quota legs alternate deterministically
  end)
  for _, best in ipairs(legs) do
    local terminal = not self.bufferItem[best.to]
    if not self:_beltAccepts(best, item) then
      Router._dlog(("MISROUTE %s '%s' >out[%d] %s — machine/port doesn't take it; skipping leg")
        :format(tostring(id):sub(1, 6), item, best.fromOutput or 0, tostring(best.to):sub(1, 6)))
    elseif terminal or self:hasRoom(best.to, item) then
      if sender:transferItem(best.fromOutput or 0) then
        best._q[item] = (best._q[item] or 1) - 1
        self:_credit(best, item)
        if not terminal then self:_creditRoom(best.to, item) end   -- routed toward a buffer: bump its cached room
        if self.isMachine[best.to] and Router._legFullMach then Router._legFullMach[best.to] = nil end   -- entrance accepted: jam (if any) cleared
        Router._dlog(("SPL %s '%s' >out[%d] %s"):format(tostring(id):sub(1,6), item, best.fromOutput or 0, tostring(best.to):sub(1,6)))
        return true
      end
      -- chosen leg physically full right now: log it (a starved consumer whose leg never accepts =
      -- its input belt is backed up = its OUTPUT is blocked or a FOREIGN item the machine won't pull
      -- is stranded at its entrance) and fall through to the next-best leg. Mark machine entrances
      -- (module-durable: the planner's feed-drain reads it next epoch; cleared on a successful push).
      if self.isMachine[best.to] then Router._legFullMach = Router._legFullMach or {}; Router._legFullMach[best.to] = true end
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
    if out and self.isMachine[out.to] then Router._legFullMach = Router._legFullMach or {}; Router._legFullMach[out.to] = true end
    return false
  end
  if out then
    if out._q and (out._q[nm] or 0) > 0 then out._q[nm] = out._q[nm] - 1 end
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

-- Gate every source container at its OWN output connector: block it, and authorize only the
-- items it still needs to release, against a LIFETIME cap so a rebuild never re-releases
-- stock it already released. The naive "top the connector budget up to demand each rebuild"
-- OVER-RELEASES without bound: App.run rebuilds every ~2s with a fresh Router (delivered=0)
-- while items already released sit in transit — topping back up re-authorizes them every
-- rebuild, dripping surplus to the sink forever.
--
-- Fix: each order is gated against the all-time demand of its TERMINAL buffer (the order
-- that actually delivers into a storage container), scaled by the recipe ratio. For an
-- order o with terminal t:
--   terminalAllTime = Router._deliv[t.src|t.item] (cumulative delivered into the buffer,
--                     durable across rebuilds) + (t.count - t.delivered) (still needed)
--   contribution    = o.count * terminalAllTime / t.count   (= ratio × terminal all-time)
-- A direct order is its own terminal, so contribution = delivered + need = the buffer target.
-- This keeps the source's cap pinned to the BUFFER's progress, not to how fast an ingredient
-- reaches a consuming machine — which is what made the constructor-fed path drip. We only ADD
-- the delta over what we have already authorized (Router._auth, durable); a drained buffer
-- grows terminalAllTime so refills still happen.
Router._auth = Router._auth or {}     -- "item:<item>" -> cumulative units authorized this session
-- SLIDING-WINDOW FLOW CONTROL: an INGREDIENT feeding a constructor is released only up to
-- "already consumed + flowWindow", not the whole terminal demand at once. Without it, a big
-- buffer (12000 wire) authorizes 12000 copper up front; the constructor crafts slowly, so the
-- copper floods the (shared) belt and saturates the input — and if the machine is then
-- reassigned, that in-flight feedstock is stranded/dumped. With it, in-flight (belt + input)
-- stays ≈ flowWindow; as the constructor crafts (terminal product delivered -> _deliv), the
-- window slides forward, so total release still converges to the full demand. Only INGREDIENT
-- orders are windowed (a DIRECT buffer fill is absorbed by its destination buffer's capacity,
-- so it doesn't flood). The terminal demand remains the hard upper bound (no over-release).
Router.flowWindow = Router.flowWindow or 50   -- max in-flight ingredient units per order (tunable)
-- STALL BACK-PRESSURE (gateSources): when an item is released but its consumer is blocked (output
-- jammed), the surplus floods the manifold. Claw a stalled item's in-flight back toward inflightFloor;
-- a consumer that delivers >= progressFloor units per gate is healthy and never throttled. Tunable.
Router.inflightFloor = Router.inflightFloor or 32
Router.progressFloor = Router.progressFloor or 8
-- machine entrances whose feed leg is physically FULL (transferItem failed): set by _routeAtSplitter /
-- _mergerPush, cleared when a push succeeds. Module-durable (router instances are rebuilt per epoch);
-- the planner's FEED-DRAIN reads it to detect a foreign item stranded at a starved machine's entrance.
Router._legFullMach = Router._legFullMach or {}
Router.stuckEpochs = Router.stuckEpochs or 3   -- empty-input epochs before temp-consumer-drain may fire
function Router:_contribution(o)
  local t = o.term or o
  local td = Router._deliv[tostring(t.src) .. "|" .. t.item] or 0
  local termAll = td + math.max(0, t.count - t.delivered)            -- terminal buffer all-time demand
  if t == o then return termAll end                                  -- direct / self-terminal: not windowed
  -- ingredient: scale the terminal demand by the STABLE recipe ratio (units of this raw item
  -- per unit of terminal product, set by the planner). Scaling by the shrinking per-epoch need
  -- (o.count/t.count) instead inflates as the buffer nears full, over-releasing out>1 recipes
  -- (e.g. 1 copper -> 2 wire) to the sink.
  local window = Router.flowWindow or 50
  local full, consumed
  if o.ratioDen and o.ratioDen > 0 then
    full     = math.ceil(termAll * o.ratioNum / o.ratioDen)          -- total ingredient for ALL product
    consumed = math.ceil(td * o.ratioNum / o.ratioDen)               -- ingredient already turned into product
  elseif (t.count or 0) > 0 then
    full     = math.ceil(o.count * termAll / t.count)                -- fallback (unstamped ratio)
    consumed = math.ceil(o.count * td / t.count)
  else
    return o.count
  end
  return math.min(full, consumed + window)   -- release only consumed + a window's worth of lookahead
end
function Router:gateSources()
  -- STALL BACK-PRESSURE state: per-item cumulative delivered as of the previous gate, used below to
  -- detect an item that is being RELEASED but not CONSUMED (its consumer's output is jammed).
  Router._delivPrev = Router._delivPrev or {}
  -- Group source containers by the item they provide and gate PER ITEM, not per container.
  -- The cap (sum of terminal-scaled contributions) and the authorized total are aggregated
  -- across all of an item's sources, so the planner re-splitting demand across containers
  -- between rebuilds (as on-hand shifts) can never re-authorize in-flight stock on a fresh
  -- source. New budget is distributed to the sources weighted by this epoch's order demand.
  local byItem = {}
  for _, c in ipairs(self.topo.containers or {}) do
    local it = self.sourceItem[c.id]
    if it then byItem[it] = byItem[it] or {}; table.insert(byItem[it], c.id) end
  end
  for item, cids in pairs(byItem) do
    local isSrc = {}; for _, id in ipairs(cids) do isSrc[id] = true end
    -- aggregate cap + per-source order weights for this item
    local cap, weight, wtotal, nOrders = 0, {}, 0, 0
    for _, o in ipairs(self.orders) do
      if isSrc[o.src] then
        cap = cap + self:_contribution(o)
        local w = math.max(0, o.count - o.delivered)
        weight[o.src] = (weight[o.src] or 0) + w; wtotal = wtotal + w; nOrders = nOrders + 1
      end
    end
    -- BLOCK every output connector of every source. Fund the metered release ONLY on the
    -- connectors that are actually belted (isConnected) — split evenly across them, so a source
    -- wired out two ports still releases its full share (and no faster), while bare ports stay
    -- blocked at zero. Funding a single guessed port can strand the whole budget on a dead port
    -- (permanent under-fill); funding every port including bare ones wastes budget. Connected-only
    -- is the safe middle. conns[cid] = all outputs (for the claw-back/seed scans); fundOuts[cid] =
    -- the belted subset that receives addUnblockedTransfers (fallback: all, if none report connected).
    local conns, fundOuts = {}, {}
    for _, cid in ipairs(cids) do
      local e = self:_connFor(cid)                  -- cached: connector list + belted (isConnected) subset
      conns[cid] = e.conns
      for _, conn in ipairs(e.conns) do self:_setBlocked(conn, true) end   -- shadowed: skips redundant write
      fundOuts[cid] = e.fund
    end
    -- grant `n` release units to a source, split evenly across its belted outputs; returns the
    -- amount ACTUALLY granted (0 if the source has no fundable connector).
    local function fund(cid, n)
      local outs = fundOuts[cid]
      if not outs or #outs == 0 or n <= 0 then return 0 end
      local base, extra, g = math.floor(n / #outs), n % #outs, 0
      for i, conn in ipairs(outs) do
        local s = base + (i <= extra and 1 or 0)
        if s > 0 then pcall(function() conn:addUnblockedTransfers(s) end); g = g + s end
      end
      return g
    end
    local k = "item:" .. item
    if nOrders == 0 then
      -- NO CONSUMER for this item this epoch. Force every source output's leftover budget to
      -- ZERO (addUnblockedTransfers clamps but accepts negatives) so the source stops dead and
      -- the item stays IN ITS CONTAINER rather than dribbling onto the belt and into the sink.
      -- This is the copper-with-no-wire case — the analog of a product simply waiting in its
      -- buffer. Decrement the lifetime ledger by exactly what we claw back (the granted-but-
      -- unreleased units) so _auth keeps tracking units ACTUALLY released: demand returning
      -- then re-authorizes the right delta, no double-grant, no overshoot.
      local clawed = 0
      for _, outs in pairs(conns) do
        for _, conn in ipairs(outs) do
          local cur = 0; pcall(function() cur = conn.unblockedTransfers or 0 end)
          if cur > 0 then pcall(function() conn:addUnblockedTransfers(-cur) end); clawed = clawed + cur end
        end
      end
      Router._auth[k] = math.max(0, (Router._auth[k] or 0) - clawed)
    else
      local justSeeded = (Router._auth[k] == nil)
      if Router._auth[k] == nil then
        -- first gate of the session: seed from the connectors' LEFTOVER budget so a program
        -- restart (ledgers cleared, but the live connectors keep their unblockedTransfers)
        -- doesn't re-grant what is already authorized in-game.
        local seed = 0
        for _, outs in pairs(conns) do
          for _, conn in ipairs(outs) do local cur = 0; pcall(function() cur = conn.unblockedTransfers or 0 end); seed = seed + cur end
        end
        Router._auth[k] = seed
      end
      local add = cap - Router._auth[k]
      -- STALL BACK-PRESSURE: in-flight = released - delivered. If a lot of this item is in flight but
      -- almost nothing reached a consumer this window, the consumer is blocked (its OUTPUT is jammed)
      -- and the surplus is flooding the shared manifold — the overflow then reroutes it through other
      -- items' belts, including machine-OUTPUT belts, clogging the very outputs whose jam started it.
      -- Claw the stalled surplus back to ~inflightFloor so it stays in the source container; release
      -- self-restores the instant delivery resumes (progress >= progressFloor). A HEALTHY high-throughput
      -- item keeps delivering, so it is never throttled regardless of how much it has in flight.
      local delivered = 0
      for _, cid in ipairs(cids) do delivered = delivered + (Router._deliv[tostring(cid) .. "|" .. item] or 0) end
      local prev = Router._delivPrev[item]
      Router._delivPrev[item] = delivered
      local inflight = Router._auth[k] - delivered
      -- throttle ONLY with a valid prior baseline: prev exists AND didn't decrease (a decrease means
      -- the _deliv ledger was reset by a session restart, so this epoch's progress is unmeasurable — a
      -- fresh session must release its seeded budget, not get clawed on a phantom stall).
      -- `>=` (not `>`): at exactly the floor the clamp yields add<=0, HOLDING release while still
      -- stalled. With `>` the floor itself escapes the clamp and the gate re-grants the full cap,
      -- oscillating claw->flood->claw every other epoch (seen live: ingot auth 32 -> 100 -> 32).
      if not justSeeded and prev and delivered >= prev and inflight >= Router.inflightFloor and (delivered - prev) < Router.progressFloor then
        add = math.min(add, Router.inflightFloor - inflight)   -- <=0 while stalled: claw down to / hold at the floor
      end
      if add > 0 then
        -- distribute `add` across the sources weighted by their ordered demand, so budget lands
        -- where the stock/orders are. Only sources with a fundable (belted) connector take part —
        -- an order-less or unwired source would have no quota leg and would leak straight to the
        -- sink. Credit the ledger by what is ACTUALLY granted (a dropped share must not inflate
        -- _auth, or the next epoch under-releases).
        local list = {}
        for cid in pairs(conns) do if (weight[cid] or 0) > 0 and #(fundOuts[cid] or {}) > 0 then list[#list + 1] = cid end end
        if #list == 0 then for cid in pairs(conns) do if #(fundOuts[cid] or {}) > 0 then list[#list + 1] = cid end end end
        local intended, given = 0, 0
        for i, cid in ipairs(list) do
          local share
          if wtotal > 0 then share = math.floor(add * (weight[cid] or 0) / wtotal)
          else share = math.floor(add / #list) end
          if i == #list then share = add - intended end        -- last source mops up rounding remainder
          intended = intended + share
          given = given + fund(cid, share)
        end
        Router._auth[k] = Router._auth[k] + given
      elseif add < 0 then
        -- demand DROPPED below what we have authorized: a consumer left or a machine changed recipe,
        -- so this item is over-released. DEDUCT the excess (-add) from the sources' LEFTOVER budget —
        -- NOT zero: cap still includes every REMAINING consumer's share, so the others keep getting
        -- their items; we only remove the surplus that the departed consumer no longer needs. Only
        -- ungranted-but-unreleased units can be reclaimed (already-released stock is in transit); we
        -- reduce _auth by exactly what we reclaim so the ledger keeps tracking released units.
        local want, removed = -add, 0
        for _, outs in pairs(conns) do
          for _, conn in ipairs(outs) do
            if removed < want then
              local cur = 0; pcall(function() cur = conn.unblockedTransfers or 0 end)
              local take = math.min(cur, want - removed)
              if take > 0 then pcall(function() conn:addUnblockedTransfers(-take) end); removed = removed + take end
            end
          end
        end
        Router._auth[k] = math.max(0, (Router._auth[k] or 0) - removed)
      end
    end
  end
  -- DEFAULT-DENY every non-source container, then OPEN only the pass-throughs. The controller is
  -- the complete authority over each container's output every rebuild: closed unless flow is
  -- actually needed there. A PASS-THROUGH — one that some order's path legitimately routes OUT of
  -- (a wire buffer wired into the cable constructor that draws from it) — is set OPEN so flow
  -- continues; everything else is a DEAD-END store (a terminal buffer like concrete, or the sink)
  -- and is BLOCKED so it can't re-emit its contents back into the belt loop ("fills the buffer but
  -- also takes from it" re-circulation; a buffer with two output ports leaking out the un-routed
  -- one). A container is pass-through iff it appears as `belt.from` on some order's path. Sources
  -- are gated above (blocked + metered budget) and are skipped here. Setting blocked explicitly in
  -- BOTH directions — not just blocking dead-ends — means a relay that was momentarily blocked (or
  -- a future start-of-session block-all) is reliably re-opened, and nothing emits by default.
  -- A non-source container's output opens only if some order legitimately routes OUT of it. flowsOut
  -- records every container an order's path leaves (belt.from). With findPath no longer traversing a
  -- DECLARED BUFFER, an unrelated item can never transit a buffer, so an idle pure-destination buffer
  -- never appears in flowsOut and stays blocked (kills the self-loop). For a DECLARED BUFFER we add a
  -- defence-in-depth item-match: its output opens only when its OWN buffered item flows out of it
  -- (a genuine relay/hub re-emitting what it stores), never because a foreign item merely transits.
  -- A plain conduit container (no buffered item) opens whenever it is on a path (legit pass-through).
  local flowsOut, flowsOutItem = {}, {}
  for _, o in ipairs(self.orders) do
    for _, b in ipairs(o.path or {}) do
      flowsOut[b.from] = true
      flowsOutItem[b.from] = flowsOutItem[b.from] or {}
      flowsOutItem[b.from][o.item] = true
    end
  end
  for _, c in ipairs(self.topo.containers or {}) do
    if not self.sourceItem[c.id] then
      local item = self.bufferItem[c.id]
      local opens
      if item then
        opens = flowsOutItem[c.id] and flowsOutItem[c.id][item] or false
      else
        opens = flowsOut[c.id] or false
      end
      local blockIt = not opens
      for _, conn in ipairs(self:_connFor(c.id).conns) do
        self:_setBlocked(conn, blockIt)             -- shadowed: skips the write when the verdict is unchanged
        -- A blocked pure-destination must release NOTHING: claw any LEFTOVER unblockedTransfers to
        -- zero. A buffer that was a funded hub-source in an earlier epoch (e.g. wire drawn for a cable
        -- machine that is now gone) keeps its granted budget; once it stops being a source it lands
        -- here, and without this it would keep emitting that budget — the item loops the manifold and
        -- re-enters the same buffer (the wire round-trip). blocked=true alone does NOT stop a connector
        -- that still has unblockedTransfers > 0. (unblockedTransfers stays a LIVE read — only the static
        -- connector list + isConnected + the blocked write are cached.)
        if blockIt then
          local cur = 0; pcall(function() cur = conn.unblockedTransfers or 0 end)
          if cur > 0 then pcall(function() conn:addUnblockedTransfers(-cur) end) end
        end
      end
    end
  end
end

--- LEVEL-TRIGGERED routing sweep. ItemRequest is edge-triggered (fires once on arrival)
--- and an item that arrives unseen never re-fires — so a purely event-driven router
--- leaves items stuck in splitter/merger inputs forever (the in-game symptom). pump()
--- actively polls every codeable input each call and drains whatever is held, looping
--- until no further progress. This is the real driver; the ItemRequest listener just
--- makes it react faster. Returns the number of items moved.
-- Returns: moved (items routed this call), present (codeables STILL holding an item on the final pass
-- = items stuck/jammed right now). The loop uses `present` to decide whether to keep pumping (work to
-- do) or block for the next signal (truly clear) — so it NEVER sleeps on a jam.
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
      computer.log(1, ("[Foreman] dbg src %s '%s' auth=%d ub=%d"):format(s6(c.id), item,
        (Router._auth and (Router._auth["item:" .. item] or 0)) or 0, ub))
    end
  end
  for _, cid in ipairs(self.topo.constructors or {}) do
    local p = self.getProxy(cid)
    local rec = "?"; if p then pcall(function() local r = p:getRecipe(); rec = (r and r.name) or "none" end) end
    local wants = {}; for it in pairs(self.consumes[cid] or {}) do wants[#wants + 1] = it end
    computer.log(1, ("[Foreman] dbg mac %s recipe=%s in=%d [%s] wants[%s] fed[%s]")
      :format(s6(cid), rec, self:_inputTotal(cid), self:_inputItems(cid), table.concat(wants, ","), self:_feedDump(cid)))
  end
end

--- Are all placed orders fulfilled (delivered to their primary dst)?
function Router:allDone()
  for _, o in ipairs(self.orders) do
    if o.delivered < o.count then return false end
  end
  return true
end

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
