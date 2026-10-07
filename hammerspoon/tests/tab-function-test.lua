-- Offline test for the Ghostty-tab pieces in hammerspoon/init.lua:
-- loads the real file against a minimal hs.* stub (just enough that its
-- top-level calls — hs.hotkey.modal.new, the eventtaps, the watchers, the
-- closing hs.alert.show — don't error), then exercises the pure parts with
-- plain Lua: DeskTab.pick_target (slot geometry) and the UUID validation
-- gate on DeskOpenTab, plus DeskTab.focus_tty_script and DeskFocusTab's
-- early-exit paths, and the background open: DeskTab.pick_target's
-- avoid rule, DeskTab.match_script_window and DeskTab.focus_was_taken.
-- Never touches a real screen, window or osascript call — run with the
-- system `lua`, not Hammerspoon.
--
-- Run: lua hammerspoon/tests/tab-function-test.lua
local pass, fail = 0, 0
local function ok(desc) pass = pass + 1; print("ok   - " .. desc) end
local function bad(desc) fail = fail + 1; print("FAIL - " .. desc) end
local function assert_eq(desc, expected, actual)
  if expected == actual then
    ok(desc)
  else
    bad(string.format("%s (expected [%s], got [%s])", desc, tostring(expected), tostring(actual)))
  end
end

-- ---------------------------------------------------------------------------
-- Minimal hs.* stub: just enough for init.lua's unconditional top-level
-- calls to run without erroring. None of it models real window/screen
-- behavior — the tests below never rely on it beyond "didn't crash".
-- ---------------------------------------------------------------------------
local inert = {}
inert.__index = function(_, k)
  if k == "start" or k == "stop" then return function(self) return self end end
  return nil
end

package.preload["hs.ipc"] = function() return {} end

local osascript_calls = 0
local last_osascript_script = nil
local timers_started = 0
-- What the stubbed Ghostty dictionary reports for `{id, name} of every window`.
local script_windows_reply = { {}, {} }

hs = {
  window = {
    animationDuration = 0,
    focusedWindow = function() return nil end,
    frontmostWindow = function() return nil end,
    orderedWindows = function() return {} end,
    get = function() return nil end,
  },
  hotkey = {
    modal = {
      new = function()
        local m = {}
        function m:bind() return m end
        return m
      end,
    },
    bind = function() end,
  },
  keycodes = {
    map = setmetatable({}, { __index = function() return 0 end }),
  },
  eventtap = {
    new = function() return setmetatable({}, inert) end,
    event = { types = setmetatable({}, { __index = function(_, k) return k end }) },
  },
  usb = { watcher = { new = function() return setmetatable({}, inert) end } },
  caffeinate = { watcher = { new = function() return setmetatable({}, inert) end } },
  alert = { show = function() return "alert-uuid" end, closeSpecific = function() end },
  timer = {
    doAfter = function() return setmetatable({}, inert) end,
    doEvery = function()
      timers_started = timers_started + 1
      return setmetatable({}, inert)
    end,
    secondsSinceEpoch = function() return 0 end,
  },
  screen = { allScreens = function() return {} end },
  application = {
    get = function() return nil end,
    frontmostApplication = function() return nil end,
  },
  osascript = {
    applescript = function(script)
      if script:find("get {id, name} of every window", 1, true) then
        return true, script_windows_reply, ""
      end
      osascript_calls = osascript_calls + 1
      last_osascript_script = script
      return false, nil, { OSAScriptErrorMessageKey = "stub: never actually run in tests" }
    end,
  },
}

local here = (arg[0] or ""):match("^(.*)/[^/]+$") or "."
local init_path = here .. "/../init.lua"

local chunk, load_err = loadfile(init_path)
if not chunk then
  bad("could not load init.lua: " .. tostring(load_err))
  os.exit(1)
end

local loaded_ok, run_err = pcall(chunk)
if not loaded_ok then
  bad("init.lua errored while loading under the stub: " .. tostring(run_err))
  os.exit(1)
end
ok("init.lua loads under a stubbed hs.* runtime")

if type(DeskTab) ~= "table" then
  bad("DeskTab global not defined after loading init.lua")
  os.exit(1)
end
if type(DeskOpenTab) ~= "function" then
  bad("DeskOpenTab global not defined after loading init.lua")
  os.exit(1)
end

-- ---------------------------------------------------------------------------
-- DeskTab.point_in_frame / frame_center
-- ---------------------------------------------------------------------------
local slot = { x = 1000, y = 0, w = 600, h = 400 }
assert_eq("centre of a frame that matches the slot exactly", true,
  DeskTab.point_in_frame(DeskTab.frame_center(slot), slot))

local nudged = { x = 1010, y = 20, w = 580, h = 360 } -- resized/nudged, centre still inside
assert_eq("a nudged/resized window still counts as inside (loose match)", true,
  DeskTab.point_in_frame(DeskTab.frame_center(nudged), slot))

local elsewhere = { x = 0, y = 0, w = 300, h = 300 } -- centre at (150,150), well outside slot
assert_eq("a window on the wrong part of the screen is outside the slot", false,
  DeskTab.point_in_frame(DeskTab.frame_center(elsewhere), slot))

-- ---------------------------------------------------------------------------
-- DeskTab.pick_target
-- ---------------------------------------------------------------------------
local function slot_frame_of(_) return slot end

-- Existing window whose centre sits in the upper_C slot on the wide screen.
local screens = { { id = "wide", wide = true }, { id = "laptop", wide = false } }
local windows = { { id = 42, screen_id = "wide", frame = nudged } }
local d = DeskTab.pick_target(screens, windows, slot_frame_of, nil)
assert_eq("a matching window on the ultrawide is picked", "existing_window", d.mode)
assert_eq("its id is reported", 42, d.window_id)

-- No matching window on the ultrawide: falls to a new, placed window.
d = DeskTab.pick_target(screens, {}, slot_frame_of, nil)
assert_eq("no match on the ultrawide opens a new window there", "new_window", d.mode)
assert_eq("targets the wide screen", "wide", d.screen_id)

-- A Ghostty window elsewhere on the ultrawide (outside the slot) still
-- falls to new_window, not to that window.
windows = { { id = 7, screen_id = "wide", frame = elsewhere } }
d = DeskTab.pick_target(screens, windows, slot_frame_of, nil)
assert_eq("a Ghostty window outside the slot doesn't count as a match", "new_window", d.mode)

-- A window on a *different* screen, even inside an equivalent rect, must
-- not match — screen_id has to agree too.
windows = { { id = 9, screen_id = "laptop", frame = slot } }
d = DeskTab.pick_target(screens, windows, slot_frame_of, nil)
assert_eq("a same-shaped window on the wrong screen doesn't match", "new_window", d.mode)

-- No ultrawide at all (laptop only): front window decides.
local laptop_only = { { id = "laptop", wide = false } }
d = DeskTab.pick_target(laptop_only, {}, slot_frame_of, { id = 3, app = "Ghostty" })
assert_eq("laptop-only, front window is Ghostty: uses it", "front_window", d.mode)
assert_eq("front window id reported", 3, d.window_id)

d = DeskTab.pick_target(laptop_only, {}, slot_frame_of, { id = 3, app = "Safari" })
assert_eq("laptop-only, front window isn't Ghostty: no target", "none", d.mode)

d = DeskTab.pick_target(laptop_only, {}, slot_frame_of, nil)
assert_eq("laptop-only, no front window at all: no target", "none", d.mode)

-- ---------------------------------------------------------------------------
-- DeskTab.looks_like_uuid
-- ---------------------------------------------------------------------------
assert_eq("a well-formed UUID passes", true,
  DeskTab.looks_like_uuid("c3d1e2f4-5a6b-47c8-9d0e-1f2a3b4c5d6e"))
assert_eq("uppercase hex is still a UUID shape", true,
  DeskTab.looks_like_uuid("C3D1E2F4-5A6B-47C8-9D0E-1F2A3B4C5D6E"))
assert_eq("missing dashes is rejected", false,
  DeskTab.looks_like_uuid("c3d1e2f45a6b47c89d0e1f2a3b4c5d6e"))
assert_eq("too short is rejected", false, DeskTab.looks_like_uuid("c3d1e2f4-5a6b"))
assert_eq("a leading dash (option-injection shape) is rejected", false,
  DeskTab.looks_like_uuid("--rf"))
assert_eq("a quote-breaking string is rejected", false,
  DeskTab.looks_like_uuid('"; do shell script "rm -rf ~"'))
assert_eq("nil is rejected", false, DeskTab.looks_like_uuid(nil))
assert_eq("a non-string is rejected", false, DeskTab.looks_like_uuid(42))

-- ---------------------------------------------------------------------------
-- DeskOpenTab: the UUID gate refuses before anything else runs, including
-- an osascript call — and with no ultrawide and no frontmost window in this
-- stub, the "none" branch also never reaches osascript.
-- ---------------------------------------------------------------------------
osascript_calls = 0
local result = DeskOpenTab("echo hi", "not-a-uuid", nil)
assert_eq("a non-UUID session id refuses outright", false, result)
assert_eq("and never calls osascript", 0, osascript_calls)

osascript_calls = 0
result = DeskOpenTab("echo hi", nil, nil)
assert_eq("no ultrawide, no frontmost Ghostty window (this stub): no target", false, result)
assert_eq("and never calls osascript either", 0, osascript_calls)

-- ---------------------------------------------------------------------------
-- Every tab command runs through the user's login+interactive
-- shell (/bin/zsh -lic '<command>'), never Ghostty's own command: field
-- invoking it directly — CLAUDE_CONFIG_DIR and PATH have to come from the user's
-- shell rc files. Reached via the laptop-only "front window is Ghostty"
-- path (the stub's screens list stays empty), so the script actually
-- reaches hs.osascript.applescript this time and its argument can be
-- inspected.
-- ---------------------------------------------------------------------------
local real_frontmost = hs.window.frontmostWindow
hs.window.frontmostWindow = function()
  return { id = function() return 5 end, application = function() return { name = function() return "Ghostty" end } end }
end

osascript_calls = 0
last_osascript_script = nil
result = DeskOpenTab("claude --resume abc-123", nil, "/some/cwd")
assert_eq("osascript was actually reached this time", 1, osascript_calls)
assert_eq("the script wraps the command in a login+interactive zsh", true,
  last_osascript_script ~= nil and last_osascript_script:find("/bin/zsh %-lic") ~= nil)
assert_eq("the original command still appears, single-quoted for that shell", true,
  last_osascript_script ~= nil and last_osascript_script:find("'claude %-%-resume abc%-123'") ~= nil)

-- A command holding its own single quote (as desk_shq-quoted argv often
-- does) must come through re-escaped for the wrapping shell, never break
-- the AppleScript string it's embedded in (or the content itself) either.
osascript_calls = 0
last_osascript_script = nil
result = DeskOpenTab("claude --resume 'abc-123'", nil, nil)
assert_eq("a command with its own single quotes still reaches osascript", 1, osascript_calls)
assert_eq("its own content survives the re-quoting intact", true,
  last_osascript_script ~= nil and last_osascript_script:find("abc-123", 1, true) ~= nil)

hs.window.frontmostWindow = real_frontmost

-- ---------------------------------------------------------------------------
-- Background opens (the scheduled passes): never into the window being
-- typed in, and Ghostty's own window id is what the script targets.
-- ---------------------------------------------------------------------------
local wide_windows = {
  { id = 42, screen_id = "wide", frame = nudged },     -- the upper_C window
  { id = 43, screen_id = "laptop", frame = elsewhere },
  { id = 44, screen_id = "wide", frame = elsewhere },
}
d = DeskTab.pick_target(screens, wide_windows, slot_frame_of, nil, 42)
assert_eq("typing in the upper_C window: another window gets the tab", "existing_window", d.mode)
assert_eq("...the frontmost other one on the ultrawide", 44, d.window_id)
assert_eq("...and the diversion is flagged", true, d.diverted)

d = DeskTab.pick_target(screens, wide_windows, slot_frame_of, nil, 43)
assert_eq("typing in some other window: upper_C is still the target", 42, d.window_id)
assert_eq("...not flagged as diverted", nil, d.diverted)

d = DeskTab.pick_target(screens, { wide_windows[1], wide_windows[2] }, slot_frame_of, nil, 42)
assert_eq("no other window on the ultrawide: any other Ghostty window", 43, d.window_id)

d = DeskTab.pick_target(screens, { wide_windows[1] }, slot_frame_of, nil, 42)
assert_eq("the only Ghostty window is the one being typed in: a new window", "new_window", d.mode)
assert_eq("...placed on the ultrawide", "wide", d.screen_id)

d = DeskTab.pick_target(laptop_only, { { id = 3, screen_id = "laptop", frame = slot } },
  slot_frame_of, { id = 3, app = "Ghostty" }, 3)
assert_eq("laptop-only, typing in the front Ghostty window: a new window", "new_window", d.mode)
assert_eq("...left unplaced (no ultrawide slot)", nil, d.screen_id)

local hs_wins = {
  { id = 10, title = "~/dev" },
  { id = 11, title = "notes" },
  { id = 12, title = "~/dev" },
}
local sc_wins = {
  { id = "tab-group-a", name = "~/dev" },
  { id = "tab-group-b", name = "notes" },
  { id = "tab-group-c", name = "~/dev" },
}
assert_eq("a unique title maps straight across", "tab-group-b",
  DeskTab.match_script_window(11, hs_wins, sc_wins))
assert_eq("a shared title maps by front-to-back rank (first)", "tab-group-a",
  DeskTab.match_script_window(10, hs_wins, sc_wins))
assert_eq("a shared title maps by front-to-back rank (second)", "tab-group-c",
  DeskTab.match_script_window(12, hs_wins, sc_wins))
assert_eq("an unknown window has no match", nil, DeskTab.match_script_window(99, hs_wins, sc_wins))
assert_eq("a shared title counted differently on the two sides is not guessed", nil,
  DeskTab.match_script_window(10, hs_wins, { sc_wins[1], sc_wins[2] }))

local known_12 = { [1] = true, [2] = true }
assert_eq("focus moved from another app onto a new Ghostty window: taken", true,
  DeskTab.focus_was_taken({ app = "Safari", window_id = 7 }, { app = "Ghostty", window_id = 3 }, known_12))
assert_eq("focus moved from a Ghostty window onto a new one: taken", true,
  DeskTab.focus_was_taken({ app = "Ghostty", window_id = 1 }, { app = "Ghostty", window_id = 3 }, known_12))
assert_eq("the user moved to another existing Ghostty window: left alone", false,
  DeskTab.focus_was_taken({ app = "Ghostty", window_id = 1 }, { app = "Ghostty", window_id = 2 }, known_12))
assert_eq("focus unchanged: not taken", false,
  DeskTab.focus_was_taken({ app = "Ghostty", window_id = 1 }, { app = "Ghostty", window_id = 1 }, known_12))
assert_eq("the user moved to another app: left alone", false,
  DeskTab.focus_was_taken({ app = "Ghostty", window_id = 1 }, { app = "Mail", window_id = 9 }, known_12))
assert_eq("no focused window yet (mid-transition): wait", false,
  DeskTab.focus_was_taken({ app = "Ghostty", window_id = 1 }, { app = "Ghostty", window_id = nil }, known_12))

local before_12 = { [1] = true, [2] = true }
assert_eq("one new window and one more Ghostty window: that one", 3,
  DeskTab.created_window(before_12, { { id = 1 }, { id = 2 }, { id = 3 } }, 2, 3))
assert_eq("Ghostty's count unchanged (a tab, not a window): nothing to place", nil,
  DeskTab.created_window(before_12, { { id = 1 }, { id = 2 }, { id = 3 } }, 2, 2))
assert_eq("an existing id vanished (its selected tab changed): nothing to place", nil,
  DeskTab.created_window(before_12, { { id = 2 }, { id = 3 } }, 2, 3))
assert_eq("two new ids: not certain, nothing to place", nil,
  DeskTab.created_window(before_12, { { id = 1 }, { id = 2 }, { id = 3 }, { id = 4 } }, 2, 3))
assert_eq("the new window not visible yet: nothing to place (yet)", nil,
  DeskTab.created_window(before_12, { { id = 1 }, { id = 2 } }, 2, 3))
assert_eq("no count from before: nothing to place", nil,
  DeskTab.created_window(before_12, { { id = 1 }, { id = 2 }, { id = 3 } }, nil, 3))

-- DeskOpenTab end to end against the stub: laptop only, the user typing in
-- Ghostty window 5, a second Ghostty window 6 behind it.
local function fake_win(id, title)
  return {
    id = function() return id end,
    title = function() return title end,
    application = function() return { name = function() return "Ghostty" end } end,
    screen = function() return { id = function() return "laptop" end } end,
    frame = function() return slot end,
  }
end
local win5, win6 = fake_win(5, "typing here"), fake_win(6, "other")
hs.window.frontmostWindow = function() return win5 end
hs.window.focusedWindow = function() return win5 end
hs.window.orderedWindows = function() return { win5, win6 } end
hs.application.frontmostApplication = function()
  return { name = function() return "Ghostty" end, activate = function() end }
end
script_windows_reply = { { "tab-group-5", "tab-group-6" }, { "typing here", "other" } }

osascript_calls, timers_started, last_osascript_script = 0, 0, nil
DeskOpenTab("echo hi", nil, nil, { background = true })
assert_eq("background: the tab goes into the other window, by Ghostty's own id", true,
  last_osascript_script ~= nil
    and last_osascript_script:find('set w to window id "tab-group-6"', 1, true) ~= nil
    and last_osascript_script:find("new tab in w with configuration", 1, true) ~= nil)
assert_eq("background: the focus guard is started", 1, timers_started)

osascript_calls, timers_started, last_osascript_script = 0, 0, nil
DeskOpenTab("echo hi", nil, nil)
assert_eq("hotkey (no background): the front window gets the tab, as asked", true,
  last_osascript_script ~= nil
    and last_osascript_script:find('set w to window id "tab-group-5"', 1, true) ~= nil
    and last_osascript_script:find("new tab in w with configuration", 1, true) ~= nil)
assert_eq("hotkey: no focus guard", 0, timers_started)

script_windows_reply = { { "tab-group-5", "tab-group-6" }, { "typing here", "renamed" } }
osascript_calls, timers_started, last_osascript_script = 0, 0, nil
DeskOpenTab("echo hi", nil, nil, { background = true })
assert_eq("target window not identifiable to Ghostty: a new window, never an untargeted tab", true,
  last_osascript_script ~= nil
    and last_osascript_script:find("new window with configuration", 1, true) ~= nil)

-- How DeskOpenTab reads hs.osascript.applescript's ok, result, descriptor:
-- success is ok, whatever the result; a failure's message is in the
-- descriptor, never the (nil) result.
assert_eq("osascript_error reads the message key", "Ghostty got an error: x.",
  DeskTab.osascript_error({ OSAScriptErrorMessageKey = "Ghostty got an error: x." }))
assert_eq("osascript_error falls back to the localized description", "y",
  DeskTab.osascript_error({ NSLocalizedDescription = "y" }))

local real_applescript = hs.osascript.applescript
local next_reply
hs.osascript.applescript = function(script)
  if script:find("get {id, name} of every window", 1, true) then
    return true, script_windows_reply, ""
  end
  last_osascript_script = script
  return table.unpack(next_reply, 1, 3)
end
local printed = {}
local real_print = print
local function open_capturing(reply)
  next_reply, printed = reply, {}
  print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
  local r = DeskOpenTab("echo hi", nil, nil)
  print = real_print
  return r
end
local function printed_has(text)
  for _, line in ipairs(printed) do
    if line:find(text, 1, true) then return true end
  end
  return false
end
script_windows_reply = { { "tab-group-5", "tab-group-6" }, { "typing here", "other" } }

assert_eq("ok with a result is success", true, open_capturing({ true, "opened", "" }))
assert_eq("ok with no result at all is success too", true, open_capturing({ true, nil, "" }))
assert_eq("...and logs no failure", false, printed_has("failed"))
assert_eq("created though Ghostty raised afterwards: success", true,
  open_capturing({ true, "opened despite: Can't get tab.", "" }))
assert_eq("...noting what Ghostty said", true, printed_has("opened despite: Can't get tab."))
assert_eq("a real failure is a failure", false, open_capturing({ false, nil,
  { OSAScriptErrorMessageKey = "Ghostty got an error: Target window is no longer available." } }))
assert_eq("...reporting Ghostty's own message, not nil", true,
  printed_has("osascript failed: Ghostty got an error: Target window is no longer available."))
assert_eq("the script judges creation by the tab count, re-raising when nothing was made", true,
  last_osascript_script:find("set countBefore to count of tabs of w", 1, true) ~= nil
    and last_osascript_script:find("error errMsg number errNum", 1, true) ~= nil)
hs.osascript.applescript = real_applescript

hs.window.frontmostWindow = real_frontmost
hs.window.focusedWindow = function() return nil end
hs.window.orderedWindows = function() return {} end
hs.application.frontmostApplication = function() return nil end

-- ---------------------------------------------------------------------------
-- DeskTab.focus_tty_script: the tty is a terminal's, looked up in /dev/ form
-- ---------------------------------------------------------------------------
if type(DeskFocusTab) ~= "function" then
  bad("DeskFocusTab global not defined after loading init.lua")
  os.exit(1)
end

local focus_script = DeskTab.focus_tty_script("ttys003")
assert_eq("a bare tty is looked up in Ghostty's /dev/ form", true,
  focus_script:find('every terminal whose tty is "/dev/ttys003"', 1, true) ~= nil)
assert_eq("a /dev/ tty is not doubled", true,
  DeskTab.focus_tty_script("/dev/ttys003"):find('"/dev/ttys003"', 1, true) ~= nil)
assert_eq("the match is focused, never a tab index set", true,
  focus_script:find("focus (item 1 of matches)", 1, true) ~= nil)
assert_eq("a quote in the tty cannot break out of the string", true,
  DeskTab.focus_tty_script('x"; quit'):find('"/dev/x\\"; quit"', 1, true) ~= nil)
assert_eq("normalize_tty strips a leading /dev/", "ttys003", DeskTab.normalize_tty("/dev/ttys003"))
assert_eq("normalize_tty leaves a bare form untouched", "ttys003", DeskTab.normalize_tty("ttys003"))

-- ---------------------------------------------------------------------------
-- DeskFocusTab's early-exit paths — never reach osascript for any of
-- these, since the stub's hs.application.get always returns nil (as if
-- Ghostty were never running) and DeskFocusTab must refuse before that.
-- ---------------------------------------------------------------------------
osascript_calls = 0
result = DeskFocusTab(nil)
assert_eq("no tty at all refuses outright", false, result)
assert_eq("and never calls osascript", 0, osascript_calls)

osascript_calls = 0
result = DeskFocusTab("")
assert_eq("an empty tty refuses outright", false, result)
assert_eq("and never calls osascript", 0, osascript_calls)

osascript_calls = 0
result = DeskFocusTab("ttys003")
assert_eq("Ghostty not running (this stub): refuses", false, result)
assert_eq("and never calls osascript either", 0, osascript_calls)

-- DeskFocusTab with Ghostty running: only a "focused" reply is success.
hs.application.get = function() return {} end
local real_as = hs.osascript.applescript
local focus_reply
hs.osascript.applescript = function() return table.unpack(focus_reply, 1, 3) end
focus_reply = { true, "focused", "" }
assert_eq("a focused terminal is success", true, DeskFocusTab("ttys003"))
focus_reply = { true, "none", "" }
assert_eq("no terminal on that tty is a failure", false, DeskFocusTab("ttys003"))
focus_reply = { false, nil, { OSAScriptErrorMessageKey = "boom" } }
assert_eq("an AppleScript error is a failure", false, DeskFocusTab("ttys003"))
hs.osascript.applescript = real_as
hs.application.get = function() return nil end

-- ---------------------------------------------------------------------------
-- A background open end to end against a simulated Ghostty: windows with
-- frames and focus, Ghostty's own activation after the open (and a second
-- steal a second later), a controllable clock and the opener's timers.
-- Every pre-existing window's frame must come out unchanged, only a window
-- the open created may get a frame, and focus must end where it started.
-- ---------------------------------------------------------------------------
local saved_hs = {
  window = hs.window, screen = hs.screen, application = hs.application,
  osascript = hs.osascript, timer = hs.timer,
}
local UPPER_C = { x = 2663, y = -498, w = 1136, h = 700 }
local LOWER_C = { x = 2663, y = 212, w = 1136, h = 690 }
local UPPER_R = { x = 3810, y = -498, w = 1131, h = 700 }
local CASCADE = { x = 1600, y = -400, w = 900, h = 600 }
local wide = { id = function() return "wide" end,
  frame = function() return { x = 1512, y = -498, w = 3440, h = 1410 } end }

