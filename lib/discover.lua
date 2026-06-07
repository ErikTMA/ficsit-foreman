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

-- classify a component type NAME into a topology role (nil = ignore). Fallback only —
-- in-game getType() returns a class OBJECT whose stringification is not guaranteed to
-- contain a friendly name, so capability detection (Discover.classify) is primary.
function Discover.roleOf(typ)
  typ = tostring(typ)
  if typ:find("Splitter") then return "splitter" end
  if typ:find("Merger") then return "merger" end
  if typ:find("Constructor") or typ:find("Assembler") or typ:find("Manufacturer")
     or typ:find("Foundry") or typ:find("Refinery") or typ:find("Blender")
     or typ:find("Packager") or typ:find("Smelter") then return "machine" end
  if typ:find("Storage") or typ:find("Container") or typ:find("ResourceSink") then return "container" end
  return nil
end

-- type name, tolerant of FIN (getType() -> class object with .name) and the emulator
-- (getType() -> string).
function Discover.typeName(p)
  if not p.getType then return "" end
  local ok, t = pcall(function() return p:getType() end)
  if not ok or t == nil then return "" end
  if type(t) == "table" then return tostring(t.name or t) end
  return tostring(t)
end

-- classify a live component proxy by CAPABILITY (reflection exposes a function only on
-- components that have it), so it works regardless of how a class name stringifies:
--   getRecipes  -> a manufacturer (constructor/assembler/foundry/refinery/…)
--   getOutput   -> a CodeableSplitter (splitter-only; mergers have no GetOutput)
--   transferItem-> a CodeableMerger (has transferItem but no GetOutput)
--   getInventories -> a storage container
-- Falls back to the type-name heuristic for anything else (e.g. an A.W.E.S.O.M.E.
-- Sink used as DEFAULT_OUT, which may expose neither).
function Discover.classify(p)
  if p.getRecipes then return "machine" end
  if p.getOutput then return "splitter" end
  if p.transferItem then return "merger" end
  if p.getInventories then return "container" end
  return Discover.roleOf(Discover.typeName(p))
end

-- ordinal of connector `conn` among `ownerProxy`'s connectors of `dir`
local function portIndex(ownerProxy, conn, dir)
  local idx = -1
  for _, c in ipairs(ownerProxy:getFactoryConnectors()) do
    if c.direction == dir then idx = idx + 1; if c == conn then return idx end end
  end
  return 0
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
      local role = Discover.classify(p)
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
