-- Three-column window layout + Divvy-style one-off placement.
-- Picker: Opt+Cmd+T enters layout mode; press one of the keys below to place
-- the focused window. Escape exits. Bindings match Dvorak home row.
--
-- First-run setup: grant Hammerspoon accessibility access
-- (System Settings → Privacy & Security → Accessibility). Enable
-- "Automatically reload config when any files change" in Hammerspoon prefs
-- if you want edits to this file to pick up without manual reload.

local GAP = 8

hs.window.animationDuration = 0

local function screen_frame(win) return win:screen():frame() end

local function target_frame(screen, xf, yf, wf, hf)
  local s = screen:frame()
  return {
    x = s.x + xf * s.w + GAP,
    y = s.y + yf * s.h + GAP,
    w = wf * s.w - 2 * GAP,
    h = hf * s.h - 2 * GAP,
  }
end

local function frames_equal(a, b)
  local tol = 4
  return math.abs(a.x - b.x) < tol and math.abs(a.y - b.y) < tol
     and math.abs(a.w - b.w) < tol and math.abs(a.h - b.h) < tol
end

-- Place the focused window at fractional coordinates of the usable screen,
-- inset by GAP on all sides. Fractions are 0..1. If the window is already at
-- the target on its current screen, cycle it to the next screen instead.
local function place(xf, yf, wf, hf)
  local win = hs.window.focusedWindow()
  if not win then return end
  local screen = win:screen()
  local target = target_frame(screen, xf, yf, wf, hf)
  local crossing = false
  if frames_equal(win:frame(), target) then
    local next_screen = screen:next()
    if next_screen and next_screen:getUUID() ~= screen:getUUID() then
      target = target_frame(next_screen, xf, yf, wf, hf)
      crossing = true
    end
  end
  win:setFrame(target)
  -- Cross-screen moves between displays with different scaling sometimes
  -- mis-size on the first setFrame; re-apply after a tick to correct.
  if crossing then
    hs.timer.doAfter(0.05, function() win:setFrame(target) end)
  end
end

local THIRD = 1 / 3

-- col ∈ {0, 1, 2} for left, center, right
local function col_third(col) place(col * THIRD, 0,   THIRD, 1)   end
local function col_upper(col) place(col * THIRD, 0,   THIRD, 0.5) end
local function col_lower(col) place(col * THIRD, 0.5, THIRD, 0.5) end

-- Half-width columns (wider than thirds): left = 0..0.5, center = 0.25..0.75, right = 0.5..1
local function half_left()   place(0,    0, 0.5, 1) end
local function half_center() place(0.25, 0, 0.5, 1) end
local function half_right()  place(0.5,  0, 0.5, 1) end

local function full() place(0, 0, 1, 1) end

-- Center-column master-stack: toggles between middle-quarter (50-75%) and
-- bottom-quarter (75-100%). Detects current position from the frame, so
-- re-invoking the picker still toggles correctly.
local function center_quarter_toggle()
  local win = hs.window.focusedWindow()
  if not win then return end
  local s = screen_frame(win)
  local f = win:frame()
  local middle_y = s.y + 0.5 * s.h + GAP
  local in_middle = math.abs(f.y - middle_y) < 4
  if in_middle then
    place(THIRD, 0.75, THIRD, 0.25)
  else
    place(THIRD, 0.5,  THIRD, 0.25)
  end
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
bind(nil, "h", function() col_third(0) end)
bind(nil, "t", function() col_third(1) end)
bind(nil, "n", function() col_third(2) end)

-- Upper half of each column
bind(nil, "g", function() col_upper(0) end)
bind(nil, "c", function() col_upper(1) end)
bind(nil, "r", function() col_upper(2) end)

-- Lower half of left/right columns
bind(nil, "m", function() col_lower(0) end)
bind(nil, "v", function() col_lower(2) end)

-- Center column stack: w = middle/bottom quarter (toggle); Opt+w = full lower half
bind(nil,       "w", center_quarter_toggle)
bind({ "alt" }, "w", function() col_lower(1) end)

-- Half-width columns (wider than thirds)
bind({ "shift" }, "h", half_left)
bind({ "shift" }, "t", half_center)
bind({ "shift" }, "n", half_right)

-- Full screen
bind(nil, "s", full)

picker:bind({}, "escape", function() picker:exit() end)

hs.alert.show("Hammerspoon loaded")
