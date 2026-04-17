-- Three-column window layout + Divvy-style one-off placement.
-- Picker: Opt+Cmd+T enters layout mode; press one of the keys below to place
-- the focused window. Escape exits. Bindings match Dvorak home row.
--
-- First-run setup: grant Hammerspoon accessibility access
-- (System Settings → Privacy & Security → Accessibility). Enable
-- "Automatically reload config when any files change" in Hammerspoon prefs
-- if you want edits to this file to pick up without manual reload.

local GAP = 8
local TOL = 4  -- frame-match tolerance in pixels for slot detection

hs.window.animationDuration = 0

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
  return math.abs(a.x - b.x) < TOL and math.abs(a.y - b.y) < TOL
     and math.abs(a.w - b.w) < TOL and math.abs(a.h - b.h) < TOL
end

local THIRD = 1 / 3

-- Named grid slots. Any window whose frame matches one of these (on its
-- current screen) is considered "on-grid" and participates in displacement.
local slots = {
  full_L   = { col = 0, xf = 0,         yf = 0,    wf = THIRD, hf = 1    },
  upper_L  = { col = 0, xf = 0,         yf = 0,    wf = THIRD, hf = 0.5  },
  lower_L  = { col = 0, xf = 0,         yf = 0.5,  wf = THIRD, hf = 0.5  },
  full_C   = { col = 1, xf = THIRD,     yf = 0,    wf = THIRD, hf = 1    },
  upper_C  = { col = 1, xf = THIRD,     yf = 0,    wf = THIRD, hf = 0.5  },
  lower_C  = { col = 1, xf = THIRD,     yf = 0.5,  wf = THIRD, hf = 0.5  },
  mquart_C = { col = 1, xf = THIRD,     yf = 0.5,  wf = THIRD, hf = 0.25 },
  bquart_C = { col = 1, xf = THIRD,     yf = 0.75, wf = THIRD, hf = 0.25 },
  full_R   = { col = 2, xf = 2 * THIRD, yf = 0,    wf = THIRD, hf = 1    },
  upper_R  = { col = 2, xf = 2 * THIRD, yf = 0,    wf = THIRD, hf = 0.5  },
  lower_R  = { col = 2, xf = 2 * THIRD, yf = 0.5,  wf = THIRD, hf = 0.5  },
}

local function slot_frame(screen, name)
  local s = slots[name]
  return target_frame(screen, s.xf, s.yf, s.wf, s.hf)
end

-- Return the slot name matching win's current frame on its screen, or nil.
local function window_slot(win)
  local screen = win:screen()
  local f = win:frame()
  for name, _ in pairs(slots) do
    if frames_equal(f, slot_frame(screen, name)) then return name end
  end
  return nil
end

-- Displacement rules per target slot:
--   conflicts = slots whose occupant overlaps the target and must be moved.
--   options   = slots in the same column that do NOT overlap the target;
--               valid destinations for a displaced occupant.
--   canonical = default destination when no swap is possible.
-- Full-column (full_L/C/R) and half-width / full-screen placements are
-- intentionally absent — no displacement there.
local displacement = {
  upper_L  = { conflicts = { "full_L", "upper_L" }, options = { "lower_L" }, canonical = "lower_L" },
  lower_L  = { conflicts = { "full_L", "lower_L" }, options = { "upper_L" }, canonical = "upper_L" },
  upper_R  = { conflicts = { "full_R", "upper_R" }, options = { "lower_R" }, canonical = "lower_R" },
  lower_R  = { conflicts = { "full_R", "lower_R" }, options = { "upper_R" }, canonical = "upper_R" },
  upper_C  = { conflicts = { "full_C", "upper_C" }, options = { "lower_C", "mquart_C", "bquart_C" }, canonical = "lower_C" },
  lower_C  = { conflicts = { "full_C", "lower_C", "mquart_C", "bquart_C" }, options = { "upper_C" }, canonical = "upper_C" },
  mquart_C = { conflicts = { "mquart_C", "lower_C" }, options = { "upper_C", "bquart_C" }, canonical = "bquart_C" },
  bquart_C = { conflicts = { "bquart_C", "lower_C" }, options = { "upper_C", "mquart_C" }, canonical = "mquart_C" },
}

-- Slots that geometrically overlap a given slot (besides itself). Used to
-- check whether moving a displaced window to a destination would crush
-- another on-grid occupant.
local slot_overlaps = {
  full_L   = { "upper_L", "lower_L" },
  upper_L  = { "full_L" },
  lower_L  = { "full_L" },
  full_C   = { "upper_C", "lower_C", "mquart_C", "bquart_C" },
  upper_C  = { "full_C" },
  lower_C  = { "full_C", "mquart_C", "bquart_C" },
  mquart_C = { "full_C", "lower_C" },
  bquart_C = { "full_C", "lower_C" },
  full_R   = { "upper_R", "lower_R" },
  upper_R  = { "full_R" },
  lower_R  = { "full_R" },
}

-- Classify windows on the given screen (excluding `exclude`) into a map of
-- slot_name → first window found at that slot. Off-grid windows are ignored.
local function classify(screen, exclude)
  local by_slot = {}
  for _, win in ipairs(hs.window.visibleWindows()) do
    if win ~= exclude and win:screen():getUUID() == screen:getUUID() then
      local name = window_slot(win)
      if name and not by_slot[name] then by_slot[name] = win end
    end
  end
  return by_slot
