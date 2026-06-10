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

-- CHEAP re-plan against a KNOWN topology: fresh router+planner, listen (new components
-- only), place fill orders + gate sources, drain. No belt crawl, no recipe re-derivation,
-- no renaming. This is what the persistent loop runs most ticks — the expensive discovery
-- (App.build) only needs to run occasionally to catch newly-built machines/containers.
function App.plan(modules, topo, getProxy, opts)
  local router  = modules.Router.new(topo, getProxy)
  -- epochSeconds (the re-plan cadence) sizes per-machine capacity for demand-proportional
  -- pool allocation; default 2s matches the persistent loop's replan interval.
  local planner = modules.Planner.new(topo, router, getProxy, opts and opts.replan)
  router:listenAll()        -- listen to all splitters/mergers (once per session; faster reactions)
  local plan = planner:fillAll()   -- places orders AND gates each source connector
  -- NOTE: NO pump() here. App.plan runs every ~2s (the cheap re-plan); pump() polls getInput on ALL
  -- ~60 codeables (each a game-thread sync) and was the dominant freeze — the old whole-network stall
  -- reintroduced on a 2s timer, which the event-driven loop could never remove because it lived in the
  -- re-plan, not the loop. Routing is event-driven (Router:_dispatch) + the held-node retry set
  -- (Router:_drainRetry); a full pump() runs only on App.build (rare: a network change) and as a rare
  -- ~15s loop backstop. So the 2s re-plan is now cheap.
  App.report(topo, planner, plan, opts)
  return router, planner
end

-- (Re)build the whole control state from the live network: in auto mode re-crawl the belt
-- graph (so containers/machines ADDED while running are picked up), re-derive products,
-- (re)assign demand-driven containers, content-name sacred-keyword ones, then plan. A
-- declared topology is kept as-is (no re-crawl) but still re-planned. Renaming/auto-assign
-- are idempotent — already-named nicks persist in-game, so repeated rebuilds are stable.
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
  local router, planner = App.plan(modules, topo, getProxy, opts)
  router:pump()             -- SEED routing once per build (initial + each re-discover, both rare): drain
                            -- items already sitting in codeables that fired no fresh edge. The 2s re-plan
                            -- (App.plan) does NOT pump; steady-state routing is event-driven.
  return router, planner, topo
end

