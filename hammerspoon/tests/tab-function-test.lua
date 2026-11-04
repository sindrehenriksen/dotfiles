-- Offline test for the Ghostty-tab pieces in hammerspoon/init.lua: loads
-- the real file against a minimal hs.* stub, then checks what would bother
-- if it broke: a tab never goes into the window being typed in, no window
-- moves or is resized, focus comes back where it was, the command reaches
-- the user's shell intact, a locked screen opens nothing, closing a
-- session's tab closes only that one, the overview's full-height
-- stretch is put back, and a stale session is offered a restart once per
-- set of reasons, from Ghostty's tab switches alone. Never touches a real screen, window or osascript
-- call; run with the system `lua`, not Hammerspoon.
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

local tasks_started = {}
local app_watcher_fn = nil
local notes_sent = {}
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
    new = function(mods, key, fn)
      local h = { mods = mods, key = key, fn = fn, enabled = false }
      function h:enable() self.enabled = true; return self end
      function h:disable() self.enabled = false; return self end
      return h
    end,
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
    watcher = {
      new = function(fn) app_watcher_fn = fn; return setmetatable({}, inert) end,
      launched = "launched", activated = "activated", deactivated = "deactivated", terminated = "terminated",
    },
  },
  uielement = { watcher = { mainWindowChanged = "AXMainWindowChanged", applicationActivated = "AXApplicationActivated" } },
  -- Tasks are recorded, never run: a test finishes one by calling its
  -- callback.
  task = {
    new = function(path, done, args)
      local t = { path = path, done = done, args = args or {} }
      function t:setEnvironment(env) self.env = env; return self end
      function t:start() tasks_started[#tasks_started + 1] = self; return self end
      return t
    end,
  },
  notify = {
    activationTypes = { actionButtonClicked = 2, contentsClicked = 1 },
    new = function(fn, attrs)
      if type(fn) == "table" then fn, attrs = nil, fn end
      local n = { fn = fn, attrs = attrs }
      function n:send() notes_sent[#notes_sent + 1] = self; return self end
      function n:activationType() return self.clicked end
      return n
    end,
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


local slot = { x = 1000, y = 0, w = 600, h = 400 }
local nudged = { x = 1010, y = 20, w = 580, h = 360 }
local elsewhere = { x = 0, y = 0, w = 300, h = 300 }
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
assert_eq("a session tab hands the user's shell the command as input, not exec'd, so a prompt is left after it", true,
  last_osascript_script ~= nil
    and last_osascript_script:find('initial input:(" /bin/zsh -lic ', 1, true) ~= nil
    and last_osascript_script:find("command:", 1, true) == nil)

last_osascript_script = nil
DeskOpenTab("true", nil, nil, { close_on_exit = true })
assert_eq("a close tab exec's it, so the tab ends with the command", true,
  last_osascript_script ~= nil and last_osascript_script:find('initial input:(" exec /bin/zsh -lic ', 1, true) ~= nil)

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

-- ---------------------------------------------------------------------------
-- Closing a session's tab: DeskTabTerminal names the terminal while the
-- session still runs in it, DeskCloseTerminalTab closes its tab afterwards.
-- ---------------------------------------------------------------------------
local close_script = DeskTab.close_terminal_tab_script('T"1')
assert_eq("a tab with other terminals in it, or two tabs claiming the terminal, are refused before the close", true,
  close_script:find('return "split"', 1, true) < close_script:find("close tab t", 1, true)
    and close_script:find('return "ambiguous"', 1, true) < close_script:find("close tab t", 1, true))
hs.application.get = function() return {} end
local real_close_as = hs.osascript.applescript
local terminal_reply
hs.osascript.applescript = function() return table.unpack(terminal_reply, 1, 3) end
terminal_reply = { true, "4242 T1", "" }
assert_eq("the terminal running the session's pid is named", "terminal T1", DeskTabTerminal("ttys007", 4242))
assert_eq("...a pid given as a string matches too", "terminal T1", DeskTabTerminal("ttys007", "4242"))
assert_eq("a terminal running another pid in the foreground is not", false,
  silently(function() return DeskTabTerminal("ttys007", 4243) end))
terminal_reply = { true, "none", "" }
assert_eq("no terminal on the tty", false, silently(function() return DeskTabTerminal("ttys007", 4242) end))
terminal_reply = { true, "many", "" }
assert_eq("several terminals on the tty", false, silently(function() return DeskTabTerminal("ttys007", 4242) end))
terminal_reply = { true, "closed", "" }
assert_eq("a closed tab is success", true, DeskCloseTerminalTab("T1"))
for _, why in ipairs({ "gone", "ambiguous", "split" }) do
  terminal_reply = { true, why, "" }
  assert_eq("not closed when " .. why, false, silently(function() return DeskCloseTerminalTab("T1") end))
end
terminal_reply = { false, nil, { OSAScriptErrorMessageKey = "boom" } }
assert_eq("an AppleScript error is a failure", false, silently(function() return DeskCloseTerminalTab("T1") end))

-- Typing into a session's tab after the session ended: only into the
-- terminal named, only while it runs the shell the restart checked.
local type_script = DeskTab.type_in_terminal_script('T"1', 777, [[exec /bin/zsh -lic 'claude --resume "x"']])
local function at(pat) return type_script:find(pat, 1, true) end
assert_eq("the script looks the terminal up by its id, quoted for AppleScript", true, at('whose id is "T\\"1"') ~= nil)
assert_eq("...checks its foreground pid before anything is typed", true,
  at("if (pid of term) is not 777 then return \"moved\"") < at('send key "c" modifiers "control" to term'))
assert_eq("...clears the line with Ctrl-C, which works in vi command mode too, and lets the prompt redraw", true,
  at('send key "c" modifiers "control" to term') < at("delay ") and at("delay ") < at("input text "))
assert_eq("...then pastes the text and presses enter", true,
  at("input text ") < at('send key "enter" to term'))
assert_eq("...with the text's own quotes escaped", true, at([[input text "exec /bin/zsh -lic 'claude --resume \"x\"'" to term]]) ~= nil)
terminal_reply = { true, "777", "" }
assert_eq("a terminal's foreground pid is reported", "pid 777", DeskTerminalPid("T1"))
for _, why in ipairs({ "gone", "ambiguous" }) do
  terminal_reply = { true, why, "" }
  assert_eq("no pid when the terminal is " .. why, false, silently(function() return DeskTerminalPid("T1") end))
end
terminal_reply = { true, "sent", "" }
assert_eq("typed is success", true, DeskTypeInTerminal("T1", 777, "claude"))
assert_eq("...a pid given as a string too", true, DeskTypeInTerminal("T1", "777", "claude"))
for _, why in ipairs({ "gone", "ambiguous", "moved" }) do
  terminal_reply = { true, why, "" }
  assert_eq("not typed when " .. why, false, silently(function() return DeskTypeInTerminal("T1", 777, "claude") end))
end
assert_eq("no text is refused", false, silently(function() return DeskTypeInTerminal("T1", 777, "") end))
terminal_reply = { false, nil, { OSAScriptErrorMessageKey = "boom" } }
assert_eq("an AppleScript error types nothing", false, silently(function() return DeskTypeInTerminal("T1", 777, "claude") end))
hs.osascript.applescript = real_close_as
hs.application.get = function() return nil end

-- ---------------------------------------------------------------------------
-- DeskWindow: full height for the review overview, and back
-- ---------------------------------------------------------------------------
local function frame_str(f)
  if not f then return "nil" end
  return string.format("%d %d %d %d", math.floor(f.x + 0.5), math.floor(f.y + 0.5), math.floor(f.w + 0.5), math.floor(f.h + 0.5))
end
local wide = { frame = function() return { x = 0, y = 25, w = 3840, h = 1575 } end }
local narrow = { frame = function() return { x = 0, y = 25, w = 1512, h = 957 } end }
-- The frames the picker gives, built the way init.lua builds them: a half
-- slot is the top or bottom half of its third, with the gaps.
local function third(col, yf, hf, scr)
  local s, GAP = scr.frame(), 10
  local left = col == 0 and GAP or 5
  local right = col == 2 and GAP or 5
  local top = yf == 0 and 0 or 5
  local bottom = yf + hf >= 0.999 and GAP or 5
  return { x = s.x + col / 3 * s.w + left, y = s.y + yf * s.h + top, w = s.w / 3 - left - right, h = hf * s.h - top - bottom }
end
for col, name in pairs({ [0] = "L", [1] = "C", [2] = "R" }) do
  assert_eq("upper_" .. name .. " goes to full_" .. name, frame_str(third(col, 0, 1, wide)),
    frame_str(DeskWindow.tall_target(wide, third(col, 0, 0.5, wide))))
  assert_eq("lower_" .. name .. " goes to full_" .. name, frame_str(third(col, 0, 1, wide)),
    frame_str(DeskWindow.tall_target(wide, third(col, 0.5, 0.5, wide))))
end
local function fake_window(id, frame, scr, app_name, title)
  local w = { set = {} }
  function w:title() return title or "nvim notes.md" end
  function w:frame() return frame end
  function w:setFrame(f) frame = f; self.set[#self.set + 1] = frame_str(f) end
  function w:id() return id end
  function w:screen() return scr end
  function w:application() return { name = function() return app_name or "Ghostty" end } end
  return w
end
local real_as, real_app_get = hs.osascript.applescript, hs.application.get
local ghostty_reply = "4242|tab-group-1|tab-group-1|nvim notes.md"
hs.application.get = function(name) return name == "Ghostty" and {} or nil end
hs.osascript.applescript = function(script)
  if script:find("every terminal whose tty is", 1, true) then return true, ghostty_reply, "" end
  return false, nil, { OSAScriptErrorMessageKey = "stub" }
end
assert_eq("the script looks the terminal up by its /dev tty", true,
  DeskWindow.terminal_window_script("ttys009"):find('tty is "/dev/ttys009"', 1, true) ~= nil)
assert_eq("a window name holding a | is read whole", "a | b",
  select(4, DeskWindow.parse_terminal_window("4242|w1|w1|a | b")))

local upper = third(1, 0, 0.5, wide)
local win = fake_window(42, upper, wide)
hs.window.focusedWindow = function() return win end
hs.window.get = function(id) return id == 42 and win or nil end
assert_eq("DeskWindowTall stretches the window of the terminal on that tty", "tall", DeskWindowTall("ttys009", 4242))
assert_eq("to its column", frame_str(third(1, 0, 1, wide)), frame_str(win:frame()))
local sets = #win.set
assert_eq("asked again while still tall: tall, nothing moved", "tall", DeskWindowTall("ttys009", 4242))
assert_eq("no second set", sets, #win.set)
assert_eq("DeskWindowRestore puts it back by terminal, no window id needed", true, DeskWindowRestore("ttys009", 4242))
assert_eq("at its old frame", frame_str(upper), frame_str(win:frame()))
assert_eq("and a second restore has nothing to do", false, DeskWindowRestore("ttys009", 4242))

win = fake_window(42, upper, wide)
DeskWindowTall("/dev/ttys009", 4242)
win:setFrame(third(2, 0, 1, wide))
local moved = #win.set
assert_eq("a window moved since is left where the user put it", false, DeskWindowRestore("ttys009", 4242))
assert_eq("untouched", moved, #win.set)
assert_eq("restoring a terminal never stretched is no error", false, DeskWindowRestore("ttys003", 7))

local function left_alone(desc, setup)
  win = fake_window(42, upper, wide)
  hs.window.focusedWindow = function() return win end
  ghostty_reply = "4242|tab-group-1|tab-group-1|nvim notes.md"
  setup()
  assert_eq(desc, "none", DeskWindowTall("ttys009", 4242))
  assert_eq(desc .. ": nothing moved", 0, #win.set)
  hs.application.get = function(name) return name == "Ghostty" and {} or nil end
end
left_alone("its window not Ghostty's front window", function() ghostty_reply = "4242|tab-group-1|tab-group-2|nvim notes.md" end)
left_alone("another pid in the terminal's foreground", function() ghostty_reply = "999|tab-group-1|tab-group-1|nvim notes.md" end)
assert_eq("no tty: none", "none", DeskWindowTall("", 4242))
hs.window.focusedWindow = function() return nil end
hs.window.get = function() return nil end
hs.osascript.applescript, hs.application.get = real_as, real_app_get

-- ---------------------------------------------------------------------------
-- The offer to restart a stale session (DeskStale): which session a tab
-- holds, when to offer, once per set of reasons, and what each button
-- runs. Tasks are recorded by the stub and finished by hand here.
-- ---------------------------------------------------------------------------
local function task_at(i) return tasks_started[i] end
local function last_task() return tasks_started[#tasks_started] end
local function last_note() return notes_sent[#notes_sent] end

local login_task = task_at(1)
assert_eq("at load, the login shell's PATH is asked for", "/bin/zsh -lc", login_task and (login_task.path .. " " .. login_task.args[1]))
login_task.done(0, "/login/bin:/usr/bin", "")

local S1 = "11111111-2222-3333-4444-555555555555"
local found = DeskStale.parse_session(42, S1 .. "\t/b\tnotes\n")
assert_eq("the session session-stale.sh --pid names: its id, config dir and name", "/b " .. S1 .. " notes 42",
  found and (found.dir .. " " .. found.id .. " " .. found.name .. " " .. found.pid))
assert_eq("...named by its id's start when it has no name", S1:sub(1, 8), DeskStale.parse_session(43, S1 .. "\t/a\t\n").name)
assert_eq("a reply without a real session id is no session", nil, DeskStale.parse_session(44, "not-an-id\t/a\tx\n"))
assert_eq("nothing named, no session", nil, DeskStale.parse_session(44, ""))

local function decided(prev, rc, out) return (DeskStale.decide(prev, rc, out)) end
assert_eq("not stale: forget the session", "clear", decided(nil, 0, ""))
assert_eq("stale and restartable: offer", "offer", decided(nil, 0, "version: 1 running, 2 installed\n"))
assert_eq("its tab would close with it: the manual offer", "manual", decided(nil, 3, "version: 1 running, 2 installed\n"))
assert_eq("cannot tell now: leave it be", "wait", decided({ reasons = "x" }, 1, ""))
assert_eq("offered for these reasons already: quiet", "quiet", decided({ reasons = "shell: ~/.zshrc changed" }, 0, "shell: ~/.zshrc changed\n"))
assert_eq("reasons that changed: offer again", "offer", decided({ reasons = "shell: ~/.zshrc changed" }, 0, "version: 1 running, 2 installed"))

local session = { id = S1, name = "notes", dir = "/b", pid = 42 }
local offer = DeskStale.offer_attributes(session, "version: 1 running, 2 installed\nshell: ~/.zshrc changed", "offer")
assert_eq("the offer names the session", "Restart notes?", offer.title)
assert_eq("...and every reason", "version: 1 running, 2 installed; shell: ~/.zshrc changed", offer.subTitle)
assert_eq("...with Restart and Dismiss", "Restart/Dismiss", offer.actionButtonTitle .. "/" .. offer.otherButtonTitle)
assert_eq("...saying unsent input is lost", true, offer.informativeText:find("Unsent text in its input box is lost", 1, true) ~= nil)
local manual = DeskStale.offer_attributes(session, "version: 1 running, 2 installed", "manual")
assert_eq("a tab that would close: no Restart button", false, manual.hasActionButton)
assert_eq("...but how to get a tab that restarts", true, manual.informativeText:find("resume it once (claude --resume " .. S1 .. ")", 1, true) ~= nil)

DeskStale.seen = {}
local before = #notes_sent
assert_eq("a stale session is offered", "offer", DeskStale.handle(session, 0, "version: 1 running, 2 installed\n"))
local note = last_note()
assert_eq("...one notification", before + 1, #notes_sent)
assert_eq("the same reasons on the next look: no second notification", "quiet", DeskStale.handle(session, 0, "version: 1 running, 2 installed\n"))
assert_eq("...none", before + 1, #notes_sent)
assert_eq("busy for now: still quiet", "wait", DeskStale.handle(session, 1, ""))
assert_eq("...and still quiet once it is idle again", "quiet", DeskStale.handle(session, 0, "version: 1 running, 2 installed\n"))
local tasks_before = #tasks_started
note.clicked = hs.notify.activationTypes.contentsClicked
note.fn(note)
assert_eq("clicking the notification itself restarts nothing", tasks_before, #tasks_started)
note.clicked = hs.notify.activationTypes.actionButtonClicked
note.fn(note)
local restart = last_task()
assert_eq("Restart runs restart-session.sh on the session", DeskStale.bin_dir .. "/restart-session.sh " .. S1,
  restart and (restart.path .. " " .. restart.args[1]))
assert_eq("...in its own config dir, on the login PATH", "/b /login/bin:/usr/bin", restart.env.CLAUDE_CONFIG_DIR .. " " .. restart.env.PATH)
restart.done(0, "restarted\t" .. S1 .. "\tnotes\tresumed in its tab (pid 77)\n", "")
assert_eq("...and says how it went", "Restarted notes: resumed in its tab (pid 77)", last_note().attrs.title .. ": " .. last_note().attrs.informativeText)
local refused = DeskStale.restart_report(session, 1, "refused\t" .. S1 .. "\tnotes\tnot idle: its status is busy\n")
assert_eq("a refusal says why", "notes not restarted: not idle: its status is busy", refused.title .. ": " .. refused.informativeText)
assert_eq("exit 3 says how to get a tab that restarts", true,
  DeskStale.restart_report(session, 3, "refused\t" .. S1 .. "\tnotes\tits tab would close\n").informativeText:find("resume it once", 1, true) ~= nil)
assert_eq("found not stale: forgotten", "clear", DeskStale.handle(session, 0, ""))
assert_eq("...so reasons coming back are offered afresh", "offer", DeskStale.handle(session, 0, "version: 1 running, 2 installed\n"))

-- The focus path end to end: a tab's pid, its pid file, the check.
-- Finishes the two tasks that find the focused tab's session: Ghostty's
-- answer, then session-stale.sh --pid's.
local function focus_answers(pid_reply, session_reply, session_rc)
  last_task().done(pid_reply and 0 or 1, pid_reply or "", "")
  if pid_reply and pid_reply:match("^%d") then
    local resolve = last_task()
    resolve.done(session_rc or 0, session_reply or "", "")
    return resolve
  end
end
DeskStale.config_dirs = { "/a", "/b" }
DeskStale.seen = {}
DeskStale.check_focused()
local ask = last_task()
assert_eq("a focus asks Ghostty for the focused terminal's pid, off the main thread", "/usr/bin/osascript", ask.path)
assert_eq("...of the selected tab's focused terminal", DeskStale.FOCUSED_PID_SCRIPT, ask.args[2])
ask.done(0, "4242\n", "")
local resolve = last_task()
assert_eq("...then has session-stale.sh name the session that pid holds, in either config dir",
  DeskStale.bin_dir .. "/session-stale.sh --pid 4242 /a /b", resolve.path .. " " .. table.concat(resolve.args, " "))
resolve.done(0, S1 .. "\t/b\tnotes\n", "")
local check = last_task()
assert_eq("...then runs session-stale.sh on that session, in its config dir", DeskStale.bin_dir .. "/session-stale.sh " .. S1 .. " /b",
  check.path .. " " .. check.args[1] .. " " .. check.env.CLAUDE_CONFIG_DIR)
local notes_before = #notes_sent
check.done(0, "shell: ~/.zshrc changed since it started\n", "")
assert_eq("...and offers the restart", notes_before + 1, #notes_sent)
local n_tasks = #tasks_started
DeskStale.check_focused()
focus_answers("4242\n", S1 .. "\t/b\tnotes\n")
assert_eq("focusing it again straight away checks nothing more", n_tasks + 2, #tasks_started)
n_tasks = #tasks_started
DeskStale.check_focused()
focus_answers("9999\n", "", 1)
assert_eq("a tab with no Claude Code session in it is left alone", n_tasks + 2, #tasks_started)
n_tasks = #tasks_started
DeskStale.check_focused()
last_task().done(1, "", "Ghostty is not running")
assert_eq("...as is one Ghostty cannot name", n_tasks + 1, #tasks_started)
local alerts = {}
local real_alert = hs.alert.show
hs.alert.show = function(text) alerts[#alerts + 1] = text; return "alert-uuid" end
local clock = 1000
local real_clock = hs.timer.secondsSinceEpoch
hs.timer.secondsSinceEpoch = function() return clock end
DeskStale.armed = nil
DeskStale.hotkey.fn()
focus_answers("4242\n", S1 .. "\t/b\tnotes\n")
local first = last_task()
assert_eq("the hotkey's first press restarts nothing: it asks session-stale.sh what a restart would do",
  DeskStale.bin_dir .. "/session-stale.sh " .. S1, first.path .. " " .. first.args[1])
first.done(0, "version: 1 running, 2 installed\n", "")
assert_eq("...and shows it, with what unsent input costs",
  "Restart notes? version: 1 running, 2 installed.\nUnsent text in its input box is lost. Press Cmd+Opt+R again to restart.",
  alerts[#alerts])
clock = clock + 2
DeskStale.hotkey.fn()
focus_answers("4242\n", S1 .. "\t/b\tnotes\n")
assert_eq("a second press within a few seconds restarts the focused tab's session", DeskStale.bin_dir .. "/restart-session.sh " .. S1,
  last_task().path .. " " .. last_task().args[1])
last_task().done(0, "restarted\t" .. S1 .. "\tnotes\tok\n", "")
DeskStale.hotkey.fn()
focus_answers("4242\n", S1 .. "\t/b\tnotes\n")
clock = clock + 10
DeskStale.hotkey.fn()
focus_answers("4242\n", S1 .. "\t/b\tnotes\n")
assert_eq("a second press too late only shows it again", DeskStale.bin_dir .. "/session-stale.sh", last_task().path)
last_task().done(1, "", "session-stale: not idle: its status is busy\n")
assert_eq("...saying when a restart would be refused, and why", true,
  alerts[#alerts]:find("a restart would be refused now: not idle: its status is busy.", 1, true) ~= nil)
assert_eq("a tab that cannot restart in place says so",
  true, DeskStale.confirm_text(session, 3, "version: x\n", ""):find("this tab can't restart it in place", 1, true) ~= nil)
assert_eq("nothing stale says so", true, DeskStale.confirm_text(session, 0, "", ""):find("Restart notes? nothing in it is stale.", 1, true) ~= nil)

DeskStale.armed = nil
DeskStale.hotkey.fn()
focus_answers("4242\n", S1 .. "\t/b\tnotes\n")
local pending = last_task()
DeskStale.hotkey.fn()
focus_answers("4242\n", S1 .. "\t/b\tnotes\n")
assert_eq("a quick double press, before the confirmation shows, restarts nothing", DeskStale.bin_dir .. "/session-stale.sh", last_task().path)
local pending2 = last_task()
clock = clock + 3
pending.done(0, "version: 1 running, 2 installed\n", "")
pending2.done(0, "version: 1 running, 2 installed\n", "")
clock = clock + 3
DeskStale.hotkey.fn()
focus_answers("4242\n", S1 .. "\t/b\tnotes\n")
assert_eq("...the window starts once it shows: a press 3s after that restarts", DeskStale.bin_dir .. "/restart-session.sh", last_task().path)
last_task().done(0, "restarted\t" .. S1 .. "\tnotes\tok\n", "")

-- An offer stands for a minute.
local seen_before = DeskStale.seen
DeskStale.seen = {}
DeskStale.handle(session, 0, "version: 1 running, 2 installed\n")
local offer_note = last_note()
assert_eq("the offer is withdrawn after a minute", 60, offer_note.attrs.withdrawAfter)
clock = clock + 61
n_tasks = #tasks_started
offer_note.clicked = hs.notify.activationTypes.actionButtonClicked
offer_note.fn(offer_note)
assert_eq("a click on it later than that does nothing", n_tasks, #tasks_started)
DeskStale.seen = seen_before
hs.timer.secondsSinceEpoch = real_clock
hs.alert.show = real_alert

-- What a check costs while a tab stays focused.
assert_eq("reasons session-stale.sh says are the ones offered (exit 4): quiet", "quiet", decided(nil, 4, "version: 1 running, 2 installed\n"))
DeskStale.recheck_secs = -1
DeskStale.check_focused()
focus_answers("4242\n", S1 .. "\t/b\tnotes\n")
local again = last_task()
assert_eq("a recheck of an offered session hands over the reasons offered, so the heavy checks can be skipped",
  S1 .. "|shell: ~/.zshrc changed since it started", again.args[1] .. "|" .. tostring(again.args[2]))
assert_eq("...a running task is held until it ends", "session-stale.sh", DeskStale.running[again])
again.done(4, "shell: ~/.zshrc changed since it started\n", "")
assert_eq("...and let go once it has", nil, DeskStale.running[again])
local timers = {}
local real_do_after = hs.timer.doAfter
hs.timer.doAfter = function(secs, fn)
  local t = { secs = secs, fn = fn, stopped = false }
  function t:stop() self.stopped = true end
  timers[#timers + 1] = t
  return t
end
DeskStale.check_focused()
local hung = last_task()
local hung_timer = timers[#timers]
assert_eq("the pid lookup has a timeout", 5, hung_timer.secs)
n_tasks = #tasks_started
DeskStale.check_focused()
assert_eq("while a check runs, another focus starts nothing", n_tasks, #tasks_started)
hung_timer.fn()
timers[#timers].fn()
assert_eq("a task that never answers is ended at its timeout", nil, DeskStale.running[hung])
DeskStale.check_focused()
assert_eq("...and the next focus checks again: nothing stays stuck", n_tasks + 1, #tasks_started)
last_task().done(1, "", "")
hung.done(0, "4242\n", "")
assert_eq("a task's late answer, after its timeout, is ignored", n_tasks + 1, #tasks_started)
DeskStale.restart({ id = S1, name = "notes", dir = "/b", pid = 42 })
local slow = last_task()
timers[#timers].fn()
slow.done(15, "", "restart-session: stopping the session; if nothing more is reported, resume it by hand: cd '/p' && claude --model 'opus' --resume " .. S1 .. "\n")
assert_eq("a restart ended at its timeout says the session may be stopped, with the exact resume it printed",
  "Restarting notes timed out|The session may be stopped. If its tab shows nothing running, resume it by hand: cd '/p' && claude --model 'opus' --resume " .. S1,
  last_note().attrs.title .. "|" .. last_note().attrs.informativeText)
assert_eq("...and its limit is above the script's own worst case", true, DeskStale.timeouts["restart-session.sh"] >= 95)
hs.timer.doAfter = real_do_after
DeskStale.recheck_secs = 30

-- The hotkey, and the watchers that keep all of this to Ghostty.
assert_eq("the hotkey is Cmd+Opt+R", "cmd+alt+r", table.concat(DeskStale.hotkey.mods, "+") .. "+" .. DeskStale.hotkey.key)
assert_eq("...off while Ghostty is not the active app", false, DeskStale.hotkey.enabled)
n_tasks = #tasks_started
app_watcher_fn("Safari", "activated", {})
assert_eq("another app activating does nothing", false, DeskStale.hotkey.enabled)
assert_eq("...starts nothing", n_tasks, #tasks_started)
app_watcher_fn("Ghostty", "activated", {})
assert_eq("Ghostty activating turns the hotkey on", true, DeskStale.hotkey.enabled)
app_watcher_fn("Ghostty", "deactivated", {})
assert_eq("...and leaving it, off", false, DeskStale.hotkey.enabled)
local ax_fn, ax_events
local fake_ghostty = { newWatcher = function(_, fn)
  ax_fn = fn
  return { start = function(self, events) ax_events = events; return self end, stop = function() end }
end }
app_watcher_fn("Ghostty", "launched", fake_ghostty)
assert_eq("Ghostty launching gets its tab switches watched", "AXMainWindowChanged", ax_events and ax_events[1])
local real_after = hs.timer.doAfter
hs.timer.doAfter = function(_, fn) fn(); return setmetatable({}, inert) end
n_tasks = #tasks_started
ax_fn()
assert_eq("a tab switch checks the focused tab", "/usr/bin/osascript", #tasks_started == n_tasks + 1 and last_task().path)
hs.timer.doAfter = real_after
last_task().done(1, "", "")

n_tasks = #tasks_started
DeskStale.hotkey.fn()
focus_answers("42\n", "", 1)
assert_eq("the hotkey in a tab with no session restarts nothing", n_tasks + 2, #tasks_started)

print()
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
