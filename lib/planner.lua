-- planner.lua — production planner for FicsIt-Networks (PRODUCT code, runs in-game).
--
-- Sits on top of router.lua. It:
--   * auto-detects constructors and reads their recipes via reflection
--     (getRecipes -> getIngredients/getProducts, with item names AND counts) — no
--     hardcoded recipe data.
--   * derives each buffer's wanted item from its label: <ITEM>_BUFFER_<n>
--     (IRON_PLATE_BUFFER_1 -> "iron plate", REANIMATED_SAM_BUFFER_1 -> "reanimated sam").
--   * keeps buffers topped up: for each buffer it computes need = target - current,
--     finds how to make the item, and places orders so it flows to the buffer.
--   * supports MULTIPLE recipes per item and picks intelligently:
--       - if a recipe can fully satisfy the need from available stock, pick the
--         most input-efficient one (max output / input).
--       - otherwise pick the one that yields the MOST from what's available.
--   * drives the double pass: order ingredients -> constructor, then the crafted
--     product (source = constructor) -> buffer.

local Planner = {}
Planner.__index = Planner

-- STAGING DEPTH for intermediate (crafted-and-consumed) hub buffers. Such a buffer is kept at ~this
-- many units, NOT filled to its capacity: filling an intermediate to capacity demands the whole
-- downstream chain's worth of feedstock up front (e.g. a 4800 plate buffer pulls 4800-worth of iron
-- ingot), which over-produces the intermediate, hoards it, and floods the shared manifold with the
-- raw it was made from. With staging, the producing machine only refills what the consumer drained,
-- so its throughput auto-matches real downstream draw (the continuous level-triggered model). MUST
-- exceed the bottleneck's peak per-epoch draw or the buffer empties mid-epoch and starves — tune via
-- the debug dump's per-buffer have/cap, don't guess. See _needingBuffers + the flow-throttle spec.
Planner.stageDepth = Planner.stageDepth or 100
-- rank multiplier for a fully-DRAINED intermediate buffer (assign): rank scales linearly with
-- emptiness from 1x stageDepth (full) to (1+rankBoost)x (empty). Tunable.
Planner.rankBoost = Planner.rankBoost or 3

local function ceil(a, b) return math.floor((a + b - 1) / b) end
-- Case-insensitive item names: reflection gives canonical (Title) case, nicks give
-- lowercase. Key/compare everything lowercase so they match. (See router.lua.)
local function lc(s) return s and tostring(s):lower() or nil end


function Planner.new(topology, router, getProxy, epochSeconds)
  local self = setmetatable({}, Planner)
  self.topo = topology
  self.router = router
  self.epochSeconds = epochSeconds   -- replan cadence; sizes _machineCap (was silently dropped -> 2s fallback always)
  self.getProxy = getProxy or function(id) return component.proxy(id) end
  self.recipesByProduct = {}     -- itemName -> list of recipe options
  self.busy = {}                 -- ctorId -> true once assigned this planning pass
  self.itemOfRecipe = {}         -- recipe display name -> product item (for stable reservation)
  self.reserved = {}             -- item -> ctorId already making it this session (anti recipe-churn)
  self.sources = {}              -- itemName -> { source container ids } (declared provides)
  for _, c in ipairs(topology.containers or {}) do
    if c.provides then
      local k = lc(c.provides)
      self.sources[k] = self.sources[k] or {}
      table.insert(self.sources[k], c.id)
    end
  end
  -- itemName -> a BUFFER container that stores it = that item's HUB. An ingredient with a
  -- hub is DRAWN from the hub (e.g. cable takes wire from the wire buffer) instead of
  -- crafting a second parallel stream; the hub is kept full by its own fill order.
  self.bufferOf = {}
  self.buffersOf = {}            -- itemName -> ALL of its buffer containers (ingredient draws span them)
  for _, c in ipairs(topology.containers or {}) do
    local di = Planner.destItem(c)
    if di and not self.bufferOf[di] then self.bufferOf[di] = c.id end
    if di then
      self.buffersOf[di] = self.buffersOf[di] or {}
      table.insert(self.buffersOf[di], c.id)
    end
  end
  return self
end

