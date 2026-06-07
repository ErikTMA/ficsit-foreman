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

-- classify a component class-name string into a topology role (nil = ignore). Matches
-- FIN reflection base-class internal names (`Manufacturer` = AFGBuildableManufacturer,
-- the recipe-machine base; `CodeableSplitter`/`CodeableMerger`) AND the leaf names the
-- emulator/game use (`Constructor`, `StorageContainer`, …). `tostring(class)` in-game is
-- `Class<InternalName>`, so substring matching works.
function Discover.roleOf(typ)
  typ = tostring(typ)
  if typ:find("Splitter") then return "splitter" end
  if typ:find("Merger") then return "merger" end
  if typ:find("Manufacturer") or typ:find("Constructor") or typ:find("Assembler")
     or typ:find("Foundry") or typ:find("Refinery") or typ:find("Blender")
     or typ:find("Packager") or typ:find("Smelter") then return "machine" end
  if typ:find("Storage") or typ:find("Container") or typ:find("ResourceSink")
     or typ:find("Depot") then return "container" end
  return nil
end

-- Concatenated class-reference text of the component's type AND its ancestors, walking
-- getType()/getParent(). This is WARNING-FREE: it uses only valid reflected calls
-- (getType, getParent) and tostring — never probes for methods that may not exist
-- (FIN logs "Nil return is deprecated" for a missing member, which mass method-probing
-- triggers). The hierarchy guarantees a machine shows its `Manufacturer` base even if
-- the leaf class name doesn't say so. Tolerant of the emulator (getType()->string).
function Discover.typeChain(p)
  if not p.getType then return "" end
  local ok, cls = pcall(function() return p:getType() end)
  if not ok then return "" end
  local parts, guard = {}, 0
  while cls and guard < 16 do
    guard = guard + 1
    parts[#parts + 1] = tostring(cls)
    local okp, par = pcall(function() return cls.getParent and cls:getParent() end)
    if not okp then break end
    cls = par
  end
  return table.concat(parts, " ")
end

-- classify a live component proxy. PRIMARY: by class hierarchy name (warning-free).
-- FALLBACK (only when the name says nothing — e.g. a storage container whose registered
-- ancestor is just `Buildable`): probe by capability. The fallback CAN emit FIN's
-- deprecation warning for a missing member, so it runs last and only for the unmatched.
function Discover.classify(p)
  local role = Discover.roleOf(Discover.typeChain(p))
  if role then return role end
  if p.getRecipes then return "machine" end       -- manufacturer
  if p.getOutput then return "splitter" end        -- CodeableSplitter (has GetOutput)
  if p.transferItem then return "merger" end       -- CodeableMerger (no GetOutput)
  if p.getInventories then return "container" end  -- storage / sink
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
