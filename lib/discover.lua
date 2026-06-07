-- discover.lua — automatic topology discovery for FICSIT Foreman (PRODUCT code).
--
-- FIN CAN see a building's belt neighbours: getFactoryConnectors() -> each
-- FactoryConnection has .direction (0=in,1=out) + .isConnected; :getConnected()
-- returns the peer connection, and .owner (from ActorComponent) is the building it
-- belongs to (a network component with .id). So one computer can crawl the whole
-- connected belt graph and rebuild the topology Foreman otherwise expects declared —
-- a link-state crawl (the single-computer analogue of OSPF).
--
--   Discover.run({ find=?, getProxy=? }) -> { containers, splitters, mergers,
--                                             constructors, belts }
--
-- belts = { {from=id, fromOutput=n, to=id, toInput=n}, ... } keyed by component UUID,
-- ready to hand to Router.new / Planner. Roles come from the component type; item
-- types/roles still come from container nicks (input/output/buffer) + recipes.

local Discover = {}

local INPUT, OUTPUT = 0, 1

-- The set of function internal-names a component exposes, gathered from its class
-- HIERARCHY via reflection: getType() -> getFunctions() / getParent(). This is the
-- only WARNING-FREE way to know a component's capabilities in-game:
--   * tostring(getType()) is "Object<Class>: <hash>" — NO usable class name (verified
--     in-game), so name matching is impossible.
--   * accessing a missing INSTANCE member (p.getOutput on a container) logs
--     "No property/function found. Nil return is deprecated and will become an error" —
--     so we must NOT probe instance members.
-- getFunctions()/function.name DO work, so we ask the class what it can do instead.
function Discover.funcSet(p)
  local set = {}
  if not p or not p.getType then return set end
  local ok, cls = pcall(function() return p:getType() end)
  if not ok then return set end
  local guard = 0
  while cls and guard < 16 do
    guard = guard + 1
    local okf, fns = pcall(function() return cls:getFunctions() end)
    if okf and type(fns) == "table" then
      for _, f in ipairs(fns) do
        local okn, nm = pcall(function() return f.name end)
        if okn and nm ~= nil then set[tostring(nm)] = true
        elseif type(f) == "string" then set[f] = true end   -- emulator shape: plain names
      end
    end
    local okp, par = pcall(function() return cls:getParent() end)
    if not okp then break end
    cls = par
  end
  return set
end

-- Classify a live component proxy by its capability FUNCTION SET (reflection-derived,
-- warning-free). In this FIN version (verified in-game):
--   getRecipes            -> a manufacturer (constructor/assembler/foundry/…)
--   transferItem+canOutput-> a CodeableSplitter  (splitter HAS canOutput)
--   transferItem (no canOutput) -> a CodeableMerger  (merger has NO canOutput, and
--                            NEITHER has getOutput — the old getOutput probe made every
--                            splitter look like a merger, which killed all routing)
--   getInventories        -> a storage container or A.W.E.S.O.M.E. Sink
--   stopComputer          -> the computer itself (has getInventories too) — NOT a node
function Discover.classify(p)
  local f = Discover.funcSet(p)
  if f.stopComputer then return nil end            -- the controller's own computer
  if f.getRecipes then return "machine" end
  if f.transferItem then return f.canOutput and "splitter" or "merger" end
  if f.getInventories then return "container" end
  return nil
end

-- ordinal of connector `conn` among `ownerProxy`'s connectors of `dir`
local function portIndex(ownerProxy, conn, dir)
  local idx = -1
  for _, c in ipairs(ownerProxy:getFactoryConnectors()) do
    if c.direction == dir then idx = idx + 1; if c == conn then return idx end end
  end
  return 0
end

-- a component's class never changes, and reflection (getFunctions over the hierarchy)
-- is not free — cache the role per id so the persistent loop's periodic re-discovery
-- doesn't re-introspect every component every tick. `false` = known not-a-node.
Discover._roleCache = {}
function Discover.roleCached(id, p)
  local r = Discover._roleCache[id]
  if r == nil then r = Discover.classify(p) or false; Discover._roleCache[id] = r end
  return r or nil
end

function Discover.run(opts)
  opts = opts or {}
  local find = opts.find or function(q) return component.findComponent(q) end
  local getProxy = opts.getProxy or function(id) return component.proxy(id) end

  local topo = { containers = {}, splitters = {}, mergers = {}, constructors = {}, belts = {} }
  local proxies = {}
  for _, id in ipairs(find("")) do
    local p = getProxy(id)
    if p then
      local role = Discover.roleCached(id, p)
      if role then
        proxies[id] = p
        if role == "splitter" then topo.splitters[#topo.splitters + 1] = id
        elseif role == "merger" then topo.mergers[#topo.mergers + 1] = id
        elseif role == "machine" then topo.constructors[#topo.constructors + 1] = id
        elseif role == "container" then topo.containers[#topo.containers + 1] = { id = id } end
      end
    end
  end

  for id, p in pairs(proxies) do
    if p.getFactoryConnectors then
      local outIdx = -1
      for _, c in ipairs(p:getFactoryConnectors()) do
        if c.direction == OUTPUT then
          outIdx = outIdx + 1
          if c.isConnected then
            local peer = c:getConnected()
            local owner = peer and peer.owner
            if owner and owner.isNetworkComponent and proxies[owner.id] then
              topo.belts[#topo.belts + 1] = {
                from = id, fromOutput = outIdx,
                to = owner.id, toInput = portIndex(owner, peer, INPUT),
              }
            end
          end
        end
      end
    end
  end
  return topo
end

return Discover
