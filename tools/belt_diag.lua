-- FICSIT Foreman BELT diagnostic. Paste into an EEPROM, run once, copy the [belt] log.
-- Discovery finds nodes but 0 belts, so we need ground truth on how a connector reaches
-- the neighbouring building: does getConnected().owner resolve to a KNOWN node (direct
-- link), or to a conveyor/lift actor in between (needs traversal through it)?

local all = component.findComponent("")
local function s(x) local ok, r = pcall(tostring, x); return ok and r or "?" end

-- hash -> friendly label for every known network node, to recognise a peer's owner
local label = {}
for _, id in ipairs(all) do
  local p = component.proxy(id)
  local ok, h = pcall(function() return p:getHash() end)
  if ok then label[tostring(h)] = (p.nick ~= "" and p.nick) or ("id:" .. tostring(id):sub(1, 6)) end
end

local shown = 0
for _, id in ipairs(all) do
  if shown >= 10 then break end
  local p = component.proxy(id)
  local okc, conns = pcall(function() return p:getFactoryConnectors() end)
  if okc and type(conns) == "table" and #conns > 0 then
    shown = shown + 1
    computer.log(1, "[belt] === " .. ((p.nick ~= "" and p.nick) or ("id:" .. tostring(id):sub(1, 8)))
      .. "  connectors=" .. #conns)
    for i, c in ipairs(conns) do
      local dir = pcall(function() return c.direction end) and c.direction or "?"
      local con = pcall(function() return c.isConnected end) and c.isConnected or false
      local line = "[belt]   [" .. i .. "] dir=" .. s(dir) .. " connected=" .. s(con)
      if con then
        local okp, peer = pcall(function() return c:getConnected() end)
        if not okp or peer == nil then
          line = line .. " getConnected=NIL"
        else
          local oko, owner = pcall(function() return peer.owner end)
          if not oko or owner == nil then
            line = line .. " peer.owner=NIL"
          else
            local okh, h = pcall(function() return owner:getHash() end)
            local known = okh and label[tostring(h)] or nil
            local okoc, oc = pcall(function() return owner:getFactoryConnectors() end)
            line = line .. " -> owner=" .. (known or "UNKNOWN(belt?)")
              .. " ownerConns=" .. ((okoc and type(oc) == "table") and #oc or "?")
          end
        end
      end
      computer.log(1, line)
    end
  end
end
computer.log(1, "[belt] done — copy all [belt] lines")
