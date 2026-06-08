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

local function ceil(a, b) return math.floor((a + b - 1) / b) end
-- Case-insensitive item names: reflection gives canonical (Title) case, nicks give
-- lowercase. Key/compare everything lowercase so they match. (See router.lua.)
local function lc(s) return s and tostring(s):lower() or nil end

-- DURABLE per-constructor pool state (module-level so it survives the ~2s App.run rebuilds —
-- the planner is reconstructed each epoch but a machine's recipe assignment + drain progress
-- must persist). Reset per session in App.run. ctorId -> { recipeName, item, state, drain }.
Planner._ctorState = Planner._ctorState or {}
local DRAIN_TIMEOUT = 5         -- epochs a reassigned machine may sit DRAINING before a forced switch

function Planner.new(topology, router, getProxy, epochSeconds)
  local self = setmetatable({}, Planner)
  self.topo = topology
  self.router = router
  self.getProxy = getProxy or function(id) return component.proxy(id) end
  self.epochSeconds = epochSeconds or 2   -- re-plan cadence (s): sizes per-machine pool capacity
  self.recipesByProduct = {}     -- itemName -> list of recipe options
  self.busy = {}                 -- ctorId -> true once assigned this planning pass
  self.demand = {}               -- itemName -> unmet UNITS this epoch (DAG-propagated; for allocation)
  self.assign = {}               -- itemName -> { {cid, opt}, ... } pool constructors assigned to it
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
  for _, c in ipairs(topology.containers or {}) do
    local di = Planner.destItem(c)
    if di and not self.bufferOf[di] then self.bufferOf[di] = c.id end
  end
  return self
end

-- ---- reflection: discover constructors + recipes ---------------------------
function Planner:scan()
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
end

-- ---- inventory reads (FIN-faithful: getInventories -> getStack) -------------
local function count_in(proxy, item)
  item = lc(item)
  local invs = proxy:getInventories()
  local total = 0
  for _, inv in ipairs(invs) do
    for i = 0, (inv.size or 0) - 1 do
      local stack = inv:getStack(i)
      -- in-game an empty slot returns a 0-count stack whose item.type is nil — guard
      if stack and (stack.count or 0) > 0 and stack.item and stack.item.type
         and lc(stack.item.type.name) == item then
        total = total + stack.count
      end
    end
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

-- Order `qty` of a raw item to `dst`, SPLIT across every source container that provides it
-- (each capped by what it physically holds), placing one router order per contributing
-- source. A single order would pin the whole qty to ONE source — the router gates the
-- others to 0 and their stock is stranded, so a buffer fed from two input containers can
-- never fill. Returns true if at least one order was placed, and the qty left unplaced.
function Planner:orderFrom(item, qty, dst, ratioNum, ratioDen)
  item = lc(item)
  local srcs = self.sources[item] or {}
  if #srcs == 0 then return false, qty end
  local function stamp()        -- record the stable recipe ratio for gateSources (out>1 fix)
    if ratioDen then local o = self.router.orders[#self.router.orders]; o.ratioNum = ratioNum; o.ratioDen = ratioDen end
  end
  local remaining, placed = qty, false
  for _, sid in ipairs(srcs) do
    if remaining <= 0 then break end
    local take = math.min(remaining, count_in(self.getProxy(sid), item))
    -- only stamp/credit a placement that ACTUALLY happened: order() returns false (and
    -- appends nothing) when there's no belt path src->dst, so stamping orders[#orders]
    -- blindly would corrupt a previous order's ratio (or index nil).
    if take > 0 and self.router:order(item, take, dst, sid) then
      stamp(); remaining = remaining - take; placed = true
    end
  end
  -- whatever the current on-hand could not cover: still order it (from the first source) so
  -- the gate AUTHORIZES that source to release as stock refills within the epoch. Without this
  -- a source that is momentarily empty at plan time (a miner/belt still catching up) would be
  -- gated shut for the whole ~2s replan interval even though demand exists.
  if remaining > 0 and self.router:order(item, remaining, dst, srcs[1]) then
    stamp(); placed = true; remaining = 0
  end
  return placed, remaining
end

-- ---- producibility (recursive) ---------------------------------------------
-- Max units of `item` that can be made from raw SOURCES, crafting through as many
-- recipe stages as needed (copper -> wire -> cable). A direct source returns its
-- available stock; a craftable item returns the best a recipe can yield given its
-- ingredients' own producibility. Cycle/depth guarded. This is what lets the planner
-- treat an intermediate (wire) as "available" even though it's only in a buffer/recipe.
function Planner:producible(item, depth, seen)
  item = lc(item); depth = depth or 0; seen = seen or {}
  if self.sources[item] then return self:available(item) end
  -- an item already sitting in a HUB buffer is available up to its on-hand (e.g. mined/
  -- imported straight into the buffer, or wire whose only supply is the hub) — so a consumer
  -- isn't judged un-producible just because its feedstock lives in a buffer rather than raw.
  local hubStock = (self.bufferOf and self.bufferOf[item]) and count_in(self.getProxy(self.bufferOf[item]), item) or 0
  if depth > 8 or seen[item] then return hubStock end
  local cands = self.recipesByProduct[item]
  if not cands then return hubStock end
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

-- Can a HUB actually supply `item` this epoch? A hub is live only if it (a) HAS stock now, or
-- (b) is being REPLENISHED — an order already fills it, or a FREE constructor can make its content.
-- A DEAD hub (empty + nothing producing into it) must NEVER be drawn from: doing so orders a
-- product whose ingredient can't exist (e.g. "craft 15192 screws" while the iron rod hub is empty
-- and no machine is free to make iron rod). The being-filled check covers the normal hub case
-- where the filling constructor is already CLAIMED (so chooseRecipe(freeOnly) is nil but the hub
-- IS being fed); the free-constructor check covers a hub not yet reached in this fill pass.
function Planner:_hubViable(item, hub)
  item = lc(item)
  if count_in(self.getProxy(hub), item) > 0 then return true end
  for _, o in ipairs(self.router.orders) do
    if o.dst == hub and o.item == item then return true end
  end
  return self:chooseRecipe(item, 1, 0, true) ~= nil