-- Diagnostic: log each order's COMPUTED PATH once (the belt sequence src -> dst with the
-- transferItem output port at each splitter hop). Short 6-char ids match the netdump labels,
-- so a path that ends somewhere other than its dst (or routes through DEFAULT_OUT) is visible.
function App.dumpPaths(router)
  if not App._debug or App._pathsLogged or not (computer and computer.log) then return end
  App._pathsLogged = true
  local function s(x) return tostring(x):sub(1, 6) end
  for _, o in ipairs(router.orders or {}) do
    local segs = {}
    for _, b in ipairs(o.path or {}) do segs[#segs + 1] = ("[%d]>%s"):format(b.fromOutput or 0, s(b.to)) end
    computer.log(1, ("[Foreman] PATH '%s' x%d  %s ->%s  : %s")
      :format(o.item, o.count, s(o.src), s(o.dst), (#segs > 0 and table.concat(segs, " ")) or "(empty!)"))
  end
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
  -- per-order reachability: if there's no belt path from a source/producer to a
  -- destination, the item will fall through to the sink. Surfaces a fragmented graph
  -- (e.g. a buffer reachable only via a beltless DirectToSplitter snap — those record
  -- as connections but don't carry items, so the path "exists" yet nothing crosses).
  for _, o in ipairs(planner.router.orders or {}) do
    if not planner.router:findPath(o.src, o.dst) then
      computer.log(2, ("[Foreman]   NO PATH: %s  %s -> %s (item will go to DEFAULT_OUT)"):format(o.item, tostring(o.src), tostring(o.dst)))
    end
  end
  if src == 0 then computer.log(2, "[Foreman] no SOURCE containers — nick an input '<Item>_input_1' (or bare 'input')") end
  if nb == 0 then computer.log(2, "[Foreman] no BELTS discovered — connect buildings with real belts (codeable splitters/mergers need belted ports; beltless 'snap' mods like DirectToSplitter don't transfer)") end
end

function App.run(modules, topology, opts)
  opts = opts or {}
  -- PERF: component.proxy(id) is a game-thread sync, and getProxy is called HUNDREDS of times per
  -- epoch (every count, connector, recipe, inventory access). Cache the proxy per id — a component's
  -- proxy is stable for its lifetime, so this turns hundreds of syncs per epoch into one sync per id
  -- per session. The cache is cleared on a full re-discover (a rebuilt component gets a new FGuid).
  local _rawProxy = opts.getProxy or function(id) return component.proxy(id) end
  local _proxyCache = {}
  local getProxy = function(id)
    local p = _proxyCache[id]
    if p == nil then p = _rawProxy(id); _proxyCache[id] = p end
    return p
  end
  local declared = topology                       -- nil => auto-discover (and re-discover)

  -- New session: clear the source-gating ledgers. Router._auth (cumulative authorized) and
  -- Router._deliv (cumulative delivered) are module-global so they PERSIST across the
  -- rebuilds inside this loop (that is what stops a rebuild re-releasing in-flight stock);
  -- but a fresh App.run is a fresh session and must start them empty.
  if modules.Router then
    modules.Router._auth = {}; modules.Router._deliv = {}; modules.Router._listened = {}
    modules.Router._delivPrev = {}   -- stall back-pressure baseline; reset with _deliv so a fresh session has no stale progress
    modules.Router._stallGates = {}  -- in-flight amnesty counters; reset with the ledgers they watch
    -- stuck-machine recovery state is module-level so it survives the in-loop rebuilds; reset per session.
    modules.Router._idleEpochs = {}; modules.Router._draining = {}
    -- static connector cache + blocked-write shadow (gateSources perf): cleared per session and on every
    -- re-discover, since a rebuilt component exposes new connector objects.
    modules.Router._connCache = {}; modules.Router._blockShadow = {}; modules.Router._retry = {}
    modules.Router._legFullMach = {}   -- machine-entrance jam marks (feed-drain signal); fresh per session
  end
  -- ingredient flow-control window (max in-flight feedstock per order, anti belt-flood); tunable.
  if modules.Router and opts.flowWindow then modules.Router.flowWindow = opts.flowWindow end
  if modules.Router and opts.stuckEpochs then modules.Router.stuckEpochs = opts.stuckEpochs end
  -- The control model keeps a DURABLE machine->recipe assignment (+ epoch clock for hysteresis)
  -- module-side so it survives the ~2s rebuilds; a fresh session starts clean.
  if modules.Planner then
    modules.Planner._assign = {}; modules.Planner._epoch = 0; modules.Planner._scanCache = nil
    modules.Planner._drain = {}; modules.Planner._starve = {}; modules.Planner._drainTried = {}; modules.Planner._infeas = {}   -- feed-drain + infeasibility state; fresh per session
    modules.Planner._tempRecipe = {}   -- drain temp-recipe marks (seed-adoption guard); fresh per session
  end

  -- DEBUG diagnostics (order paths + per-splitter/merger routing decisions) are OFF by
  -- default for clean output. Enable by passing opts.debug=true OR nicking the Computer Case
  -- "debug". Surfaces App.dumpPaths + Router._dlog.
  local dbg = opts.debug
  if dbg == nil then pcall(function() local ci = computer.getInstance and computer.getInstance(); dbg = (ci and ci.nick == "debug") or false end) end
  App._debug = dbg and true or false
  if modules.Router then modules.Router.DEBUG = App._debug end

  -- One long-lived listener delegating to the CURRENT router; rebuilds swap the
  -- router instance in `ctx` rather than re-registering (no duplicate listeners).
  local ctx = {}
  ctx.router, ctx.planner, ctx.topo = App.build(modules, declared, getProxy, opts)
  App.dumpPaths(ctx.router)                        -- one-time diagnostic: each order's belt path
  event.registerListener(event.filter{ event = "ItemRequest" },
    function(_, sender, a, b) ctx.router:_dispatch(sender, a, b) end)

  if opts.once then
    -- batch mode (tests / one-shot): drain current routing work and return.
    ctx.planner:run(opts.maxLoops)
    return ctx.router, ctx.planner
  end

  -- IN-GAME DEFAULT: a persistent control loop. ITEM MOVEMENT IS EVENT-DRIVEN — an ItemRequest fires
  -- when an item ARRIVES at a codeable splitter/merger, and the registered listener routes it
  -- (Router:_dispatch). We do NOT poll all ~120 ports every tick: that game-thread-sync storm is what
  -- froze the whole network in visible pulses (items stop, then jump, at every splitter/merger). A
  -- route that hits a full output emits no fresh signal, so the held node goes into a small ACTIVE SET
  -- and is retried cheaply each loop (Router:_drainRetry) until its input clears. A rare full pump()
  -- is only a safety BACKSTOP for any edge the listener missed. The periodic REFRESH is the ONLY
  -- planning work — re-plan orders + re-gate sources (and re-crawl when the component count changes).
  local replan = opts.replan or 2                 -- seconds: idle wait + refresh cadence
  local replanMs = opts.replanMs or (replan * 1000)
  -- A full belt re-crawl (App.build) walks every connector — the single most sync-heavy operation,
  -- and it FREEZES routing while it runs (seconds, on a big factory). It only needs to run when the
  -- network actually CHANGED (the player built/removed something), which we detect cheaply by the
  -- component count (one sync) instead of on a timer. A large periodic backstop catches re-snaps that
  -- keep the count the same. So in steady state there is NO crawl freeze. opts.rediscover overrides
  -- the backstop cadence.
  local rediscover = opts.rediscover or 30        -- periodic backstop re-crawl (~60s); count-change re-crawls immediately
  local nref, lastCount = 0, nil
  local function compCount()
    local ok, all = pcall(function() return component.findComponent("") end)
    return (ok and all) and #all or nil
  end
  lastCount = compCount()
  local function now() return (computer.millis and computer.millis()) or 0 end
  local lastMs = now()
  local function refresh()
    nref = nref + 1
    local cc = compCount()
    local changed = (cc ~= nil and lastCount ~= nil and cc ~= lastCount)
    local p0 = now()
    if (not declared) and (changed or (nref % rediscover == 0)) then
      for k in pairs(_proxyCache) do _proxyCache[k] = nil end   -- rebuilt components may have new FGuids — drop stale proxies
      modules.Router._connCache = {}; modules.Router._blockShadow = {}  -- same: drop stale connector objects + their block shadow
      ctx.router, ctx.planner, ctx.topo = App.build(modules, declared, getProxy, opts)  -- full re-crawl
      lastCount = cc
    else
      ctx.router, ctx.planner = App.plan(modules, ctx.topo, getProxy, opts)              -- cheap re-plan
    end
    App._planMs = now() - p0
    -- STUCK-MACHINE RECOVERY is OPT-IN (opts.recovery) and OFF by default. In-game it caused a churn:
    -- it temp-switches a starved screws machine to Iron Rod to drain a foreign iron ingot, but reverts
    -- before it crafts — setRecipe EMPTIES the input, so the iron ingots are destroyed — and its bogus
    -- iron-ingot order keeps the splitter routing more iron ingot to it, forever (user-diagnosed). It
    -- also dominated the re-plan time (setRecipe is heavy). Until it routes the foreign item AWAY instead
    -- of switching recipes, it stays off.
    local s0 = now()
    if opts.recovery and ctx.planner and ctx.router._stuckScan then
      pcall(function() ctx.router:_stuckScan(ctx.planner) end)
    end
    App._stuckMs = now() - s0
    lastMs = now()
  end
  -- CONTINUOUS-PUMP loop (restored — this is what flowed smoothly before v0.13.5). Each iteration the
  -- LEVEL-TRIGGERED pump() polls every splitter/merger and moves what it can. It returns `present` = how
  -- many codeables STILL hold an item (stuck/jammed right now). The rule:
  --   * flowing (moved > 0)  -> event.pull(0): non-blocking, loop immediately, pump again. Smooth flow.
  --   * jammed (present > 0) -> keep pumping (capped) so a CLEARING jam is caught the instant a downstream
  --     frees — instead of sleeping 2s with items frozen at the codeables (THE stutter: v0.13.5+ pushed
  --     the pump to a rare 15s backstop, so items only moved in 15s bursts).
  --   * truly clear (moved 0, present 0) -> event.pull(replan): block for the next signal, then re-plan.
  -- The level-triggered pump is what catches items that arrived but fired no fresh ItemRequest (a held
  -- item never re-signals) — event-driven routing alone (v0.13.5-0.13.7) could not, hence the bursts.
  -- pump() is CHEAP (the in-game perf line confirms maxwork ~0-1ms); it was removed on a wrong premise.
  -- PERF LINE (every opts.logMs, default 10s; 0 silences): routed=items moved/window, present=current
  -- jam depth, sunk/stuck=overflow rates (over-supply!), refresh=re-plan ms, maxwork=worst pump ms.
  -- DEBUG (nick the Computer Case "debug" or opts.debug): adds a full buffer/source/machine dump every
  -- opts.dbgMs (3s) plus the per-route SPL/RECOVER/SINK/STUCK/PATH trace.
  local logMs = (opts.logMs == nil) and 10000 or opts.logMs
  local dbgMs = opts.dbgMs or 3000
  local jamSpin = opts.jamSpin or 200
  local lastLog, lastDbg = now(), now()
  local routed, maxWork, refreshMs, noProg = 0, 0, 0, 0
  while true do
    local w0 = now()
    local moved, present = ctx.router:pump()        -- level-triggered routing EVERY iteration (cheap)
    ctx.router:_drainRetry()                         -- drain held-node set (bounded safety; pump also covers it)
    routed = routed + moved
    local work = now() - w0; if work > maxWork then maxWork = work end
    local t = now()
    if App._debug and t - lastDbg >= dbgMs then ctx.router:debugDump(); lastDbg = t end
    if logMs > 0 and t - lastLog >= logMs and computer and computer.log then
      computer.log(1, ("[Foreman] perf: routed %d in %.0fs, present %d, sunk %d, stuck %d, refresh %dms (plan %d/stuck %d), maxwork %dms")
        :format(routed, (t - lastLog) / 1000, present,
                modules.Router._nSunk or 0, modules.Router._nStuck or 0, refreshMs,
                App._planMs or 0, App._stuckMs or 0, maxWork))
      routed, maxWork = 0, 0; modules.Router._nSunk, modules.Router._nStuck = 0, 0; lastLog = t
    end
    if t - lastMs >= replanMs then
      local r0 = now(); refresh(); refreshMs = now() - r0; lastMs = now(); noProg = 0
    elseif moved > 0 then
      noProg = 0; event.pull(0)                      -- flowing: loop fast, pump again
    elseif present > 0 and noProg < jamSpin then
      noProg = noProg + 1; event.pull(0)             -- jammed: keep retrying (capped) — don't sleep on a clearing jam
    else
      noProg = 0
      if event.pull(replan) == nil then refreshMs = 0; refresh(); lastMs = now() end  -- clear / hard jam: wait, re-plan
    end
  end
  return ctx.router, ctx.planner                  -- unreachable; kept for symmetry
end

return App
