-- D7 test: the status line (desk.status) — pure formatting, plus reading a
-- from-scratch fixture status.json off disk.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-status-test.lua
local status = require("desk.status")

local pass, fail = 0, 0
local function ok(desc)
	pass = pass + 1
	print("ok   - " .. desc)
end
local function bad(desc)
	fail = fail + 1
	print("FAIL - " .. desc)
end
local function assert_eq(desc, expected, actual)
	local e, a = vim.json.encode(expected), vim.json.encode(actual)
	if e == a then
		ok(desc)
	else
		bad(string.format("%s (expected %s, got %s)", desc, e, a))
	end
end

print("=== summary: a clean, fully-ok status ===")

assert_eq("no status at all: an empty string, never an error", "", status.summary(nil))

local clean = { passes = { morning = { last_run = 1, result = "ok" } } }
assert_eq("a single ok pass", "morning: ok", status.summary(clean))

print()
print("=== summary: a failed pass names the step it stopped at ===")

local failed = { passes = { ["1630"] = { last_run = 1, result = "failed", stopped_at = "fetch" } } }
assert_eq("failed pass names its stopped_at step", "1630: failed (fetch)", status.summary(failed))

print()
print("=== summary: multiple passes are sorted, so the line is stable ===")

local multi = {
	passes = {
		weekly = { result = "ok" },
		morning = { result = "partial" },
		["1630"] = { result = "ok" },
	},
}
assert_eq("passes sort by name", "1630: ok · morning: partial · weekly: ok", status.summary(multi))

print()
print("=== summary: the proposal state and overflow ===")

local pending = { proposal = { state = "pending", queued = 1 } }
assert_eq("a pending proposal with something still unresolved", "proposal pending", status.summary(pending))

local resolved_already = { proposal = { state = "pending", queued = 0, deferred = 0 } }
assert_eq(
	"'pending' with nothing left queued or deferred: silent (every item's since been resolved by hand)",
	"",
	status.summary(resolved_already)
)

local none = { proposal = { state = "none" } }
assert_eq("state 'none' shows nothing", "", status.summary(none))

local overflow = {
	proposal = { state = "pending", queued = 1, overflow = { act = 2, worth_knowing = 0, wildcard = 1 } },
}
assert_eq(
	"nonzero overflow tiers are named, a zero one is silent",
	"proposal pending · +2 more ACT → brief · +1 more wildcard → brief",
	status.summary(overflow)
)

print()
print("=== summary: his-text counts, only when nonzero ===")

local all_zero = { waiting_edits = {}, resolved_without_key = {}, accepted_by_accident = {}, proposal = { deferred = 0 } }
assert_eq("every count at zero: nothing shown", "", status.summary(all_zero))

local counts = {
	waiting_edits = { 12 },
	resolved_without_key = { "j1", "j2" },
	accepted_by_accident = { "j3" },
	proposal = { deferred = 4 }, -- desk-run's own field: under proposal, never top-level
}
assert_eq(
	"each nonzero count gets its own segment, in his terms, deferred read from proposal.deferred",
	"1 of your edits wait on a suggestion · 2 resolved without a key · 1 accepted by accident · 4 deferred",
	status.summary(counts)
)

print()
print("=== summary: closes/refusals/lockouts, only when nonzero ===")

local ops = { closes = 3, refused_closes = 1, failed_closes = 0, lockouts = 2 }
assert_eq(
	"zero fields are silent, nonzero ones show their count, real closes included",
	"3 closes · 1 refused closes · 2 lockouts",
	status.summary(ops)
)

print()
print("=== read: a from-scratch fixture file ===")

local tmp = vim.fn.tempname()
local fd = assert(io.open(tmp, "w"))
fd:write(vim.json.encode({ passes = { morning = { result = "ok" } } }))
fd:close()
local parsed = status.read(tmp)
assert_eq("the fixture parses", "ok", parsed.passes.morning.result)
os.remove(tmp)

assert_eq("a missing file returns nil", nil, status.read("/nonexistent/desk-status-fixture.json"))

local bad_tmp = vim.fn.tempname()
local bfd = assert(io.open(bad_tmp, "w"))
bfd:write("{ not json")
bfd:close()
assert_eq("invalid JSON returns nil", nil, status.read(bad_tmp))
os.remove(bad_tmp)

print()
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
