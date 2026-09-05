-- Three-column window layout + Divvy-style one-off placement.
-- Picker: Opt+Cmd+T enters layout mode; press one of the keys below to place
-- the focused window. Escape exits. Bindings match Dvorak home row.
--
-- First-run setup: grant Hammerspoon accessibility access
-- (System Settings → Privacy & Security → Accessibility). Enable
-- "Automatically reload config when any files change" in Hammerspoon prefs
-- if you want edits to this file to pick up without manual reload.

-- Message port for the `hs` CLI, so live state can be inspected from a shell
-- (`hs -c 'print(caps_tap:isEnabled())'`). Diagnosing key handling without it
-- means guessing from symptoms.
require("hs.ipc")

local GAP = 10     -- gap between windows and between window and screen edge
local TOP_GAP = 0  -- top edge: 0 keeps windows flush to the menu bar
local TOL = 4      -- frame-match tolerance in pixels for slot detection

hs.window.animationDuration = 0

-- Compute the target frame for a slot with fractional coords. Windows
-- touching a screen boundary get the full GAP; interior edges get GAP/2,
-- so adjacent windows sum to exactly GAP between them. Top edge uses
-- TOP_GAP (0 by default — the menu bar provides visual separation).
local function target_frame(screen, xf, yf, wf, hf)
  local s = screen:frame()
  local half = GAP / 2
  local at_left   = xf <= 0.001
  local at_right  = xf + wf >= 0.999
  local at_top    = yf <= 0.001
  local at_bottom = yf + hf >= 0.999
  local left   = at_left   and GAP     or half
  local right  = at_right  and GAP     or half
  local top    = at_top    and TOP_GAP or half
  local bottom = at_bottom and GAP     or half
  return {
    x = s.x + xf * s.w + left,
    y = s.y + yf * s.h + top,
    w = wf * s.w - left - right,
    h = hf * s.h - top - bottom,
  }
end

local function frames_equal(a, b)
  return math.abs(a.x - b.x) < TOL and math.abs(a.y - b.y) < TOL
     and math.abs(a.w - b.w) < TOL and math.abs(a.h - b.h) < TOL
end

-- Looser "already at target" check: treats a window with matching x/y as
-- "placed" even if it's larger than the target (e.g. Chrome's min width
-- prevents shrinking on smaller screens). Without this, apps that refuse
-- to shrink get stuck on a screen since repeat-presses would only re-apply
-- the same (ineffective) target.
local function at_target(frame, target)
  return math.abs(frame.x - target.x) < TOL
     and math.abs(frame.y - target.y) < TOL
     and frame.w >= target.w - TOL
     and frame.h >= target.h - TOL
end

local THIRD = 1 / 3

-- Named grid slots. Any window whose frame matches one of these (on its
-- current screen) counts as a known placement for the screen-cycling check.
local slots = {
  full_L   = { col = 0, xf = 0,         yf = 0,    wf = THIRD, hf = 1    },
  upper_L  = { col = 0, xf = 0,         yf = 0,    wf = THIRD, hf = 0.5  },
  lower_L  = { col = 0, xf = 0,         yf = 0.5,  wf = THIRD, hf = 0.5  },
  full_C   = { col = 1, xf = THIRD,     yf = 0,    wf = THIRD, hf = 1    },
  upper_C  = { col = 1, xf = THIRD,     yf = 0,    wf = THIRD, hf = 0.5  },
  lower_C  = { col = 1, xf = THIRD,     yf = 0.5,  wf = THIRD, hf = 0.5  },
  full_R   = { col = 2, xf = 2 * THIRD, yf = 0,    wf = THIRD, hf = 1    },
  upper_R  = { col = 2, xf = 2 * THIRD, yf = 0,    wf = THIRD, hf = 0.5  },
  lower_R  = { col = 2, xf = 2 * THIRD, yf = 0.5,  wf = THIRD, hf = 0.5  },
}