-- ---- reflection: discover constructors + recipes ---------------------------
-- PERF: getRecipes()/getIngredients()/getProducts() are game-thread syncs and a machine exposes ~30
-- recipes — re-reading them on every ~2s re-plan is hundreds of syncs that BLOCK routing. A machine's
-- recipe LIST never changes, so cache the scan module-side, keyed by the constructor set, and on reuse
-- only refresh the live ctor proxy (pure Lua). A full re-discover with a different machine set (or a
-- new session — App.run clears the cache) re-reads. itemOfRecipe/recipesByProduct are not mutated
-- after scan, so the cached tables are safely shared across the per-epoch Planner instances.
function Planner:scan()
  local ids = {}
  for _, cid in ipairs(self.topo.constructors or {}) do ids[#ids + 1] = tostring(cid) end
  table.sort(ids)
  local sig = table.concat(ids, ",")
  local cache = Planner._scanCache
  if cache and cache.sig == sig then
    self.recipesByProduct, self.itemOfRecipe = cache.recipesByProduct, cache.itemOfRecipe
    for _, list in pairs(self.recipesByProduct) do
      for _, opt in ipairs(list) do opt.ctor = self.getProxy(opt.ctorId) end   -- refresh the live proxy (no sync vs the game thread for cached recipe data)
    end
    return
  end
  for _, cid in ipairs(self.topo.constructors or {}) do
    local ctor = self.getProxy(cid)
    for _, recipe in ipairs(ctor:getRecipes()) do
      local ings = {}
      local totalIn = 0
      for _, ia in ipairs(recipe:getIngredients()) do
        ings[#ings + 1] = { name = lc(ia.type.name), amount = ia.amount }
        totalIn = totalIn + ia.amount
      end
      local duration = recipe.duration or 1
      for _, pa in ipairs(recipe:getProducts()) do
        local key = lc(pa.type.name)
        self.itemOfRecipe[tostring(recipe.name)] = key   -- live getRecipe().name -> what it makes
        local list = self.recipesByProduct[key] or {}
        list[#list + 1] = {
          recipe = recipe, ctorId = cid, ctor = ctor,
          out = pa.amount, ingredients = ings, totalIn = totalIn,
          duration = duration,
          throughput = pa.amount / duration,   -- output per minute decides when stock is plentiful
        }
        self.recipesByProduct[key] = list
      end
    end
  end
  Planner._scanCache = { sig = sig, recipesByProduct = self.recipesByProduct, itemOfRecipe = self.itemOfRecipe }
end

-- ---- inventory reads (FIN-faithful: getInventories -> getStack) -------------
-- PERF: every planner count_in reads a SINGLE-ITEM container (a source holds its provided item; a
-- buffer/hub holds its stored item — overflow only ever routes an item to its OWN buffer, so they
-- don't get mixed), so the inventory's itemCount IS the count of `item`. That's ONE property read per
-- inventory instead of a 24-48-slot getStack scan (each slot is a game-thread sync) — the dominant
-- cost of the ~2s re-plan on a big factory. (`item` is kept for the call signature / intent.)
local function count_in(proxy, item)
  local total = 0
  for _, inv in ipairs(proxy:getInventories()) do
    local n = 0; pcall(function() n = inv.itemCount or 0 end)
    total = total + n
  end
  return total
end

-- total available of an item across all declared source containers
function Planner:available(item)
  item = lc(item)
  local n = 0
  for _, c in ipairs(self.topo.containers or {}) do
    if lc(c.provides) == item then n = n + count_in(self.getProxy(c.id), item) end
  end
  return n
end

-- ---- producibility (recursive) ---------------------------------------------
-- Max units of `item` that can be made from raw SOURCES, crafting through as many
-- recipe stages as needed (copper -> wire -> cable). A direct source returns its
-- available stock; a craftable item returns the best a recipe can yield given its
-- ingredients' own producibility. Cycle/depth guarded. This is what lets the planner
-- treat an intermediate (wire) as "available" even though it's only in a buffer/recipe.
function Planner:producible(item, depth, seen)
  item = lc(item); depth = depth or 0; seen = seen or {}
  -- MEMOIZE per epoch. producible recurses through the craft DAG; with only a path-local `seen` set it
  -- re-descended every SHARED subtree once per path that reaches it (iron ingot sits under BOTH iron
  -- plate AND screws->iron rod), and it is called from _addNeed, chooseRecipe AND _hubViable — an
  -- EXPONENTIAL blowup, each node doing a count_in. That was the ~3.7s re-plan (the stutter). The value
  -- depends only on the current inventory, which is constant during one fillAll, so caching each item's
  -- result collapses it to linear. The cache is reset at the top of fillAll. The cycle (seen) early-out
  -- is NOT cached (its value is path-dependent).
  self._prodMemo = self._prodMemo or {}
  local memo = self._prodMemo[item]
  if memo ~= nil then return memo end
  if self.sources[item] then local v = self:available(item); self._prodMemo[item] = v; return v end
  -- an item already sitting in a HUB buffer is available up to its on-hand (e.g. mined/
  -- imported straight into the buffer, or wire whose only supply is the hub) — so a consumer
  -- isn't judged un-producible just because its feedstock lives in a buffer rather than raw.
  local hubStock = 0
  for _, h in ipairs((self.buffersOf and self.buffersOf[item]) or {}) do
    hubStock = hubStock + count_in(self.getProxy(h), item)   -- ALL hubs: stock in a sibling buffer is real supply
  end
  if depth > 8 or seen[item] then return hubStock end
  local cands = self.recipesByProduct[item]
  if not cands then self._prodMemo[item] = hubStock; return hubStock end
  seen[item] = true
  local best = hubStock
  for _, opt in ipairs(cands) do
    local crafts = math.huge
    for _, ing in ipairs(opt.ingredients) do
      crafts = math.min(crafts, math.floor(self:producible(ing.name, depth + 1, seen) / ing.amount))
    end
    if crafts ~= math.huge and crafts > 0 then best = math.max(best, crafts * opt.out) end
  end
  seen[item] = nil
  self._prodMemo[item] = best
  return best
end

-- ---- recipe selection ------------------------------------------------------
-- Returns { opt, crafts, produced } or nil if nothing can be made.
--   * if a recipe can fully satisfy the need, pick the highest THROUGHPUT (out/min).
--   * otherwise pick the one that yields the MOST from what's producible.
-- Ingredient availability is RECURSIVE (producible): an ingredient that is itself
-- craftable counts, enabling multi-stage chains. Busy constructors are skipped;
-- freeOnly=true never reuses one (each craft stage needs its own machine).
function Planner:chooseRecipe(item, need, depth, freeOnly)
  local cands = self.recipesByProduct[item]
  if not cands then return nil end
  depth = depth or 0
  local function evaluate(allowBusy)
    local full, scarce
    for _, opt in ipairs(cands) do
      if allowBusy or not self.busy[opt.ctorId] then
        local craftsPossible = math.huge
        for _, ing in ipairs(opt.ingredients) do
          craftsPossible = math.min(craftsPossible, math.floor(self:producible(ing.name, depth + 1) / ing.amount))
        end
        if craftsPossible > 0 then
          local producedPossible = craftsPossible * opt.out
          if producedPossible >= need then            -- plenty: maximise throughput
            if not full or opt.throughput > full.opt.throughput then
              full = { opt = opt, crafts = ceil(need, opt.out), produced = ceil(need, opt.out) * opt.out }
            end
          end
          if not scarce or producedPossible > scarce.produced then   -- scarce: maximise yield
            scarce = { opt = opt, crafts = craftsPossible, produced = producedPossible }
          end
        end
      end
    end
    return full or scarce
  end
  return evaluate(false) or (not freeOnly and evaluate(true)) or nil   -- prefer a free constructor
end

-- PROVIDERS of `item` this epoch: raw source containers + stocked sibling hubs (excluding ids in
-- `exclude`, e.g. the demanders themselves). Returns list of { id, stock } (stock = math.huge for
-- raw sources — the gate batches releases; physical stock bounds them anyway).
function Planner:_providersFor(item, exclude)
  item = lc(item)
  local out = {}
  for _, sid in ipairs(self.sources[item] or {}) do
    if not (exclude and exclude[sid]) then out[#out + 1] = { id = sid, stock = count_in(self.getProxy(sid), item) } end
  end
  for _, hid in ipairs(self.buffersOf[item] or {}) do
    if not (exclude and exclude[hid]) then
      local n = count_in(self.getProxy(hid), item)
      if n > 0 then out[#out + 1] = { id = hid, stock = n } end
    end
  end
  -- CONTENT-BASED relays: an UNCLASSIFIED container (no provides, no buffer name, not a sink)
  -- that physically holds the item is in-line storage on the route — it must release toward the
  -- demanders or everything that entered it is stranded (the wire-through-a-plain-box wiring).
  for _, c in ipairs(self.topo.containers or {}) do
    if not c.provides and not Planner.destItem(c) and not c.isDefault
       and not tostring(c.id):match("^DEFAULT_OUT_%%d+$")
       and not (exclude and exclude[c.id]) then
      local n = count_in(self.getProxy(c.id), item)
      if n > 0 then out[#out + 1] = { id = c.id, stock = n } end
    end
  end
  table.sort(out, function(x, y) if x.stock ~= y.stock then return x.stock > y.stock end return tostring(x.id) < tostring(y.id) end)
  return out
end

-- Assign each ingredient of a MULTI-INPUT machine to a DISTINCT input port (one item type per belt).
-- Returns ingredientName -> toInput (a partial map: only ingredients with a KNOWN source and a valid
-- port assignment; crafted ingredients and unmatched ones are omitted -> routed normally). Reachability
-- is the INTERSECTION over ALL of an ingredient's source containers (orderFrom splits across them, all
-- pinned to the same port), so a port is valid only if EVERY co-source can reach it. The assignment is a
-- maximum bipartite matching (Kuhn) so a full injective assignment is found whenever one exists.
function Planner:_assignPorts(cid, opt)
  local belts = self.router.inputBelts and self.router.inputBelts[cid]
  local ings = opt.ingredients or {}
  if not belts or #belts < 2 or #ings < 2 then return nil end
  local function sourcesOf(name)                      -- raw: all providers; hub: the buffer; crafted: none
    if self.sources[name] then return self.sources[name] end
    if self.bufferOf[name] then return { self.bufferOf[name] } end
    return nil
  end
  local feederOf, portList = {}, {}                   -- distinct ports (toInput) and each port's feeder node
  for _, e in ipairs(belts) do
    if feederOf[e.port] == nil then feederOf[e.port] = e.feeder; portList[#portList + 1] = e.port end
  end
  table.sort(portList)                                -- deterministic: matching is a pure fn of topology, not pairs() order
  if #portList < 2 then return nil end
  if #ings > #portList then
    pcall(function()
      computer.log(2, ("[Foreman] machine %s: %d ingredients but %d input belts — wire one belt per ingredient")
        :format(tostring(cid):sub(1, 6), #ings, #portList))
    end)
  end
  local reach = {}                                    -- reach[i][port] = ALL of ingredient i's sources reach it
  for i, ing in ipairs(ings) do
    reach[i] = {}; local srcs = sourcesOf(ing.name)
    for _, p in ipairs(portList) do
      local ok = srcs ~= nil and #srcs > 0
      if ok then
        for _, s in ipairs(srcs or {}) do
          if not (s == feederOf[p] or self.router:findPath(s, feederOf[p])) then ok = false; break end
        end
      end
      reach[i][p] = ok
    end
  end
  -- Kuhn maximum bipartite matching: ingredients (left) -> distinct ports (right).
  local matchPort = {}                                -- port -> ingredient index
  local function aug(i, seen)
    for _, p in ipairs(portList) do
      if reach[i][p] and not seen[p] then
        seen[p] = true
        if matchPort[p] == nil or aug(matchPort[p], seen) then matchPort[p] = i; return true end
      end
    end
    return false
  end
  for i = 1, #ings do aug(i, {}) end
  local assign = {}
  for p, i in pairs(matchPort) do assign[ings[i].name] = p end
  return assign
end

-- DEMAND the ingredients of recipe `opt` for machine `cid` (demand-pull: no orders — a per-
-- ingredient refill request sized by the machine's LIVE input level). Hysteresis band: request a
-- top-up to hiCrafts' worth once the level is below lowCrafts' worth (refills arrive in batches,
-- not a trickle). An ingredient with NO conceivable supply — no raw source, no stocked hub, no
-- assigned producer, and not deep-craftable on a free machine — fails the attempt (drives the
-- infeasibility yield exactly as the order rollback used to).
Planner.lowCrafts = Planner.lowCrafts or 2
Planner.hiCrafts  = Planner.hiCrafts or 6
function Planner:_demandIngredients(opt, cid, depth, maxCrafts, txn)
  local ports = self:_assignPorts(cid, opt)
  local have = self:_inputMap(cid)
  -- refill toward hiCrafts' worth, but never demand more feedstock than the REMAINING product
  -- job needs (a finite 8-wire fill must pull exactly 8 copper, not a full hi-water batch)
  local hiC = Planner.hiCrafts
  if maxCrafts and maxCrafts < hiC then hiC = maxCrafts end
  for _, ing in ipairs(opt.ingredients) do
    local lo, hi = math.min(Planner.lowCrafts, hiC) * ing.amount, hiC * ing.amount
    local h = have[ing.name] or 0
    if h < lo then
      -- supply check (mirrors the old viability rules): someone must be able to PROVIDE this
      -- AND physically REACH this machine (a source with no belt path is no supply — restoring
      -- a recipe toward it would churn setRecipe forever)
      local supplied = false
      for _, sid in ipairs(self.sources[ing.name] or {}) do
        if self.router:firstHopTo(sid, cid) then supplied = true; break end
      end
      if not supplied then
        for _, hid in ipairs(self.buffersOf[ing.name] or {}) do
          if count_in(self.getProxy(hid), ing.name) > 0 and self.router:firstHopTo(hid, cid) then supplied = true; break end
        end
      end
      if not supplied and self.served and self.served[ing.name] and #self.served[ing.name] > 0 then supplied = true end
      if not supplied then
        -- deep-craft chain (un-hubbed intermediate): claim a FREE machine to make it, recursively,
        -- sized to exactly what THIS machine will pull (no hi-water slack compounding per stage)
        supplied = self:produceInto(ing.name, (depth or 0) + 1, txn, hi - h, cid)
      end
      if not supplied then self._lastFailIng = ing.name; return false end
      if hi > h then
        table.insert(txn.staged, { item = ing.name, id = cid, n = hi - h, port = ports and ports[ing.name] })
      end
    end
  end
  return true
end

-- ATOMIC attempt wrapper: stage demand entries + sub-machine claims; COMMIT only when every
-- ingredient of the whole (possibly recursive) plan is suppliable — a partially-suppliable
-- recipe must demand NOTHING (the rollback rule: one available ingredient released for an
-- impossible craft just clogs the belts) and must release every machine the attempt claimed.
function Planner:_demandAtomic(opt, cid, maxCrafts)
  local txn = { staged = {}, claimed = {} }
  if not self:_demandIngredients(opt, cid, 0, maxCrafts, txn) then
    for _, c in ipairs(txn.claimed) do
      self.busy[c[1]] = nil
      if self._claimed then self._claimed[c[2]] = nil end
    end
    return false
  end
  for _, e in ipairs(txn.staged) do
    if e.setRecipe then
      pcall(function() e.setRecipe.ctor:setRecipe(e.setRecipe.recipe) end)
      Planner._tempRecipe[e.id] = nil
    else
      self:_addDemand(e.item, e.id, e.n, e.port, true)
    end
  end
  return true
end

-- Deep-craft (un-hubbed intermediate, e.g. deeptree's iron rod -> screw): claim a FREE machine,
-- set its recipe (only on change), and demand ITS ingredients recursively. Its output then flows
-- to the demander via the next-hop table like any other flow. Returns true if a producer exists.
function Planner:produceInto(item, depth, txn, needUnits, forCid)
  item = lc(item); depth = depth or 0
  if depth > 8 then return false end
  if self.sources[item] then
    -- raw: a source must also REACH the consumer to count as supply
    for _, sid in ipairs(self.sources[item]) do
      if not forCid or self.router:firstHopTo(sid, forCid) then return true end
    end
    return false
  end
  -- already producing it this epoch (assigned or claimed)?
  if self.served and self.served[item] and #self.served[item] > 0 then return true end
  if self._claimed and self._claimed[item] then return true end
  local pick = self:chooseRecipe(item, 1, depth, true)
  if not pick then return false end
  local cid = pick.opt.ctorId
  self.busy[cid] = true
  self._claimed = self._claimed or {}
  self._claimed[item] = cid
  table.insert(txn.claimed, { cid, item })
  -- defer the (expensive, input-ejecting) setRecipe until the whole plan COMMITS: stage it
  local okc, cur = pcall(function() return pick.opt.ctor:getRecipe() end)
  if (okc and cur and cur.name) ~= pick.opt.recipe.name then
    table.insert(txn.staged, { setRecipe = pick.opt, id = cid })
  end
  local maxCrafts = needUnits and ceil(needUnits, pick.opt.out) or nil
  if not self:_demandIngredients(pick.opt, cid, depth, maxCrafts, txn) then
    return false   -- _demandAtomic releases every claim in txn
  end
  return true
end

-- append one demand entry (consumer `id` needs `n` of `item`, optionally on a pinned port)
function Planner:_addDemand(item, id, n, port, isMachine)
  item = lc(item)
  if n <= 0 then return end
  self._demand[item] = self._demand[item] or {}
  table.insert(self._demand[item], { id = id, need = n, port = port, machine = isMachine or false })
  if isMachine and port ~= nil then
    self._pins[id] = self._pins[id] or {}
    self._pins[id][port] = item
  end
end

-- ---- fill one buffer -------------------------------------------------------
-- Parse <Item>_(Buffer|Output)_<n>[_<target>] -> item, target (target may be nil).
local function parseDest(id)
  id = tostring(id)
  local prefix, kw, _n, tgt = id:match("^(.-)_(%a+)_(%d+)_(%d+)$")
  if not (prefix and (kw:lower() == "buffer" or kw:lower() == "output")) then
    prefix, kw = id:match("^(.-)_(%a+)_(%d+)$"); tgt = nil
  end
  if prefix and (kw:lower() == "buffer" or kw:lower() == "output") then
    return prefix:gsub("_", " "):lower(), tgt and tonumber(tgt) or nil
  end
end
-- Resolve a container's destination item from an explicit c.buffer / c.output
-- field (set by the namer's auto-assignment / auto-discovery) or its name
-- <Item>_(Buffer|Output)_<n>[_<target>].
function Planner.destItem(c)
  if c.buffer then return tostring(c.buffer):lower() end
  if c.output then return tostring(c.output):lower() end
  return (parseDest(c.id))
end
-- Optional fill target carried in the name suffix (iron_plate_buffer_1_500 -> 500).
function Planner.destTarget(c)
  local _, tgt = parseDest(c.id); return tgt
end
-- back-compat alias
function Planner.bufferItemOf(id) return Planner.destItem({ id = id }) end


-- ============================================================================
-- CONTROL MODEL — spec docs/superpowers/specs/2026-06-09-foreman-control-model-design.md.
-- DEMAND (computeNeed) -> ASSIGNMENT (assign; durable + hysteresis) -> EXECUTION (produceFor;
-- lossless). One coherent model replacing the reactive v0.9.x patches.
-- ============================================================================

-- DEMAND: per-item NEED (units) used to RANK what gets a machine — buffer shortfalls propagated
-- through the craft DAG, PRODUCIBLE-CAPPED so a blocked item (no available feedstock) never ranks.
-- INTERMEDIATE set: items that are BOTH a crafted demanded buffer AND consumed as an ingredient by
-- some crafted demanded item — i.e. staging hubs (plate/screws/rod), not final products (RIP) or raw
-- sources (iron ingot). _needingBuffers stages these to stageDepth instead of capacity.
--   demanded  = has a buffer+target, not a declared source, and is producible VIA A RECIPE
--               (recipesByProduct ~= nil — NOT producible()>0, which also returns recipe-less hub
--               on-hand and would pull a final product into the set if a downstream sink holds stock).
--   consumed  = ingredient of ANY recipe of a demanded item (union over all recipes, so an ingredient
--               used by the assignment recipe but not a representative pick is never missed).
function Planner:_intermediateSet()
  local demanded, consumed = {}, {}
  for _, c in ipairs(self.topo.containers or {}) do
    local item = Planner.destItem(c)
    local target = c.target or Planner.destTarget(c)
    if item and target and not self.sources[item] and self.recipesByProduct[item] then
      demanded[item] = true
    end
  end
  for item in pairs(demanded) do
    for _, opt in ipairs(self.recipesByProduct[item]) do
      for _, ing in ipairs(opt.ingredients) do consumed[ing.name] = true end
    end
  end
  local inter = {}
  for item in pairs(demanded) do if consumed[item] then inter[item] = true end end
  return inter
end
function Planner:computeNeed()
  self.need, self.hubDraw = {}, {}     -- hubDraw is tallied during propagation (each hub-buffered
  self.intermediate = self:_intermediateSet()   -- staging hubs (read by _needingBuffers)
  self.bufShort = {}                   -- intermediate item -> { short=, target= } (emptiness for assign's rank)
  for _, c in ipairs(self.topo.containers or {}) do          -- ingredient is a DRAW from its hub)
    local item = Planner.destItem(c)
    local target = c.target or Planner.destTarget(c)
    if item and target and not self.sources[item] then
      local have = count_in(self.getProxy(c.id), item)
      if self.intermediate[item] then
        local e = self.bufShort[item] or { short = 0, target = 0 }
        e.short = e.short + math.max(0, target - have); e.target = e.target + target
        self.bufShort[item] = e
      end
      self:_addNeed(item, target - have, 0, {})
    end
  end
end
function Planner:_addNeed(item, units, depth, seen)
  item = lc(item)
  if units <= 0 or depth > 8 or seen[item] then return end
  -- producible is a CAP, not just a gate: 2 stray solid biofuel in a hub must not wave through a
  -- 4798-unit demand for an item whose ingredient (biomass) doesn't exist anywhere — that bogus
  -- rank steals a machine and churns its recipe against an impossible job. Demand = want ∧ can.
  local can = self:producible(item)
  if can <= 0 then return end
  units = math.min(units, can)
  self.need[item] = (self.need[item] or 0) + units
  if self.sources[item] then return end                      -- raw leaf
  local pick = self:chooseRecipe(item, units, depth, false)  -- representative recipe (sizing only)
  if not pick then return end
  seen[item] = true
  local crafts = ceil(units, pick.opt.out)
  for _, ing in ipairs(pick.opt.ingredients) do
    local q = crafts * ing.amount
    if self.bufferOf[ing.name] and not self.sources[ing.name] then
      self.hubDraw[ing.name] = (self.hubDraw[ing.name] or 0) + q   -- drawn FROM ing's hub (sizes its fill)
    end
    self:_addNeed(ing.name, q, depth + 1, seen)
  end
  seen[item] = nil
end

-- per-epoch machine capacity (units) — sizes fan-out. Coarse fallback to one output batch.
function Planner:_machineCap(opt)
  local tp = opt.throughput or 0
  if tp <= 0 then return opt.out or 1 end
  return math.max(1, math.floor(tp * (self.epochSeconds or 2)))
end

-- a consumer (a buffer/hub or an assigned recipe's ingredient) that would accept item `it` — so
-- dumping a leftover on setRecipe routes to it rather than sinking. Reads self.consumedSet, which
-- assign() computes ONCE per epoch from the assignment — NOT the partially-built router.orders,
-- which would make the verdict depend on pairs(self.served) execution order.
function Planner:_hasConsumer(it)
  it = lc(it)
  if self.bufferOf[it] then return true end
  return (self.consumedSet and self.consumedSet[it]) or false
end

-- LOSSLESS SWITCH gate. FIN setRecipe empties the input to the OUTPUT (router then routes it). Safe
-- to switch `cid` to `wantOpt` iff EVERY leftover input item is routable — a new-recipe ingredient,
-- or something with a consumer (_hasConsumer). If any leftover would SINK (no consumer, e.g. copper
-- once wire is deallocated), keep draining instead so it's crafted into the current product, not
-- dumped. (We do NOT special-case "can't finish a craft" — a partial of one ingredient can sit
-- alongside a full stack of another, so that is NOT a bounded remnant.) Unknown input -> false.
function Planner:canSwitch(cid, wantOpt)
  local p = self.getProxy(cid)
  local oki, inv = pcall(function() return p:getInputInv() end)
  if not (oki and inv and inv.getStack) then return false end
  local have = {}
  for i = 0, (inv.size or 0) - 1 do
    local s = inv:getStack(i)
    if s and (s.count or 0) > 0 and s.item and s.item.type then
      have[lc(s.item.type.name)] = (have[lc(s.item.type.name)] or 0) + s.count
    end
  end
  if not next(have) then return true end                     -- empty: safe
  local wantIng = {}
  for _, ing in ipairs(wantOpt.ingredients) do wantIng[ing.name] = true end
  for it in pairs(have) do
    if not wantIng[it] and not self:_hasConsumer(it) then return false end   -- would sink: keep draining
  end
  return true
end

-- ASSIGNMENT (durable, anti-thrash). Keep each machine on its recipe while its product is still
-- wanted; reassign only when satisfied, or out-ranked by need >= MARGIN after >= MIN_DWELL epochs.
-- Cover distinct top-need recipes first (breadth), then spare machines fan out onto the highest-
-- need item exceeding its served capacity. Only BUFFERED items are pooled; un-hubbed intermediates
-- are produced on demand by produce() inside _orderIngredients.
local MARGIN, MIN_DWELL = 1.6, 3
Planner._assign = Planner._assign or {}    -- ctorId -> { recipe=<name>, item=<item>, since=<epoch> }
Planner._epoch  = Planner._epoch or 0
function Planner:assign()
  Planner._epoch = (Planner._epoch or 0) + 1
  -- PRUNE stale assignments for constructors no longer in the topology (a repaired/re-snapped
  -- machine gets a NEW id; the old one would leave a phantom cid in self.served whose fill-share is
  -- silently lost). Mirrors Router.listenAll's orphan prune.
  local liveCid = {}
  for _, cid in ipairs(self.topo.constructors or {}) do liveCid[cid] = true end
  for cid in pairs(Planner._assign) do if not liveCid[cid] then Planner._assign[cid] = nil end end
  local pool = {}
  for it, n in pairs(self.need) do
    if n > 0 and self.bufferOf[it] and self.recipesByProduct[it] and not self.sources[it] then
      -- an INTERMEDIATE's per-epoch fill is capped at its staging slice (_needingBuffers), so rank
      -- it by that ceiling — NOT by the recursion-propagated demand of its consumers. Else a staged
      -- item (RIP, needed by frames) OUTRANKS the very consumers (frames) that would draw it and
      -- hogs every machine while its own fill orders are ~0: the live RIP-pinned-at-100 stall where
      -- frame production never got a machine because need[RIP] (inflated by the frame demand
      -- itself) beat need[frames] forever. With the cap, consumers win machines once the staging
      -- buffer is primed, and the staged refill keeps drawing as they consume.
      if self.intermediate and self.intermediate[it] then
        -- EMPTINESS-SCALED rank: the emptier an intermediate buffer, the higher its claim on
        -- spare machines — from one slice (nearly full) up to (1+rankBoost) slices (drained).
        -- A depleted hub pulls machines back urgently (consumers starve without it anyway);
        -- a comfortable one never "maxes out iron plates" over consumer products.
        local bs, slice = self.bufShort and self.bufShort[it], self.stageDepth or 100
        if bs and bs.target > 0 then
          n = math.min(bs.short, math.ceil(slice * (1 + (Planner.rankBoost or 3) * bs.short / bs.target)))
        else
          n = math.min(n, slice)
        end
      end
      -- INFEASIBILITY YIELD: an item whose production failed for 2+ epochs (its hub-drawn
      -- ingredient is dry and the machines it holds are the only ones that could prime it) sits
      -- out ONE assignment round so the ingredient wins a machine; it re-enters next epoch and,
      -- once feasible, out-ranks the (staged) ingredient again. With one machine this ping-pongs
      -- ingredient/consumer in stageDepth-sized batches; with N machines they split stably.
      -- ONLY IF IT CAN HELP: yielding frees THIS item's machines — that primes the dry ingredient
      -- only if one of those machines can actually PRODUCE it. When the blocker needs a machine
      -- class this item doesn't hold (live: RIP on an assembler starving for screws, which need a
      -- CONSTRUCTOR), the yield just swaps two equally-starved siblings forever (RIP<->Rotor),
      -- orphaning each other's in-transit ingredients every dwell window. Unknown blocker (no
      -- ingredient recorded) keeps the original always-yield behavior.
      if (Planner._infeas[it] or 0) >= 2 then
        Planner._infeas[it] = 0
        local ing = Planner._infeasIng[it]
        local helpful = ing == nil
        if ing and self.recipesByProduct[ing] then
          for cid, a in pairs(Planner._assign) do
            if a.item == it then
              for _, o2 in ipairs(self.recipesByProduct[ing]) do
                if o2.ctorId == cid then helpful = true; break end
              end
              if helpful then break end
            end
          end
        end
        if not helpful then pool[it] = n end   -- keep the assignment; freeing the machine gains nothing
      else
        pool[it] = n
      end
    end
  end
  local cap = {}                              -- ctorId -> { item -> opt }; FIRST opt per (cid,item) wins (deterministic)
  for it in pairs(pool) do
    for _, opt in ipairs(self.recipesByProduct[it]) do
      cap[opt.ctorId] = cap[opt.ctorId] or {}; cap[opt.ctorId][it] = cap[opt.ctorId][it] or opt
    end
  end
  -- SEED from machines' LIVE recipes (untracked ones) so a running recipe is respected — but stamp
  -- `since` back by MIN_DWELL so a seeded machine is IMMEDIATELY re-rankable: a tiny-need live recipe
  -- must not monopolize a machine for MIN_DWELL epochs while the top-need item starves.
  -- NEVER seed a machine that is mid-DRAIN or still wearing a drain's temp recipe: adopting the
  -- temp recipe as a real assignment turns the drain into a FUNDED competing consumer (orders,
  -- quota, gate budget) that vacuums other machines' in-transit feedstock off a shared chain —
  -- the live 222D68/B13DC6 temp 'Copper Sheet' eating C5504C's copper ingots. A MANUAL recipe
  -- change (live ~= recorded temp) still seeds normally.
  for _, cid in ipairs(self.topo.constructors or {}) do
    if not Planner._assign[cid] and not Planner._drain[cid] then
      local okc, rec = pcall(function() return self.getProxy(cid):getRecipe() end)
      local it = okc and rec and rec.name and self.itemOfRecipe[tostring(rec.name)]
      if it and pool[it] and cap[cid] and cap[cid][it]
         and Planner._tempRecipe[cid] ~= tostring(rec.name) then
        Planner._assign[cid] = { recipe = cap[cid][it].recipe.name, item = it, opt = cap[cid][it], since = Planner._epoch - MIN_DWELL }
      end
    end
  end
  local function servedN(it) local n = 0; for _, a in pairs(Planner._assign) do if a.item == it then n = n + 1 end end; return n end
  -- DROP an assignment whose item left the pool — but never hysteresis-free unless GENUINELY
  -- satisfied. Pool exits are frequent and FLICKERY (the infeasibility yield removes an item for
  -- one round; the producible demand cap drops it whenever feasibility flickers), and an instant
  -- drop hands the machine to a rival in the SAME assign() call: the rival's setRecipe ejects the
  -- hoarded input and every in-flight item ordered for the old recipe is orphaned on the belts to
  -- sink — the live Rotor<->RIP / SAM<->Cable flap. need[] cannot tell satisfied from flicker
  -- (both leave it empty), so test the buffers directly: every targeted buffer at target = done,
  -- release the machine NOW (a finished job must not squat); anything else waits out MIN_DWELL
  -- (the pacing the de-serve path already applies). Never tear down a machine mid-DRAIN — the
  -- seed-skip above relies on _drain/_tempRecipe, and an unassigned drained machine would have
  -- nothing to restore to. The infeasibility yield still works: the item leaves the RANKING
  -- immediately; its machine is merely handed over at dwell pace.
  local function satisfied(it)
    for _, c in ipairs(self.topo.containers or {}) do
      if Planner.destItem(c) == it and not self.sources[it] then
        local target = c.target or Planner.destTarget(c)
        if target and target - count_in(self.getProxy(c.id), it) > 0 then return false end
      end
    end
    return true
  end
  for cid, a in pairs(Planner._assign) do
    if not pool[a.item] and not Planner._drain[cid]
       and (satisfied(a.item) or (Planner._epoch - (a.since or 0)) >= MIN_DWELL) then
      Planner._assign[cid] = nil
    end
  end
  -- de-serve out-ranked machines (margin + dwell), spreading freed machines across DISTINCT unserved
  -- items (pendingServe) so one top item doesn't free EVERY out-ranked machine (avoidable thrash).
  local pendingServe = {}
  local function topUnserved() local b, bn for it, n in pairs(pool) do if servedN(it) == 0 and not pendingServe[it] and (not bn or n > bn) then b, bn = it, n end end return b, bn end
  for cid, a in pairs(Planner._assign) do
    local tu, tn = topUnserved()
    if tu and tn >= MARGIN * (pool[a.item] or 1) and (Planner._epoch - (a.since or 0)) >= MIN_DWELL and cap[cid] and cap[cid][tu] then
      Planner._assign[cid] = nil; pendingServe[tu] = true
    end
  end
  local free = {}
  -- a DRAINING machine is out of the rotation entirely: granting it a pool item would fund
  -- production on top of (or right after) its temp recipe — the same diversion the seed-skip
  -- blocks. _jamSweep keeps servicing it; it re-enters the pool once the drain completes.
  for _, cid in ipairs(self.topo.constructors or {}) do
    if not Planner._assign[cid] and not Planner._drain[cid] then free[cid] = true end
  end
  local ranked = {}
  for it in pairs(pool) do ranked[#ranked + 1] = it end
  table.sort(ranked, function(a, b) if pool[a] ~= pool[b] then return pool[a] > pool[b] end return tostring(a) < tostring(b) end)
  local function capCount(cid) local n = 0; for _ in pairs(cap[cid] or {}) do n = n + 1 end; return n end
  local function grab(it)                     -- the MOST SPECIALIZED free machine (don't burn a versatile machine on a coverable specialized item); deterministic over topo order
    local best
    for _, cid in ipairs(self.topo.constructors or {}) do
      if free[cid] and cap[cid] and cap[cid][it] and (not best or capCount(cid) < capCount(best)) then best = cid end
    end
    if best then Planner._assign[best] = { recipe = cap[best][it].recipe.name, item = it, opt = cap[best][it], since = Planner._epoch }; free[best] = nil; return true end
  end
  for _, it in ipairs(ranked) do if servedN(it) == 0 then grab(it) end end   -- BREADTH
  local more = true                                                          -- FAN-OUT
  while more do
    more = false
    for _, it in ipairs(ranked) do
      local sc = 0
      for cid, a in pairs(Planner._assign) do if a.item == it and cap[cid] and cap[cid][it] then sc = sc + self:_machineCap(cap[cid][it]) end end
      if pool[it] > sc and grab(it) then more = true; break end
    end
  end
  self.served, self.consumedSet = {}, {}      -- publish served + the per-epoch consumed-item set (canSwitch)
  for cid, a in pairs(Planner._assign) do
    self.served[a.item] = self.served[a.item] or {}
    self.served[a.item][#self.served[a.item] + 1] = cid
    self.busy[cid] = true
    if a.opt then for _, ing in ipairs(a.opt.ingredients) do self.consumedSet[ing.name] = true end end
  end
  -- PUBLISH per-machine acceptance for the router: with no orders yet, _machineAccepts used to wave
  -- ANY item into a machine — assignment gaps and drain holds (both order-less) routinely let
  -- overflow/merger pushes land foreign items on machine legs (the wrong-items-to-constructors).
  -- An assigned machine accepts its recipe's ingredients; an unassigned/draining one accepts
  -- NOTHING new (its lane is cleared by the drain, not refilled). Machines unknown to the planner
  -- stay permissive in the router (pre-plan grace).
  local allow = {}
  for _, cid in ipairs(self.topo.constructors or {}) do
    allow[cid] = {}
    local a = Planner._assign[cid]
    if a and a.opt then for _, ing in ipairs(a.opt.ingredients) do allow[cid][ing.name] = true end end
  end
  self.router.machineAllow = allow
end

-- total hub-fill amount for an item (Σ its needing buffers' need, incl. hub draw).
function Planner:_fillAmount(item)
  local amt = 0; for _, b in ipairs(self:_needingBuffers(item)) do amt = amt + b.need end; return amt
end

-- the buffer(s) of `item` that still need filling: { {id=, need=} ... }. The hub (bufferOf) carries
-- the draw on top of its own shortfall; other buffers just their shortfall.
--
-- Each buffer of an item is an INDEPENDENT destination (it may be far across the factory; the hub
-- cannot serve a buffer it is not wired to), so staging is sized PER BUFFER, not pooled. An
-- intermediate (crafted-and-consumed) buffer is staged to ~stageDepth with NO hubDraw — the
-- consumer's draw shows up next epoch as a lower count_in and is refilled then, so production tracks
-- real consumption rather than the full downstream-to-capacity shortfall (the flood).
function Planner:_needingBuffers(item)
  item = lc(item); local out = {}
  for _, c in ipairs(self.topo.containers or {}) do
    if Planner.destItem(c) == item then
      local target = c.target or Planner.destTarget(c)
      -- demand is capped by PHYSICAL capacity: producing more than the buffer can hold just
      -- strands the surplus on the lanes (the v0.16.x reroute-or-sink churn). Targets above
      -- capacity fill to capacity and stop.
      if target and c.capacity and c.capacity < target then target = c.capacity end
      if target then
        local need
        if self.intermediate and self.intermediate[item] then
          -- PACED FILL: intermediates fill toward their FULL target (targets are goals, per the
          -- user — not ceilings), but only a stageDepth SLICE per epoch. The slice is what made
          -- the original capacity-fill safe to restore: a 4800 buffer never demands its whole
          -- chain's feedstock at once (the flood), release stays inside the flow window, and the
          -- slice-sized rank (assign) keeps CONSUMER products out-ranking trickle-fills — finals
          -- first, then every buffer tops up to target, then the factory idles genuinely done.
          need = math.min(self.stageDepth or 100, target - count_in(self.getProxy(c.id), item))
        else
          need = target - count_in(self.getProxy(c.id), item)
          if self.bufferOf[item] == c.id and self.hubDraw and self.hubDraw[item] then need = need + self.hubDraw[item] end
        end
        if need > 0 then out[#out + 1] = { id = c.id, need = need } end
      end
    end
  end
  return out
end

-- ---- FEED-DRAIN: clear a FOREIGN item stranded on a machine's ENTRANCE BELT -----------------
-- A machine only pulls items its current recipe consumes; a mis-delivered item (an iron ingot on
-- the screws machine's feed) sits on the belt FOREVER — no routing can remove it, and everything
-- behind it stalls. The ONLY actor that can clear it is the machine itself: temporarily switch to
-- a recipe that CONSUMES the blockage, let it pull+craft the strays, then restore the assignment.
-- Detection: the machine is assigned + STARVED (empty input) for drainAfter epochs while the
-- router reports its feed leg physically FULL (Router._legFullMach — a full entrance + an empty
-- input can only mean the belt head is something the recipe won't pull). The temp recipe HOLDS
-- until it stops pulling (drainIdle epochs with an empty input), then the assignment is restored.
-- A MANUAL recipe change on a starved+jammed machine is adopted as a drain (never fought) — the
-- user clearing a blockage by hand must not be reverted seconds later. setRecipe is safe here:
-- the input is empty by construction (starved), so nothing is ejected.
Planner._infeas     = Planner._infeas or {}       -- item -> consecutive epochs every produceFor failed (assign yields at 2)
Planner._infeasIng  = Planner._infeasIng or {}    -- item -> the ingredient that blocked it (yield-helpfulness check)
Planner._drain      = Planner._drain or {}        -- cid -> { recipe = name, idle = n }
Planner._starve     = Planner._starve or {}       -- cid -> consecutive starved epochs while on the assigned recipe
Planner._drainTried = Planner._drainTried or {}   -- cid -> last drain recipe name (round-robin cursor)
Planner._tempRecipe = Planner._tempRecipe or {}   -- cid -> drain temp recipe name; blocks assign() seed-adoption until a real switch overwrites it
Planner._drainAdmit = Planner._drainAdmit or {}   -- cid -> the corked item a targeted drain may admit through the live gate
Planner.drainAfter  = Planner.drainAfter or 3     -- starved+jammed epochs before a drain switch
Planner.drainIdle   = Planner.drainIdle or 3      -- drain epochs with no pull before restoring

-- total items in a machine's INPUT inventory (0 on any read error)
function Planner:_inputCount(cid)
  local p = self.getProxy(cid)
  local ok, inv = pcall(function() return p:getInputInv() end)
  if not (ok and inv) then return 0 end
  local n = 0; pcall(function() n = inv.itemCount or 0 end)
  return n
end

-- a machine's INPUT inventory as item -> count (empty map on read error)
function Planner:_inputMap(cid)
  local p = self.getProxy(cid)
  local ok, inv = pcall(function() return p:getInputInv() end)
  local have = {}
  if not (ok and inv and inv.getStack) then return have end
  for i = 0, (inv.size or 0) - 1 do
    local s = inv:getStack(i)
    if s and (s.count or 0) > 0 and s.item and s.item.type then
      have[lc(s.item.type.name)] = (have[lc(s.item.type.name)] or 0) + s.count
    end
  end
  return have
end

-- the next drain recipe to try on `cid` (≠ the assigned `opt`). The blockage is BY DEFINITION an
-- item the assigned recipe does NOT consume (the machine would already pull its own feedstock), so:
--   * a feeder-item hint matching the assigned ingredients is in-transit feedstock, NOT the jam —
--     ignore it (the live bug: B13DC6 assigned Iron Rod(<-ingot) was hinted 'iron ingot' and picked
--     Iron Plate(<-ingot), a recipe that by construction can never pull the jam);
--   * a candidate that consumes ONLY assigned ingredients is equally useless — rank it last.
-- Ranking: tier 1 = recipes consuming another assignment's ingredient (strays come from the shared
-- manifold's own flows: rod/plate/screws); tier 2 = recipes consuming any buffered/sourced item;
-- tier 3 = the rest (a player-dropped stray). Alphabetical within a tier. The round-robin cursor
-- (_drainTried) is only set by a drain that pulled NOTHING — a working recipe is reused next jam.
function Planner:_drainCandidate(cid, opt)
  local assignedIng = {}
  for _, ing in ipairs(opt.ingredients) do assignedIng[ing.name] = true end
  local tier1, tier2 = {}, {}
  for _, a in pairs(Planner._assign) do
    if a.opt then for _, ing in ipairs(a.opt.ingredients) do if not assignedIng[ing.name] then tier1[ing.name] = true end end end
  end
  for it in pairs(self.bufferOf) do if not assignedIng[it] then tier2[it] = true end end
  for it in pairs(self.sources) do if not assignedIng[it] then tier2[it] = true end end
  local seen, list = {}, {}
  for _, opts in pairs(self.recipesByProduct) do
    for _, o2 in ipairs(opts) do
      local nm = tostring(o2.recipe.name)
      if o2.ctorId == cid and nm ~= tostring(opt.recipe.name) and not seen[nm] then
        seen[nm] = true
        local t = 3
        for _, ing in ipairs(o2.ingredients) do
          if tier1[ing.name] then t = 1; break elseif tier2[ing.name] then t = math.min(t, 2) end
        end
        list[#list + 1] = { o2 = o2, tier = t, nm = nm }
      end
    end
  end
  if #list == 0 then return nil end
  table.sort(list, function(a, b) if a.tier ~= b.tier then return a.tier < b.tier end return a.nm < b.nm end)
  local lastFail = Planner._drainTried[cid]          -- set only when the previous drain pulled nothing
  local hint = self.router._feedItem and self.router:_feedItem(cid)
  if hint and not assignedIng[hint] then             -- assigned feedstock at the feeder = in transit, not the jam
    for _, e in ipairs(list) do
      if e.nm ~= lastFail then
        for _, ing in ipairs(e.o2.ingredients) do if ing.name == hint then return e.o2 end end
      end
    end
  end
  if lastFail then
    for i, e in ipairs(list) do if e.nm == lastFail then return list[(i % #list) + 1].o2 end end
  end
  return list[1].o2
end

-- JAM SWEEP for machines with NO assignment this epoch. The frozen+jammed drain trigger lives in
-- produceFor, which only runs for ASSIGNED machines — so an unassigned machine (its item ran out
-- of feedstock and dropped from the pool) with foreign items stranded on its dedicated lane was
-- invisible: nobody ever cleared it (the live Reanimated-SAM constructor whose lane filled with
-- the ~100 copper ingots in flight when the sheet machine got reassigned). The machine is that
-- lane's ONLY consumer, so it must eat the blockage regardless of assignment: same trigger and
-- progress-based hold, minus the restore (nothing assigned to restore to).
function Planner:_jamSweep(servedCid)
  for _, cid in ipairs(self.topo.constructors or {}) do
    if not servedCid[cid] then
      local inN = self:_inputCount(cid)
      local d = Planner._drain[cid]
      if d then
        if d.lastIn ~= nil and inN ~= d.lastIn then d.idle = 0; d.pulled = true
        else d.idle = (d.idle or 0) + 1 end
        d.lastIn = inN
        if d.idle >= (Planner.drainIdle or 3) then
          if d.pulled then Planner._drainTried[cid] = nil end
          Planner._drain[cid] = nil
        end
      else
        local jammed = self.router.legJammed and self.router:legJammed(cid)
        local st = Planner._starve[cid]
        if type(st) ~= "table" then st = { n = 0 }; Planner._starve[cid] = st end
        if st.lastIn == inN then st.n = st.n + 1 else st.n = 0 end
        st.lastIn = inN
        if jammed and st.n >= (Planner.drainAfter or 3) then
          local p = self.getProxy(cid)
          local okr, rec = pcall(function() return p:getRecipe() end)
          local liveIt = okr and rec and rec.name and self.itemOfRecipe[tostring(rec.name)]
          local opt
          for _, o2 in ipairs((liveIt and self.recipesByProduct[liveIt]) or {}) do
            if o2.ctorId == cid and tostring(o2.recipe.name) == tostring(rec.name) then opt = o2; break end
          end
          if opt then
            local have = self:_inputMap(cid)
            local canCraft = true
            for _, ing in ipairs(opt.ingredients) do
              if (have[ing.name] or 0) < ing.amount then canCraft = false; break end
            end
            local cand = (not canCraft) and self:_drainCandidate(cid, opt) or nil
            if cand then
              pcall(function() opt.ctor:setRecipe(cand.recipe) end)   -- partial leftovers eject to OUTPUT (routed) — user rule: losing a sub-craft remnant beats a clogged lane
              Planner._drain[cid] = { recipe = tostring(cand.recipe.name), idle = 0 }
              Planner._drainTried[cid] = tostring(cand.recipe.name)
              Planner._tempRecipe[cid] = tostring(cand.recipe.name)   -- never seed-adopted as a real assignment
              st.n = 0
              pcall(function() computer.log(1, ("[Foreman] DRAIN %s (idle): lane jammed; temp recipe '%s' pulls the blockage")
                :format(tostring(cid):sub(1, 6), tostring(cand.recipe.name))) end)
            end
          end
        end
      end
    end
  end
end

-- EXECUTION: machine `cid` makes its `share` of `item`'s hub fill, delivered to the item's buffer.
-- Lossless: if the live recipe ≠ assigned, switch only when canSwitch, else DRAIN (route the
-- current recipe's finishing output, no new feed). Atomic rollback on any ingredient failure.
function Planner:produceFor(cid, item, share)
  self._lastFailIng = nil       -- per-attempt: only a real ingredient failure below sets it
  -- use the EXACT recipe assign() chose (stored on _assign) — not a re-pick by first-opt, which can
  -- disagree with the demand layers and set an infeasible alternate when one machine knows
  -- several recipes for the same product.
  local a = Planner._assign[cid]
  local opt = a and a.opt
  if not opt then return false end
  local okc, cur = pcall(function() return opt.ctor:getRecipe() end)
  local live = okc and cur and cur.name or nil
  local needSwitch = false
  local inN = self:_inputCount(cid)
  -- ---- FEED-DRAIN hold: a machine clearing its jammed entrance keeps the drain recipe ----
  local d = Planner._drain[cid]
  if d then
    -- PROGRESS-based hold (not presence): the drain stays only while the input CHANGES. A stuck
    -- sub-craft remnant (1 wire when Cable needs 2) used to reset the idle counter forever and
    -- pin the drain recipe while the assigned ingredient jammed the entrance. Now it idles out;
    -- the restore's setRecipe EJECTS the remnant to the output (routed away) — losing a partial
    -- input below the craft requirement beats a clogged machine.
    if d.lastIn ~= nil and inN ~= d.lastIn then d.idle = 0; d.pulled = true
    else d.idle = (d.idle or 0) + 1 end
    d.lastIn = inN
    if live and live ~= opt.recipe.name then d.recipe = tostring(live) end   -- adopt manual changes mid-drain
    if d.idle >= (Planner.drainIdle or 3) then
      -- a drain that PULLED worked: clear the round-robin cursor so the same recipe is reused on
      -- the next jam; a drain that pulled nothing keeps the cursor so the next attempt advances.
      if d.pulled then Planner._drainTried[cid] = nil end
      Planner._drain[cid] = nil       -- no input movement for a while: drained (or unpullable) -> restore below
    else
      local di = live and self.itemOfRecipe[tostring(live)]                 -- route the drained product away
      if di and self.bufferOf[di] then
        self:_addDemand(di, self.bufferOf[di], math.max(1, self:_fillAmount(di)), nil, false)
      end
      return true                     -- hold: no assigned-recipe production (and no feedstock demand) this epoch
    end
  end
  local jammed = self.router.legJammed and self.router:legJammed(cid)
  if live == opt.recipe.name then
    -- FROZEN tracking on the assigned recipe: the machine is STUCK when its input count AND its
    -- production are both UNCHANGED across epochs. This covers an empty input, a PARTIAL input
    -- below the recipe requirement (a machine holding 1 of 3 ingots with a stray blocking its
    -- entrance freezes exactly like an empty one — the live C5504C case "in=1" that the old
    -- inN==0 test missed), and an uncraftable mix. Generic for any machine, any recipe.
    -- frozen = the input's CONTENTS are unchanged across epochs (count AND composition): covers
    -- empty, partial-below-requirement and uncraftable-mix inputs. A healthy machine's pushes
    -- keep succeeding, so it is never jam-marked and the drain can't trigger on it anyway.
    local sigT = {}
    for it, n in pairs(self:_inputMap(cid)) do sigT[#sigT + 1] = it .. "=" .. n end
    table.sort(sigT)
    local sig = table.concat(sigT, ",")
    local st = Planner._starve[cid]
    if type(st) ~= "table" then st = { n = 0 }; Planner._starve[cid] = st end
    if st.lastIn == inN and st.lastSig == sig then st.n = st.n + 1 else st.n = 0 end
    st.lastIn, st.lastSig = inN, sig
    if jammed and st.n >= (Planner.drainAfter or 3) then
      -- a frozen machine that COULD craft from what it holds is OUTPUT-blocked — its fix is
      -- downstream; never touch its recipe (setRecipe would eject full feedstock into the very
      -- path that is blocked — the live B13DC6 "in=100, output jammed" case).
      local have = self:_inputMap(cid)
      local canCraft = true
      for _, ing in ipairs(opt.ingredients) do
        if (have[ing.name] or 0) < ing.amount then canCraft = false; break end
      end
      local cand = (not canCraft) and self:_drainCandidate(cid, opt) or nil
      if cand then
        pcall(function() opt.ctor:setRecipe(cand.recipe) end)   -- leftovers (if any) eject to OUTPUT and are routed
        Planner._drain[cid] = { recipe = tostring(cand.recipe.name), idle = 0 }
        Planner._drainTried[cid] = tostring(cand.recipe.name)
        Planner._tempRecipe[cid] = tostring(cand.recipe.name)   -- never seed-adopted as a real assignment
        st.n = 0
        pcall(function() computer.log(1, ("[Foreman] DRAIN %s: entrance jammed while frozen; temp recipe '%s' pulls the blockage (assigned '%s')")
          :format(tostring(cid):sub(1, 6), tostring(cand.recipe.name), tostring(opt.recipe.name))) end)
        local di = self.itemOfRecipe[tostring(cand.recipe.name)]
        if di and self.bufferOf[di] then
          self:_addDemand(di, self.bufferOf[di], math.max(1, self:_fillAmount(di)), nil, false)
        end
        return true
      end
    end
  else
    -- live ≠ assigned. A frozen+jammed machine whose recipe was changed by hand is DRAINING its
    -- blockage — ADOPT it (switching back would re-block the belt and fight the user).
    local stA = Planner._starve[cid]
    if live ~= nil and type(stA) == "table" and stA.n > 0 and jammed then
      Planner._drain[cid] = { recipe = tostring(live), idle = 0 }
      stA.n = 0
      local di = self.itemOfRecipe[tostring(live)]
      if di and self.bufferOf[di] then
        self:_addDemand(di, self.bufferOf[di], math.max(1, self:_fillAmount(di)), nil, false)
      end
      return true
    end
    if self:canSwitch(cid, opt) then
      needSwitch = true    -- defer the actual setRecipe until the ingredient orders PLACE (below)
    else
      local curItem = live and self.itemOfRecipe[tostring(live)]   -- DRAIN: route finishing output
      if curItem and self.bufferOf[curItem] then
        self:_addDemand(curItem, self.bufferOf[curItem], math.max(1, self:_fillAmount(curItem)), nil, false)
      end
      return true
    end
  end
  local maxCrafts = share and ceil(share, opt.out) or nil
  if maxCrafts and maxCrafts <= 0 then return true end   -- product satisfied: idle, demand nothing
  if not self:_demandAtomic(opt, cid, maxCrafts) then
    self.busy[cid] = nil   -- an unexecutable assignment releases its machine for this epoch's
    return false           -- deep-craft claims (the old rollback rule)
  end
  -- setRecipe ONLY after the ingredients are suppliable: switching first churned the (expensive,
  -- input-ejecting) setRecipe every epoch on an infeasible assignment — the live Solid Biofuel /
  -- Reanimated SAM flip-flop on one constructor, retrying a job whose ingredient doesn't exist.
  if needSwitch then
    pcall(function() opt.ctor:setRecipe(opt.recipe) end)
    Planner._tempRecipe[cid] = nil          -- real assignment switch: the drain's temp recipe is history
  end
  return true
end

--- One epoch: scan -> rank -> assign -> reconcile recipes (drain/switch lifecycle) -> build the
--- DEMAND SETS from live machine/buffer levels -> publish next-hop routes + provider gates.
--- Demand-pull: no orders, no quotas, no release ledgers — inventory is the ground truth.
function Planner:fillAll()
  self._prodMemo = {}    -- reset the per-epoch producible cache (inventory snapshot for this re-plan)
  self.busy = {}         -- machine claims are PER-EPOCH (assign re-marks; produceInto re-claims)
  self:scan()
  self:computeNeed()     -- need[] for ranking + staged hub sizing
  self:assign()
  self._demand, self._pins, self._claimed = {}, {}, {}
  local plan = {}
  -- direct raw-source buffers (e.g. concrete straight into its store): plain buffer demand
  for _, c in ipairs(self.topo.containers or {}) do
    local item = Planner.destItem(c); local target = c.target or Planner.destTarget(c)
    if item and target and self.sources[item] then
      local qty = math.min(target - count_in(self.getProxy(c.id), item), self:available(item))
      if qty > 0 then
        self:_addDemand(item, c.id, qty, nil, false)
        plan[#plan + 1] = ("%s: direct %s"):format(tostring(c.id):sub(1, 6), item)
      end
    end
  end
  -- assigned machines: reconcile recipe (drain/switch lifecycle) + demand their ingredient gaps
  for item, cids in pairs(self.served or {}) do
    local need = 0
    for _, b in ipairs(self:_needingBuffers(item)) do need = need + math.max(0, b.need) end
    local k = #cids
    local base, extra = math.floor(need / k), need % k
    local placed = 0
    for i, cid in ipairs(cids) do
      local sh = base + (i <= extra and 1 or 0)
      if self:produceFor(cid, item, need > 0 and sh or nil) then placed = placed + 1 end
    end
    plan[#plan + 1] = ("%s: %d/%d ctor"):format(item, placed, #cids)
    -- INFEASIBILITY tracking: an assigned item whose every produceFor failed (its ingredient has
    -- no conceivable supply) must eventually YIELD its machines so the blocker can be primed.
    if placed > 0 then Planner._infeas[item] = nil; Planner._infeasIng[item] = nil
    else
      Planner._infeas[item] = (Planner._infeas[item] or 0) + 1
      Planner._infeasIng[item] = self._lastFailIng           -- which ingredient blocked it (yield helpfulness)
    end
  end
  local servedCid = {}
  for _, cids in pairs(self.served or {}) do for _, cid in ipairs(cids) do servedCid[cid] = true end end
  self:_jamSweep(servedCid)   -- unassigned machines still clear their jammed lanes (drain trigger + hold)
  -- CORK DRAINS: the router reported items held past patience with no exit at a machine-feeding
  -- node. The corked item is KNOWN, so drain it precisely: temp recipe that consumes exactly it,
  -- a temp demand so the splitter pushes it onto the leg, and a live-gate admission for it alone.
  for cid, corkItem in pairs(self.router._corked or {}) do
    self.router._corked[cid] = nil
    if not Planner._drain[cid] then
      local cand
      for _, opts in pairs(self.recipesByProduct) do
        for _, o2 in ipairs(opts) do
          if o2.ctorId == cid and not cand then
            for _, ing in ipairs(o2.ingredients) do if ing.name == corkItem then cand = o2; break end end
          end
        end
      end
      if cand then
        pcall(function() cand.ctor:setRecipe(cand.recipe) end)
        Planner._drain[cid] = { recipe = tostring(cand.recipe.name), idle = 0 }
        Planner._drainTried[cid] = tostring(cand.recipe.name)
        Planner._tempRecipe[cid] = tostring(cand.recipe.name)
        Planner._drainAdmit[cid] = corkItem
        pcall(function() computer.log(1, ("[Foreman] CORKDRAIN %s: '%s' corks the lane (no route, no sink); temp recipe '%s' eats it")
          :format(tostring(cid):sub(1, 6), corkItem, tostring(cand.recipe.name))) end)
      end
    end
  end
  -- cork demand entries: give the corked item a next hop onto the draining machine's leg
  for cid, corkItem in pairs(Planner._drainAdmit) do
    if Planner._drain[cid] then self:_addDemand(corkItem, cid, 10, nil, true)
    else Planner._drainAdmit[cid] = nil end
  end
  -- PROVIDER GRANTS first (stocked hubs that will SUPPLY a demander act as sources this epoch and
  -- must not also demand a refill — their own granted outflow would route straight back to them).
  local grants, providing = {}, {}
  for item, consumers in pairs(self._demand) do
    local total = 0
    local consumerIds = {}
    for _, cn in ipairs(consumers) do total = total + cn.need; consumerIds[cn.id] = true end
    local remaining = total
    for _, pr in ipairs(self:_providersFor(item, consumerIds)) do
      if remaining <= 0 then break end
      local take = math.min(remaining, pr.stock)
      if take > 0 then
        grants[pr.id] = (grants[pr.id] or 0) + take
        providing[pr.id] = true
        remaining = remaining - take
      end
    end
    -- residual demand with a raw source: keep its gate open a batch so stock flowing INTO the
    -- source this epoch (miners) still releases (the old momentarily-empty-source rule)
    if remaining > 0 then
      local srcs = self.sources[item]
      if srcs and srcs[1] then grants[srcs[1]] = (grants[srcs[1]] or 0) + remaining end
    end
  end
  -- product destinations: every below-target buffer that is NOT providing this epoch demands its
  -- staged refill, so machine OUTPUT (and drain ejecta) has a next hop toward storage
  for item in pairs(self.bufferOf) do
    for _, b in ipairs(self:_needingBuffers(item)) do
      if b.need > 0 and not providing[b.id] then self:_addDemand(item, b.id, b.need, nil, false) end
    end
  end
  -- PUBLISH the LIVE-RECIPE gate for the router (user rule: a machine leg only ever receives what
  -- the machine will pull RIGHT NOW). Read AFTER produceFor's switches and the jam sweep so the
  -- set reflects this epoch's actual recipes. A DRAINING machine admits NOTHING new — its temp
  -- recipe must clear the lane, not vacuum more of the blockage item in.
  local liveGate = {}
  for _, cid in ipairs(self.topo.constructors or {}) do
    liveGate[cid] = {}
    if Planner._drain[cid] and Planner._drainAdmit[cid] then
      liveGate[cid][Planner._drainAdmit[cid]] = true   -- targeted drain: admit the cork, nothing else
    elseif not Planner._drain[cid] then
      local okr, rec = pcall(function() return self.getProxy(cid):getRecipe() end)
      if okr and rec and rec.getIngredients then
        local oki, ings = pcall(function() return rec:getIngredients() end)
        if oki then for _, ia in ipairs(ings or {}) do
          if ia.type and ia.type.name then liveGate[cid][lc(ia.type.name)] = true end
        end end
      end
    end
    if liveGate[cid] and not next(liveGate[cid]) and not Planner._drain[cid] then
      -- not draining but no readable recipe: keep the empty set (admit nothing)
    end
  end
  self.router.machineLive = liveGate
  self.router:setDemand(self._demand, self._pins)
  self.router:buildNextHop()
  self.router:applyGates(grants)
  return plan
end

function Planner:run(maxLoops) return self.router:run(maxLoops) end

return Planner
