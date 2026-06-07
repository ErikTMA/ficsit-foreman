-- FICSIT Foreman — reflection DIAGNOSTIC. Paste into an EEPROM, run once, copy the
-- whole log back. It dumps, for each DISTINCT component type on the network, how FIN
-- actually exposes it: tostring(getType()), the parent chain, and the function list
-- (via reflection getFunctions — NOT by probing instance members, so it should not
-- spam deprecation warnings). This tells us how to classify machines/splitters/
-- mergers/containers without probing. No spam: one block per distinct type.

local all = component.findComponent("")
computer.log(1, "[diag] components on network: " .. tostring(#all))

local function s(x) local ok, r = pcall(tostring, x); return ok and r or "?" end

-- names of all functions on a class + its ancestors (reflection, warning-free)
local function funcNames(cls)
  local names, seen, c, g = {}, {}, cls, 0
  while c and g < 16 do
    g = g + 1
    local ok, fns = pcall(function() return c:getFunctions() end)
    if ok and type(fns) == "table" then
      for _, f in ipairs(fns) do
        local okn, nm = pcall(function() return f.name end)
        nm = (okn and nm) and tostring(nm) or s(f)
        if not seen[nm] then seen[nm] = true; names[#names + 1] = nm end
      end
    end
    local okp, par = pcall(function() return c:getParent() end)
    if not okp then break end
    c = par
  end
  return names
end

local function chain(cls)
  local out, c, g = {}, cls, 0
  while c and g < 16 do
    g = g + 1
    out[#out + 1] = s(c)
    local okp, par = pcall(function() return c.getParent and c:getParent() end)
    if not okp then break end
    c = par
  end
  return table.concat(out, " <- ")
end

local seen = {}
local count = 0
for _, id in ipairs(all) do
  local p = component.proxy(id)
  local ok, cls = pcall(function() return p:getType() end)
  local key = ok and s(cls) or "NO_getType"
  if not seen[key] then
    seen[key] = true
    count = count + 1
    computer.log(1, "[diag] === type #" .. count .. " : " .. key .. "  nick=" .. s(p.nick))
    if ok and cls then
      computer.log(1, "[diag]   chain: " .. chain(cls))
      local fns = funcNames(cls)
      -- log in chunks so a long list isn't truncated
      local line = ""
      for _, nm in ipairs(fns) do
        if #line + #nm + 1 > 180 then computer.log(1, "[diag]   fns: " .. line); line = "" end
        line = line .. nm .. ","
      end
      if #line > 0 then computer.log(1, "[diag]   fns: " .. line) end
    end
  end
end
computer.log(1, "[diag] distinct types: " .. count .. " — done. Copy everything above.")
