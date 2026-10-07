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
-- What the stubbed Ghostty dictionary reports for `{id, name} of every window`
-- and for `id of front window`.
local script_windows_reply = { {}, {} }
local front_window_reply = nil
-- What `defaults read … NSWindowLastPosition` prints, or nil for nothing.
local saved_position_reply = nil

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
    usleep = function() end,
  },
  screen = {
    allScreens = function() return {} end,
    primaryScreen = function() return { fullFrame = function() return { h = 1000 } end } end,
  },
  execute = function() return saved_position_reply, saved_position_reply ~= nil end,
  application = {
    get = function() return nil end,
    frontmostApplication = function() return nil end,
  },
  osascript = {
    applescript = function(script)
      if script:find("get {id, name} of every window", 1, true) then
        return true, script_windows_reply, ""
      end
      if script:find("get id of front window", 1, true) then
        return true, front_window_reply, ""
      end
      osascript_calls = osascript_calls + 1
      if script:find("activate window", 1, true) then return true, nil, "" end
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
-- DeskTab.slot_windows, DeskTab.plan_open
-- ---------------------------------------------------------------------------
local lower_slot = { x = 1000, y = 400, w = 600, h = 400 }
local function slot_frame_of(_, name) return name == "lower_C" and lower_slot or slot end

local screens = { { id = "wide", wide = true }, { id = "laptop", wide = false } }
local windows = {
  { id = 42, screen_id = "wide", frame = nudged },
  { id = 43, screen_id = "wide", frame = { x = 1010, y = 420, w = 580, h = 360 } },
}
local up, low = DeskTab.slot_windows(screens, windows, slot_frame_of, nil)
assert_eq("the upper_C window is found", 42, up)
assert_eq("the lower_C window is found", 43, low)

up, low = DeskTab.slot_windows(screens, { { id = 7, screen_id = "wide", frame = elsewhere } }, slot_frame_of, nil)
assert_eq("a window outside both slots is neither", nil, up)
assert_eq("...in either slot", nil, low)

up = DeskTab.slot_windows(screens, { { id = 9, screen_id = "laptop", frame = slot } }, slot_frame_of, nil)
assert_eq("a same-shaped window on the wrong screen doesn't match", nil, up)

local laptop_only = { { id = "laptop", wide = false } }
assert_eq("laptop-only: a frontmost Ghostty window stands in for upper_C", 3,
  DeskTab.slot_windows(laptop_only, {}, slot_frame_of, { id = 3, app = "Ghostty" }))
assert_eq("laptop-only: another app in front means no upper_C", nil,
  DeskTab.slot_windows(laptop_only, {}, slot_frame_of, { id = 3, app = "Safari" }))

local plan = DeskTab.plan_open(42, 43, 99, true)
assert_eq("typing elsewhere: the tab goes to upper_C", 42, plan.window_id)
plan = DeskTab.plan_open(42, 43, 42, true)
assert_eq("typing in upper_C: a background tab falls back to lower_C", 43, plan.window_id)
plan = DeskTab.plan_open(42, nil, 42, true)
assert_eq("typing in upper_C with no lower_C: a new window", "new_window", plan.mode)
plan = DeskTab.plan_open(nil, 43, 99, true)
assert_eq("no upper_C: a new window (lower_C is only the fallback)", "new_window", plan.mode)
plan = DeskTab.plan_open(42, 43, nil, false)
assert_eq("the hotkey: upper_C", 42, plan.window_id)
plan = DeskTab.plan_open(42, 43, 42, false)
assert_eq("the hotkey, typing in upper_C: still upper_C (it wants the focus)", 42, plan.window_id)

-- ---------------------------------------------------------------------------
-- A new window: identified only for certain, and placed clear of focus
-- ---------------------------------------------------------------------------
local before_12 = { [1] = true, [2] = true }
assert_eq("one new id and one more Ghostty window: that one", 3,
  DeskTab.created_window(before_12, { { id = 1 }, { id = 2 }, { id = 3 } }, 2, 3))
assert_eq("Ghostty's count unchanged: not certain", nil,
  DeskTab.created_window(before_12, { { id = 1 }, { id = 2 }, { id = 3 } }, 2, 2))
assert_eq("an existing id vanished (its selected tab changed): not certain", nil,
  DeskTab.created_window(before_12, { { id = 2 }, { id = 3 } }, 2, 3))
assert_eq("two new ids: not certain", nil,
  DeskTab.created_window(before_12, { { id = 1 }, { id = 2 }, { id = 3 }, { id = 4 } }, 2, 3))
assert_eq("no count from before: not certain", nil,
  DeskTab.created_window(before_12, { { id = 1 }, { id = 2 }, { id = 3 } }, nil, 3))

local A = { x = 0, y = 0, w = 100, h = 100 }
assert_eq("overlapping frames overlap", true, DeskTab.frames_overlap(A, { x = 50, y = 50, w = 100, h = 100 }))
assert_eq("frames that only touch do not", false, DeskTab.frames_overlap(A, { x = 100, y = 0, w = 100, h = 100 }))
local slot_a, slot_b, slot_c = { x = 0, y = 0, w = 100, h = 100 }, { x = 200, y = 0, w = 100, h = 100 },
  { x = 400, y = 0, w = 100, h = 100 }
assert_eq("a slot over the focused window is never picked", slot_b,
  DeskTab.pick_free_slot({ slot_a, slot_b }, {}, slot_a))
assert_eq("a free slot beats one holding another window", slot_c,
  DeskTab.pick_free_slot({ slot_b, slot_c }, { { x = 210, y = 10, w = 80, h = 80 } }, slot_a))
assert_eq("no free slot: one at least clear of the focused window", slot_b,
  DeskTab.pick_free_slot({ slot_a, slot_b }, { { x = 210, y = 10, w = 80, h = 80 } }, slot_a))
assert_eq("every slot over the focused window: none", nil,
  DeskTab.pick_free_slot({ slot_a }, {}, slot_a))

-- ---------------------------------------------------------------------------
-- Ghostty's saved last window position
-- ---------------------------------------------------------------------------
local saved = DeskTab.parse_saved_position("(\n    2663,\n    780,\n    1136,\n    700\n)\n")
assert_eq("the defaults output parses", "2663,780,1136,700",
  saved and string.format("%d,%d,%d,%d", saved.x, saved.y, saved.w, saved.h))
assert_eq("fractional values parse too", 780.5, DeskTab.parse_saved_position("(1, 780.5, 3, 4)").y)
assert_eq("too few values is nil", nil, DeskTab.parse_saved_position("(1, 2)"))
assert_eq("no output is nil", nil, DeskTab.parse_saved_position(nil))
-- The live case: the upper-mid window, primary screen 982 high.
local upper_mid = { x = 2663, y = -498, w = 1136, h = 700 }
local lower_mid = { x = 2663, y = 212, w = 1136, h = 690 }
assert_eq("the saved position is the upper-mid window's", true, DeskTab.saved_position_is(saved, upper_mid, 982))
assert_eq("...not the lower-mid window's", false, DeskTab.saved_position_is(saved, lower_mid, 982))
assert_eq("no saved position is never a match", false, DeskTab.saved_position_is(nil, upper_mid, 982))

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
last_osascript_script = nil
result = DeskOpenTab("echo hi", nil, nil)
assert_eq("no ultrawide, no frontmost Ghostty window (this stub): a new window is asked for", true,
  last_osascript_script ~= nil and last_osascript_script:find("new window with configuration", 1, true) ~= nil)
assert_eq("...which this stub's osascript fails, so false", false, result)

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

front_window_reply = "tab-group-5"
osascript_calls, timers_started, last_osascript_script = 0, 0, nil
DeskOpenTab("echo hi", nil, nil, { background = true })
assert_eq("background, typing in Ghostty: a new window, never a tab in an existing one", true,
  last_osascript_script ~= nil
    and last_osascript_script:find("new window with configuration", 1, true) ~= nil
    and last_osascript_script:find("new tab", 1, true) == nil)
assert_eq("background: the focus guard is started, and no other timer", 1, timers_started)

-- The window's frame (`slot`, primary screen 1000 high) as Ghostty saves it.
local SAVED_WIN5 = "(\n    1000,\n    600,\n    600,\n    400\n)"
saved_position_reply = SAVED_WIN5
osascript_calls, timers_started, last_osascript_script = 0, 0, nil
DeskOpenTab("echo hi", nil, nil)
assert_eq("hotkey (no background), saved position already its own: the tab goes in", true,
  last_osascript_script ~= nil
    and last_osascript_script:find('set w to window id "tab-group-5"', 1, true) ~= nil
    and last_osascript_script:find("new tab in w with configuration", 1, true) ~= nil)
assert_eq("hotkey: no focus guard", 0, timers_started)
assert_eq("...and no activation was needed", 1, osascript_calls)

-- The saved position is another window's: Ghostty is asked to focus the
-- target first, and the tab goes in only once the saved position is the
-- target's own; if it never becomes so, a new window instead.
local scripts_seen = {}
local real_as_for_saved = hs.osascript.applescript
hs.osascript.applescript = function(script)
  scripts_seen[#scripts_seen + 1] = script
  if script:find("activate window", 1, true) then saved_position_reply = SAVED_WIN5 end
  return real_as_for_saved(script)
end
saved_position_reply = "(1, 2, 3, 4)"
last_osascript_script = nil
DeskOpenTab("echo hi", nil, nil)
local activated_first = false
for _, sc in ipairs(scripts_seen) do
  if sc:find('activate window (window id "tab-group-5")', 1, true) then activated_first = true end
  if sc:find("new tab in w", 1, true) then break end
end
assert_eq("another window's saved position: the target is focused first", true, activated_first)
assert_eq("...then the tab goes in", true,
  last_osascript_script ~= nil and last_osascript_script:find("new tab in w with configuration", 1, true) ~= nil)

scripts_seen = {}
hs.osascript.applescript = function(script)
  scripts_seen[#scripts_seen + 1] = script
  return real_as_for_saved(script)
end
saved_position_reply = "(1, 2, 3, 4)"
last_osascript_script = nil
DeskOpenTab("echo hi", nil, nil)
assert_eq("the saved position never becomes the target's: a new window, so nothing moves", true,
  last_osascript_script ~= nil and last_osascript_script:find("new window with configuration", 1, true) ~= nil)
hs.osascript.applescript = real_as_for_saved
saved_position_reply = SAVED_WIN5

script_windows_reply = { { "tab-group-5", "tab-group-6" }, { "typing here", "renamed" } }
osascript_calls, timers_started, last_osascript_script = 0, 0, nil
win5 = fake_win(5, "renamed meanwhile")
DeskOpenTab("echo hi", nil, nil)
assert_eq("hotkey, target not identifiable to Ghostty: a new window, never an untargeted tab", true,
  last_osascript_script ~= nil
    and last_osascript_script:find("new window with configuration", 1, true) ~= nil)
win5 = fake_win(5, "typing here")
script_windows_reply = { { "tab-group-5", "tab-group-6" }, { "typing here", "other" } }

osascript_calls, last_osascript_script = 0, nil
DeskOpenTab("echo hi", nil, nil, { background = true, close_on_exit = true })
assert_eq("close_on_exit: the command is the shell's initial input, exec'ed", true,
  last_osascript_script ~= nil
    and last_osascript_script:find('initial input:(" exec /bin/zsh -lic', 1, true) ~= nil
    and last_osascript_script:find("command:", 1, true) == nil)
osascript_calls, last_osascript_script = 0, nil
DeskOpenTab("echo hi", nil, nil, { background = true })
assert_eq("default: a command surface, which Ghostty keeps open after exit", true,
  last_osascript_script ~= nil and last_osascript_script:find('command:"/bin/zsh -lic', 1, true) ~= nil)
front_window_reply = nil

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
  if script:find("get id of front window", 1, true) then
    return true, nil, ""
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
-- No window may be given a frame at all, every pre-existing window's frame
-- must come out unchanged, and focus must end where it started.
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

local PRIMARY_H = 982
local function new_world(recs, focused, front_app)
  local world = { recs = recs, focused = focused, front_app = front_app, clock = 0,
    timers = {}, events = {}, set_frames = {}, next_id = 2001, moved = {} }
  -- Ghostty's saved last position: the frame of the Ghostty window it last
  -- focused. It starts as the frontmost Ghostty window's.
  for _, r in ipairs(recs) do
    if r.app == "Ghostty" then world.saved = r.frame break end
  end
  local function rec_by_id(id)
    for _, r in ipairs(world.recs) do if r.id == id then return r end end
  end
  local function focus_rec(r)
    world.focused, world.front_app = r.id, r.app
    if r.app == "Ghostty" and not world.freeze_saved then world.saved = r.frame end
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
        -- Ghostty saves a window's frame whenever it moves or resizes.
        if r.app == "Ghostty" and not world.freeze_saved then world.saved = f end
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
  -- Showing a new tab moves its whole window to the saved position, as
  -- Ghostty does: this is how a tab moved a window on screen.
  local function ghostty_shows_tab(r)
    at(0.08, function()
      local f, sv = r.frame, world.saved
      if sv and (sv.x ~= f.x or sv.y ~= f.y) then
        world.moved[#world.moved + 1] = r.script_id
        r.frame = { x = sv.x, y = sv.y, w = f.w, h = f.h }
      end
    end)
  end

  hs.screen = {
    allScreens = function() return { wide } end,
    primaryScreen = function() return { fullFrame = function() return { h = PRIMARY_H } end } end,
  }
  hs.execute = function()
    local sv = world.saved
    if not sv then return "", false end
    return string.format("(\n    %d,\n    %d,\n    %d,\n    %d\n)\n", sv.x, PRIMARY_H - (sv.y + sv.h), sv.w, sv.h), true
  end
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
    usleep = function() end,
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
      if script:find("get id of front window", 1, true) then
        for _, r in ipairs(world.recs) do
          if r.app == "Ghostty" then return true, r.script_id, "" end
        end
        return true, nil, ""
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
            ghostty_shows_tab(r)
            ghostty_takes_focus(r)
          end
        end
        return true, "opened", ""
      end
      if script:find("new window with configuration", 1, true) then
        world.opened_window = true
        -- Ghostty shows a new window at its saved position: right over the
        -- window the user was working in.
        local sv = world.saved or CASCADE
        local r = { id = world.next_id, script_id = "tab-group-new", title = "👻",
          frame = { x = sv.x, y = sv.y, w = 900, h = 600 }, app = "Ghostty" }
        world.next_id = world.next_id + 1
        world.created_id = r.id
        at(0.15, function() table.insert(world.recs, 1, r) end)
        ghostty_takes_focus(r)
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

local function new_window_rec(world)
  for _, r in ipairs(world.recs) do
    if r.script_id == "tab-group-new" then return r end
  end
end
local function overlaps(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end
-- After a new-window open: the new window is clear of the window that had
-- focus, only it was given a frame, and Ghostty's saved position is the
-- user's own window's (when it is Ghostty's), so the next tab cannot drag.
local function new_window_checks(desc, world, focused_frame, user_ghostty_frame)
  local nw = new_window_rec(world)
  assert_eq(desc .. ": a new window exists", true, nw ~= nil)
  assert_eq(desc .. ": it does not overlap the window that had focus", false,
    nw ~= nil and overlaps(nw.frame, focused_frame))
  local only_new = true
  for _, sf in ipairs(world.set_frames) do
    if sf.id ~= world.created_id then only_new = false end
  end
  assert_eq(desc .. ": only the new window was given a frame", true, only_new)
  if user_ghostty_frame then
    local sv = world.saved
    assert_eq(desc .. ": Ghostty's saved position is the user's window's again", true,
      sv ~= nil and sv.x == user_ghostty_frame.x and sv.y == user_ghostty_frame.y)
  end
end

local function silently(fn)
  local real = print
  print = function() end
  local r = fn()
  print = real
  return r
end

-- Typing in upper_C: the tab falls back to lower_C. Ghostty's saved
-- position is upper_C's, so lower_C is focused first (saving its own
-- frame), then the tab goes in; nothing moves, and focus comes back to
-- upper_C after both of Ghostty's steals.
local w = new_world({
  { id = 1138, script_id = "tab-group-a", title = "deploy", frame = UPPER_C, app = "Ghostty" },
  { id = 175, script_id = "tab-group-b", title = "~/dev", frame = LOWER_C, app = "Ghostty" },
  { id = 510, script_id = "tab-group-c", title = "notes", frame = UPPER_R, app = "Ghostty" },
}, 1138, "Ghostty")
local frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(6)
assert_eq("typing in upper_C: the tab went into lower_C", "tab-group-b", w.tab_target)
assert_eq("...no window moved on screen", 0, #w.moved)
assert_eq("...focus is back on upper_C, after both steals", 1138, w.focused)
assert_eq("...no window was given a frame by the opener", 0, #w.set_frames)
frames_unchanged("...every window's frame is unchanged", frames0, w)

-- Typing in lower_C: the tab goes to upper_C the same way.
w = new_world({
  { id = 1524, script_id = "tab-group-b", title = "watcher", frame = LOWER_C, app = "Ghostty" },
  { id = 175, script_id = "tab-group-a", title = "deploy", frame = UPPER_C, app = "Ghostty" },
  { id = 510, script_id = "tab-group-c", title = "notes", frame = UPPER_R, app = "Ghostty" },
}, 1524, "Ghostty")
frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(6)
assert_eq("typing in lower_C: the tab went into upper_C", "tab-group-a", w.tab_target)
assert_eq("...no window moved on screen", 0, #w.moved)
assert_eq("...focus is back on lower_C", 1524, w.focused)
frames_unchanged("...every window's frame is unchanged", frames0, w)

-- Another app frontmost and Ghostty's saved position already upper_C's:
-- the tab goes straight in, and focus returns to that app.
w = new_world({
  { id = 9, title = "page", frame = CASCADE, app = "Safari" },
  { id = 1138, script_id = "tab-group-a", title = "deploy", frame = UPPER_C, app = "Ghostty" },
  { id = 175, script_id = "tab-group-b", title = "~/dev", frame = LOWER_C, app = "Ghostty" },
}, 9, "Safari")
frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(6)
assert_eq("another app, saved position upper_C's: the tab went into upper_C", "tab-group-a", w.tab_target)
assert_eq("...no window moved on screen", 0, #w.moved)
assert_eq("...focus is back in that app, on its window", 9, w.front_app == "Safari" and w.focused)
frames_unchanged("...every window's frame is unchanged", frames0, w)

-- Another app frontmost but the saved position is lower_C's (it was
-- Ghostty's last focused window): upper_C is focused first, so nothing moves.
w = new_world({
  { id = 9, title = "page", frame = CASCADE, app = "Safari" },
  { id = 175, script_id = "tab-group-b", title = "~/dev", frame = LOWER_C, app = "Ghostty" },
  { id = 1138, script_id = "tab-group-a", title = "deploy", frame = UPPER_C, app = "Ghostty" },
}, 9, "Safari")
frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(6)
assert_eq("another app, saved position lower_C's: the tab still went into upper_C", "tab-group-a", w.tab_target)
assert_eq("...no window moved on screen", 0, #w.moved)
assert_eq("...focus is back in that app", "Safari", w.front_app)
frames_unchanged("...every window's frame is unchanged", frames0, w)

-- Ghostty never saves the target's frame (focusing it did not take): a
-- new window instead of a tab that would move the target.
w = new_world({
  { id = 1138, script_id = "tab-group-a", title = "deploy", frame = UPPER_C, app = "Ghostty" },
  { id = 175, script_id = "tab-group-b", title = "~/dev", frame = LOWER_C, app = "Ghostty" },
}, 1138, "Ghostty")
w.freeze_saved = true
frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(6)
assert_eq("the saved position never becomes the target's: a new window, no tab", true,
  w.opened_window and w.tab_target == nil)
new_window_checks("...that new window", w, UPPER_C, nil)
assert_eq("...no window moved on screen", 0, #w.moved)
assert_eq("...focus is back on upper_C", 1138, w.focused)
frames_unchanged("...every window's frame is unchanged", frames0, w, "tab-group-new")

-- Typing in upper_C with no lower_C window: a new window.
w = new_world({
  { id = 1138, script_id = "tab-group-a", title = "deploy", frame = UPPER_C, app = "Ghostty" },
  { id = 510, script_id = "tab-group-c", title = "notes", frame = UPPER_R, app = "Ghostty" },
}, 1138, "Ghostty")
frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(6)
assert_eq("typing in upper_C, no lower_C: a new window", true, w.opened_window and w.tab_target == nil)
assert_eq("...focus is back on upper_C", 1138, w.focused)
frames_unchanged("...every window's frame is unchanged", frames0, w, "tab-group-new")
new_window_checks("...that new window", w, UPPER_C, UPPER_C)
-- The next open finds Ghostty's saved position where it belongs: a tab
-- the user (or the hotkey) adds to upper_C now moves nothing.
local frames1 = w.frames()
silently(function() return DeskOpenTab("echo again", nil, nil) end)
w.run(3)
assert_eq("...and the next tab into upper_C moves nothing", 0, #w.moved)
frames_unchanged("...every window's frame still unchanged", frames1, w, "tab-group-new")

-- Another app frontmost and no Ghostty window in either middle slot: the
-- new window goes clear of that app's focused window too.
w = new_world({
  { id = 9, title = "page", frame = UPPER_C, app = "Safari" },
  { id = 510, script_id = "tab-group-c", title = "notes", frame = UPPER_R, app = "Ghostty" },
}, 9, "Safari")
w.saved = UPPER_C
frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil, { background = true }) end)
w.run(6)
assert_eq("another app, no middle-slot window: a new window", true, w.opened_window and w.tab_target == nil)
assert_eq("...focus is back in that app", "Safari", w.front_app)
frames_unchanged("...every window's frame is unchanged", frames0, w, "tab-group-new")
new_window_checks("...that new window", w, UPPER_C, nil)
local nw = new_window_rec(w)
assert_eq("...and it took a free slot, not the occupied upper_R", false, nw ~= nil and overlaps(nw.frame, UPPER_R))

-- The notes hotkey from a window that isn't upper_C: upper_C is focused
-- first, so it does not move, and focus stays on the new tab, as asked.
w = new_world({
  { id = 1524, script_id = "tab-group-b", title = "nvim", frame = LOWER_C, app = "Ghostty" },
  { id = 175, script_id = "tab-group-a", title = "deploy", frame = UPPER_C, app = "Ghostty" },
}, 1524, "Ghostty")
frames0 = w.frames()
silently(function() return DeskOpenTab("echo hi", nil, nil) end)
w.run(3)
assert_eq("hotkey: the tab went into upper_C", "tab-group-a", w.tab_target)
assert_eq("...no window moved on screen", 0, #w.moved)
assert_eq("...focus is on the new tab", 2001, w.focused)
frames_unchanged("...every window's frame is unchanged", frames0, w)

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
