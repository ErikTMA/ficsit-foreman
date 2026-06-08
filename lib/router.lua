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
function Router._dlog(msg)
  if Router._dn < 60 and computer and computer.log then
    Router._dn = Router._dn + 1
    computer.log(1, "[Foreman] " .. msg)
  end
end

-- Case-insensitive item names: FIN reflection returns canonical (Title) case
-- ("Iron Plate"), nicks give lowercase. Normalize everything to lowercase so keys
-- and comparisons match regardless of source.
local function lc(s) return s and tostring(s):lower() or nil end
-- name of an item from a FIN signal payload (FInventoryItem: .type is an ItemType
-- OBJECT with .name) — tolerant of the emulator/legacy {type=string} shape too.
local function itemName(it)
  if type(it) ~= "table" then return lc(it) end
  local t = it.type
  if type(t) == "table" then return lc(t.name) end
  return lc(t)
end

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
  self.isSplitter, self.isMerger = {}, {}
  for _, id in ipairs(topology.splitters or {}) do self.isSplitter[id] = true end
  for _, id in ipairs(topology.mergers or {}) do self.isMerger[id] = true end
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
  local prev, seen, queue, head = {}, { [src] = true }, { src }, 1
  while head <= #queue do
    local node = queue[head]; head = head + 1
    if node == dst then break end
    for _, b in ipairs(self.adj[node] or {}) do
      if not seen[b.to] then
        seen[b.to] = true
        prev[b.to] = b
        queue[#queue + 1] = b.to
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

--- Route `count` of `item` to `dst`. Discovers the path and programs every
--- splitter on it. `src` is optional — if omitted, the container declared to
--- `provide` the item is used (the double-pass production case passes the
--- constructor as the explicit src for the crafted product). Returns true, or
--- false + reason if no path/source.
function Router:order(item, count, dst, src)
  item = lc(item)
  src = src or self:sourceOf(item)
  if not src then return false, "no source provides " .. item end
  local path = self:findPath(src, dst)
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
  return true
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
function Router:_count(dst, item)
  local p = self.getProxy(dst)
  if not p or not p.getInventories then return 0 end
  local total = 0
  item = lc(item)
  for _, inv in ipairs(p:getInventories()) do
    for i = 0, (inv.size or 0) - 1 do
      local s = inv:getStack(i)
      -- empty slots return a 0-count stack with a nil item.type in-game — guard it
      if s and (s.count or 0) > 0 and s.item and s.item.type and lc(s.item.type.name) == item then
        total = total + s.count
      end
    end
  end
  return total
end

-- Does a destination have room for one more of `item`? Non-buffer dests
-- (constructor, sink) always accept.
function Router:hasRoom(dst, item)
  local cap = self.capacity[dst]
  if not cap then return true end
  return self:_count(dst, item) < cap
end

--- Handle one ItemRequest. Separated from install() so a long-lived listener can
--- delegate to the CURRENT router after a live re-discovery (App swaps the router
--- instance without re-registering — avoids stacking duplicate listeners).
--- FIN signal payload is an FInventoryItem; the item name is item.type.name
--- (item.type is the ItemType OBJECT, not a string). itemName() normalizes to
--- lowercase so matching is case-insensitive vs reflection's canonical (Title) case.
function Router:_dispatch(sender, a, b)
  local id = sender.id
  if self.isSplitter[id] then
    local nm = itemName(a)                             -- splitter sig: (item)
    if nm then self:_routeAtSplitter(sender, id, nm) end
  elseif self.isMerger[id] then
    local nm = itemName(b)                             -- merger sig: (input, item)
    if nm then self:_mergerPush(sender, id, a, nm) end
  end
end

--- Start listening to every splitter/merger so their ItemRequest signals actually
--- reach this computer. CRITICAL: in FIN, event.registerListener only sets a callback
--- filter — you must ALSO event.listen(component) for each signal source, or NOTHING
--- arrives (the "items stuck at the first merger" symptom).
--- Listen each component at most ONCE per session: in-game event.listen(component) calls
--- HookSubsystem::AttachHooks which does ClearHooks + NewObject<UFIRHook> EVERY call, so
--- re-listening all components on every ~2s rebuild churns hook UObjects and piles up GC
--- pressure (the "lags more and more the longer it runs" symptom). The set is reset per
--- App.run session; the FIN side de-dupes the listener itself (AddUnique).
Router._listened = Router._listened or {}
function Router:listenAll()
  if not (event and event.listen) then return end
  local function listen(id)
    if Router._listened[id] then return end
    local p = self.getProxy(id)
    if p then pcall(function() event.listen(p) end); Router._listened[id] = true end
  end
  for _, id in ipairs(self.topo.splitters or {}) do listen(id) end
  for _, id in ipairs(self.topo.mergers or {}) do listen(id) end
end

--- Register the signal handler that executes routing AND listen to all codeable nodes.
--- Call once, then pump the event loop (e.g. Router:run() or your own event.pull loop).
function Router:install()
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
function Router:buildQuota()
  for _, belts in pairs(self.adj) do for _, b in ipairs(belts) do b._q = {} end end
  for _, o in ipairs(self.orders) do
    local remaining = o.count - o.delivered
    if remaining > 0 and o.path then
      for _, b in ipairs(o.path) do
        b._q[o.item] = (b._q[o.item] or 0) + remaining
      end
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
    if q > bestq then
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

-- Fallback for an item with NO remaining quota leg at this node (its quota is spent, or
-- it is overflow/unmanaged). In order: reroute to any reachable buffer for the item that
-- has room; else the catch-all sink; else HOLD (managed item waits for path repair); else
-- jam + panic (a destination-less unknown item with no sink). `fromOutput` is the
-- transferItem arg used for sink/reroute hops out of this node.
function Router:_overflow(sender, id, item)
  local active = {}
  for _, o in ipairs(self.ordersForItem[item] or {}) do
    if o.delivered < o.count then active[#active + 1] = o end
  end
  -- RECOVER an item that fell off its pre-built quota path. In a dense shared manifold an
  -- item routed greedily (or merged onto a belt that isn't on its BFS route) can reach a
  -- node carrying no quota for it; rather than dump it, RE-PATHFIND from HERE toward an
  -- active order's destination — most-behind first, so balance is preserved — whether that
  -- destination is a constructor or a buffer. This is the "recalculate a new way to the
  -- destination" path; only if NO order's dst is reachable do we fall through to the sink.
  table.sort(active, function(a, b) return (a.count - a.delivered) > (b.count - b.delivered) end)
  for _, o in ipairs(active) do
    local terminal = not self.bufferItem[o.dst]
    if terminal or self:hasRoom(o.dst, item) then
      local belt = self:firstHopTo(id, o.dst)
      if belt then
        if sender:transferItem(belt.fromOutput or 0) then
          if belt.to == o.dst then self:_credit(belt, item) end
          Router._dlog(("RECOVER %s '%s' >out[%d] %s ->%s"):format(tostring(id):sub(1,6), item, belt.fromOutput or 0, tostring(belt.to):sub(1,6), tostring(o.dst):sub(1,6)))
          return true
        end
        return false                                 -- chosen output full; retry later
      end
    end
  end
  -- reroute/overflow: an alternate buffer for the same item (e.g. primary full).
  for _, D in ipairs(self.buffersForItem[item] or {}) do
    if self:hasRoom(D, item) then
      local belt = self:firstHopTo(id, D)
      if belt then return sender:transferItem(belt.fromOutput or 0) and true or false end
    end
  end
  -- catch-all sink.
  local sink = self.defaults[1]
  if sink then
    local belt = self:firstHopTo(id, sink)
    if belt then
      if #active > 0 and computer and computer.log then
        Router._sinkLog = (Router._sinkLog or 0)
        if Router._sinkLog < 16 then
          Router._sinkLog = Router._sinkLog + 1
          -- recovery already tried to re-pathfind to every active dst, so reaching here means
          -- NO belt path exists from this node to the destination — the discovered graph is
          -- disconnected here (a mis-mapped port, a one-way snap, or a genuinely missing belt).
          computer.log(2, ("[Foreman] SINK: '%s' stuck at %s — NO belt path to %s (graph disconnected here)")
            :format(item, tostring(id), tostring(active[1].dst)))
        end
      end
      Router._dlog(("SINK %s '%s' (no path to any dst)"):format(tostring(id):sub(1,6), item))
      return sender:transferItem(belt.fromOutput or 0) and true or false
    end
  end
  -- No route and no sink. A MANAGED item (active order whose path was deleted, or a buffer
  -- merely full) HOLDS on the belt and waits for repair — rebuilding the missing node lets
  -- it flow again with no restart. Only a destination-less unknown item jams + asks for a sink.
  if #active > 0 or next(self.buffersForItem[item] or {}) then return false end
  computer.panic(("unroutable item '%s' at %s: add a container named DEFAULT_OUT_%d and wire it into the network")
    :format(tostring(item), id, #self.defaults + 1))
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
  local best = self:_bestEdge(id, item)
  if best then
    if sender:transferItem(best.fromOutput or 0) then
      best._q[item] = (best._q[item] or 1) - 1       -- reserve-on-dispatch: this leg got one
      self:_credit(best, item)
      Router._dlog(("SPL %s '%s' >out[%d] %s"):format(tostring(id):sub(1,6), item, best.fromOutput or 0, tostring(best.to):sub(1,6)))
      return true
    end
    return false                                     -- chosen output full; retry later
  end
  return self:_overflow(sender, id, item)
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
  if not sender:transferItem(input) then return false end
  local out = (self.adj[id] or {})[1]                -- merger's single output belt
  if out then
    if out._q and (out._q[nm] or 0) > 0 then out._q[nm] = out._q[nm] - 1 end
    self:_credit(out, nm)
  end
  return true
end

-- The OUTPUT FactoryConnection of a building (direction 1), or nil.
function Router:_outputConnector(p)
  if not (p and p.getFactoryConnectors) then return nil end
  local ok, conns = pcall(function() return p:getFactoryConnectors() end)
  if not ok then return nil end
  for _, conn in ipairs(conns or {}) do if conn.direction == 1 then return conn end end
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
function Router:_contribution(o)
  local t = o.term or o
  local td = Router._deliv[tostring(t.src) .. "|" .. t.item] or 0
  local termAll = td + math.max(0, t.count - t.delivered)            -- terminal buffer all-time demand
  if t == o then return termAll end                                  -- direct / self-terminal
  -- ingredient: scale the terminal demand by the STABLE recipe ratio (units of this raw item
  -- per unit of terminal product, set by the planner). Scaling by the shrinking per-epoch need
  -- (o.count/t.count) instead inflates as the buffer nears full, over-releasing out>1 recipes
  -- (e.g. 1 copper -> 2 wire) to the sink.
  if o.ratioDen and o.ratioDen > 0 then return math.ceil(termAll * o.ratioNum / o.ratioDen) end
  if (t.count or 0) > 0 then return math.ceil(o.count * termAll / t.count) end  -- fallback (unstamped)
  return o.count
end
function Router:gateSources()
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
    local cap, weight, wtotal = 0, {}, 0
    for _, o in ipairs(self.orders) do
      if isSrc[o.src] then
        cap = cap + self:_contribution(o)
        local w = math.max(0, o.count - o.delivered)
        weight[o.src] = (weight[o.src] or 0) + w; wtotal = wtotal + w
      end
    end
    -- block every source; collect their connectors
    local conns = {}
    for _, cid in ipairs(cids) do
      local conn = self:_outputConnector(self.getProxy(cid))
      if conn then pcall(function() conn.blocked = true end); conns[cid] = conn end
    end
    local k = "item:" .. item
    if Router._auth[k] == nil then
      -- first gate of the session: seed from the connectors' LEFTOVER budget so a program
      -- restart (ledgers cleared, but the live connectors keep their unblockedTransfers)
      -- doesn't re-grant what is already authorized in-game.
      local seed = 0
      for _, conn in pairs(conns) do local cur = 0; pcall(function() cur = conn.unblockedTransfers or 0 end); seed = seed + cur end
      Router._auth[k] = seed
    end
    local add = cap - Router._auth[k]
    if add > 0 then
      Router._auth[k] = Router._auth[k] + add
      -- distribute `add` across the sources weighted by their ordered demand, so budget lands
      -- where the stock/orders are — never on an order-less source (which would have no quota
      -- leg and leak straight to the sink).
      local list = {}
      for cid in pairs(conns) do if (weight[cid] or 0) > 0 then list[#list + 1] = cid end end
      if #list == 0 then for cid in pairs(conns) do list[#list + 1] = cid end end   -- safety fallback
      local given = 0
      for i, cid in ipairs(list) do
        local share
        if wtotal > 0 then share = math.floor(add * (weight[cid] or 0) / wtotal)
        else share = math.floor(add / #list) end
        if i == #list then share = add - given end          -- last source mops up rounding remainder
        if share > 0 then local s = share; pcall(function() conns[cid]:addUnblockedTransfers(s) end); given = given + share end
      end
    end
    -- NOTE: we deliberately do NOT claw budget back when add < 0. cap dips transiently below
    -- the authorized total as the dispatch-lag resolves (in-flight items landing), and clawing
    -- on that jitter strips legitimate budget mid-fill. A genuine demand drop (a buffer the
    -- player hand-fills or deletes) therefore leaves a small, bounded leftover budget that can
    -- leak to the sink — a rare manual-intervention edge, accepted over breaking normal fills.
  end
end

--- LEVEL-TRIGGERED routing sweep. ItemRequest is edge-triggered (fires once on arrival)
--- and an item that arrives unseen never re-fires — so a purely event-driven router
--- leaves items stuck in splitter/merger inputs forever (the in-game symptom). pump()
--- actively polls every codeable input each call and drains whatever is held, looping
--- until no further progress. This is the real driver; the ItemRequest listener just
--- makes it react faster. Returns the number of items moved.
function Router:pump()
  local total = 0
  local progressed, guard = true, 0
  while progressed and guard < 10000 do
    progressed = false; guard = guard + 1
    for _, id in ipairs(self.topo.splitters or {}) do
      local s = self.getProxy(id)
      if s and s.getInput then
        local ok, it = pcall(function() return s:getInput() end)
        local nm = ok and itemName(it)               -- nil for an empty input (FIN empty struct)
        if nm and self:_routeAtSplitter(s, id, nm) then total = total + 1; progressed = true end
      end
    end
    for _, id in ipairs(self.topo.mergers or {}) do
      local m = self.getProxy(id)
      if m and m.getInput then
        for i = 0, 2 do
          local ok, it = pcall(function() return m:getInput(i) end)
          local nm = ok and itemName(it)
          if nm and self:_mergerPush(m, id, i, nm) then total = total + 1; progressed = true end
        end
      end
    end
  end
  return total
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
