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

-- distinct item types currently in a container (count > 0)
local function itemTypes(proxy)
  if not proxy.getInventories then return {} end
  local seen, out = {}, {}
  for _, inv in ipairs(proxy:getInventories()) do
    for i = 0, (inv.size or 0) - 1 do
      local s = inv:getStack(i)
      if s and s.count > 0 and not seen[s.item.type.name] then
        seen[s.item.type.name] = true; out[#out + 1] = s.item.type.name
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
