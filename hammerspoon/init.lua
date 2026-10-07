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
-- case of a terminal and a browser. Each sits a fixed margin in from its
-- outer edge, so left and right mirror exactly. Geometry is per display: the
-- ultrawide has room to tile both with air around them, the laptop does not,
-- so there the large window takes the screen and the small one floats over it.
--
-- Vertical placement is centred unless a box gives an explicit `y`. The
-- laptop's small window is deliberately high rather than centred — it is the
-- terminal, and the space below it is where the large window stays readable.
local two_up = {
  wide   = { margin = 0.10,  small = { w = 0.295, h = 0.70 },           large = { w = 0.48, h = 0.90 } },
  narrow = { margin = 0.005, small = { w = 0.53,  h = 0.79, y = 0.06 }, large = { w = 0.73, h = 0.96 } },
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
  return xf, box.y or (1 - box.h) / 2, box.w, box.h
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

-- ---------------------------------------------------------------------------
-- Desk: open a command in a Ghostty tab, never typed into a terminal. Used
-- from outside Hammerspoon (nvim, a shell wrapper) via `hs -c`, for the
-- notes hotkey's session resume and the Wednesday weekly tab. Opens in the
-- Ghostty window whose centre sits in the ultrawide's upper_C slot; with
-- none there, opens a new window placed at that slot; with no ultrawide at
-- all (laptop screen only), uses the frontmost window.
--
-- Pure decision/validation logic is exposed on the DeskTab global (same
-- convention as caps_tap above: unprefixed globals so `hs -c` and a plain
-- Lua process can reach in) so it can be exercised without the hs.* runtime
-- — see hammerspoon/tests/tab-function-test.lua.
-- ---------------------------------------------------------------------------

DeskTab = {}

-- A session id must look like a UUID before it is ever interpolated into an
-- AppleScript string: it can arrive as a raw shell argument, and a token
-- that starts with `-` or holds a quote must never reach osascript unchecked.
function DeskTab.looks_like_uuid(s)
  return type(s) == "string" and s:match(
    "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
  ) ~= nil
end

function DeskTab.frame_center(frame)
  return { x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 }
end

-- Loose match: the window's centre sits inside the slot's rectangle, not an
-- exact frame match — the user may have nudged or resized it, and re-placing it
-- isn't this function's job.
function DeskTab.point_in_frame(pt, frame)
  return pt.x >= frame.x and pt.x <= frame.x + frame.w
     and pt.y >= frame.y and pt.y <= frame.y + frame.h
end

-- The Ghostty windows whose centres sit in the ultrawide's upper_C and
-- lower_C slots, as Hammerspoon ids (either may be nil). With no ultrawide,
-- the frontmost window stands in for upper_C when it is Ghostty's.
-- Pure, so it's testable without hs.*:
--   screens: list of { id, wide }
--   windows: Ghostty's own windows, front to back, as { id, screen_id, frame }
--   slot_frame_of(screen_id, slot): that slot's absolute frame on the screen
--   front_window: { id, app } or nil
function DeskTab.slot_windows(screens, windows, slot_frame_of, front_window)
  local wide_screen
  for _, s in ipairs(screens) do
    if s.wide then
      wide_screen = s
      break
    end
  end
  if not wide_screen then
    return front_window and front_window.app == "Ghostty" and front_window.id or nil, nil
  end
  local function in_slot(slot)
    local target = slot_frame_of(wide_screen.id, slot)
    for _, w in ipairs(windows) do
      if w.screen_id == wide_screen.id
          and DeskTab.point_in_frame(DeskTab.frame_center(w.frame), target) then
        return w.id
      end
    end
    return nil
  end
  return in_slot("upper_C"), in_slot("lower_C")
end

-- Where an open puts its tab: { mode = "tab", window_id = <Hammerspoon id> }
-- or { mode = "new_window" }. Session tabs go to upper_C. A background open
-- never goes into the window being typed in (Ghostty cannot add a tab
-- without selecting it, which would take over that terminal), so when that
-- is upper_C it falls back to lower_C, and to a new window with neither.
--   typing_id: the Ghostty window the user is typing in, or nil
function DeskTab.plan_open(upper, lower, typing_id, background)
  local target = upper
  if background and typing_id ~= nil and target == typing_id then
    target = lower
  end
  if target == nil or (background and target == typing_id) then
    return { mode = "new_window" }
  end
  return { mode = "tab", window_id = target }
end

-- Ghostty's AppleScript window ids ("tab-group-…") are its own, unrelated to
-- the window-server ids Hammerspoon sees, and its dictionary exposes no
-- geometry. The two sides do agree on each window's title and on front-to-
-- back order, so a window is matched by title, and among windows sharing a
-- title by its rank in that order. Returns Ghostty's id, or nil when the
-- match is not certain (no such title, or the two sides count a shared
-- title differently, e.g. a same-titled window on another Space).
--   hs_windows: { id, title } front to back, Ghostty's only
--   script_windows: { id, name } front to back, from Ghostty's dictionary
function DeskTab.match_script_window(target_id, hs_windows, script_windows)
  local title
  for _, w in ipairs(hs_windows) do
    if w.id == target_id then title = w.title break end
  end
  if title == nil then return nil end

  local rank, hs_count = nil, 0
  for _, w in ipairs(hs_windows) do
    if w.title == title then
      hs_count = hs_count + 1
      if w.id == target_id then rank = hs_count end
    end
  end
  local same = {}
  for _, w in ipairs(script_windows) do
    if w.name == title then same[#same + 1] = w end
  end
  if #same ~= hs_count then return nil end
  return same[rank].id
end

-- True when focus sits on a Ghostty window the open itself created: the
-- theft a background open undoes. Ghostty's activation always lands on the
-- new tab or window, and each tab is its own window with its own id, so
-- that id is one `known` (every Ghostty window id from before the open)
-- does not hold. Focus the user moves anywhere else, including to another
-- existing Ghostty window, is left alone.
--   before/now: { app, window_id } (window_id may be nil mid-transition)
function DeskTab.focus_was_taken(before, now, known)
  if now == nil or now.app ~= "Ghostty" or now.window_id == nil then return false end
  if before and before.app == now.app and before.window_id == now.window_id then return false end
  return not (known or {})[now.window_id]
end

-- Why a tab can move a window: Ghostty saves the frame of the window it
-- last focused, moved or resized (its "NSWindowLastPosition" preference)
-- and moves every window it shows to that saved position, a new tab's
-- included. A tab joins its window before it is shown, so the window goes
-- with it: a tab added to any window but the one whose frame is saved
-- moves that window on screen, onto the saved one's place. So a tab is
-- added to a window only once the saved position is that window's own
-- frame; Ghostty's `activate window` on it makes it the focused window,
-- which saves its frame.

-- The saved position from `defaults read com.mitchellh.ghostty
-- NSWindowLastPosition` output, as { x, y, w, h } in AppKit coordinates
-- (origin bottom-left of the primary screen), or nil.
function DeskTab.parse_saved_position(text)
  if type(text) ~= "string" then return nil end
  local nums = {}
  for n in text:gmatch("-?%d+%.?%d*") do nums[#nums + 1] = tonumber(n) end
  if #nums < 4 then return nil end
  return { x = nums[1], y = nums[2], w = nums[3], h = nums[4] }
end

-- True when `saved` (AppKit coordinates) is exactly the window frame
-- `frame` (Hammerspoon's: origin top-left, y down), given the primary
-- screen's full height. Within a point, since AppKit keeps fractions.
function DeskTab.saved_position_is(saved, frame, primary_height)
  if not saved or not frame or not primary_height then return false end
  local y = primary_height - (frame.y + frame.h)
  return math.abs(saved.x - frame.x) < 1 and math.abs(saved.y - y) < 1
     and math.abs(saved.w - frame.w) < 1 and math.abs(saved.h - frame.h) < 1
end

-- The one window a new-window open created, as Hammerspoon's id, or nil
-- whenever that is not certain; only that window is ever given a frame.
-- Certain means: Ghostty counts exactly one more window than before, and
-- exactly one Hammerspoon id is new while every id from before is still
-- there. An existing window's id changes when its selected tab does, so a
-- vanished id means the new id could be an existing window, never to be
-- moved.
--   before_ids: set of Ghostty window ids before the open
--   after: list of { id } now
--   groups_before, groups_after: Ghostty's own window counts
function DeskTab.created_window(before_ids, after, groups_before, groups_after)
  if groups_before == nil or groups_after ~= groups_before + 1 then return nil end
  local seen, created = {}, {}
  for _, w in ipairs(after) do
    seen[w.id] = true
    if not before_ids[w.id] then created[#created + 1] = w.id end
  end
  for id in pairs(before_ids) do
    if not seen[id] then return nil end
  end
  if #created ~= 1 then return nil end
  return created[1]
end

function DeskTab.frames_overlap(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- Where a newly created window goes so it is not over the window the user
-- is working in (Ghostty shows it right on top of that one): the first
-- candidate slot that does not overlap `focused` and holds no other
-- window's centre, else the first that at least does not overlap
-- `focused`, else nil (left where Ghostty put it).
--   candidates: ordered list of frames; occupied: frames of the other
--   visible windows; focused: the frame of the window that had focus, or nil
function DeskTab.pick_free_slot(candidates, occupied, focused)
  local away = {}
  for _, c in ipairs(candidates) do
    if not (focused and DeskTab.frames_overlap(c, focused)) then away[#away + 1] = c end
  end
  for _, c in ipairs(away) do
    local free = true
    for _, o in ipairs(occupied) do
      if DeskTab.point_in_frame(DeskTab.frame_center(o), c) then free = false break end
    end
    if free then return c end
  end
  return away[1]
end

local function as_string_literal(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- A single-quoted token for $1 at the POSIX-shell level (as opposed to
-- as_string_literal, which quotes for the AppleScript source this whole
-- thing is embedded in) — the one place a command line built elsewhere
-- (already shell-quoted for ITS OWN argv, e.g. desk-lib/common.sh's own
-- desk_shq) needs re-quoting as a single argument to a further wrapping
-- shell.
local function shell_single_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Every tab command (the follow-up tab, the hotkey's resume, the
-- Wednesday tab) runs through the user's own login+interactive shell rather than
-- however Ghostty's own `command:` field would otherwise invoke it —
-- the desk launch envelope assumes CLAUDE_CONFIG_DIR and PATH
-- (~/.local/bin, mise shims, ...) come from the user's shell rc files, which a
-- bare exec of the command never sources.
local function wrap_in_login_shell(cmd)
  return "/bin/zsh -lic " .. shell_single_quote(cmd)
end

-- Ghostty's AppleScript dictionary takes the new tab's (or window's) shell
-- command and cwd as a `configuration` record. Ghostty keeps a surface
-- given a `command` open after it exits ("Process exited. Press any key"),
-- and a record cannot turn that off, which suits a session tab the user may
-- want to read afterwards. A tab that should close when done
-- (`close_on_exit`) instead starts the user's own shell and hands it the
-- command as its initial input, `exec`ed so the surface ends with it, the
-- way Ghostty runs a script file it is asked to open. Either way the text
-- goes only to the new surface, never as keystrokes to whatever is focused.
local function tab_configuration(cmd, cwd, close_on_exit)
  local fields
  if close_on_exit then
    fields = { "initial input:(" .. as_string_literal(" exec " .. wrap_in_login_shell(cmd)) .. " & linefeed)" }
  else
    fields = { "command:" .. as_string_literal(wrap_in_login_shell(cmd)) }
  end
  if cwd and cwd ~= "" then
    fields[#fields + 1] = "initial working directory:" .. as_string_literal(cwd)
  end
  return "{" .. table.concat(fields, ", ") .. "}"
end

-- hs.osascript.applescript returns ok, result, descriptor; on failure the
-- result is nil and the error is a table in the descriptor.
function DeskTab.osascript_error(descriptor)
  if type(descriptor) == "table" then
    return tostring(descriptor.OSAScriptErrorMessageKey
      or descriptor.NSLocalizedDescription
      or descriptor.OSAScriptErrorBriefMessageKey
      or "unknown error")
  end
  return tostring(descriptor)
end

-- An AppleScript that runs `create` in Ghostty and judges it by whether
-- `count` went up, not by whether the command raised: Ghostty can create
-- the tab or window and still fail to hand back a reference to it. A real
-- failure (nothing created) re-raises with Ghostty's own message. Returns
-- "opened", or "opened despite: <message>". `setup` is an optional first
-- statement, e.g. binding the target window.
function DeskTab.created_or_error_script(setup, count, create)
  return table.concat({
    'tell application "Ghostty"',
    setup or "",
    "set countBefore to " .. count,
    "try",
    create,
    "on error errMsg number errNum",
    "if (" .. count .. ") > countBefore then return \"opened despite: \" & errMsg",
    "error errMsg number errNum",
    "end try",
    'return "opened"',
    "end tell",
  }, "\n")
end

-- Ghostty's visible windows, front to back (one per tab group: a native
-- tab bar shows as the selected tab's own window).
local function ghostty_app_windows()
  local out = {}
  for _, w in ipairs(hs.window.orderedWindows()) do
    local app = w:application()
    if app and app:name() == "Ghostty" and (w:id() or 0) ~= 0 then
      out[#out + 1] = { id = w:id(), title = w:title(), screen_id = w:screen():id(), frame = w:frame() }
    end
  end
  return out
end

-- Ghostty's own view of its windows, front to back, as { id, name }; nil
-- when the query fails.
local function ghostty_script_windows()
  local ok, result = hs.osascript.applescript(
    'tell application "Ghostty" to get {id, name} of every window'
  )
  if not ok or type(result) ~= "table" or type(result[1]) ~= "table" then
    return nil
  end
  local out = {}
  for i, id in ipairs(result[1]) do
    out[#out + 1] = { id = id, name = result[2] and result[2][i] }
  end
  return out
end

-- Ghostty's saved last window position (see DeskTab.parse_saved_position),
-- read fresh each time, or nil.
local function ghostty_saved_position()
  local out, ok = hs.execute("/usr/bin/defaults read com.mitchellh.ghostty NSWindowLastPosition 2> /dev/null")
  return ok and DeskTab.parse_saved_position(out) or nil
end

local function primary_height()
  local p = hs.screen.primaryScreen()
  return p and p:fullFrame().h or nil
end

-- Candidate frames for a new window, in order: the ultrawide's half slots
-- off the middle column, then its middle ones, then every other screen.
local NEW_WINDOW_SLOTS = { "upper_L", "lower_L", "upper_R", "lower_R", "upper_C", "lower_C" }
local function new_window_slots(screens_by_id)
  local out, others = {}, {}
  for _, scr in pairs(screens_by_id) do
    if screen_kind(scr) == "wide" then
      for _, name in ipairs(NEW_WINDOW_SLOTS) do out[#out + 1] = slot_frame(scr, name) end
    else
      others[#others + 1] = scr:frame()
    end
  end
  for _, f in ipairs(others) do out[#out + 1] = f end
  return out
end

-- Makes `frame` (the target window's) Ghostty's saved position, so a tab
-- added to that window cannot move it: already so, or after `activate
-- window` makes it Ghostty's focused window, which saves its frame. Waits
-- briefly for the save to land (blocking, so kept short). True when it is
-- safe to add the tab; `activated` says whether focus was moved for it.
local SAVE_WAIT_TRIES, SAVE_WAIT_USECS = 6, 50000
local function make_saved_position(frame, script_id)
  local height = primary_height()
  if DeskTab.saved_position_is(ghostty_saved_position(), frame, height) then
    return true, false
  end
  local ok = hs.osascript.applescript(string.format(
    'tell application "Ghostty" to activate window (window id %s)', as_string_literal(script_id)))
  if not ok then return false, false end
  for _ = 1, SAVE_WAIT_TRIES do
    if DeskTab.saved_position_is(ghostty_saved_position(), frame, height) then
      return true, true
    end
    hs.timer.usleep(SAVE_WAIT_USECS)
  end
  return false, true
end

-- Ghostty's own id for its key window (the one being typed in when Ghostty
-- is active), or nil.
local function ghostty_front_window_id()
  local ok, result = hs.osascript.applescript('tell application "Ghostty" to get id of front window')
  if ok and type(result) == "string" and result ~= "" then return result end
  return nil
end

local function focus_snapshot()
  local app = hs.application.frontmostApplication()
  local win = hs.window.focusedWindow()
  return {
    app = app and app:name(),
    window_id = win and win:id(),
    app_obj = app,
    win_obj = win,
  }
end

-- Hammerspoon's own console print, kept from load time: inside a timer
-- that an `hs -c` call started, `print` still goes to that CLI session,
-- which has usually exited by then, so the message would be lost.
local console_print = print

-- A timer nothing references can be collected before it fires, so every
-- desk timer is held here until it stops.
local desk_timers = {}
local function every_until_done(interval, fn)
  local timer
  timer = hs.timer.doEvery(interval, function()
    if fn() then
      timer:stop()
      desk_timers[timer] = nil
    end
  end)
  desk_timers[timer] = true
  return timer
end

-- Hands focus back to where it was. A Ghostty window is reactivated by
-- Ghostty itself (`activate window`), since a Hammerspoon focus on another
-- window of the app that has just made a new window key does not reliably
-- take; any other app's window gets Hammerspoon's focus.
local function hand_focus_back(before)
  if before.app == "Ghostty" and before.script_id then
    local ok, _, descriptor = hs.osascript.applescript(string.format(
      'tell application "Ghostty" to activate window (window id %s)', as_string_literal(before.script_id)))
    if ok then return end
    console_print("DeskOpenTab: could not reactivate the Ghostty window: " .. DeskTab.osascript_error(descriptor))
  end
  if before.win_obj then
    before.win_obj:focus()
  elseif before.app_obj then
    before.app_obj:activate()
  end
end

-- Ghostty activates itself and makes the new tab or window key once the
-- AppleEvent has returned, with no option to skip it, and may do so more
-- than once while the window settles. So a background open watches for
-- the whole FOCUS_WATCH_SECS and hands focus back every time it lands on
-- what the open created. In the gap, a key typed can still land in the new
-- tab; Ghostty offers no way to close it. Each step is logged to the
-- console, so a live run can be read back.
-- `own_id` is a window this open focused itself to add its tab. Handing
-- focus back from it before Ghostty has shown the tab would make the
-- user's window the saved position again, and the tab would then move the
-- target onto it; so focus there is left alone until the new tab has been
-- seen, which is after that move would have happened, or OWN_GRACE_SECS.
local FOCUS_WATCH_SECS, FOCUS_POLL_SECS, OWN_GRACE_SECS = 4, 0.05, 1
-- `place`, for a new-window open, gives the new window a slot away from
-- the window that had focus (DeskTab.pick_free_slot), once
-- DeskTab.created_window names it for certain. It is done in the tick
-- that hands focus back, just before: a frame set on the new window makes
-- it Ghostty's saved position, and handing focus back to a Ghostty window
-- through `activate window` saves that window's frame again, so a tab the
-- user opens next in it cannot drag it. Nothing is placed when focus is
-- never seen on the new window.
local function place_new_window(place, now)
  local script_windows = ghostty_script_windows()
  local id = DeskTab.created_window(place.known, ghostty_app_windows(), place.groups_before,
    script_windows and #script_windows)
  if not id or id ~= now.window_id then return false end
  local occupied = {}
  for _, w in ipairs(hs.window.orderedWindows()) do
    if w:id() ~= id then occupied[#occupied + 1] = w:frame() end
  end
  local frame = DeskTab.pick_free_slot(place.candidates, occupied, place.focused_frame)
  local win = hs.window.get(id)
  if frame and win then
    win:setFrame(frame)
    console_print(string.format("DeskOpenTab: placed the new window %s at %d,%d away from the focused window",
      tostring(id), frame.x, frame.y))
  else
    console_print("DeskOpenTab: no slot away from the focused window; the new window stays where Ghostty put it")
  end
  return true
end

local function restore_focus_when_taken(before, known, own_id, place)
  local started = hs.timer.secondsSinceEpoch()
  local handed_back = 0
  local seen_new = false
  local placed = place == nil
  every_until_done(FOCUS_POLL_SECS, function()
    local now = focus_snapshot()
    local taken = DeskTab.focus_was_taken(before, now, known)
    if taken and now.window_id ~= own_id then seen_new = true end
    if taken and now.window_id == own_id and not seen_new
        and hs.timer.secondsSinceEpoch() - started <= OWN_GRACE_SECS then
      taken = false
    end
    if hs.timer.secondsSinceEpoch() - started > FOCUS_WATCH_SECS then
      console_print(string.format("DeskOpenTab: focus watch done: handed back %d time(s); focus on %s window %s%s",
        handed_back, tostring(now.app), tostring(now.window_id), taken and " (STILL the new one)" or ""))
      if before.app == "Ghostty" and before.win_obj
          and not DeskTab.saved_position_is(ghostty_saved_position(), before.win_obj:frame(), primary_height()) then
        console_print("DeskOpenTab: WARNING Ghostty's saved position is not the focused window's; a tab opened there next could move it")
      end
      return true
    end
    if taken and not placed then
      placed = place_new_window(place, now)
    end
    if taken then
      handed_back = handed_back + 1
      if handed_back == 1 then
        console_print(string.format("DeskOpenTab: focus moved to the new window %s; handing it back to %s window %s (Ghostty id %s)",
          tostring(now.window_id), tostring(before.app), tostring(before.window_id), tostring(before.script_id)))
      end
      hand_focus_back(before)
    end
    return false
  end)
end

-- Opens `cmd` (with optional `cwd`) in a new Ghostty tab per the placement
-- rule above. `session_id`, if given, must be UUID-shaped or nothing runs.
-- `opts.background` (the scheduled passes) keeps focus where the user has
-- it: the tab never goes into the window being typed in, and the focus
-- Ghostty takes on opening it is handed back. Without it (the notes
-- hotkey) the new tab is focused, as asked for.
-- An osascript failure is reported (print, so `hs -c` surfaces it) and
-- nothing further is attempted — never falls back to typing the command.
function DeskOpenTab(cmd, session_id, cwd, opts)
  opts = opts or {}
  if session_id ~= nil and not DeskTab.looks_like_uuid(session_id) then
    print("DeskOpenTab: refusing non-UUID session id: " .. tostring(session_id))
    return false
  end

  local screens, screens_by_id = {}, {}
  for _, s in ipairs(hs.screen.allScreens()) do
    local entry = { id = s:id(), wide = screen_kind(s) == "wide" }
    screens[#screens + 1] = entry
    screens_by_id[entry.id] = s
  end
  local windows = ghostty_app_windows()
  local front = hs.window.frontmostWindow()
  local front_plain = front and {
    id = front:id(),
    app = front:application() and front:application():name() or "",
  }
  local script_windows = ghostty_script_windows()
  if script_windows and #script_windows > 0 and #windows == 0 then
    -- What a locked screen looks like: Ghostty has windows that Hammerspoon
    -- cannot see, so neither the layout nor the window being typed in is
    -- known, and any choice could land on top of it.
    print("DeskOpenTab: Ghostty's windows are not visible (screen locked?); not opening")
    return false
  end
  local known = {}
  for _, w in ipairs(windows) do known[w.id] = true end
  local before = opts.background and focus_snapshot() or nil
  local user_in_ghostty = before ~= nil and before.app == "Ghostty"
  if user_in_ghostty then
    -- Ghostty's key window is the one being typed in; its id comes from
    -- Ghostty directly, never from matching titles, which a live session
    -- keeps changing.
    before.script_id = ghostty_front_window_id()
  end

  local function slot_frame_of(screen_id, slot)
    return slot_frame(screens_by_id[screen_id], slot)
  end
  local upper, lower = DeskTab.slot_windows(screens, windows, slot_frame_of, front_plain)
  local plan = DeskTab.plan_open(upper, lower, user_in_ghostty and before.window_id or nil, opts.background)

  local tab_in, own_id
  if plan.mode == "tab" then
    local target
    for _, w in ipairs(windows) do
      if w.id == plan.window_id then target = w end
    end
    tab_in = target and script_windows and DeskTab.match_script_window(target.id, windows, script_windows)
    if not tab_in then
      -- Without `in`, Ghostty adds the tab to its own last-focused window,
      -- which may be the one being typed in: a new window is the safe fallback.
      console_print("DeskOpenTab: could not identify the target window to Ghostty; opening a new window")
    else
      local safe, activated = make_saved_position(target.frame, tab_in)
      if activated then
        -- Focus on the target is this open's own doing, to be handed back.
        known[target.id] = nil
        own_id = target.id
      end
      if not safe then
        console_print("DeskOpenTab: Ghostty's saved position did not become the target window's; opening a new window so nothing moves")
        tab_in = nil
      end
    end
  end

  local config = tab_configuration(cmd, cwd, opts.close_on_exit)
  local script
  if tab_in then
    script = DeskTab.created_or_error_script(
      string.format("set w to window id %s", as_string_literal(tab_in)),
      "count of tabs of w",
      "new tab in w with configuration " .. config
    )
  else
    script = DeskTab.created_or_error_script(nil, "count of windows", "new window with configuration " .. config)
  end

  local place
  if before and not tab_in then
    local before_ids = {}
    for _, w in ipairs(windows) do before_ids[w.id] = true end
    place = {
      known = before_ids,
      groups_before = script_windows and #script_windows,
      candidates = new_window_slots(screens_by_id),
      focused_frame = before.win_obj and before.win_obj:frame() or nil,
    }
  end

  local ok, result, descriptor = hs.osascript.applescript(script)
  -- Ghostty may already have taken focus even when the call reports an
  -- error, so the guard runs either way.
  if before then restore_focus_when_taken(before, known, own_id, place) end
  if not ok then
    print("DeskOpenTab: osascript failed: " .. DeskTab.osascript_error(descriptor))
    return false
  end
  if type(result) == "string" and result:find("^opened despite: ") then
    print("DeskOpenTab: " .. result)
  end
  console_print(string.format("DeskOpenTab: opened a %s%s", tab_in and "tab in Ghostty window " or "new window",
    tab_in or ""))

  return true
end

-- ---------------------------------------------------------------------------
-- Desk: focus an existing Ghostty tab by the tty of the process running in
-- it — the notes hotkey's live-session case, so it never opens a second tab
-- against a session that's already live. In Ghostty's dictionary the tty
-- belongs to a terminal (a tab's split), not to the tab, and `focus` on a
-- terminal selects its tab and brings its window and Ghostty forward.
-- ---------------------------------------------------------------------------

--- Strips a leading "/dev/" so "ttys003" and "/dev/ttys003" compare equal
--- — session-status.sh's own pid-file-derived tty and Ghostty's own `tty`
--- property aren't guaranteed to agree on which form they report.
function DeskTab.normalize_tty(tty)
  if type(tty) ~= "string" then
    return tty
  end
  return (tty:gsub("^/dev/", ""))
end

-- The AppleScript that focuses the terminal on `tty` (either form), in one
-- call: "focused", or "none" when no open terminal is on it. Ghostty
-- reports the /dev/ form.
function DeskTab.focus_tty_script(tty)
  return table.concat({
    'tell application "Ghostty"',
    "set matches to every terminal whose tty is " .. as_string_literal("/dev/" .. DeskTab.normalize_tty(tty)),
    'if (count of matches) = 0 then return "none"',
    "focus (item 1 of matches)",
    'return "focused"',
    "end tell",
  }, "\n")
end

-- Focuses the Ghostty tab running `tty`. Returns true on success; false
-- (printed, so `hs -c` surfaces it) if Ghostty isn't running, the
-- AppleScript failed, or no open terminal is on that tty — callers (the
-- notes hotkey) must treat false as "don't resume either": falling back to
-- resuming a session this returned false for would risk a second process
-- against a live transcript.
function DeskFocusTab(tty)
  if type(tty) ~= "string" or tty == "" then
    print("DeskFocusTab: no tty given")
    return false
  end
  if not hs.application.get("Ghostty") then
    print("DeskFocusTab: Ghostty is not running")
    return false
  end
  local ok, result, descriptor = hs.osascript.applescript(DeskTab.focus_tty_script(tty))
  if not ok then
    print("DeskFocusTab: osascript failed: " .. DeskTab.osascript_error(descriptor))
    return false
  end
  if result ~= "focused" then
    print("DeskFocusTab: no Ghostty tab is running " .. tty)
    return false
  end
  return true
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
