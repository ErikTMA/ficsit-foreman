-- app.lua — FICSIT Foreman entry/wiring (PRODUCT code).
-- Shared by the LITE and FULL distributions.
--
--   App.run({ Router=, Planner=, Namer=? }, topology, opts)
--     opts.getProxy  — component resolver (default component.proxy)
--     opts.maxLoops  — router run cap
--
-- If a Namer is provided it (1) auto-assigns demand-driven containers
-- (auto_buffer/auto_output → the next item the machines can make), then (2) does a
-- content-based naming pass (input/output/buffer → <Item>_<Keyword>_<N>). Then the
-- router + planner run against the (possibly auto-extended) topology.
--
-- Returns router, planner (for inspection/tests).

local App = {}

-- Discover, from every manufacturer machine's recipes (constructors / assemblers /
-- fabricators) via reflection:
--   products — ordered, de-duped list of items the factory CAN make (candidate pool)
--   usage    — item -> TRANSITIVE demand weight = how many distinct items depend on
--              it across the whole recipe tree. Iron plate scores high because it is
--              consumed by reinforced iron plate, which is consumed by modular frames,
--              etc. — its demand propagates up the dependency graph, not just its
--              direct uses. Lets auto-assignment reinforce the most-needed items.
function App.deriveProducts(topology, getProxy)
  local products, seen = {}, {}
  local consumers, items = {}, {}   -- consumers[ing] = {prod=true}; items = set of all names
  local lists = { topology.constructors, topology.assemblers, topology.fabricators, topology.machines }
  for _, list in ipairs(lists) do
    for _, mid in ipairs(list or {}) do
      local ok, m = pcall(getProxy, mid)
      if ok and m and m.getRecipes then
        for _, r in ipairs(m:getRecipes()) do
          local prods, ings = {}, {}
          for _, p in ipairs(r:getProducts()) do
            local nm = p.type and p.type.name
            if nm then
              prods[#prods + 1] = nm; items[nm] = true
              if not seen[nm] then seen[nm] = true; products[#products + 1] = nm end
            end
          end
          for _, ing in ipairs(r:getIngredients()) do
            local nm = ing.type and ing.type.name
            if nm then ings[#ings + 1] = nm; items[nm] = true end
          end
          for _, ing in ipairs(ings) do
            consumers[ing] = consumers[ing] or {}
            for _, prod in ipairs(prods) do consumers[ing][prod] = true end
          end
        end
      end
    end
  end
  -- transitive consumer reach (with cycle guard): weight = #distinct downstream items
  local function reach(item, acc, onpath)
    for prod in pairs(consumers[item] or {}) do
      if not acc[prod] and not onpath[prod] then
        acc[prod] = true; onpath[prod] = true; reach(prod, acc, onpath); onpath[prod] = nil
      end
    end
    return acc
  end
  local usage = {}
  for item in pairs(items) do
    local acc = reach(item, {}, { [item] = true })
    local n = 0; for _ in pairs(acc) do n = n + 1 end
    usage[item] = n
  end
  return products, usage
end

-- ---- nick-convention parsing (auto-mode) ----------------------------------
local function destOf(nick)   -- <Item>_<buffer|output>_<n>[_<target>] -> item, role, target
  nick = tostring(nick)
  local prefix, kw, _n, tgt = nick:match("^(.-)_(%a+)_(%d+)_(%d+)$")
  if not (prefix and (kw:lower() == "buffer" or kw:lower() == "output")) then
    prefix, kw = nick:match("^(.-)_(%a+)_(%d+)$"); tgt = nil
  end
  if prefix and (kw:lower() == "buffer" or kw:lower() == "output") then
    return prefix:gsub("_", " "):lower(), kw:lower(), tgt and tonumber(tgt) or nil
  end
end
local function sourceOf(nick)  -- <Item>_input_<n> -> item ; "input" -> "" (use content)
  nick = tostring(nick)
  local prefix = nick:match("^(.-)_input_%d+$")
  if prefix then return prefix:gsub("_", " "):lower() end
  if nick:lower() == "input" then return "" end
end
local function contentItem(p)  -- the single item type currently in a container, or nil
  if not p.getInventories then return nil end
  for _, inv in ipairs(p:getInventories()) do
    for i = 0, (inv.size or 0) - 1 do local s = inv:getStack(i); if s and s.count > 0 then return s.item.type.name end end
  end
end
local function capacityOf(p, item)  -- slots * stack max (fill-to-capacity)
  local inv = p.getInventories and p:getInventories()[1]
  local max = (findItem and findItem(item) and findItem(item).max) or 100
  return (inv and inv.size or 24) * max
end

-- Build a topology purely from the live network: crawl belts (Discover) and read
-- each container's role/item/target from its nick. No declared table needed.
function App.discoverTopology(modules, getProxy)
  local topo = modules.Discover.run({ getProxy = getProxy })
  for _, c in ipairs(topo.containers) do
    local p = getProxy(c.id); local nick = (p and p.nick) or ""
    if tostring(nick):match("^DEFAULT_OUT_%d+$") then
      c.isDefault = true
    else
      local src = sourceOf(nick)
      if src ~= nil then
        c.provides = (src ~= "" and src) or contentItem(p)
      else
        local item, role, tgt = destOf(nick)
        if item then c[role] = item; c.target = tgt or capacityOf(p, item) end
      end
    end
  end
  return topo
end

function App.run(modules, topology, opts)
  opts = opts or {}
  local getProxy = opts.getProxy or function(id) return component.proxy(id) end
  if (not topology or opts.discover) and modules.Discover then
    topology = App.discoverTopology(modules, getProxy)   -- paste-and-go: no declared topology
  end
  if modules.Namer then
    local products, usage = App.deriveProducts(topology, getProxy)
    -- optional explicit priority via topology.wishlist; else what the machines make
    local candidates = topology.wishlist or products
    modules.Namer.autoAssign(topology, { getProxy = getProxy, candidates = candidates, usage = usage })
    modules.Namer.new(getProxy):scan()
  end
  local router  = modules.Router.new(topology, getProxy)
  local planner = modules.Planner.new(topology, router, getProxy)
  planner:fillAll()
  router:install()
  planner:run(opts.maxLoops)
  return router, planner
end

return App
