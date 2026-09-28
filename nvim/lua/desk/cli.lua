-- D7/D8: a `nvim -l` entry point onto the desk Lua modules (design.md §10
-- D7: "expose desk.block via nvim -l ... printing JSON"), so a non-Lua
-- caller — the private regression test (design.md's own F5), and the
-- runner (design.md §6: "the his-text and apply module ... also run by the
-- runner via nvim -l") — reaches the one implementation instead of a
-- second copy that could quietly drift from it. D8 adds the verbs the
-- runner itself needs (commit-his-text, ledger and proposal reads/writes):
-- every one of them is a thin JSON-in/JSON-out wrapper around an existing
-- module function, never new git-plumbing logic of its own.
--
-- `nvim -l` runs this file under nvim's embedded Lua without loading any
-- config or 'runtimepath', so this module's own directory is added to
-- package.path by hand before requiring anything else here.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../?/init.lua;" .. package.path

local block = require("desk.block")
local snippet = require("desk.snippet")
local git = require("desk.git")
local ledger = require("desk.ledger")
local review = require("desk.review")
local histext = require("desk.histext")
local tokens = require("desk.tokens")
local annotate = require("desk.annotate")

local function fail(msg)
	io.stderr:write("desk/cli.lua: " .. msg .. "\n")
	os.exit(1)
end

local function read_file(path)
	local fd = io.open(path, "r")
	if not fd then
		fail("could not open " .. path)
	end
	local content = fd:read("*a")
	fd:close()
	return content
end

local function print_json(v)
	io.write(vim.json.encode(v) .. "\n")
end

--- The blocks in `lines` (design.md §2's "The block rule"), in file order.
local function compute_blocks(lines)
	local blocks = {}
	local i, n = 1, #lines
	while i <= n do
		local line = lines[i]
		if line:match("^%s*$") then
			i = i + 1 -- blank: not a block
		elseif line:match("^%S") and line:match("[%a%d]") then
			-- column-0, has alnum: a real block start (a "———"-style
			-- separator is column-0 but has none, so it falls to the else
			-- branch below and is skipped rather than started).
			local e = block.block_end(lines, i)
			blocks[#blocks + 1] = { start = i, ["end"] = e }
			i = e + 1
		else
			i = i + 1 -- a separator, or (shouldn't normally happen at top
			-- level) an indented line with no block open yet
		end
	end
	return blocks
end

local args = arg or {}
local verb = args[1]

if verb == "blocks" then
	local path = args[2]
	if not path then
		fail("usage: nvim -l nvim/lua/desk/cli.lua blocks <file>")
	end
	local lines = snippet.split_lines(read_file(path))
	print_json(compute_blocks(lines))
	os.exit(0)
elseif verb == "commit-his-text" then
	-- Usage: commit-his-text <repo> <file> [<file>...]
	-- Index-only: writes each file's his-text (design.md §2) into the git
	-- index via desk.histext, never the working file. Prints, per file,
	-- {file, sha, changed, results} or {file, error}; a caller (the
	-- runner) decides from `changed` whether a `git commit` is warranted,
	-- and does that commit itself — this verb never commits.
	--
	-- Also writes the pending-set snapshot (§9(g)) for each file: the ids
	-- this run derived as "pending", against the repo's HEAD sha as of
	-- this call (the commit this verb's caller may make next hasn't
	-- happened yet, but no pending item's state changes because of it —
	-- commit-his-text only ever reverts pending content in the index/
	-- worktree to match head, never the reverse). A later `ledger-classify`
	-- call reads this snapshot back to tell "resolved through the review
	-- key" apart from "resolved some other way" between this run and that
	-- one.
	local repo = args[2]
	if not repo or not args[3] then
		fail("usage: nvim -l nvim/lua/desk/cli.lua commit-his-text <repo> <file> [<file>...]")
	end
	local head_sha_ok, head_sha_out = git.run(repo, { "rev-parse", "--verify", "--quiet", "HEAD" })
	local head_sha = head_sha_ok and vim.trim(head_sha_out) or ""
	local out = {}
	for i = 3, #args do
		local file = args[i]
		local head = review.head_lines(repo, file)
		local pending_ids = {}
		local sha, results, err = histext.write_to_index(repo, file, function()
			local index_lines = snippet.split_lines(git.index_content(repo, file) or "")
			local worktree_lines = snippet.split_lines(read_file(repo .. "/" .. file))
			local states, items = ledger.derive_all(repo, head, index_lines, worktree_lines)
			local pending_items = {}
			pending_ids = {}
			for id, item in pairs(items) do
				if states[id] == "pending" then
					table.insert(pending_items, item)
					table.insert(pending_ids, id)
				end
			end
			return {
				worktree_lines = worktree_lines,
				index_lines = index_lines,
				pending_items = pending_items,
				head_lines = head,
			}
		end)
		if not sha then
			out[#out + 1] = { file = file, error = err }
		else
			local head_blob_ok, head_blob = git.run(repo, { "rev-parse", "--verify", "--quiet", "HEAD:" .. file })
			local changed = not (head_blob_ok and vim.trim(head_blob) == sha)
			ledger.write_pending_snapshot(ledger.pending_snapshot_path(repo, file), head_sha, pending_ids)
			out[#out + 1] = { file = file, sha = sha, changed = changed, results = results }
		end
	end
	print_json(out)
	os.exit(0)
elseif verb == "ledger-derive" then
	-- Usage: ledger-derive <repo> <file>
	-- Every item's derived state for `file` (design.md §2's queued/pending/
	-- accepted/declined/postponed, via desk.ledger.derive_all) against its
	-- current HEAD/index/worktree content. This is how the runner tells a
	-- genuinely postponed item ("not now"'d after being laid in) apart from
	-- one merely still queued (never laid in) or already resolved — the one
	-- state desk.ledger.state_summary alone can't answer, since that needs
	-- each item's own anchor resolved against real file content, not just
	-- the ledger's own records. Prints {states: {id: state}, items: {id:
	-- item}}.
	local repo, file = args[2], args[3]
	if not repo or not file then
		fail("usage: nvim -l nvim/lua/desk/cli.lua ledger-derive <repo> <file>")
	end
	local head = review.head_lines(repo, file)
	local index_lines = snippet.split_lines(git.index_content(repo, file) or "")
	local worktree_lines = snippet.split_lines(read_file(repo .. "/" .. file))
	local states, items = ledger.derive_all(repo, head, index_lines, worktree_lines)
	print_json({ states = states, items = items })
	os.exit(0)
elseif verb == "ledger-classify" then
	-- Usage: ledger-classify <repo> <file>
	-- The runner's his-text-derived status fields (design.md §9(f)),
	-- read-only against whatever the ledger/index/worktree already hold —
	-- never mutates anything, so calling it repeatedly (or not at all)
	-- never changes the outcome of a later commit-his-text.
	--
	-- accepted_by_accident / resolved_without_key: compares the pending-
	-- set snapshot (§9(g)) written by the last commit-his-text run against
	-- freshly derived states (desk.ledger.classify_transitions) — an item
	-- pending back then that's since become accepted/declined with no
	-- matching key record went through some route other than the review
	-- keys (a `git add -A`, a manual edit that happened to erase it). No
	-- snapshot yet (never run) means an empty "prev pending" set, never
	-- an error.
	--
	-- waiting_edits: every currently-pending item whose content doesn't
	-- resolve cleanly against the index right now (desk.histext.compute's
	-- own "waiting_edit" — design.md §2's "an edit of his that waits on
	-- the suggestion beside it") — independent of the snapshot, since
	-- it's about right now, not a transition.
	--
	-- Prints {accepted_by_accident, resolved_without_key, waiting_edits},
	-- each an array of item ids.
	local repo, file = args[2], args[3]
	if not repo or not file then
		fail("usage: nvim -l nvim/lua/desk/cli.lua ledger-classify <repo> <file>")
	end
	local head = review.head_lines(repo, file)
	local index_lines = snippet.split_lines(git.index_content(repo, file) or "")
	local worktree_lines = snippet.split_lines(read_file(repo .. "/" .. file))
	local states, items, last_key = ledger.derive_all(repo, head, index_lines, worktree_lines)

	local snap = ledger.read_pending_snapshot(ledger.pending_snapshot_path(repo, file))
	local prev_pending_ids = (snap and snap.items) or {}
	local accepted_by_accident, resolved_without_key = ledger.classify_transitions(prev_pending_ids, states, last_key)

	local pending_items = {}
	for id, item in pairs(items) do
		if states[id] == "pending" then
			table.insert(pending_items, item)
		end
	end
	local _, histext_results = histext.compute(worktree_lines, index_lines, pending_items, head)
	local waiting_edits = {}
	for id, result in pairs(histext_results) do
		if result == "waiting_edit" then
			table.insert(waiting_edits, id)
		end
	end

	print_json({
		accepted_by_accident = accepted_by_accident,
		resolved_without_key = resolved_without_key,
		waiting_edits = waiting_edits,
	})
	os.exit(0)
elseif verb == "ledger-state" then
	-- Usage: ledger-state <repo>
	-- The runner's dedup/postponed-re-add input (design.md §2): every item
	-- record, which ids have ever been laid in, and each id's latest `key`
	-- record.
	local repo = args[2]
	if not repo then
		fail("usage: nvim -l nvim/lua/desk/cli.lua ledger-state <repo>")
	end
	print_json(ledger.state_summary(repo))
	os.exit(0)
elseif verb == "ledger-append-batch" then
	-- Usage: ledger-append-batch <repo> <ndjson-file>
	-- Appends every record in the NDJSON file to refs/desk/ledger under one
	-- compare-and-swap (design.md §2 "one compare-and-swap-with-retry
	-- helper"), so a pass's own new items and re-added postponed ones land
	-- together, never half-written. Prints {sha} or {error}.
	local repo, path = args[2], args[3]
	if not repo or not path then
		fail("usage: nvim -l nvim/lua/desk/cli.lua ledger-append-batch <repo> <ndjson-file>")
	end
	local records = {}
	for line in read_file(path):gmatch("[^\n]+") do
		local ok, rec = pcall(vim.json.decode, line)
		if not ok or type(rec) ~= "table" then
			fail("invalid JSON line in " .. path .. ": " .. line)
		end
		records[#records + 1] = rec
	end
	local sha, err = ledger.append_many(repo, records)
	if not sha then
		print_json({ error = err })
		os.exit(1)
	end
	print_json({ sha = sha })
	os.exit(0)
elseif verb == "proposal-read" then
	-- Usage: proposal-read <repo>
	local repo = args[2]
	if not repo then
		fail("usage: nvim -l nvim/lua/desk/cli.lua proposal-read <repo>")
	end
	print_json({ items = review.read_proposal(repo) })
	os.exit(0)
elseif verb == "proposal-write" then
	-- Usage: proposal-write <repo> <items-json-file>
	-- <items-json-file> holds {"items": [...]} (the pinned shape, design.md
	-- §9(e)). Prints {sha} or {error}.
	local repo, path = args[2], args[3]
	if not repo or not path then
		fail("usage: nvim -l nvim/lua/desk/cli.lua proposal-write <repo> <items-json-file>")
	end
	local ok, parsed = pcall(vim.json.decode, read_file(path))
	if not ok or type(parsed) ~= "table" then
		fail("invalid JSON in " .. path)
	end
	local sha, err = review.write_proposal(repo, parsed.items or {})
	if not sha then
		print_json({ error = err })
		os.exit(1)
	end
	print_json({ sha = sha })
	os.exit(0)
elseif verb == "notes-diff" then
	-- Usage: notes-diff <repo> <file> <since>
	-- The weekly tab's own notes-diff input (design's weekly/README.md):
	-- his own additions/removals in `file` between `since` (any commit-
	-- ish) and HEAD, with every line the ledger says is agent-originated
	-- excluded on its own side — never a second heuristic, and the two
	-- sides are excluded two different ways on purpose:
	--
	-- Additions: an item's own `after`, whenever desk.ledger.derive_all
	-- (the same per-position state machine the review key and the daily
	-- marked-head-copy already use) calls it "accepted" *or* "pending".
	-- "pending" is included deliberately, not defensively: an accepted
	-- edit/remove/move's own anchor quotes its `before`'s first line,
	-- text that the very next `commit_his_text` erases from HEAD — so a
	-- read any time after that (this one, run a weekly's worth of commits
	-- later) can no longer resolve that anchor and mis-derives "pending"
	-- (derive_all's own "can't resolve; conservatively still needs
	-- review" fallback) for an item that was actually accepted long ago.
	-- `after` is agent text either way, so both states exclude it; a
	-- truly still-pending item's `after` never reaches a commit in the
	-- first place (his committed text always reverts pending items), so
	-- including "pending" here never wrongly excludes something of his.
	--
	-- Removals: never derive_all's own per-item state — a stale anchor is
	-- exactly the case that matters most here, and the one derive_all can
	-- no longer place at all (same reasoning as above, but "removed"
	-- has no "pending" to fall back on: the removal already happened).
	-- Instead, an item's own `before` is excluded whenever the ledger's
	-- own `key` records say its last key was an accept — position-
	-- independent, since it never re-resolves an anchor at all. The
	-- "removed-line hashes": a plain content lookup built once from the
	-- ledger's own records, not re-derived from wherever the line used to
	-- sit.
	local repo, file, since = args[2], args[3], args[4]
	if not repo or not file or not since then
		fail("usage: nvim -l nvim/lua/desk/cli.lua notes-diff <repo> <file> <since>")
	end

	-- `^{tree}` rather than `^{commit}`: a real commit-ish peels to its own
	-- tree same as ever, but this also accepts a bare tree object directly
	-- — the well-known empty-tree sha (desk_write_notes_diff's own fallback
	-- for "no commit before the window start") isn't itself a commit and
	-- would otherwise fail this check even though `git diff` handles a
	-- tree-ish on either side just fine.
	local since_ok = git.run(repo, { "rev-parse", "--verify", "--quiet", since .. "^{tree}" })
	if not since_ok then
		print_json({ error = "since does not resolve to a commit or tree: " .. tostring(since) })
		os.exit(1)
	end

	local function read_worktree_or_empty(path)
		local fd = io.open(path, "r")
		if not fd then
			return ""
		end
		local content = fd:read("*a")
		fd:close()
		return content
	end

	local head_lines = review.head_lines(repo, file)
	local index_lines = snippet.split_lines(git.index_content(repo, file) or "")
	local worktree_lines = snippet.split_lines(read_worktree_or_empty(repo .. "/" .. file))
	local states, items, last_key = ledger.derive_all(repo, head_lines, index_lines, worktree_lines)

	local exclude_add, exclude_remove = {}, {}
	for id, item in pairs(items) do
		if item.file == file then
			local state = states[id]
			if item.after and item.after ~= "" and (state == "accepted" or state == "pending") then
				for _, l in ipairs(snippet.split_lines(item.after)) do
					exclude_add[l] = true
				end
			end
			local key = last_key[id]
			if item.before and item.before ~= "" and key and key.action == "accept" then
				for _, l in ipairs(snippet.split_lines(item.before)) do
					exclude_remove[l] = true
				end
			end
		end
	end

	local diff_ok, diff_out = git.run(repo, { "diff", "--no-color", "--unified=0", since, "HEAD", "--", file })
	if not diff_ok then
		print_json({ error = "git diff failed" })
		os.exit(1)
	end

	local additions, removals = {}, {}
	for _, line in ipairs(snippet.split_lines(diff_out)) do
		local head3 = line:sub(1, 3)
		if head3 == "+++" or head3 == "---" then
			-- a file header, not a content line
		elseif line:sub(1, 1) == "+" then
			local content = line:sub(2)
			if not exclude_add[content] then
				table.insert(additions, content)
			end
		elseif line:sub(1, 1) == "-" then
			local content = line:sub(2)
			if not exclude_remove[content] then
				table.insert(removals, content)
			end
		end
		-- "@@" hunk headers, "diff --git"/"index ..." headers, and (with
		-- --unified=0, rare) "\ No newline..." markers all fall through
		-- here unmatched, silently skipped.
	end

	print_json({ additions = additions, removals = removals })
	os.exit(0)
elseif verb == "namespace-ids" then
	-- Usage: namespace-ids <repo> <pass> <scheduled-date> <items-json-file>
	-- The runner's own staging step (desk.ledger.namespace_ids): rewrites
	-- each item's own (model-assigned) `id` into one unique across the
	-- whole ledger before it's ever appended, so the model's own promise
	-- of uniqueness (good only within one reply) never becomes the
	-- ledger's key space. <items-json-file> holds {"items": [...]}, each
	-- with its own `id`. Prints {"items": [...]}, same order, every `id`
	-- rewritten to `<pass>-<scheduled date>-<seq>-<model id>`.
	local repo, pass, scheduled_date, path = args[2], args[3], args[4], args[5]
	if not repo or not pass or not scheduled_date or not path then
		fail("usage: nvim -l nvim/lua/desk/cli.lua namespace-ids <repo> <pass> <scheduled-date> <items-json-file>")
	end
	local ok, parsed = pcall(vim.json.decode, read_file(path))
	if not ok or type(parsed) ~= "table" then
		fail("invalid JSON in " .. path)
	end
	print_json({ items = ledger.namespace_ids(repo, pass, scheduled_date, parsed.items or {}) })
	os.exit(0)
elseif verb == "tokens" then
	-- Usage: tokens <file>
	-- Every token in `file` that $DESK_CONFIG's own tokens list classifies
	-- as a session or url handler (desk.tokens, via desk.annotate's own
	-- per-line tokenizer) — the same classification the hotkey and the
	-- annotations use, never a second implementation. For the private
	-- regression test to call. Prints, in file order:
	-- [{"line": N, "token": "...", "handler": "session"|"url", "url":
	-- "..."}], `url` present only for a url-handler token. An absent or
	-- invalid $DESK_CONFIG just means nothing classifies, same as
	-- desk.tokens.load()'s own contract — never an error here.
	local path = args[2]
	if not path then
		fail("usage: nvim -l nvim/lua/desk/cli.lua tokens <file>")
	end
	local lines = snippet.split_lines(read_file(path))
	local config = select(1, tokens.load())
	local tokens_config = tokens.tokens_from(config)
	local out = {}
	for i, line in ipairs(lines) do
		for _, t in ipairs(annotate.tokens_in_line(line)) do
			local classification = tokens.classify(t.text, tokens_config)
			if classification.kind == "session" or classification.kind == "url" then
				local entry = { line = i, token = t.text, handler = classification.kind }
				if classification.kind == "url" then
					entry.url = classification.url
				end
				out[#out + 1] = entry
			end
		end
	end
	print_json(out)
	os.exit(0)
else
	fail("unknown verb: "
		.. tostring(verb)
		.. " (expected: blocks, commit-his-text, ledger-derive, ledger-classify, ledger-state,"
		.. " ledger-append-batch, proposal-read, proposal-write, notes-diff, namespace-ids, tokens)")
end