local function new_world(recs, focused, front_app)
  local world = { recs = recs, focused = focused, front_app = front_app, clock = 0,
    timers = {}, events = {}, set_frames = {}, next_id = 2001 }
  local function rec_by_id(id)
    for _, r in ipairs(world.recs) do if r.id == id then return r end end
  end
  local function focus_rec(r)
    world.focused, world.front_app = r.id, r.app
    for i, x in ipairs(world.recs) do
      if x == r then table.remove(world.recs, i) break end
    end
    table.insert(world.recs, 1, r)
  end
  local function win_obj(r)
    if not r then return nil end
    return {
      id = function() return r.id end,
      title = function() return r.title end,
      application = function() return { name = function() return r.app end } end,
      screen = function() return wide end,
      frame = function() return r.frame end,
      setFrame = function(_, f)
        world.set_frames[#world.set_frames + 1] = { id = r.id, frame = f }
        r.frame = f
      end,
      focus = function() focus_rec(r) end,
    }
  end
  local function at(dt, fn) world.events[#world.events + 1] = { at = world.clock + dt, fn = fn } end
  -- Ghostty makes what it created key, then does it once more a second later.
  local function ghostty_takes_focus(r)
    at(0.1, function() focus_rec(r) end)
    at(1.0, function() focus_rec(r) end)
  end

  hs.screen = { allScreens = function() return { wide } end }
  hs.window = {
    animationDuration = 0,
    orderedWindows = function()
      local out = {}
      for _, r in ipairs(world.recs) do out[#out + 1] = win_obj(r) end
      return out
    end,
    focusedWindow = function() return win_obj(rec_by_id(world.focused)) end,
    frontmostWindow = function() return win_obj(rec_by_id(world.focused)) end,
    get = function(id) return win_obj(rec_by_id(id)) end,
  }
  hs.application = {
    get = function() return {} end,
    frontmostApplication = function()
      return { name = function() return world.front_app end, activate = function() end }
    end,
  }
  hs.timer = {
    secondsSinceEpoch = function() return world.clock end,
    doEvery = function(_, fn)
      local t = { fn = fn }
      function t:stop() self.stopped = true end
      world.timers[#world.timers + 1] = t
      return t
    end,
    doAfter = function(_, fn)
      local t = { fn = fn, once = true }
      function t:stop() self.stopped = true end
      world.timers[#world.timers + 1] = t
      return t
    end,
  }
  hs.osascript = {
    applescript = function(script)
      if script:find("get {id, name} of every window", 1, true) then
        local ids, names = {}, {}
        for _, r in ipairs(world.recs) do
          if r.app == "Ghostty" then ids[#ids + 1] = r.script_id; names[#names + 1] = r.title end
        end
        return true, { ids, names }, ""
      end
      local target = script:match('set w to window id "([^"]+)"')
      if target and script:find("new tab in w", 1, true) then
        world.tab_target = target
        for _, r in ipairs(world.recs) do
          if r.script_id == target then
            -- The new tab is its own window: the group now shows under a new id.
            local new_id = world.next_id
            world.next_id = new_id + 1
            at(0.05, function() r.id, r.title = new_id, "👻" end)
            ghostty_takes_focus(r)
          end
        end
        return true, "opened", ""
      end
      if script:find("new window with configuration", 1, true) then
        world.opened_window = true
        local r = { id = world.next_id, script_id = "tab-group-new", title = "👻",
          frame = CASCADE, app = "Ghostty" }
        world.next_id = world.next_id + 1
        world.created_id = r.id
        at(0.15, function() table.insert(world.recs, 1, r) end)
        ghostty_takes_focus(r)
        if world.also_swap then
          at(0.05, function() rec_by_id(world.also_swap).id = 3999 end)
        end
        return true, "opened", ""
      end
      local activate = script:match('activate window %(window id "([^"]+)"%)')
      if activate then
        for _, r in ipairs(world.recs) do
          if r.script_id == activate then focus_rec(r) end
        end
        return true, nil, ""
      end
      return false, nil, { OSAScriptErrorMessageKey = "unexpected script" }
    end,
  }

  function world.run(seconds)
    local stop_at = world.clock + seconds
    while world.clock < stop_at do
      world.clock = world.clock + 0.01
      for _, e in ipairs(world.events) do
        if not e.done and e.at <= world.clock then e.done = true; e.fn() end
      end
      for _, t in ipairs(world.timers) do
        if not t.stopped then
          t.fn()
          if t.once then t.stopped = true end
        end
      end
    end
  end
  function world.frames()
    local out = {}
    for _, r in ipairs(world.recs) do out[r.script_id or r.id] = r.frame end
    return out
  end
  return world
end

local function frames_unchanged(desc, before_frames, world, except_key)
  local after = world.frames()
  local same = true
  for key, f in pairs(before_frames) do
    local g = after[key]
    if key ~= except_key and (g == nil or g.x ~= f.x or g.y ~= f.y or g.w ~= f.w or g.h ~= f.h) then
      same = false
    end
  end
  assert_eq(desc, true, same)
end

local function silently(fn)
  local real = print
  print = function() end
  local r = fn()
  print = real
  return r
end

-- Typing in the upper_C window: the tab goes into another window, which
-- shows under a new id afterwards; nothing moves and focus comes back.
local w = new_world({
  { id = 1138, script_id = "tab-group-a", title = "deploy", frame = UPPER_C, app = "Ghostty" },
  { id = 175, script_id = "tab-group-b", title = "~/dev", frame = LOWER_C, app = "Ghostty" },
  { id = 510, script_id = "tab-group-c", title = "notes", frame = UPPER_R, app = "Ghostty" },
}, 1138, "Ghostty")
local frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(6)
assert_eq("typing in upper_C: the tab went to another window", true, w.tab_target ~= "tab-group-a")
assert_eq("...focus is back on the window being typed in, after both steals", 1138, w.focused)
assert_eq("...no window was given a frame", 0, #w.set_frames)
frames_unchanged("...every existing window's frame is unchanged", frames0, w)

-- The live failure: typing in a Ghostty window with nothing in upper_C, so
-- a new window opens. Only that window is placed; focus comes back.
w = new_world({
  { id = 1138, script_id = "tab-group-a", title = "deploy", frame = LOWER_C, app = "Ghostty" },
  { id = 510, script_id = "tab-group-c", title = "notes", frame = UPPER_R, app = "Ghostty" },
}, 1138, "Ghostty")
frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(6)
assert_eq("new window: one was opened", true, w.opened_window)
assert_eq("...focus is back on the window being typed in, after both steals", 1138, w.focused)
assert_eq("...exactly one frame was set", 1, #w.set_frames)
assert_eq("...and only on the window the open created", w.created_id, w.set_frames[1] and w.set_frames[1].id)
frames_unchanged("...every existing window's frame is unchanged", frames0, w, "tab-group-new")

-- Another app frontmost: the tab goes into upper_C, and focus returns to
-- that app's window.
w = new_world({
  { id = 9, title = "page", frame = CASCADE, app = "Safari" },
  { id = 1138, script_id = "tab-group-a", title = "deploy", frame = UPPER_C, app = "Ghostty" },
}, 9, "Safari")
frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(6)
assert_eq("another app frontmost: the tab went into upper_C", "tab-group-a", w.tab_target)
assert_eq("...focus is back in that app", "Safari", w.front_app)
assert_eq("...on its window", 9, w.focused)
assert_eq("...no window was given a frame", 0, #w.set_frames)
frames_unchanged("...every existing window's frame is unchanged", frames0, w)

-- A new window while an existing window's id changes (the user switched
-- tabs in it): the new id is not certainly the created window, so nothing
-- is placed at all.
w = new_world({
  { id = 1138, script_id = "tab-group-a", title = "deploy", frame = LOWER_C, app = "Ghostty" },
  { id = 510, script_id = "tab-group-c", title = "notes", frame = UPPER_R, app = "Ghostty" },
}, 1138, "Ghostty")
w.also_swap = 510
frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(6)
assert_eq("an id swap during the open: no window is given a frame", 0, #w.set_frames)
frames_unchanged("...every existing window's frame is unchanged", frames0, w, "tab-group-new")

-- The user moves to another existing Ghostty window right after the open:
-- left there, not pulled back.
w = new_world({
  { id = 9, title = "page", frame = CASCADE, app = "Safari" },
  { id = 1138, script_id = "tab-group-a", title = "deploy", frame = UPPER_C, app = "Ghostty" },
  { id = 510, script_id = "tab-group-c", title = "notes", frame = UPPER_R, app = "Ghostty" },
}, 9, "Safari")
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(0.5)
hs.window.get(510):focus()
w.run(0.3)
assert_eq("the user's own move to an existing window is left alone", 510, w.focused)

-- A locked screen: Ghostty has windows, Hammerspoon sees none. Nothing is
-- opened (no new window landing on top of the layout) and it says so.
w = new_world({
  { id = 1138, script_id = "tab-group-a", title = "deploy", frame = UPPER_C, app = "Ghostty" },
}, 0, "loginwindow")
hs.window.orderedWindows = function() return {} end
local locked_result = silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(1)
assert_eq("screen locked: the open is refused", false, locked_result)
assert_eq("...no window was opened", nil, w.opened_window)
assert_eq("...no tab was opened", nil, w.tab_target)

for k, v in pairs(saved_hs) do hs[k] = v end

print()
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
