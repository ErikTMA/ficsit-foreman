-- app.lua — FICSIT Foreman entry/wiring (PRODUCT code).
-- Wires the modules together and runs one fill pass. Shared by the LITE and FULL
-- distributions; the only difference is `opts.autoname` (FULL auto-renames
-- containers via the namer; LITE expects hand-named containers).
--
--   App.run({ Router=, Planner=, Namer=? }, topology, opts)
--     opts.getProxy  — component resolver (default component.proxy)
--     opts.autoname  — run the namer pass first (FULL only)
--     opts.maxLoops  — router run cap
--
-- Returns router, planner (for inspection/tests).

local App = {}

function App.run(modules, topology, opts)
  opts = opts or {}
  local getProxy = opts.getProxy
  if opts.autoname and modules.Namer then
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
