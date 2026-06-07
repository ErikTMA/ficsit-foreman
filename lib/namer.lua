-- namer.lua — auto-naming of containers for FicsIt-Networks (PRODUCT code).
--
-- You nick a container with a SACRED KEYWORD — "input", "output" or "buffer".
-- The namer watches those and, based on what's inside, renames it to
--   <Item>_<Keyword>_<N>     e.g.  Iron_Plate_Buffer_1
-- where N is the lowest free index for that item+keyword (starting at 1).
--
-- Rules:
--   * sacred-keyword container with exactly ONE item type  -> renamed.
--   * with MULTIPLE item types -> error logged, left alone (not used) until it is
--     back to a single type, then renamed. The program keeps running.
--   * empty -> left alone (waiting for its first item).
--   * an already-named <Item>_<Keyword>_<N> that goes EMPTY keeps its name — the
--     namer never silently reassigns it.
--   * if you MANUALLY put a different single item type into a named container, the
--     namer re-types it (your manual action is the trigger).
--
-- Stateless: everything is derived from the live nicks each scan, so it survives
-- restarts (in-game) with no saved state.

local Namer = {}
Namer.__index = Namer

local KEYWORDS   = { input = true, output = true, buffer = true }
local KW_TITLE   = { input = "Input", output = "Output", buffer = "Buffer" }
-- demand-driven keywords: the system picks the item (see Namer.autoAssign)
local AUTO       = { auto_buffer = "buffer", auto_output = "output" }
local AUTO_DEFAULT_TARGET = 50

function Namer.new(getProxy, find, log)
  return setmetatable({
    getProxy = getProxy or function(id) return component.proxy(id) end,
    find = find or function(q) return component.findComponent(q) end,
    log = log or function(msg) if computer.log then computer.log(1, msg) end end,
  }, Namer)
end

-- "iron plate" -> "Iron_Plate"
local function titleItem(item)
  return (item:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end):gsub("%s+", "_"))
end

-- parse "Iron_Plate_Buffer_3" -> item="iron plate", kw="buffer", n=3 (else nil)
local function parseGenerated(nick)
  local prefix, kwraw, n = nick:match("^(.+)_(%a+)_(%d+)$")
  if prefix and KEYWORDS[kwraw:lower()] then
    return prefix:gsub("_", " "):lower(), kwraw:lower(), tonumber(n)
  end
end

