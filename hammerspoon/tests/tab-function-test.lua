-- Offline test for the Ghostty-tab pieces in hammerspoon/init.lua:
-- loads the real file against a minimal hs.* stub (just enough that its
-- top-level calls — hs.hotkey.modal.new, the eventtaps, the watchers, the
-- closing hs.alert.show — don't error), then exercises the pure parts with
-- plain Lua: DeskTab.pick_target (slot geometry) and the UUID validation
-- gate on DeskOpenTab, plus DeskTab.pick_tab_by_tty and DeskFocusTab's
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
-- Every tab command runs through his login+interactive
-- shell (/bin/zsh -lic '<command>'), never Ghostty's own command: field
-- invoking it directly — CLAUDE_CONFIG_DIR and PATH have to come from his
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

assert_eq("focus moved onto a new Ghostty tab: taken", true,
  DeskTab.focus_was_taken({ app = "Safari", window_id = 1 }, { app = "Ghostty", window_id = 2 }))
assert_eq("focus moved between Ghostty windows: taken", true,
  DeskTab.focus_was_taken({ app = "Ghostty", window_id = 1 }, { app = "Ghostty", window_id = 2 }))
assert_eq("focus unchanged: not taken", false,
  DeskTab.focus_was_taken({ app = "Ghostty", window_id = 1 }, { app = "Ghostty", window_id = 1 }))
assert_eq("the user moved to another app: left alone", false,
  DeskTab.focus_was_taken({ app = "Ghostty", window_id = 1 }, { app = "Mail", window_id = 9 }))

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
    and last_osascript_script:find('new tab in window id "tab-group-6"', 1, true) ~= nil)
assert_eq("background: the focus guard is started", 1, timers_started)

osascript_calls, timers_started, last_osascript_script = 0, 0, nil
DeskOpenTab("echo hi", nil, nil)
assert_eq("hotkey (no background): the front window gets the tab, as asked", true,
  last_osascript_script ~= nil
    and last_osascript_script:find('new tab in window id "tab-group-5"', 1, true) ~= nil)
assert_eq("hotkey: no focus guard", 0, timers_started)

script_windows_reply = { { "tab-group-5", "tab-group-6" }, { "typing here", "renamed" } }
osascript_calls, timers_started, last_osascript_script = 0, 0, nil
DeskOpenTab("echo hi", nil, nil, { background = true })
assert_eq("target window not identifiable to Ghostty: a new window, never an untargeted tab", true,
  last_osascript_script ~= nil
    and last_osascript_script:find("new window with configuration", 1, true) ~= nil)

hs.window.frontmostWindow = real_frontmost
hs.window.focusedWindow = function() return nil end
hs.window.orderedWindows = function() return {} end
hs.application.frontmostApplication = function() return nil end

-- ---------------------------------------------------------------------------
-- DeskTab.pick_tab_by_tty
-- ---------------------------------------------------------------------------
if type(DeskTab.pick_tab_by_tty) ~= "function" then
  bad("DeskTab.pick_tab_by_tty not defined after loading init.lua")
  os.exit(1)
end
if type(DeskFocusTab) ~= "function" then
  bad("DeskFocusTab global not defined after loading init.lua")
  os.exit(1)
end

local tabs = {
  { window_id = 1, tab_index = 1, tty = "ttys001" },
  { window_id = 1, tab_index = 2, tty = "ttys003" },
  { window_id = 2, tab_index = 1, tty = "ttys007" },
}
local found = DeskTab.pick_tab_by_tty(tabs, "ttys003")
assert_eq("a matching tty is found", 1, found and found.window_id)
assert_eq("...at its own tab index", 2, found and found.tab_index)

found = DeskTab.pick_tab_by_tty(tabs, "ttys999")
assert_eq("no matching tty returns nil", nil, found)

found = DeskTab.pick_tab_by_tty({}, "ttys001")
assert_eq("an empty tab list returns nil", nil, found)

-- normalize_tty matches both "ttysNNN" and "/dev/ttysNNN"
-- regardless of which form either side happens to report.
local tabs_with_dev_prefix = {
  { window_id = 9, tab_index = 1, tty = "/dev/ttys003" },
}
found = DeskTab.pick_tab_by_tty(tabs_with_dev_prefix, "ttys003")
assert_eq("a bare-form target still matches a /dev/-prefixed tab", 9, found and found.window_id)
found = DeskTab.pick_tab_by_tty(tabs, "/dev/ttys003")
assert_eq("a /dev/-prefixed target still matches a bare-form tab", 1, found and found.window_id)
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

print()
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