end

-- Recursively MAKE `need` of `item`: claim a free constructor per craft stage, set its
-- recipe, and (recursively) order each ingredient from its own producer. Returns the
-- producer id where `item` becomes available (a source container, or the constructor
-- that makes it), or nil if it can't be produced (no recipe, or no free constructor for
-- a stage). Each stage uses a DISTINCT free constructor (freeOnly) — a machine runs one
-- recipe.
-- cumNum/cumDen carry the CUMULATIVE recipe ratio: units of `item` (this stage's product)
-- per unit of the TERMINAL product. The top call (terminal product itself) is 1/1; each
-- recursion multiplies by the stage's ingredient.amount / product.out. Ingredient orders are
-- stamped with their ratio-to-terminal so gateSources caps the raw source by a stable ratio.
-- Returns producerId, claimedCtors (the constructors this whole sub-tree claimed) on success,
-- or nil on failure. ATOMIC: if ANY ingredient can't be produced (no free constructor, no
-- feedstock, no path), it rolls back every order it placed AND un-claims every constructor it
-- claimed — so a recipe that can only be PARTIALLY supplied (e.g. screws available but iron
-- plate uncraftable for reinforced plate) places NO orders at all, instead of releasing the
-- one available ingredient to clog the belts with stock nothing will consume.
function Planner:produce(item, need, depth, cumNum, cumDen)
  item = lc(item); depth = depth or 0; cumNum = cumNum or 1; cumDen = cumDen or 1
  if self.sources[item] then return self.sources[item][1], {} end   -- raw: first source (back-compat)
  if depth > 8 then return nil end
  local pick = self:chooseRecipe(item, need, depth, true)
  if not pick then return nil end
  local startN = #self.router.orders
  local claimed = { pick.opt.ctorId }
  self.busy[pick.opt.ctorId] = true              -- claim before recursing (no reuse)
  -- setRecipe EMPTIES the constructor's input inventory EVERY call (FIN moves input->output,
  -- even when set to the SAME recipe). The persistent loop re-plans every ~2s, so calling it
  -- unconditionally would dump partial inputs each rebuild — a constructor holding 1 of 2 wire
  -- loses it, items vanish, and it burns several copper per crafted wire. ONLY set it when the
  -- recipe actually CHANGES (compare by recipe name).
  local okc, cur = pcall(function() return pick.opt.ctor:getRecipe() end)
  local curName = okc and cur and cur.name
  if curName ~= pick.opt.recipe.name then pick.opt.ctor:setRecipe(pick.opt.recipe) end
  local function rollback()
    self.router:_truncateOrders(startN)          -- drop the partial ingredient orders
    for _, c in ipairs(claimed) do self.busy[c] = nil end   -- release the constructors
    return nil
  end
  local out = pick.opt.out or 1
  for _, ing in ipairs(pick.opt.ingredients) do
    local qty = pick.crafts * ing.amount
    local rNum, rDen = cumNum * ing.amount, cumDen * out   -- this ingredient per terminal product
    if self.sources[ing.name] then
      -- raw ingredient: split the order across ALL providing source containers, ratio-stamped.
      if not self:orderFrom(ing.name, qty, pick.opt.ctorId, rNum, rDen) then return rollback() end
    elseif self.bufferOf[ing.name] then
      -- ingredient stored in a BUFFER HUB (e.g. cable's wire in the wire buffer): DRAW from it
      -- (the hub is filled by its own enlarged fill order) rather than crafting a parallel
      -- stream; register it as a source so gateSources gates its output to this demand.
      local hub = self.bufferOf[ing.name]
      if not self:_hubViable(ing.name, hub) then return rollback() end   -- never draw from a DEAD hub
      if not self.router:order(ing.name, qty, pick.opt.ctorId, hub) then return rollback() end
      local o = self.router.orders[#self.router.orders]; o.ratioNum = rNum; o.ratioDen = rDen
      self.router.sourceItem[hub] = lc(ing.name)
    else
      -- otherwise CRAFT it on its own constructor, then order from there.
      local src, sub = self:produce(ing.name, qty, depth + 1, rNum, rDen)
      if not src then return rollback() end
      if not self.router:order(ing.name, qty, pick.opt.ctorId, src) then return rollback() end
      local o = self.router.orders[#self.router.orders]; o.ratioNum = rNum; o.ratioDen = rDen
      for _, c in ipairs(sub or {}) do claimed[#claimed + 1] = c end   -- inherit sub-tree claims
    end
  end
  return pick.opt.ctorId, claimed
end

-- ============================================================================
-- CONSTRUCTOR-POOL SCHEDULER (multi-constructor per recipe + demand-proportional
-- allocation of the shared pool + graceful drain-then-switch reallocation).
--
-- Three pieces:
--   computeDemand()  — per-item unmet UNITS, propagated through the whole craft DAG, so
--                      allocation can weigh "how behind is iron plate vs wire".
--   allocate()       — greedily hands each free pool constructor to the item with the most
--                      unmet demand it can MAKE and physically REACH a needing buffer for,
--                      decrementing that item's demand by the machine's per-epoch capacity.
--                      Several machines pile onto one item (fan-out); the split is recomputed
--                      every epoch from live demand (rebalance).
--   _fsmFeed()       — graceful reallocation: a machine reassigned to a new recipe keeps its
--                      current recipe and is NOT fed (DRAIN) until its input empties, only THEN
--                      setRecipe + resume — so an in-flight run finishes and no partial is dumped.
-- Only BUFFERED, craftable items are pooled; un-hubbed intermediates (e.g. a screw stage with
-- no buffer) stay on the existing produce() recursion (one dedicated machine per stage).
-- ============================================================================

-- per-item unmet demand (UNITS), seeded from buffer shortfalls and propagated through the DAG.
function Planner:computeDemand()
  self.demand = {}
  for _, c in ipairs(self.topo.containers or {}) do
    local item   = Planner.destItem(c)
    local target = c.target or Planner.destTarget(c)
    if item and target and not self.sources[item] then
      local root = target - count_in(self.getProxy(c.id), item)
      if root > 0 then self:addDemand(item, root, 0, {}) end
    end
  end
end
-- Accumulate `units` of demand on `item` and push the proportional demand onto each ingredient
-- of a representative recipe (crafts × ingredient.amount). An item consumed by several parents
-- accumulates the SUM. Raw sources are leaves (released by gateSources). Cycle/depth guarded.
function Planner:addDemand(item, units, depth, seen)
  item = lc(item)
  if units <= 0 or depth > 8 or seen[item] then return end
  self.demand[item] = (self.demand[item] or 0) + units
  if self.sources[item] then return end                      -- raw leaf
  local pick = self:chooseRecipe(item, units, depth, false)  -- representative recipe (sizing only)
  if not pick then return end
  seen[item] = true
  local crafts = ceil(units, pick.opt.out)
  for _, ing in ipairs(pick.opt.ingredients) do
    self:addDemand(ing.name, crafts * ing.amount, depth + 1, seen)
  end
  seen[item] = nil
end

-- per-epoch capacity (units) of one constructor running `opt`: how many it pushes before the
-- next ~2s re-plan. Drives allocation proportion only (never the order size). Coarse fallback
-- to one output batch when throughput is unknown.
function Planner:_machineCap(opt)
  local tp = opt.throughput or 0
  if tp <= 0 then return opt.out or 1 end
  return math.max(1, math.floor(tp * (self.epochSeconds or 2)))
end

-- Memoized belt-path reachability cid -> dst (findPath is a BFS; allocate/assignedReaching probe
-- the same pairs many times per epoch, and re-crawling 200 belts each probe is the kind of cost
-- that made the loop lag — cache per epoch, cleared in allocate; paths are fixed within a build).
function Planner:_canReach(cid, dst)
  self._reach = self._reach or {}
  local m = self._reach[cid]; if not m then m = {}; self._reach[cid] = m end
  local v = m[dst]
  if v == nil then v = self.router:findPath(cid, dst) ~= nil; m[dst] = v end
  return v
end

-- Does `cid` reach at least one buffer of `item` that still NEEDS filling (target - on-hand
-- + hub draw > 0)? A constructor wired to wire-buffer-B cannot fill wire-buffer-A, so pooling
-- is gated on real reachability to a needing buffer (the multi-buffer-same-item case). Memoized.
function Planner:reachesNeedingBuffer(cid, item)
  self._rnb = self._rnb or {}
  local key = tostring(cid) .. "\0" .. item
  local cached = self._rnb[key]
  if cached ~= nil then return cached end
  local v = false
  for _, c in ipairs(self.topo.containers or {}) do
    if Planner.destItem(c) == item then
      local target = c.target or Planner.destTarget(c)
      if target then
        local need = target - count_in(self.getProxy(c.id), item)
        if self.bufferOf[item] == c.id and self.hubDraw and self.hubDraw[item] then
          need = need + self.hubDraw[item]
        end
        if need > 0 and self:_canReach(cid, c.id) then v = true; break end
      end
    end
  end
  self._rnb[key] = v
  return v
end

-- Greedy demand-proportional pool allocation. Repeatedly assign the (free constructor, pooled
-- item) pair with the highest remaining unmet demand — reachable to a needing buffer and
-- actually producible — then knock that item's demand down by the machine's capacity, so the
-- next machine flows to whatever is now most behind. Multiple machines stack on one item.
function Planner:allocate()
  self.assign = {}
  self._reach, self._rnb, self._failed = {}, {}, {}   -- per-epoch memo + this-epoch rollback set
  -- POOLED items: in demand, craftable, AND with a buffer to deliver into (terminal or hub).
  local rem = {}
  for it, d in pairs(self.demand) do
    if d > 0 and self.bufferOf[it] and self.recipesByProduct[it] and not self.sources[it] then rem[it] = d end
  end
  -- per-constructor candidate options for the pooled items it can make
  local cand = {}
  for it in pairs(rem) do
    for _, opt in ipairs(self.recipesByProduct[it]) do
      cand[opt.ctorId] = cand[opt.ctorId] or {}
      cand[opt.ctorId][#cand[opt.ctorId] + 1] = { item = it, opt = opt }
    end
  end
  local free = {}
  for _, cid in ipairs(self.topo.constructors or {}) do
    if not self.busy[cid] then free[cid] = true end
  end
  while true do
    local pick
    for cid in pairs(free) do
      for _, ci in ipairs(cand[cid] or {}) do
        local d = rem[ci.item] or 0
        if d > 0 and self:reachesNeedingBuffer(cid, ci.item) and self:producible(ci.item) > 0 then
          -- anti-thrash anchor: on a demand tie, keep a machine on the recipe it already runs.
          local st = Planner._ctorState[cid]
          local anchored = st and st.recipeName == ci.opt.recipe.name or false
          if (not pick) or d > pick.score or (d == pick.score and anchored and not pick.anchored) then
            pick = { cid = cid, item = ci.item, opt = ci.opt, score = d, anchored = anchored }
          end
        end
      end
    end
    if not pick then break end
    self.assign[pick.item] = self.assign[pick.item] or {}
    self.assign[pick.item][#self.assign[pick.item] + 1] = { cid = pick.cid, opt = pick.opt }
    self.busy[pick.cid] = true
    free[pick.cid] = nil
    rem[pick.item] = math.max(0, rem[pick.item] - self:_machineCap(pick.opt))
  end
end

-- Pool constructors ASSIGNED to `item` that can physically reach `bufferId` (so the right
-- machines fill the right buffer when one item has several buffers fed by dedicated lines).
function Planner:assignedReaching(item, bufferId)
  local out = {}
  for _, ce in ipairs(self.assign[item] or {}) do
    if not (self._failed and self._failed[ce.cid]) and self:_canReach(ce.cid, bufferId) then
      out[#out + 1] = ce
    end
  end
  return out
end

-- Is constructor `cid`'s INPUT inventory empty? (FIN getInputInv; emulator mirrors it.) Drives
-- the graceful drain — a reassigned machine only switches recipe once its current run is done.
function Planner:inputEmpty(cid)
  local p = self.getProxy(cid)
  local ok, inv = pcall(function() return p:getInputInv() end)
  if ok and inv and inv.getStack then
    for i = 0, (inv.size or 0) - 1 do
      local s = inv:getStack(i)
      if s and (s.count or 0) > 0 and s.item and s.item.type then return false end
    end
    return true
  end
  return false   -- unknown shape: treat as NON-empty (conservative); DRAIN_TIMEOUT forces the switch
end

-- Graceful reallocation state machine for ONE pool constructor heading to recipe `opt`.
-- Returns true if it should be FED this epoch (place ingredient orders), false if DRAINING
-- (place product-only, no new feedstock). setRecipe is issued ONLY when the recipe actually
-- changes AND the input is already empty (or a stuck drain times out) — so FIN's
-- setRecipe-empties-input never dumps a partial run.
function Planner:_fsmFeed(cid, opt, item)
  local st = Planner._ctorState[cid]
  if not st then st = { state = "IDLE", drain = 0 }; Planner._ctorState[cid] = st end
  local wantName = opt.recipe.name
  local okc, cur = pcall(function() return opt.ctor:getRecipe() end)
  local curName = okc and cur and cur.name or nil
  if curName == wantName then                     -- already running the wanted recipe: feed
    st.state, st.recipeName, st.item, st.drain = "RUNNING", wantName, item, 0
    return true
  end
  if self:inputEmpty(cid) then                    -- recipe differs but input drained: switch now
    pcall(function() opt.ctor:setRecipe(opt.recipe) end)
    st.state, st.recipeName, st.item, st.drain, st.drainFor = "RUNNING", wantName, item, 0, nil
    return true
  end
  -- recipe differs, input not empty: DRAIN, no feed. Count consecutive epochs draining toward the
  -- SAME want — if the target keeps changing (oscillating demand) reset, so DRAIN_TIMEOUT never
  -- fires (and dumps a partial) for a recipe the drain was never actually "for".
  if st.drainFor ~= wantName then st.drain, st.drainFor = 0, wantName end
  st.drain = st.drain + 1
  if st.drain >= DRAIN_TIMEOUT then               -- stuck (mismatched residue that can't finish)
    pcall(function() opt.ctor:setRecipe(opt.recipe) end)
    st.state, st.recipeName, st.item, st.drain, st.drainFor = "RUNNING", wantName, item, 0, nil
    return true
  end
  st.state = "DRAINING"
  return false
end

-- Produce `need` of `item` on the SPECIFIC pooled constructor `cid` (running `opt`), delivering
-- to `dst`. Mirrors produce()'s ingredient handling (raw -> orderFrom; hub -> draw; un-hubbed
-- crafted -> recursive produce() on a dedicated machine) and its ATOMIC rollback (any ingredient
-- failure drops every order placed here AND un-claims cid + sub-tree constructors — so a recipe
-- that can't be fully supplied places nothing). When DRAINING, skips ingredient orders but still
-- routes the machine's finishing output to dst. Returns true on success, false on rollback.
function Planner:produceOn(cid, opt, item, need, dst)
  local startN = #self.router.orders
  local claimed = { cid }
  local function rollback()
    self.router:_truncateOrders(startN)
    for _, c in ipairs(claimed) do self.busy[c] = nil end
    -- mark cid failed THIS epoch so assignedReaching won't re-dispatch it to another buffer of
    -- the same item (it's no longer busy, so without this it could be re-grabbed -> double orders
    -- / double setRecipe). Cleared next epoch in allocate.
    self._failed = self._failed or {}; self._failed[cid] = true
    return false
  end
  -- DRAINING (recipe change pending, input not yet empty): place NOTHING. No feedstock is
  -- routed to it ("no more gets routed to it"), and we do NOT place a want-item product order —
  -- the machine is still finishing its CURRENT recipe, so its output is the OLD item, not `item`;
  -- a want-item order here would mis-route. Any finishing output is handled generically by the
  -- router's _overflow (routes a no-order item to its own buffer / sink). It crafts `item` only
  -- once it has switched (a later epoch, feed=true).
  if not self:_fsmFeed(cid, opt, item) then return true end
  local crafts = ceil(need, opt.out)
  for _, ing in ipairs(opt.ingredients) do
    local qty = crafts * ing.amount
    local rNum, rDen = ing.amount, opt.out            -- this stage fills its own hub: one-hop ratio
    if self.sources[ing.name] then
      if not self:orderFrom(ing.name, qty, cid, rNum, rDen) then return rollback() end
    elseif self.bufferOf[ing.name] then
      local hub = self.bufferOf[ing.name]
      if not self:_hubViable(ing.name, hub) then return rollback() end   -- never draw from a DEAD hub
      if not self.router:order(ing.name, qty, cid, hub) then return rollback() end
      local o = self.router.orders[#self.router.orders]; o.ratioNum = rNum; o.ratioDen = rDen
      self.router.sourceItem[hub] = lc(ing.name)
    else
      local src, sub = self:produce(ing.name, qty, 0, rNum, rDen)
      if not src then return rollback() end
      if not self.router:order(ing.name, qty, cid, src) then return rollback() end
      local o = self.router.orders[#self.router.orders]; o.ratioNum = rNum; o.ratioDen = rDen
      for _, c in ipairs(sub or {}) do claimed[#claimed + 1] = c end
    end
  end
  -- product order: this machine -> the buffer. Ingredient orders point their `term` at it so
  -- gateSources caps each source against the BUFFER's delivery × recipe ratio (see fillBuffer).
  -- assignedReaching pre-checks the path, so this should not fail; if it does, roll back so the
  -- ingredient orders aren't left gating against themselves (term = self) and over-releasing.
  if not self.router:order(item, need, dst, cid) then return rollback() end
  local terminal = self.router.orders[#self.router.orders]
  for i = startN + 1, #self.router.orders - 1 do self.router.orders[i].term = terminal end
  return true
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

-- DRY-RUN the craft tree of `item` to tally how much of each HUB item it will DRAW, WITHOUT
-- placing orders or claiming constructors. fillAll runs this for every craftable buffer
-- BEFORE filling, so a hub's own fill order is enlarged by the total drawn THROUGH it (else
-- the hub is permanently under-fed by the draw amount, and the raw source feeding it is
-- never authorized for the throughput it must pass on).
function Planner:tallyDraws(item, need, depth, seen)
  item = lc(item); depth = depth or 0
  if self.sources[item] or depth > 8 or (seen and seen[item]) then return end
  local pick = self:chooseRecipe(item, need, depth, false)
  if not pick then return end
  seen = seen or {}; seen[item] = true
  for _, ing in ipairs(pick.opt.ingredients) do
    local qty = pick.crafts * ing.amount
    if self.sources[ing.name] then                                   -- raw: no hub draw
    elseif self.bufferOf[ing.name] then
      self.hubDraw[ing.name] = (self.hubDraw[ing.name] or 0) + qty    -- DRAWN from this hub
    else
      self:tallyDraws(ing.name, qty, depth + 1, seen)                 -- crafted: recurse
    end
  end
  seen[item] = nil
end

function Planner:fillBuffer(bufferId, item, target)
  if not item then return false, "not a destination: " .. tostring(bufferId) end
  local current = count_in(self.getProxy(bufferId), item)
  local need = target - current
  -- if THIS buffer is the hub others DRAW from, produce extra so it holds its target AND
  -- supplies the consumers (the draw total was tallied in fillAll's pre-pass).
  if self.bufferOf[item] == bufferId and self.hubDraw and self.hubDraw[item] then
    need = need + self.hubDraw[item]
  end
  if need <= 0 then return true, "already full" end

  -- direct source available? route it straight, SPLIT across every providing source.
  if self.sources[item] then
    local qty = math.min(need, self:available(item))
    if qty > 0 then self:orderFrom(item, qty, bufferId) end
    return true, ("direct %d %s"):format(qty, item)
  end

  -- otherwise craft it — possibly through multiple stages (copper -> wire -> cable).
  if self:producible(item) <= 0 then return false, "no recipe / no ingredients for " .. item end

  -- POOL PATH: allocate() may have assigned several constructors to this item. Split the need
  -- across the ones that can REACH this buffer (so the right machines fill the right buffer when
  -- an item has several buffers on dedicated lines), each crafting its share on its own machine.
  local ctors = self:assignedReaching(item, bufferId)
  if #ctors > 0 then
    local k = #ctors
    local base, extra = math.floor(need / k), need % k
    local placed = 0
    for i, ce in ipairs(ctors) do
      local share = base + (i <= extra and 1 or 0)
      if share > 0 and self:produceOn(ce.cid, ce.opt, item, share, bufferId) then placed = placed + 1 end
    end
    -- if at least one machine took its share, we're done. If ALL of them rolled back (no feasible
    -- ingredients this epoch), fall through to the single-machine produce() fallback below rather
    -- than claim success with zero orders placed.
    if placed > 0 then return true, ("pooled %d %s across %d/%d ctor"):format(need, item, placed, k) end
  end

  -- FALLBACK (no pooled constructor reaches this buffer): the original single-machine produce()
  -- recursion. Keeps the un-hubbed / un-allocated cases (deep craft trees, contended pools)
  -- working exactly as before.
  local startN = #self.router.orders          -- ingredient orders produce() places land after here
  local producer = self:produce(item, need, 0)
  if not producer then return false, "no free constructor to craft " .. item end
  self.router:order(item, need, bufferId, producer)   -- TERMINAL product order: producer -> buffer
  -- point every ingredient order in this craft sub-tree at the terminal product order, so
  -- gateSources gates each raw source against the BUFFER's delivery (× recipe ratio), not
  -- against the ingredient's arrival at a constructor (which would over-release unboundedly).
  local terminal = self.router.orders[#self.router.orders]
  for i = startN + 1, #self.router.orders - 1 do self.router.orders[i].term = terminal end
  return true, ("craft %d %s"):format(need, item)
end

--- Fill every destination in the topology (a container resolving to an item via
--- c.buffer/c.output or a *_(Buffer|Output)_<n> name) that has a `target`, then
--- run the router until orders complete.
function Planner:fillAll()
  self:scan()
  -- PASS 1 (dry run): tally how much of each hub item is DRAWN through it by all the craftable
  -- buffers, so PASS 2 can enlarge each hub's own fill to cover its draws.
  self.hubDraw = {}
  for _, c in ipairs(self.topo.containers or {}) do
    local item = Planner.destItem(c)
    local target = c.target or Planner.destTarget(c)
    if item and target and not self.sources[item] and self:producible(item) > 0 then
      self:tallyDraws(item, target - count_in(self.getProxy(c.id), item), 0, {})
    end
  end
  -- PASS 1.5: size per-item unmet demand across the whole craft DAG, then hand the shared
  -- constructor pool out demand-proportionally (multi-constructor per recipe; graceful
  -- drain-then-switch reallocation lives in produceOn's FSM). hubDraw is ready, so
  -- reachesNeedingBuffer sees the true (hold + draw) need.
  self:computeDemand()
  self:allocate()
  -- PASS 2: fill every buffer (pooled split where allocated, else single-machine produce()).
  local plan = {}
  for _, c in ipairs(self.topo.containers or {}) do
    local item = Planner.destItem(c)
    local target = c.target or Planner.destTarget(c)
    if item and target then
      local ok, msg = self:fillBuffer(c.id, item, target)
      plan[#plan + 1] = ("%s: %s"):format(c.id, msg)
    end
  end
  -- now that all orders exist: (1) compute per-edge quota from their stored paths so
  -- routing is balanced and node-agnostic, then (2) gate each source at its own output
  -- connector so it releases EXACTLY the demanded total (un-demanded sources release nothing).
  if self.router and self.router.buildQuota then self.router:buildQuota() end
  if self.router and self.router.gateSources then self.router:gateSources() end
  return plan
end

function Planner:run(maxLoops) return self.router:run(maxLoops) end

return Planner
