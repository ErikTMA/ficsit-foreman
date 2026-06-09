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


function Planner.new(topology, router, getProxy, epochSeconds)
  local self = setmetatable({}, Planner)
  self.topo = topology
  self.router = router
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
  for _, c in ipairs(topology.containers or {}) do
    local di = Planner.destItem(c)
    if di and not self.bufferOf[di] then self.bufferOf[di] = c.id end
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

-- Order `qty` of a raw item to `dst`, SPLIT across every source container that provides it
-- (each capped by what it physically holds), placing one router order per contributing
-- source. A single order would pin the whole qty to ONE source — the router gates the
-- others to 0 and their stock is stranded, so a buffer fed from two input containers can
-- never fill. Returns true if at least one order was placed, and the qty left unplaced.
function Planner:orderFrom(item, qty, dst, ratioNum, ratioDen, toInput)
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
    if take > 0 and self.router:order(item, take, dst, sid, toInput) then
      stamp(); remaining = remaining - take; placed = true
    end
  end
  -- whatever the current on-hand could not cover: still order it (from the first source) so
  -- the gate AUTHORIZES that source to release as stock refills within the epoch. Without this
  -- a source that is momentarily empty at plan time (a miner/belt still catching up) would be
  -- gated shut for the whole ~2s replan interval even though demand exists.
  if remaining > 0 and self.router:order(item, remaining, dst, srcs[1], toInput) then
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
  if count_in(self.getProxy(hub), item) > 0 then return true end             -- has stock
  if self.served and self.served[item] and #self.served[item] > 0 then return true end  -- a machine is ASSIGNED to fill it this epoch (order-independent of execution sequence)
  for _, o in ipairs(self.router.orders) do
    if o.dst == hub and o.item == item then return true end                  -- already being filled
  end
  return self:chooseRecipe(item, 1, 0, true) ~= nil                          -- a free machine can fill it
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
-- Order every ingredient of recipe `opt` (for `crafts` batches) INTO machine `cid`. Shared by
-- produce() (recursive un-hubbed sub-production) and produceFor() (the assigned-machine path).
--   raw source       -> orderFrom (split across providers, ratio-stamped)
--   hub-buffered      -> DRAW from the item's hub buffer (filled by its own machine), if viable
--   un-hubbed crafted -> recursively produce() it on a free machine, order from there
-- cumNum/cumDen carry the cumulative ratio of this ingredient per TERMINAL product (for gating).
-- Returns ok, subClaimed (constructors the recursion claimed) — or false on any failure (caller
-- rolls back). Places NO product order; the caller does that.
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