end

-- Is `dest` a safe destination for moving `occupant`? Safe iff `dest`
-- itself and every slot that geometrically overlaps it are free of other
-- on-grid windows. The occupant's current slot counts as vacated.
local function dest_valid(dest, occupant, by_slot)
  if by_slot[dest] and by_slot[dest] ~= occupant then return false end
  for _, ov in ipairs(slot_overlaps[dest] or {}) do
    if by_slot[ov] and by_slot[ov] ~= occupant then return false end
  end
  return true
end

-- For each conflict occupant:
--   1. If focused came from one of the target's options, swap: displaced
--      goes to focused's old slot.
--   2. Else use the canonical complement.
-- Either way, only perform the move if the destination is safe (no new
-- overlap with another on-grid window).
local function displace(focused, target_name, screen)
  local rule = displacement[target_name]
  if not rule then return end
  local focused_old = window_slot(focused)
  local by_slot = classify(screen, focused)
  local function option_contains(name)
    for _, o in ipairs(rule.options) do if o == name then return true end end
    return false
  end
  for _, conflict_name in ipairs(rule.conflicts) do
    local occupant = by_slot[conflict_name]
    if occupant then
      local dest
      if focused_old and option_contains(focused_old) then
        dest = focused_old
      else
        dest = rule.canonical
      end
      if dest and dest_valid(dest, occupant, by_slot) then
        occupant:setFrame(slot_frame(screen, dest))
        by_slot[dest] = occupant
        by_slot[conflict_name] = nil
      end
    end
  end
end

-- Place the focused window into a named slot. If it's already there, cycle
-- to the next screen. Applies displacement on the destination screen.
local function place_slot(name)
  local win = hs.window.focusedWindow()
  if not win then return end
  local screen = win:screen()
  local target = slot_frame(screen, name)
  local crossing = false
  if frames_equal(win:frame(), target) then
    local next_screen = screen:next()
    if next_screen and next_screen:getUUID() ~= screen:getUUID() then
      screen = next_screen
      target = slot_frame(screen, name)
      crossing = true
    end
  end
  displace(win, name, screen)
  win:setFrame(target)
  if crossing then
    hs.timer.doAfter(0.05, function() win:setFrame(target) end)
  end
end

-- Raw placement for slots not in the named grid (half-width, full-screen).
-- No displacement, but keeps screen-cycling on repeat.
local function place_raw(xf, yf, wf, hf)
  local win = hs.window.focusedWindow()
  if not win then return end
  local screen = win:screen()
  local target = target_frame(screen, xf, yf, wf, hf)
  local crossing = false
  if frames_equal(win:frame(), target) then
    local next_screen = screen:next()
    if next_screen and next_screen:getUUID() ~= screen:getUUID() then
      screen = next_screen
      target = target_frame(screen, xf, yf, wf, hf)
      crossing = true
    end
  end
  win:setFrame(target)
  if crossing then
    hs.timer.doAfter(0.05, function() win:setFrame(target) end)
  end
end

-- Center stack `w`: if already in a quarter, toggle to the other; otherwise
-- prefer middle-quarter but fall back to bottom-quarter if middle is occupied
-- (repeated `w` then swaps middle ↔ bottom via the displacement rule).
local function center_quarter_toggle()
  local win = hs.window.focusedWindow()
  if not win then return end
  local current = window_slot(win)
  local target
  if current == "mquart_C" then
    target = "bquart_C"
  elseif current == "bquart_C" then
    target = "mquart_C"
  else
    local by_slot = classify(win:screen(), win)
    if by_slot["mquart_C"] and not by_slot["bquart_C"] then
      target = "bquart_C"
    else
      target = "mquart_C"
    end
  end
  place_slot(target)
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

-- Lower half of left/right columns
bind(nil, "m", function() place_slot("lower_L") end)
bind(nil, "v", function() place_slot("lower_R") end)

-- Center column stack: w = middle/bottom quarter (toggle); Opt+w = full lower half
bind(nil,       "w", center_quarter_toggle)
bind({ "alt" }, "w", function() place_slot("lower_C") end)

-- Half-width columns (wider than thirds)
bind({ "shift" }, "h", function() place_raw(0,    0, 0.5, 1) end)
bind({ "shift" }, "t", function() place_raw(0.25, 0, 0.5, 1) end)
bind({ "shift" }, "n", function() place_raw(0.5,  0, 0.5, 1) end)

-- Full screen
bind(nil, "s", function() place_raw(0, 0, 1, 1) end)

picker:bind({}, "escape", function() picker:exit() end)

-- Cross-window directional focus (Ctrl+Alt) and swap (Cmd+Ctrl) on the
-- Dvorak home row h/t/n/s = west/north/south/east. Works across screens.
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
  hs.hotkey.bind({ "ctrl", "alt" }, key, function() focus(dir) end)
  hs.hotkey.bind({ "cmd",  "ctrl" }, key, function() swap(dir)  end)
end

hs.alert.show("Hammerspoon loaded")
