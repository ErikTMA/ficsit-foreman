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

function Planner.new(topology, router, getProxy)
  local self = setmetatable({}, Planner)
  self.topo = topology
  self.router = router
  self.getProxy = getProxy or function(id) return component.proxy(id) end
  self.recipesByProduct = {}     -- itemName -> list of recipe options
  self.busy = {}                 -- ctorId -> true once assigned this planning pass
  self.sources = {}              -- itemName -> source container id (declared provides)
  for _, c in ipairs(topology.containers or {}) do
    if c.provides then self.sources[c.provides] = c.id end
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
        ings[#ings + 1] = { name = ia.type.name, amount = ia.amount }
        totalIn = totalIn + ia.amount
      end
      local duration = recipe.duration or 1
      for _, pa in ipairs(recipe:getProducts()) do
        local list = self.recipesByProduct[pa.type.name] or {}
        list[#list + 1] = {
          recipe = recipe, ctorId = cid, ctor = ctor,
          out = pa.amount, ingredients = ings, totalIn = totalIn,
          duration = duration,
          throughput = pa.amount / duration,   -- output per minute decides when stock is plentiful
        }
        self.recipesByProduct[pa.type.name] = list
      end
    end
  end
end

-- ---- inventory reads (FIN-faithful: getInventories -> getStack) -------------
local function count_in(proxy, item)
  local invs = proxy:getInventories()
  local total = 0
  for _, inv in ipairs(invs) do
    for i = 0, inv.size - 1 do
      local stack = inv:getStack(i)
      if stack and stack.item.type.name == item then total = total + stack.count end
    end
  end
  return total
end

-- total available of an item across all declared source containers
function Planner:available(item)
  local n = 0
  for _, c in ipairs(self.topo.containers or {}) do
    if c.provides == item then n = n + count_in(self.getProxy(c.id), item) end
  end
  return n
end

-- ---- recipe selection ------------------------------------------------------
-- Returns { opt, crafts, produced } or nil if nothing can be made.
--   * if a recipe can fully satisfy the need from available stock, pick the one
--     with the highest THROUGHPUT (output per minute = out/duration).
--   * otherwise pick the one that yields the MOST from what's available.
-- Constructors already assigned this pass (self.busy) are skipped unless none else
-- is available, so multiple constructors naturally take on different products.
function Planner:chooseRecipe(item, need)
  local cands = self.recipesByProduct[item]
  if not cands then return nil end
  local function evaluate(allowBusy)
    local full, scarce
    for _, opt in ipairs(cands) do
      if allowBusy or not self.busy[opt.ctorId] then
        local craftsPossible = math.huge
        for _, ing in ipairs(opt.ingredients) do
          craftsPossible = math.min(craftsPossible, math.floor(self:available(ing.name) / ing.amount))
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
  return evaluate(false) or evaluate(true)   -- prefer a free constructor
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

function Planner:fillBuffer(bufferId, item, target)
  if not item then return false, "not a destination: " .. tostring(bufferId) end
  local current = count_in(self.getProxy(bufferId), item)
  local need = target - current
  if need <= 0 then return true, "already full" end

  -- direct source available? route it straight.
  if self.sources[item] then
    local qty = math.min(need, self:available(item))
    if qty > 0 then self.router:order(item, qty, bufferId) end
    return true, ("direct %d %s"):format(qty, item)
  end

  -- otherwise craft it.
  local pick = self:chooseRecipe(item, need)
  if not pick then return false, "no recipe / no ingredients for " .. item end
  self.busy[pick.opt.ctorId] = true   -- this constructor is now committed this pass
  pick.opt.ctor:setRecipe(pick.opt.recipe)
  for _, ing in ipairs(pick.opt.ingredients) do
    self.router:order(ing.name, pick.crafts * ing.amount, pick.opt.ctorId, self.sources[ing.name])
  end
  self.router:order(item, pick.produced, bufferId, pick.opt.ctorId)  -- product src = constructor
  return true, ("craft %d %s via '%s' (%d crafts)"):format(pick.produced, item, pick.opt.recipe.name, pick.crafts)
end

--- Fill every destination in the topology (a container resolving to an item via
--- c.buffer/c.output or a *_(Buffer|Output)_<n> name) that has a `target`, then
--- run the router until orders complete.
function Planner:fillAll()
  self:scan()
  local plan = {}
  for _, c in ipairs(self.topo.containers or {}) do
    local item = Planner.destItem(c)
    local target = c.target or Planner.destTarget(c)
    if item and target then
      local ok, msg = self:fillBuffer(c.id, item, target)
      plan[#plan + 1] = ("%s: %s"):format(c.id, msg)
    end
  end
  return plan
end

function Planner:run(maxLoops) return self.router:run(maxLoops) end

return Planner