function Planner:_orderIngredients(opt, crafts, cid, cumNum, cumDen, depth)
  local sub, out = {}, opt.out or 1
  local ports = self:_assignPorts(cid, opt)           -- ingredientName -> toInput (nil for single-input machines)
  -- ATOMIC: if any ingredient fails partway, un-claim the constructors EARLIER ingredients' recursive
  -- produce() already claimed (else they leak busy + a setRecipe, re-churning every epoch). The
  -- caller truncates the orders; this releases the machines.
  local function fail() for _, c in ipairs(sub) do self.busy[c] = nil end; return false end
  for _, ing in ipairs(opt.ingredients) do
    local qty = crafts * ing.amount
    local rNum, rDen = cumNum * ing.amount, cumDen * out   -- this ingredient per terminal product
    local port = ports and ports[ing.name]                 -- assigned input port (nil = route normally)
    if self.sources[ing.name] then
      if not self:orderFrom(ing.name, qty, cid, rNum, rDen, port) then return fail() end
    elseif self.bufferOf[ing.name] then
      local hub = self.bufferOf[ing.name]
      if not self:_hubViable(ing.name, hub) then return fail() end   -- never draw from a DEAD hub
      if not self.router:order(ing.name, qty, cid, hub, port) then return fail() end
      local o = self.router.orders[#self.router.orders]; o.ratioNum = rNum; o.ratioDen = rDen
      self.router.sourceItem[hub] = lc(ing.name)
    else
      local src, sc = self:produce(ing.name, qty, (depth or 0) + 1, rNum, rDen)
      if not src then return fail() end
      for _, c in ipairs(sc or {}) do sub[#sub + 1] = c end   -- record claims BEFORE the order so fail() releases them
      if not self.router:order(ing.name, qty, cid, src, port) then return fail() end
      local o = self.router.orders[#self.router.orders]; o.ratioNum = rNum; o.ratioDen = rDen
    end
  end
  return true, sub
end

-- Recursively MAKE `need` of an UN-HUBBED crafted `item` on a FREE machine (claimed via
-- chooseRecipe), set its recipe (only on change — FIN setRecipe empties the input), order its
-- ingredients (via _orderIngredients), and return the producer id + claimed constructors — or nil
-- on any failure (atomic rollback: drops its orders AND un-claims its machines, so a partially-
-- suppliable recipe places nothing). This is the deep-craft-tree path (e.g. deeptree's iron rod ->
-- screw, which have no buffer); buffered items go through the assignment layer instead.
function Planner:produce(item, need, depth, cumNum, cumDen)
  item = lc(item); depth = depth or 0; cumNum = cumNum or 1; cumDen = cumDen or 1
  if self.sources[item] then return self.sources[item][1], {} end   -- raw: first source (back-compat)
  if depth > 8 then return nil end
  local pick = self:chooseRecipe(item, need, depth, true)
  if not pick then return nil end
  local startN = #self.router.orders
  local claimed = { pick.opt.ctorId }
  self.busy[pick.opt.ctorId] = true
  local okc, cur = pcall(function() return pick.opt.ctor:getRecipe() end)
  if (okc and cur and cur.name) ~= pick.opt.recipe.name then pick.opt.ctor:setRecipe(pick.opt.recipe) end
  local ok, sub = self:_orderIngredients(pick.opt, pick.crafts, pick.opt.ctorId, cumNum, cumDen, depth)
  if not ok then
    self.router:_truncateOrders(startN)
    for _, c in ipairs(claimed) do self.busy[c] = nil end
    return nil
  end
  for _, c in ipairs(sub or {}) do claimed[#claimed + 1] = c end
  return pick.opt.ctorId, claimed
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
function Planner:computeNeed()
  self.need, self.hubDraw = {}, {}     -- hubDraw is tallied during propagation (each hub-buffered
  for _, c in ipairs(self.topo.containers or {}) do          -- ingredient is a DRAW from its hub)
    local item = Planner.destItem(c)
    local target = c.target or Planner.destTarget(c)
    if item and target and not self.sources[item] then
      self:_addNeed(item, target - count_in(self.getProxy(c.id), item), 0, {})
    end
  end
end
function Planner:_addNeed(item, units, depth, seen)
  item = lc(item)
  if units <= 0 or depth > 8 or seen[item] then return end
  if self:producible(item) <= 0 then return end              -- producible cap (subsumes dead-hub)
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
    if n > 0 and self.bufferOf[it] and self.recipesByProduct[it] and not self.sources[it] then pool[it] = n end
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
  for _, cid in ipairs(self.topo.constructors or {}) do
    if not Planner._assign[cid] then
      local okc, rec = pcall(function() return self.getProxy(cid):getRecipe() end)
      local it = okc and rec and rec.name and self.itemOfRecipe[tostring(rec.name)]
      if it and pool[it] and cap[cid] and cap[cid][it] then
        Planner._assign[cid] = { recipe = cap[cid][it].recipe.name, item = it, opt = cap[cid][it], since = Planner._epoch - MIN_DWELL }
      end
    end
  end
  local function servedN(it) local n = 0; for _, a in pairs(Planner._assign) do if a.item == it then n = n + 1 end end; return n end
  for cid, a in pairs(Planner._assign) do if not pool[a.item] then Planner._assign[cid] = nil end end   -- drop satisfied
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
  for _, cid in ipairs(self.topo.constructors or {}) do if not Planner._assign[cid] then free[cid] = true end end
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
end

-- total hub-fill amount for an item (Σ its needing buffers' need, incl. hub draw).
function Planner:_fillAmount(item)
  local amt = 0; for _, b in ipairs(self:_needingBuffers(item)) do amt = amt + b.need end; return amt
end

-- the buffer(s) of `item` that still need filling: { {id=, need=} ... }. The hub (bufferOf) carries
-- the draw on top of its own shortfall; other buffers just their shortfall.
function Planner:_needingBuffers(item)
  item = lc(item); local out = {}
  for _, c in ipairs(self.topo.containers or {}) do
    if Planner.destItem(c) == item then
      local target = c.target or Planner.destTarget(c)
      if target then
        local need = target - count_in(self.getProxy(c.id), item)
        if self.bufferOf[item] == c.id and self.hubDraw and self.hubDraw[item] then need = need + self.hubDraw[item] end
        if need > 0 then out[#out + 1] = { id = c.id, need = need } end
      end
    end
  end
  return out
end

-- EXECUTION: machine `cid` makes its `share` of `item`'s hub fill, delivered to the item's buffer.
-- Lossless: if the live recipe ≠ assigned, switch only when canSwitch, else DRAIN (route the
-- current recipe's finishing output, no new feed). Atomic rollback on any ingredient failure.
function Planner:produceFor(cid, item, share, dst)
  -- use the EXACT recipe assign() chose (stored on _assign) — not a re-pick by first-opt, which can
  -- disagree with the demand/hub-draw layers and set an infeasible alternate when one machine knows
  -- several recipes for the same product.
  local a = Planner._assign[cid]
  local opt = a and a.opt
  dst = dst or self.bufferOf[item]   -- which buffer of `item` to deliver to (multi-buffer items)
  if not opt or not dst then return false end
  local startN = #self.router.orders
  local claimed = { cid }
  local function rollback() self.router:_truncateOrders(startN); for _, c in ipairs(claimed) do self.busy[c] = nil end; return false end
  local okc, cur = pcall(function() return opt.ctor:getRecipe() end)
  local live = okc and cur and cur.name or nil
  if live ~= opt.recipe.name then
    if self:canSwitch(cid, opt) then
      pcall(function() opt.ctor:setRecipe(opt.recipe) end)
    else
      local curItem = live and self.itemOfRecipe[tostring(live)]   -- DRAIN: route finishing output
      if curItem and self.bufferOf[curItem] then
        self.router:order(curItem, math.max(1, self:_fillAmount(curItem)), self.bufferOf[curItem], cid)
      end
      return true
    end
  end
  local crafts = ceil(share, opt.out)
  local ok, sub = self:_orderIngredients(opt, crafts, cid, 1, 1, 0)
  if not ok then return rollback() end
  for _, c in ipairs(sub or {}) do claimed[#claimed + 1] = c end
  if self.router:order(item, share, dst, cid) then
    local terminal = self.router.orders[#self.router.orders]
    for i = startN + 1, #self.router.orders - 1 do self.router.orders[i].term = terminal end
  end
  return true
end

--- Fill every destination: DEMAND -> ASSIGNMENT -> EXECUTION, then edge-quota + source gating.
function Planner:fillAll()
  self:scan()
  self:computeNeed()     -- need[] for ranking + hubDraw[] for hub-fill sizing (folded into one pass)
  self:assign()
  local plan = {}
  -- direct raw-source buffers route straight (no machine)
  for _, c in ipairs(self.topo.containers or {}) do
    local item = Planner.destItem(c); local target = c.target or Planner.destTarget(c)
    if item and target and self.sources[item] then
      local qty = math.min(target - count_in(self.getProxy(c.id), item), self:available(item))
      if qty > 0 then self:orderFrom(item, qty, c.id) end
      plan[#plan + 1] = ("%s: direct %s"):format(tostring(c.id):sub(1, 6), item)
    end
  end
  -- assigned machines fill their item's buffer(s). Common case = ONE buffer per item: fan all its
  -- machines into it, splitting the (hold + draw) need. RARE case = several buffers for one item on
  -- dedicated lines: route each machine to a needing buffer it can REACH (per-buffer findPath only
  -- here, so the common path stays cheap).
  for item, cids in pairs(self.served or {}) do
    local buffers = self:_needingBuffers(item)
    if #buffers == 1 then
      local amt, k = buffers[1].need, #cids
      local base, extra, placed = math.floor(amt / k), amt % k, 0
      for i, cid in ipairs(cids) do
        local sh = base + (i <= extra and 1 or 0)
        if sh > 0 and self:produceFor(cid, item, sh, buffers[1].id) then placed = placed + 1 end
      end
      plan[#plan + 1] = ("%s: %d across %d/%d ctor"):format(item, amt, placed, k)
    elseif #buffers > 1 then
      for _, cid in ipairs(cids) do                 -- each machine -> a reachable needing buffer (max remaining)
        local best
        for _, b in ipairs(buffers) do
          if b.need > 0 and self.router:findPath(cid, b.id) and (not best or b.need > best.need) then best = b end
        end
        if best and self:produceFor(cid, item, best.need, best.id) then best.need = 0 end
      end
      plan[#plan + 1] = ("%s: across %d buffers"):format(item, #buffers)
    end
  end
  if self.router and self.router.buildQuota then self.router:buildQuota() end
  if self.router and self.router.gateSources then self.router:gateSources() end
  return plan
end

function Planner:run(maxLoops) return self.router:run(maxLoops) end

return Planner
