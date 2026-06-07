-- router.lua — topology-aware item routing framework for FicsIt-Networks.
--
-- This is PRODUCT code: it runs in-game on a Computer Case as well as under the
-- devbox emulator. It does NOT sense belt topology (FIN can't — a FactoryConnection
-- exposes no owner building), so you DECLARE the topology once as data; the router
-- then DISCOVERS routes through it with breadth-first search:
--
--     order("iron ingot", 100, "OUT_IRON")
--
-- finds the path from the container that provides the item to the target container
-- and programs every CodeableSplitter along the way to send that item type out the
-- correct port. CodeableMergers just pass through. Works for any declared topology.
--
-- Topology shape:
--   {
--     containers = { {id=, provides=?, items=?}, ... },   -- provides: item type this source emits
--     splitters  = { "S1", ... },                          -- CodeableSplitter ids/nicks
--     mergers    = { "M1", ... },                          -- CodeableMerger ids/nicks
--     belts      = { {from=, to=, fromOutput=?, toInput=?}, ... },  -- directed, port-aware
--   }
--
-- Resolution of an id to a live component proxy is pluggable (default component.proxy)
-- so the same code drives the emulator and a real network.

local Router = {}
Router.__index = Router

-- Resolve a container's destination item + ordinal, from an explicit
-- c.buffer / c.output item field (set by auto-assignment) or its name
-- <Item>_(Buffer|Output)_<n> (case-insensitive). Returns nil if not a destination.
function Router.destItem(c)
  if c.buffer then return tostring(c.buffer):lower(), c.n end
  if c.output then return tostring(c.output):lower(), c.n end
  local prefix, kw, n = tostring(c.id):match("^(.-)_(%a+)_(%d+)$")
  if prefix and (kw:lower() == "buffer" or kw:lower() == "output") then
    return prefix:gsub("_", " "):lower(), tonumber(n)
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
  -- gated source release: a networked source container feeding a merger input only
  -- releases items when an order calls for them. gated[mergerId][input] = item type.
  self.sourceItem = {}
  for _, c in ipairs(topology.containers or {}) do
    if c.provides then self.sourceItem[c.id] = c.provides end
  end
  self.gated = {}
  for _, b in ipairs(topology.belts or {}) do
    if self.sourceItem[b.from] and self.isMerger[b.to] then
      self.gated[b.to] = self.gated[b.to] or {}
      self.gated[b.to][b.toInput or 0] = self.sourceItem[b.from]
    end
  end
  -- containers named DEFAULT_OUT_<n> are the catch-all sinks for unroutable items.
  self.defaults = {}
  for _, c in ipairs(topology.containers or {}) do
    if tostring(c.id):match("^DEFAULT_OUT_%d+$") then table.insert(self.defaults, c.id) end
  end
  -- buffer/output destinations: an explicit c.buffer / c.output item (e.g. set by
  -- the namer's auto-assignment) OR a name <Item>_(Buffer|Output)_<n>. item +
  -- capacity, grouped per item, numerically ordered.
  self.bufferItem = {}            -- destId -> item
  self.capacity = {}              -- destId -> max units (defaults to its target)
  self.buffersForItem = {}        -- item -> { destId... } ordered by <n>
  local order_n = {}
  for _, c in ipairs(topology.containers or {}) do
    local item, n = Router.destItem(c)
    if item then
      self.bufferItem[c.id] = item
      self.capacity[c.id] = c.capacity or c.target
      self.buffersForItem[item] = self.buffersForItem[item] or {}
      table.insert(self.buffersForItem[item], c.id)
      order_n[c.id] = n or 1
    end
  end
  for _, list in pairs(self.buffersForItem) do
    table.sort(list, function(x, y) return order_n[x] < order_n[y] end)
  end
  self.ordersByItem = {}          -- item -> order (latest placed)
  self._fh = {}                   -- firstHop cache: [from][dst] = belt | false
  return self
end

-- Find the container that emits `item` (declared via `provides`).
function Router:sourceOf(item)
  for _, c in ipairs(self.topo.containers or {}) do
    if c.provides == item then return c.id end
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
  src = src or self:sourceOf(item)
  if not src then return false, "no source provides " .. item end
  if not self:findPath(src, dst) then return false, ("no path %s -> %s"):format(src, dst) end
  local order = { item = item, count = count, dst = dst, src = src, delivered = 0, rerouted = 0, released = 0 }
  table.insert(self.orders, order)
  self.ordersByItem[item] = order
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
  for _, inv in ipairs(p:getInventories()) do
    for i = 0, inv.size - 1 do
      local s = inv:getStack(i)
      if s and s.item.type.name == item then total = total + s.count end
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

--- Register the signal handler that executes routing. Call once, then pump the
--- event loop (e.g. Router:run() or your own event.pull loop).
function Router:install()
  event.registerListener(event.filter{ event = "ItemRequest" },
    function(_, sender, a, b)
      local id = sender.id
      if self.isSplitter[id] then
        self:_routeAtSplitter(sender, id, a.type)       -- splitter sig: (item)
      elseif self.isMerger[id] then
        local input, item = a, b                        -- merger sig: (input, item)
        if self.gated[id] and self.gated[id][input] ~= nil then
          -- Gated networked source: release ONLY what an order still wants, so the
          -- container outputs exactly what's ordered and otherwise stays stopped.
          local ord = self:_needRelease(item.type)
          -- count a release ONLY when the pull actually succeeds (transferItem can
          -- fail under back-pressure when the merger output is full) — else the
          -- counter over-reports and the source stops short.
          if ord and sender:transferItem(input) then
            ord.released = ord.released + 1
          end
          -- else: do not pull -> the container holds its items (stopped)
        else
          sender:transferItem(input)                    -- in-transit: always forward
        end
      end
    end)
end

-- An active order for this item type that still has items left to release.
function Router:_needRelease(itemType)
  for _, o in ipairs(self.orders) do
    if o.item == itemType and o.released < o.count then return o end
  end
end

-- Decide where an item at a splitter goes, checking destination ROOM and
-- rerouting on the loop when a buffer is full:
--   1. the item's primary buffer (the order's dst), then any OTHER buffer for the
--      same item, in number order — first one that is reachable and has room;
--   2. for a non-buffer target (constructor/sink) just route to it (always accepts);
--   3. last resort: the DEFAULT_OUT sink;
--   4. nothing reachable: jam + panic.
-- Because the belts form a loop, every buffer is reachable from every splitter, so
-- an item whose nearest buffer is full is forwarded on toward an alternate.
function Router:_routeAtSplitter(sender, id, item)
  local ord = self.ordersByItem[item]
  local targets, skipRoom = {}, false
  if ord and not self.bufferItem[ord.dst] then
    targets, skipRoom = { ord.dst }, true            -- non-buffer dst (constructor): always accepts
  else
    local prim = ord and ord.dst
    if prim and self.bufferItem[prim] then targets[#targets + 1] = prim end
    for _, b in ipairs(self.buffersForItem[item] or {}) do
      if b ~= prim then targets[#targets + 1] = b end
    end
  end

  for _, D in ipairs(targets) do
    local belt = self:firstHopTo(id, D)
    if belt and (skipRoom or self:hasRoom(D, item)) then
      -- only act/count when the transfer succeeds; if the chosen output is full
      -- (back-pressure) leave the item — the engine re-fires ItemRequest when the
      -- output drains, giving a retry.
      if sender:transferItem(belt.fromOutput or 0) then
        if belt.to == D and ord then                 -- delivered directly this hop
          if D == ord.dst then ord.delivered = ord.delivered + 1
          else ord.rerouted = ord.rerouted + 1 end
        end
      end
      return
    end
  end

  -- last resort: the catch-all sink
  local sink = self.defaults[1]
  if sink then
    local belt = self:firstHopTo(id, sink)
    if belt then sender:transferItem(belt.fromOutput or 0); return end
  end
  computer.panic(("unroutable item '%s' at splitter %s: add a container named DEFAULT_OUT_%d and wire it into the network")
    :format(tostring(item), id, #self.defaults + 1))
end

--- Are all placed orders fulfilled (delivered to their primary dst)?
function Router:allDone()
  for _, o in ipairs(self.orders) do
    if o.delivered < o.count then return false end
  end
  return true
end

--- Drive the event loop until the system is quiescent (every item settled into a
--- buffer or the sink, every gated source stopped). Returns true when quiescent.
function Router:run(maxLoops)
  for _ = 1, maxLoops or 5000000 do
    if event.pull(0) == nil then return true end   -- nil => queue empty and nothing left to flow
  end
  return false
end

return Router