-- distinct item types currently in a container (count > 0), names normalized to
-- lowercase — FIN reflection returns canonical (Title) case ("Concrete") while names
-- parsed from nicks are lowercase ("concrete"); without this they never compare equal,
-- so the namer re-typed an already-named container on every run (Concrete_Input_1 ->
-- _2 -> ...). titleItem() restores display case for the new nick.
local function itemTypes(proxy)
  if not proxy.getInventories then return {} end
  local seen, out = {}, {}
  for _, inv in ipairs(proxy:getInventories()) do
    for i = 0, (inv.size or 0) - 1 do
      local s = inv:getStack(i)
      local nm = s and s.count > 0 and tostring(s.item.type.name):lower()
      if nm and not seen[nm] then
        seen[nm] = true; out[#out + 1] = nm
      end
    end
  end
  return out
end

-- lowest free N for item+keyword among the current nick set
local function nextIndex(usedNames, item, kw)
  local base = titleItem(item) .. "_" .. KW_TITLE[kw] .. "_"
  local n = 1
  while usedNames[base .. n] do n = n + 1 end
  return base .. n
end

-- Item a container already resolves to (explicit field or generated name), or nil.
local function resolvedItem(c)
  if c.buffer then return tostring(c.buffer):lower() end
  if c.output then return tostring(c.output):lower() end
  local prefix, kw = tostring(c.id):match("^(.-)_(%a+)_%d+$")
  if prefix and (kw:lower() == "buffer" or kw:lower() == "output") then
    return prefix:gsub("_", " "):lower()
  end
  return nil
end

--- Demand-driven assignment: a container whose live nick is `auto_buffer` /
--- `auto_output` (or topology field c.auto = "buffer"/"output") claims the next
--- item from `candidates` (what the machines can make) that no destination covers
--- yet — e.g. with iron plate + wire already buffered, an auto_buffer becomes
--- Iron_Rod_Buffer_1. Mutates the topology (sets c.buffer/c.output + c.target so
--- the router/planner treat it as a real destination) and renames the live nick.
--- Returns the list of assignments.
function Namer.autoAssign(topology, opts)
  opts = opts or {}
  local getProxy = opts.getProxy or function(id) return component.proxy(id) end
  local log = opts.log or function(v, m) if computer.log then computer.log(v, m) end end
  local candidates = opts.candidates or {}
  local usage = opts.usage or {}

  -- how many destinations already cover each item, + used nicks for indexing
  local nbuf, used = {}, {}
  for _, c in ipairs(topology.containers or {}) do
    local it = resolvedItem(c); if it then nbuf[it] = (nbuf[it] or 0) + 1 end
    local p = getProxy(c.id); if p then used[p.nick or ""] = true end
  end

  -- choose the item this auto container should hold: the first item NOTHING covers
  -- yet (in candidate order); if every item is covered, the LEAST-covered relative
  -- to usage (buffers / recipes-that-consume-it) — heavily-used items get reinforced.
  local function choose()
    for _, cand in ipairs(candidates) do
      if (nbuf[cand] or 0) == 0 then return cand end
    end
    local best, bestScore
    for _, cand in ipairs(candidates) do
      local score = (nbuf[cand] or 0) / math.max(usage[cand] or 0, 1)
      if not best or score < bestScore
         or (score == bestScore and (usage[cand] or 0) > (usage[best] or 0)) then
        best, bestScore = cand, score
      end
    end
    return best
  end

  local assignments = {}
  for _, c in ipairs(topology.containers or {}) do
    if not resolvedItem(c) then
      local p = getProxy(c.id)
      local role = AUTO[((p and p.nick) or ""):lower()] or c.auto
      if role then
        local pick = choose()
        if pick then
          nbuf[pick] = (nbuf[pick] or 0) + 1
          c[role] = pick                                   -- c.buffer / c.output = item
          c.target = c.target or AUTO_DEFAULT_TARGET
          c.capacity = c.capacity or c.target
          local newnick = nextIndex(used, pick, role)
          used[newnick] = true
          if p then p.nick = newnick end
          assignments[#assignments + 1] = { id = c.id, item = pick, role = role, nick = newnick }
          log(1, ("[Foreman] auto-assigned %s -> %s"):format(tostring(c.id), newnick))
        else
          log(2, ("[Foreman] no producible item left for auto container %s"):format(tostring(c.id)))
        end
      end
    end
  end
  return assignments
end

--- One naming pass over every component. Returns a list of human-readable actions.
function Namer:scan()
  local ids = self.find("")                        -- all components
  local proxies, used, actions = {}, {}, {}
  for _, id in ipairs(ids) do
    local p = self.getProxy(id)
    proxies[#proxies + 1] = p
    used[p.nick or ""] = true
  end

  for _, p in ipairs(proxies) do
    local nick = p.nick or ""
    local kw = KEYWORDS[nick:lower()] and nick:lower()
    if kw then
      -- sacred keyword: type it by its single content item
      local types = itemTypes(p)
      if #types == 1 then
        local name = nextIndex(used, types[1], kw)
        p.nick = name; used[name] = true
        actions[#actions + 1] = ("named %q -> %s"):format(nick, name)
      elseif #types > 1 then
        actions[#actions + 1] = ("ERROR: %q has %d item types; not used until single-type"):format(nick, #types)
        self.log(("namer: container nicked %q has multiple item types; ignoring it"):format(nick))
      end
      -- 0 types: wait
    else
      -- already named: only re-type on a MANUAL different single item
      local item, kwt = parseGenerated(nick)
      if item then
        local types = itemTypes(p)
        if #types == 1 and types[1] ~= item then
          local name = nextIndex(used, types[1], kwt)
          p.nick = name; used[name] = true
          actions[#actions + 1] = ("retyped %s -> %s (manual %s)"):format(nick, name, types[1])
        elseif #types > 1 then
          actions[#actions + 1] = ("ERROR: %s has %d item types; left as-is"):format(nick, #types)
          self.log(("namer: %s has multiple item types; left as-is"):format(nick))
        end
        -- empty or matching item: keep the name (never auto-reassign)
      end
    end
  end
  return actions
end

return Namer