local function slot_frame(screen, name)
  local s = slots[name]
  return target_frame(screen, s.xf, s.yf, s.wf, s.hf)
end

-- Raw fractional layouts used by place_raw (half-width columns, full
-- screen). Listed here so the cycle check can recognize them as known
-- placements alongside the named slots.
local raw_layouts = {
  { 0,    0, 0.5, 1 },
  { 0.25, 0, 0.5, 1 },
  { 0.5,  0, 0.5, 1 },
  { 0,    0, 1,   1 },
}

-- Two windows sharing a screen: one large beside one small, for the common
-- case of a terminal and a browser. Each is centred vertically and sits a
-- fixed margin in from its outer edge, so left and right mirror exactly.
-- Geometry is per display: the ultrawide has room to tile both with air
-- around them, the laptop does not, so there the large window takes the
-- screen and the small one floats over it.
local two_up = {
  wide   = { margin = 0.10,  small = { w = 0.295, h = 0.70 }, large = { w = 0.48, h = 0.90 } },
  narrow = { margin = 0.005, small = { w = 0.49,  h = 0.66 }, large = { w = 0.73, h = 0.96 } },
}

local function screen_kind(screen)
  local f = screen:frame()
  return f.w / f.h > 2 and "wide" or "narrow"
end

-- Fractional rect for one of the four two-up placements on `screen`.
local function two_up_rect(screen, size, side)
  local spec = two_up[screen_kind(screen)]
  local box = spec[size]
  local xf = side == "left" and spec.margin or 1 - spec.margin - box.w
  return xf, (1 - box.h) / 2, box.w, box.h
end

