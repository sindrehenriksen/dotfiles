-- the status line. Reads the
-- runner-written status file and formats it for an nvim statusline
-- component — wire `require("desk.status").summary()` into whatever
-- statusline plugin is in use; this module doesn't install one itself,
-- since which plugin (if any) is a per-machine choice outside desk's
-- remit.
--
-- The per-pass fields (`last_run`, `result`, `stopped_at`,
-- `failed_sources`) are pinned; the rest is the runner's own shape
-- (claude/desk-lib/status.sh, read-only here): `proposal` is `{state:
-- "pending"|"partial"|"none", partial, overflow: {act, worth_knowing,
-- wildcard}, counts, untaken}` — `untaken` is how many suggestions still
-- wait on the user (not taken, not declined), and `state` alone doesn't mean
-- "something's unresolved", so the segment only shows when `untaken` is
-- nonzero. `closes` / `refused_closes` / `failed_closes` / `lockouts` are
-- each a plain count. If the runner ends up writing something else, this is
-- the one place to change.
local M = {}

--- The status file path, overridable (`$DESK_STATUS_FILE`) the same way
--- every other desk path is.
function M.path()
	local override = vim.env.DESK_STATUS_FILE
	return vim.fn.expand((override and override ~= "") and override or "~/.local/state/desk/status.json")
end

--- Reads and parses the status file, or nil if it's absent/invalid — a
--- caller shows nothing rather than erroring.
function M.read(path)
	path = path or M.path()
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local data = fd:read("*a")
	fd:close()
	local ok, parsed = pcall(vim.json.decode, data)
	if not ok or type(parsed) ~= "table" then
		return nil
	end
	return parsed
end

--- One segment per configured pass: "morning: ok", "morning: failed
--- (fetch)", "morning: partial" — `stopped_at` names the step only on a
--- failure, since a clean run has none to name.
local function pass_segments(status)
	local out = {}
	for name, p in pairs(status.passes or {}) do
		local result = p.result or "unknown"
		if result == "failed" and p.stopped_at then
			out[#out + 1] = string.format("%s: failed (%s)", name, p.stopped_at)
		else
			out[#out + 1] = string.format("%s: %s", name, result)
		end
	end
	table.sort(out)
	return out
end

--- An open review's count, the same text in both of its bars: what is
--- still waiting with unsaved takes and declines counted as done, then
--- what the ledger and HEAD say.
function M.live_count(left, saved)
	return string.format("%d left (%d saved)", left, saved or left)
end

--- The proposal segment: "proposal pending", "proposal partial", and any
--- "+N more ACT → brief" / worth_knowing / wildcard overflow counts. Only
--- shown while at least one suggestion still waits on the user (`untaken`).
local function proposal_segments(status, opts)
	local out = {}
	local p = status.proposal or {}
	local untaken = opts and opts.untaken
	if opts and opts.left ~= nil then
		out[#out + 1] = M.live_count(opts.left, opts.saved)
	elseif untaken == nil then
		untaken = p.untaken or 0
		if not p.state or p.state == "none" then
			return out
		end
	end
	if #out == 0 then
		if untaken <= 0 then
			return out
		end
		out[#out + 1] = string.format("proposal %s (%d untaken)", (p.state and p.state ~= "none") and p.state or "pending", untaken)
	end
	local tier_labels = { act = "ACT", worth_knowing = "worth knowing", wildcard = "wildcard" }
	for _, tier in ipairs({ "act", "worth_knowing", "wildcard" }) do
		local n = p.overflow and p.overflow[tier]
		if n and n > 0 then
			out[#out + 1] = string.format("+%d more %s → brief", n, tier_labels[tier])
		end
	end
	return out
end

--- Segments for any closes/refusals/lockouts — each only shown when it's
--- actually nonzero, so a clean status line stays a clean status line. The
--- real closes name the sessions closed most recently (`closed_names`).
local function counts_segments(status)
	local out = {}
	-- "closes" (real, successful closes) never had a segment at all —
	-- only its refused/failed/lockout counterparts did, so a clean run's
	-- own closes were invisible next to its failures.
	for _, field in ipairs({ "closes", "refused_closes", "failed_closes", "lockouts" }) do
		local n = status[field]
		if n and n > 0 then
			local label = string.format("%d %s", n, (field:gsub("_", " ")))
			local names = field == "closes" and status.closed_names
			if type(names) == "table" and #names > 0 then
				local shown = vim.list_slice(names, math.max(1, #names - 2))
				label = label .. " (" .. table.concat(shown, ", ") .. ")"
			end
			out[#out + 1] = label
		end
	end
	return out
end

--- A single-line summary, segments joined with " · ", or "" if the status
--- file is missing/empty (so a statusline component can just show nothing
--- rather than a placeholder).
--- `opts.untaken` is the recorded count of suggestions still waiting on the
--- user (what a review would show); without it the runner's own `untaken`
--- applies, which only moves when a pass runs. `opts.left` and `opts.saved`,
--- while a review is open, are that review's live and recorded counts, and
--- replace the proposal segment with `live_count`'s text, shown even at zero.
function M.summary(status, opts)
	if not status then
		if opts and ((opts.untaken or 0) > 0 or opts.left ~= nil) then
			status = {}
		else
			return ""
		end
	end
	local segments = {}
	for _, s in ipairs(pass_segments(status)) do
		segments[#segments + 1] = s
	end
	for _, s in ipairs(proposal_segments(status, opts)) do
		segments[#segments + 1] = s
	end
	for _, s in ipairs(counts_segments(status)) do
		segments[#segments + 1] = s
	end
	return table.concat(segments, " · ")
end

--- Reads the status file and formats it in one call — the function a
--- statusline component actually wires in.
function M.statusline(opts)
	return M.summary(M.read(), opts)
end

return M
