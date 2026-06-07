-- ============================================================================
-- EXAMPLE topology for FICSIT Foreman — REPLACE THIS WITH YOUR OWN FACTORY.
-- This is the demo manifold used to develop Foreman; copy the SHAPE, not the
-- specific buildings. Assign each container/splitter/merger/constructor a unique
-- id (its in-game nick), and declare the belts with port indices. FIN can't sense
-- belt wiring, so this declaration is how Foreman learns your layout.
--
-- Load it in your EEPROM's TOPOLOGY, e.g.:  local TOPOLOGY = (your table below)
-- ============================================================================

-- Shared topology declaration for the manifold + production test.
-- Pure data (no FIN globals): loaded by both the emulator world file and the FIN
-- program. Recipe DEFINITIONS are NOT here — they are game data the planner
-- discovers at runtime via the constructor's getRecipes() (declared in the world
-- file for the emulator).
--
-- Layout: 3 input containers -> merger chain (M1->M2->M3) -> backbone -> splitter
-- chain (S1->S2->S3) -> 3 output BUFFERS (reversed) + a constructor in the loop.
--
--   IN_IRON   (iron plate) -> M1.in0       CTOR1.out -> M1.in1   (crafted product re-enters)
--   IN_COPPER (wire)       -> M2.in0       M1.out -> M2.in1
--   IN_SAM    (sam ore)    -> M3.in0       M2.out -> M3.in1      M3.out -> S1
--   S1.out0 -> REANIMATED_SAM_BUFFER_1     S1.out1 -> S2     S1.out2 -> DEFAULT_OUT_1 (sink)
--   S2.out0 -> WIRE_BUFFER_1               S2.out1 -> S3
--   S3.out0 -> IRON_PLATE_BUFFER_1         S3.out1 -> CTOR1 (constructor input)
--   S3.out2 -> M1.in2   (LOOP: the belt system is a closed ring)
--
-- The ring means every splitter can reach every buffer, so when a destination is
-- full an item is forwarded on to an alternate buffer (or, last resort, the sink).
-- Double pass: sam ore is ordered to CTOR1 (pass 1, ingredient); CTOR1 crafts
-- reanimated sam which re-enters at M1 and is ordered to its buffer (pass 2, product).

return {
  containers = {
    { id = "IN_IRON",   provides = "iron plate", items = 50 },
    { id = "IN_COPPER", provides = "wire",       items = 50 },
    { id = "IN_SAM",    provides = "sam ore",    items = 12 },
    -- buffers: name encodes the wanted item; target = how full to keep it
    { id = "REANIMATED_SAM_BUFFER_1", target = 5 },   -- wants "reanimated sam" (crafted)
    { id = "WIRE_BUFFER_1",           target = 50 },  -- wants "wire" (direct)
    { id = "IRON_PLATE_BUFFER_1",     target = 50 },  -- wants "iron plate" (direct)
    -- catch-all sink (A.W.E.S.O.M.E. Sink); always accepts, never jams
    { id = "DEFAULT_OUT_1", class = "ResourceSink" },
  },
  mergers      = { "M1", "M2", "M3" },
  splitters    = { "S1", "S2", "S3" },
  constructors = { "CTOR1" },
  belts = {
    -- inputs into the merger chain
    { from = "IN_IRON",   to = "M1", toInput = 0 },
    { from = "IN_COPPER", to = "M2", toInput = 0 },
    { from = "IN_SAM",    to = "M3", toInput = 0 },
    -- crafted product re-enters the loop at M1 input 1
    { from = "CTOR1", to = "M1", toInput = 1 },
    -- merger chain
    { from = "M1", to = "M2", toInput = 1 },
    { from = "M2", to = "M3", toInput = 1 },
    { from = "M3", to = "S1" },                        -- backbone into splitter chain
    -- splitter chain peeling off to the (reversed) buffers
    { from = "S1", fromOutput = 0, to = "REANIMATED_SAM_BUFFER_1" },
    { from = "S1", fromOutput = 1, to = "S2" },
    { from = "S1", fromOutput = 2, to = "DEFAULT_OUT_1" },   -- catch-all sink
    { from = "S2", fromOutput = 0, to = "WIRE_BUFFER_1" },
    { from = "S2", fromOutput = 1, to = "S3" },
    { from = "S3", fromOutput = 0, to = "IRON_PLATE_BUFFER_1" },
    { from = "S3", fromOutput = 1, to = "CTOR1" },           -- constructor INPUT (splitter 3, output 1)
    { from = "S3", fromOutput = 2, to = "M1", toInput = 2 }, -- LOOP back: closes the ring
  },
}