local two_up_placements = {}
for _, size in ipairs({ "small", "large" }) do
  for _, side in ipairs({ "left", "right" }) do
    two_up_placements[#two_up_placements + 1] = { size, side }
  end
end

-- True if `frame` matches any known placement on `screen` other than
-- `target`. Used to distinguish "stuck oversized at target" (where we
-- want to cycle screens) from "currently at a different known slot, just
-- larger" (where we want to place at the new target instead).
local function matches_other_known(frame, target, screen)
  for name, _ in pairs(slots) do
    local f = slot_frame(screen, name)
    if not frames_equal(f, target) and frames_equal(frame, f) then
      return true
    end
  end
  for _, l in ipairs(raw_layouts) do
    local f = target_frame(screen, l[1], l[2], l[3], l[4])
    if not frames_equal(f, target) and frames_equal(frame, f) then
      return true
    end
  end
  for _, p in ipairs(two_up_placements) do
    local f = target_frame(screen, two_up_rect(screen, p[1], p[2]))
    if not frames_equal(f, target) and frames_equal(frame, f) then
      return true
    end
  end
  return false
end

-- Should pressing the same target again cycle to the next screen? Yes if
-- the window is precisely at target, or oversized-at-target (x/y match,
-- larger than target) AND not at any other known placement.
local function should_cycle(frame, target, screen)
  return at_target(frame, target)
     and not matches_other_known(frame, target, screen)
end

-- Place the focused window at a rect given as a function of the screen. If it
-- is already there, cycle to the next screen — recomputing the rect for that
-- screen, since two-up geometry differs between displays.
local function place_by(rect_for)
  local win = hs.window.focusedWindow()
  if not win then return end
  local screen = win:screen()
  local target = target_frame(screen, rect_for(screen))
  local crossing = false
  if should_cycle(win:frame(), target, screen) then
    local next_screen = screen:next()
    if next_screen and next_screen:getUUID() ~= screen:getUUID() then
      screen = next_screen
      target = target_frame(screen, rect_for(screen))
      crossing = true
    end
  end
  win:setFrame(target)
  if crossing then
    hs.timer.doAfter(0.05, function() win:setFrame(target) end)
  end
end

local function place_slot(name)
  local s = slots[name]
  place_by(function() return s.xf, s.yf, s.wf, s.hf end)
end

local function place_raw(xf, yf, wf, hf)
  place_by(function() return xf, yf, wf, hf end)
end

local function place_two_up(size, side)
  place_by(function(screen) return two_up_rect(screen, size, side) end)
end

local picker = hs.hotkey.modal.new({ "alt", "cmd" }, "t")
local alert_uuid

function picker:entered()
  alert_uuid = hs.alert.show("Layout", { textSize = 14 }, 10)
end

function picker:exited()
  if alert_uuid then hs.alert.closeSpecific(alert_uuid) end
  alert_uuid = nil
end

local function bind(mods, key, fn)
  picker:bind(mods or {}, key, function() fn(); picker:exit() end)
end

-- Columns (third-width, full height)
bind(nil, "h", function() place_slot("full_L") end)
bind(nil, "t", function() place_slot("full_C") end)
bind(nil, "n", function() place_slot("full_R") end)

-- Upper half of each column
bind(nil, "g", function() place_slot("upper_L") end)
bind(nil, "c", function() place_slot("upper_C") end)
bind(nil, "r", function() place_slot("upper_R") end)

-- Lower half of each column
bind(nil, "m", function() place_slot("lower_L") end)
bind(nil, "w", function() place_slot("lower_C") end)
bind(nil, "v", function() place_slot("lower_R") end)

-- Half-width columns (wider than thirds)
bind({ "shift" }, "h", function() place_raw(0,    0, 0.5, 1) end)
bind({ "shift" }, "t", function() place_raw(0.25, 0, 0.5, 1) end)
bind({ "shift" }, "n", function() place_raw(0.5,  0, 0.5, 1) end)

-- Full screen
bind(nil, "s", function() place_raw(0, 0, 1, 1) end)

-- Two windows sharing a screen: small or large, on either side
bind(nil, ",", function() place_two_up("small", "left")  end)
bind(nil, ".", function() place_two_up("small", "right") end)
bind(nil, "o", function() place_two_up("large", "left")  end)
bind(nil, "e", function() place_two_up("large", "right") end)

picker:bind({}, "escape", function() picker:exit() end)

-- Cross-window directional focus and swap on the Dvorak home row
-- h/t/n/s = west/north/south/east. Works across screens.
-- Focus uses Caps Lock as a hold-modifier (see dual-function block below).
-- Swap uses Cmd+Ctrl.
local directions = { h = "West", t = "North", n = "South", s = "East" }

local function focus(dir)
  local win = hs.window.focusedWindow()
  if win then win["focusWindow" .. dir](win) end
end

local function swap(dir)
  local win = hs.window.focusedWindow()
  if not win then return end
  local others = win["windowsTo" .. dir](win)
  local other = others and others[1]
  if not other then return end
  local a, b = win:frame(), other:frame()
  local cross = win:screen():getUUID() ~= other:screen():getUUID()
  win:setFrame(b)
  other:setFrame(a)
  if cross then
    hs.timer.doAfter(0.05, function()
      win:setFrame(b)
      other:setFrame(a)
    end)
  end
end

for key, dir in pairs(directions) do
  hs.hotkey.bind({ "cmd", "ctrl" }, key, function() swap(dir) end)
end

-- Dual-function Caps Lock (remapped to F18 at the HID level by
-- macos/keyboard-remap.sh):
--   Tap                  → Escape
--   Hold + h/t/n/s       → focus window west/north/south/east
--   Hold + c/g/l/r/z/b/w → launch or focus an app
--   Hold + other key     → passes through as normal (after TAP_MS commit)
-- Every bound key is also a vim command, so caps→b is ambiguous: Escape then
-- back-a-word, or Caps+b for Finder. The two differ only in release order — a
-- chord lets the letter up first, a roll lets Caps up first — so the first
-- bound key of a hold waits for whichever comes up first (or TAP_MS, if both
-- are held). Once one has fired, the rest of that hold acts on press.
-- During the tap-decision window non-bound keys are buffered and replayed
-- after the tap/hold decision, so fast rolls like caps→b correctly produce
-- Escape followed by b instead of dropping Escape.
--
-- Troubleshooting: caps→Escape and the picker's bare keys both dead while
-- Cmd+Opt+T still works means macOS Secure Input is on — it suppresses
-- eventtaps and unmodified hotkeys, but not modifier hotkeys. Confirm and
-- find the holder:
--   hs -c 'print(hs.eventtap.isSecureInputEnabled())'
--   hs -c 'for _,w in ipairs(hs.window.allWindows()) do print(w:application():name(), w:title()) end'
-- Usual culprits: a locked 1Password window, a terminal with Secure Keyboard
-- Entry on, a hidden auth prompt. Don't trust kCGSSessionSecureInputPID from
-- ioreg — it names loginwindow, not the app actually holding it.
local TAP_MS = 150
local f18_kc = hs.keycodes.map.f18

-- Dvorak top and bottom rows, so they stay clear of the h/t/n/s home row.
local hold_apps = {
  c = "Google Chrome",
  g = "Ghostty",
  l = "Slack",
  r = "Notes",
  z = "Safari",
  b = "Finder",
  w = "Claude",
}

local hold_actions = {}
for k, dir in pairs(directions) do
  hold_actions[hs.keycodes.map[k]] = function() focus(dir) end
end
for k, app in pairs(hold_apps) do
  hold_actions[hs.keycodes.map[k]] = function() hs.application.launchOrFocus(app) end
end

local f18_down = false
local acted_on = {}              -- keycodes whose keyDown fired a hold action
local pending_action_kc = nil    -- bound key held, waiting on the release order
local decision_pending = false   -- buffering, waiting on tap/hold decision
local committed_to_hold = false  -- decided hold (timer fired or bound key)
local pending = {}
local decision_timer = nil

local function flags_to_mods(flags)
  local mods = {}
  for k, v in pairs(flags) do
    if v and k ~= "capslock" then table.insert(mods, k) end
  end
  return mods
end

local function replay_pending()
  for _, d in ipairs(pending) do
    hs.eventtap.event.newKeyEvent(d.mods, d.kc, d.is_down):post()
  end
  pending = {}
end

local function cancel_timer()
  if decision_timer then decision_timer:stop(); decision_timer = nil end
end

local function commit_hold()
  decision_pending = false
  pending_action_kc = nil
  committed_to_hold = true
  cancel_timer()
  replay_pending()
end

-- The held key won: run its action and drop its own buffered press, keeping
-- anything typed after it.
local function commit_action(kc)
  cancel_timer()
  decision_pending = false
  pending_action_kc = nil
  committed_to_hold = true
  acted_on[kc] = true
  local rest = {}
  for _, d in ipairs(pending) do
    if d.kc ~= kc then rest[#rest + 1] = d end
  end
  pending = rest
  hold_actions[kc]()
  replay_pending()
end

local function commit_tap()
  decision_pending = false
  pending_action_kc = nil
  cancel_timer()
  hs.eventtap.keyStroke({}, "escape", 0)
  replay_pending()
end

caps_tap = hs.eventtap.new({
  hs.eventtap.event.types.keyDown,
  hs.eventtap.event.types.keyUp,
}, function(e)
  local kc = e:getKeyCode()
  local is_down = (e:getType() == hs.eventtap.event.types.keyDown)

  if kc == f18_kc then
    if is_down then
      if not f18_down then
        f18_down = true
        acted_on = {}
        pending_action_kc = nil
        decision_pending = false
        committed_to_hold = false
        pending = {}
      end
    else
      if decision_pending then
        commit_tap()
      elseif not committed_to_hold then
        -- Lone caps press (no other key): always treat as tap, regardless
        -- of how long it was held.
        hs.eventtap.keyStroke({}, "escape", 0)
      end
      f18_down = false
    end
    return true
  end

  if f18_down then
    local action = hold_actions[kc]

    -- First bound key of the hold: buffer it and let the release order decide.
    if is_down and action and not committed_to_hold then
      cancel_timer()
      decision_pending = true
      pending_action_kc = kc
      pending = { { kc = kc, mods = flags_to_mods(e:getFlags()), is_down = true } }
      decision_timer = hs.timer.doAfter(TAP_MS / 1000, function() commit_action(kc) end)
      return true
    end

    -- Already committed to hold, so no ambiguity left.
    if is_down and action then
      acted_on[kc] = true
      action()
      return true
    end

    -- Came up while Caps is still down: a chord, not a roll.
    if not is_down and pending_action_kc == kc then
      commit_action(kc)
      acted_on[kc] = nil
      return true
    end

    if not is_down and acted_on[kc] then
      acted_on[kc] = nil
      return true  -- swallow keyUp to match swallowed keyDown
    end
    -- Non-bound key: open the decision window on first occurrence,
    -- then buffer until tap or hold is committed.
    if not committed_to_hold then
      if not decision_pending then
        decision_pending = true
        decision_timer = hs.timer.doAfter(TAP_MS / 1000, commit_hold)
      end
      table.insert(pending, {
        kc = kc,
        mods = flags_to_mods(e:getFlags()),
        is_down = is_down,
      })
      return true
    end
    -- Past decision in hold mode: pass through
  end

  return false
end)
caps_tap:start()

-- Shift+Backspace -> forward delete, which macOS itself only offers as
-- fn+Delete. Rewriting the event in place rather than posting a new one keeps
-- key repeat and the matching keyUp intact.
local backspace_kc = hs.keycodes.map.delete
local forwarddelete_kc = hs.keycodes.map.forwarddelete

shift_delete_tap = hs.eventtap.new({
  hs.eventtap.event.types.keyDown,
  hs.eventtap.event.types.keyUp,
}, function(e)
  if e:getKeyCode() ~= backspace_kc then return false end
  local f = e:getFlags()
  if not f.shift or f.cmd or f.alt or f.ctrl or f.fn then return false end
  e:setKeyCode(forwarddelete_kc)
  e:setFlags({})
  return false
end)
shift_delete_tap:start()

-- Tap a modifier on its own → a chord that otherwise needs two hands. Holding
-- it, or pressing any key or mouse button while it is down, behaves normally.
--   Left Ctrl (the fn key position on the built-in keyboard) → Ctrl+Tab
--   Left Shift                                               → Ctrl+Shift+Tab
-- Gestures that hold a modifier over the mouse (Ctrl+scroll to zoom) outlast
-- MOD_TAP_MS on their own, so only clicks need to cancel explicitly.
--
-- Shift additionally has to be followed by a quiet window: a shift released a
-- fraction early, just before the key it was meant to capitalise, looks exactly
-- like a deliberate tap until that next key lands. Ctrl has no such window —
-- nothing follows a Ctrl tap by accident, and it stays instant.
--
-- Both need a quiet window *before* the press too: a stray tap happens in the
-- middle of typing, a deliberate one from rest. Tab is kept out of that clock
-- so the gesture's own output cannot block the next one — two quick taps are
-- two switches, which is how you walk back several tabs.
local MOD_TAP_MS = 200
local SETTLE_MS = 80
local QUIET_MS = 300

local tab_kc = hs.keycodes.map.tab
local last_typing = 0

local mod_taps = {
  [59] = { flag = "ctrl",  mods = { "ctrl" } },                              -- left Ctrl
  [56] = { flag = "shift", mods = { "ctrl", "shift" }, settle = SETTLE_MS }, -- left Shift
}

local mod_tap_kc = nil
local mod_tap_timer = nil
local settling = nil       -- tapped, waiting out its quiet window
local settle_timer = nil

local function cancel_mod_tap()
  mod_tap_kc = nil
  if mod_tap_timer then mod_tap_timer:stop(); mod_tap_timer = nil end
end

local function stop_settle()
  if settle_timer then settle_timer:stop(); settle_timer = nil end
  local spec = settling
  settling = nil
  return spec
end

local function fire_settled()
  local spec = stop_settle()
  if spec then hs.eventtap.keyStroke(spec.mods, "tab", 0) end
end

local function alone(flags, want)
  for k, v in pairs(flags) do
    if v and k ~= want and k ~= "capslock" then return false end
  end
  return true
end

mod_tap = hs.eventtap.new({
  hs.eventtap.event.types.flagsChanged,
  hs.eventtap.event.types.keyDown,
  hs.eventtap.event.types.leftMouseDown,
  hs.eventtap.event.types.rightMouseDown,
  hs.eventtap.event.types.otherMouseDown,
}, function(e)
  if e:getType() ~= hs.eventtap.event.types.flagsChanged then
    if e:getType() == hs.eventtap.event.types.keyDown and e:getKeyCode() ~= tab_kc then
      last_typing = hs.timer.secondsSinceEpoch()
    end
    stop_settle()   -- something landed in the quiet window: it was not a tap
    cancel_mod_tap()
    return false
  end

  local kc = e:getKeyCode()
  local spec = mod_taps[kc]
  if not spec or f18_down then
    stop_settle()
    cancel_mod_tap()
    return false
  end

  local flags = e:getFlags()
  if flags[spec.flag] then
    -- Pressed. The same modifier again is a repeat tap, so let the waiting one
    -- through; any other is the start of something else.
    if settling == spec then fire_settled() else stop_settle() end
    -- A second modifier on top of a pending one is a chord, not a tap, and a
    -- press that lands mid-burst is a mistap rather than a gesture.
    local quiet = (hs.timer.secondsSinceEpoch() - last_typing) * 1000 >= QUIET_MS
    if mod_tap_kc or not alone(flags, spec.flag) or not quiet then
      cancel_mod_tap()
    else
      mod_tap_kc = kc
      mod_tap_timer = hs.timer.doAfter(MOD_TAP_MS / 1000, cancel_mod_tap)
    end
  elseif mod_tap_kc == kc then
    cancel_mod_tap()
    if spec.settle then
      settling = spec
      settle_timer = hs.timer.doAfter(spec.settle / 1000, fire_settled)
    else
      hs.eventtap.keyStroke(spec.mods, "tab", 0)
    end
  end
  return false
end)
mod_tap:start()

-- hidutil mappings are per-device and only reach the keyboards connected when
-- macos/keyboard-remap.sh runs, so one plugged in after login comes up with
-- only the unscoped mappings — a Windows keyboard keeps Alt where Cmd should
-- be. Re-run the script on USB attach and on wake. USB attach fires once per
-- interface, hence the debounce. A Bluetooth keyboard paired mid-session is
-- not covered; that still needs the kickstart in macos/README.md.
local remap_script = os.getenv("HOME") .. "/dotfiles/macos/keyboard-remap.sh"
local remap_timer = nil

local function reapply_key_remap()
  if remap_timer then remap_timer:stop() end
  remap_timer = hs.timer.doAfter(1, function()
    remap_timer = nil
    hs.task.new(remap_script, nil):start()
  end)
end

usb_watcher = hs.usb.watcher.new(function(ev)
  if ev.eventType == "added" then reapply_key_remap() end
end)
usb_watcher:start()

wake_watcher = hs.caffeinate.watcher.new(function(ev)
  if ev == hs.caffeinate.watcher.systemDidWake then reapply_key_remap() end
end)
wake_watcher:start()

hs.alert.show("Hammerspoon loaded")
