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

-- Case-insensitive item names (reflection = canonical/Title case, nicks = lowercase).
local function lc(s) return s and tostring(s):lower() or nil end

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
            local nm = p.type and lc(p.type.name)
            if nm then
              prods[#prods + 1] = nm; items[nm] = true
              if not seen[nm] then seen[nm] = true; products[#products + 1] = nm end
            end
          end
          for _, ing in ipairs(r:getIngredients()) do
            local nm = ing.type and lc(ing.type.name)
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
local function sourceOf(nick)  -- <Item>_Input_<n> -> item ; "input" -> "" (use content)
  nick = tostring(nick)
  -- case-insensitive on the keyword: the namer writes Title-case ("Iron_Ingot_Input_2"),
  -- so a literal lowercase "_input_" match would never fire on a re-discovered nick.
  local prefix, kw = nick:match("^(.-)_(%a+)_%d+$")
  if prefix and kw:lower() == "input" then return prefix:gsub("_", " "):lower() end
  if nick:lower() == "input" then return "" end
end
local function contentItem(p)  -- the single item type currently in a container, or nil
  if not p.getInventories then return nil end
  for _, inv in ipairs(p:getInventories()) do
    for i = 0, (inv.size or 0) - 1 do
      local s = inv:getStack(i)
      -- empty slots return a 0-count stack with nil item.type in-game — guard
      if s and (s.count or 0) > 0 and s.item and s.item.type then return lc(s.item.type.name) end
    end
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

-- (Re)build the whole control state from the live network: in auto mode re-crawl
-- the belt graph (so containers/machines ADDED while running are picked up), re-derive
-- products, (re)assign demand-driven containers, content-name sacred-keyword ones,
-- then make a fresh router+planner and place fill orders. A declared topology is kept
-- as-is (no re-crawl) but still re-planned. Renaming/auto-assign are idempotent —
-- already-named nicks persist in-game, so repeated rebuilds are stable.
function App.build(modules, declared, getProxy, opts)
  local topo = declared
  if (not topo or opts.discover) and modules.Discover then
    topo = App.discoverTopology(modules, getProxy)
  end
  if modules.Namer then
    local products, usage = App.deriveProducts(topo, getProxy)
    local candidates = topo.wishlist or products          -- explicit priority else machine-makeable
    modules.Namer.autoAssign(topo, { getProxy = getProxy, candidates = candidates, usage = usage })
    modules.Namer.new(getProxy):scan()
  end
  local router  = modules.Router.new(topo, getProxy)
  local planner = modules.Planner.new(topo, router, getProxy)
  router:listenAll()        -- listen to all splitters/mergers (faster reactions)
  local plan = planner:fillAll()
  router:pump()             -- level-triggered: drain any items already held in codeables
  App.report(topo, planner, plan, opts)
  return router, planner, topo
end

-- One concise observability line per build + the plan, so "nothing happening" is never
-- silent: you can see exactly what was discovered (sources/buffers/belts) and whether
-- any orders were placed. Set opts.quiet=true to suppress once it's working.
function App.report(topo, planner, plan, opts)
  if (opts and opts.quiet) or not (computer and computer.log) then return end
  local src, buf = 0, 0
  for _, c in ipairs(topo.containers or {}) do
    if c.provides then src = src + 1 end
    if c.buffer or c.output then buf = buf + 1 end
  end
  local nc, ns, nm, nk, nb, no =
    #(topo.containers or {}), #(topo.splitters or {}), #(topo.mergers or {}),
    #(topo.constructors or {}), #(topo.belts or {}), #(planner.router.orders or {})
  -- only log when the discovered SHAPE changes — the loop rebuilds every couple of
  -- seconds and logging each tick floods the console.
  local sig = table.concat({ nc, src, buf, ns, nm, nk, nb, no }, ",")
  if sig == App._lastReport then return end
  App._lastReport = sig
  computer.log(1, ("[Foreman] discovered: %d containers (%d src, %d buf), %d splitters, %d mergers, %d machines, %d belts; %d orders")
    :format(nc, src, buf, ns, nm, nk, nb, no))
  for _, line in ipairs(plan or {}) do computer.log(1, "[Foreman]   plan: " .. line) end
  if src == 0 then computer.log(2, "[Foreman] no SOURCE containers — nick an input '<Item>_input_1' (or bare 'input')") end
  if nb == 0 then computer.log(2, "[Foreman] no BELTS discovered — connect buildings with real belts (codeable splitters/mergers need belted ports; beltless 'snap' mods like DirectToSplitter don't transfer)") end
end

function App.run(modules, topology, opts)
  opts = opts or {}
  local getProxy = opts.getProxy or function(id) return component.proxy(id) end
  local declared = topology                       -- nil => auto-discover (and re-discover)

  -- One long-lived listener delegating to the CURRENT router; rebuilds swap the
  -- router instance in `ctx` rather than re-registering (no duplicate listeners).
  local ctx = {}
  ctx.router, ctx.planner = App.build(modules, declared, getProxy, opts)
  event.registerListener(event.filter{ event = "ItemRequest" },
    function(_, sender, a, b) ctx.router:_dispatch(sender, a, b) end)

  if opts.once then
    -- batch mode (tests / one-shot): drain current routing work and return.
    ctx.planner:run(opts.maxLoops)
    return ctx.router, ctx.planner
  end

  -- IN-GAME DEFAULT: a persistent control loop, LEVEL-TRIGGERED. Each iteration pumps
  -- (actively drains every splitter/merger input — robust against missed ItemRequest
  -- edges, the cause of "items stuck at the merger"). If the pump moved nothing, block
  -- on event.pull (woken by a new ItemRequest, or a timeout) and on timeout REBUILD:
  -- re-discover (catch added components), re-plan, top up drained buffers.
  local replan = opts.replan or 2
  while true do
    local moved = ctx.router:pump()
    if moved == 0 then
      local ev = event.pull(replan)               -- nothing to do: wait for a signal/timeout
      if ev == nil then                           -- idle timeout: refresh everything
        ctx.router, ctx.planner = App.build(modules, declared, getProxy, opts)
      end
    end
  end
  return ctx.router, ctx.planner                  -- unreachable; kept for symmetry
end

return App
