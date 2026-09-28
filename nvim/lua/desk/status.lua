-- D7: the status line (design.md §2 "Status line", §9(f)). Reads the
-- runner-written status file and formats it for an nvim statusline
-- component — wire `require("desk.status").summary()` into whatever
-- statusline plugin is in use; this module doesn't install one itself,
-- since which plugin (if any) is a per-machine choice outside desk's
-- remit.
--
-- §9(f) pins the per-pass fields (`last_run`, `result`, `stopped_at`,
-- `failed_sources`) and the his-text-derived ones (`accepted_by_accident`,
-- `resolved_without_key`, `waiting_edits` — each a plain array of item ids,
-- never a line number: this file is read by any editor instance at any
-- time, with no live buffer to resolve a line against) exactly. The rest
-- is the runner's own shape (claude/desk-lib/status.sh, D8a), read-only
-- here: `proposal` is `{state: "pending"|"partial"|"none", partial,
-- overflow: {act, worth_knowing, wildcard}, counts, queued, deferred}` —
-- `deferred` (an item that didn't apply cleanly at lay-in) lives HERE,
-- never as its own top-level field, and `state` alone doesn't mean
-- "something's unresolved": it's set from whether the standing proposal
-- ref holds any items at all, not from whether any of them still are —
-- `queued`/`deferred` are what's actually left for him to act on. `closes`
-- / `refused_closes` / `failed_closes` / `lockouts` are each a plain count.
-- If the runner ends up writing something else, this is the one place to
-- change.
local M = {}

--- The status file path, overridable (`$DESK_STATUS_FILE`) the same way
--- every other desk path is.
function M.path()
	local override = vim.env.DESK_STATUS_FILE
	return vim.fn.expand((override and override ~= "") and override or "~/.local/state/desk/status.json")
end

--- Reads and parses the status file, or nil if it's absent/invalid — a
--- caller shows nothing rather than erroring (design.md's own "a pass
--- that didn't finish says so" is about the file's *content*, not about
--- this reader surviving the file not existing yet at all).
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

--- The proposal segment: "proposal pending", "proposal partial", and any
--- "+N more ACT → brief" / worth_knowing / wildcard overflow counts. `state`
--- alone isn't enough — desk-run sets it from whether the STANDING
--- proposal ref holds any items at all, not from whether any of them are
--- still unresolved, so a proposal every item of which he's since
--- accepted/declined by hand (never through a run) would still read
--- "pending" forever. `queued`/`deferred` (also desk-run's own fields) are
--- what's actually left for him to act on, so the segment only shows when
--- at least one of them is nonzero.
local function proposal_segments(status)
	local out = {}
	local p = status.proposal
	if not p or not p.state or p.state == "none" then
		return out
	end
	if ((p.queued or 0) + (p.deferred or 0)) <= 0 then
		return out
	end
	out[#out + 1] = "proposal " .. p.state
	local tier_labels = { act = "ACT", worth_knowing = "worth knowing", wildcard = "wildcard" }
	for _, tier in ipairs({ "act", "worth_knowing", "wildcard" }) do
		local n = p.overflow and p.overflow[tier]
		if n and n > 0 then
			out[#out + 1] = string.format("+%d more %s → brief", n, tier_labels[tier])
		end
	end
	return out
end

--- Segments for the his-text-derived counts and any closes/refusals/
--- lockouts — each only shown when it's actually nonzero, so a clean
--- status line stays a clean status line.
local function counts_segments(status)
	local out = {}
	local waiting = #(status.waiting_edits or {})
	if waiting > 0 then
		out[#out + 1] = string.format("%d of your edits wait on a suggestion", waiting)
	end
	local resolved = #(status.resolved_without_key or {})
	if resolved > 0 then
		out[#out + 1] = string.format("%d resolved without a key", resolved)
	end
	local accidental = #(status.accepted_by_accident or {})
	if accidental > 0 then
		out[#out + 1] = string.format("%d accepted by accident", accidental)
	end
	-- desk-run writes this under proposal.deferred (an item that didn't
	-- apply cleanly at lay-in), never as a top-level field — reading
	-- status.deferred directly always read nil.
	local deferred = status.proposal and status.proposal.deferred or 0
	if deferred > 0 then
		out[#out + 1] = deferred .. " deferred"
	end
	-- "closes" (real, successful closes) never had a segment at all —
	-- only its refused/failed/lockout counterparts did, so a clean run's
	-- own closes were invisible next to its failures.
	for _, field in ipairs({ "closes", "refused_closes", "failed_closes", "lockouts" }) do
		local n = status[field]
		if n and n > 0 then
			out[#out + 1] = string.format("%d %s", n, (field:gsub("_", " ")))
		end
	end
	return out
end

--- A single-line summary, segments joined with " · ", or "" if the status
--- file is missing/empty (so a statusline component can just show nothing
--- rather than a placeholder).
function M.summary(status)
	if not status then
		return ""
	end
	local segments = {}
	for _, s in ipairs(pass_segments(status)) do
		segments[#segments + 1] = s
	end
	for _, s in ipairs(proposal_segments(status)) do
		segments[#segments + 1] = s
	end
	for _, s in ipairs(counts_segments(status)) do
		segments[#segments + 1] = s
	end
	return table.concat(segments, " · ")
end

--- Reads the status file and formats it in one call — the function a
--- statusline component actually wires in.
function M.statusline()
	return M.summary(M.read())
end

return M
