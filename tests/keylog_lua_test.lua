-- Runs the Lua chunks keylog.py sends to `hyprctl eval` against a mock `hl`.
-- usage: lua tests/keylog_lua_test.lua <arm.lua> <arm-all.lua> <disarm.lua>
-- The arm chunks write to the raw path baked into them; tests/run.sh checks it.
local handlers, subs = {}, {}
hl = {
  on = function(name, fn)
    local s = { active = true }
    function s:is_active() return self.active end
    function s:remove() self.active = false end
    handlers[name] = fn
    subs[#subs + 1] = s
    return s
  end,
}
local arm, armall, disarm = arg[1], arg[2], arg[3]
local function key(c, s) handlers["input.keyboard.key"](c, 0, s) end

dofile(arm)
key(38, 1) key(38, 0)                            -- a: hidden
key(50, 1) key(113, 1) key(113, 0) key(50, 0)    -- Shift+Left: shown
key(37, 1) key(54, 1) key(54, 0) key(37, 0)      -- Ctrl+C: the C is revealed
key(108, 1) key(38, 1) key(38, 0) key(108, 0)    -- AltGr+a types text: hidden
key(202, 1)                                      -- F24: shown
handlers["keybinds.submap"]("resize")
dofile(arm)                                      -- live listener: only the pause flag changes
assert(#subs == 2, "re-arming a live listener must not register it again")
_G.bfrec.paused = true
key(113, 1)                                      -- paused: nothing written
_G.bfrec.paused = false
dofile(disarm)
assert(_G.bfrec == nil and not subs[1].active and not subs[2].active, "disarm must remove both listeners")
dofile(armall)
key(38, 1)                                       -- all keys: a is written
dofile(disarm)
print("lua ok")
