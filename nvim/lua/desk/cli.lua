-- A `nvim -l` entry point onto the desk Lua modules, so the runner and
-- desk-propose reach the one implementation rather than a second copy. Every
-- verb is a thin JSON-in/JSON-out wrapper around an existing module function.
--
-- `nvim -l` loads no config, but 'runtimepath' still holds the config
-- directory, whose `lua/` nvim searches before package.path. So this
-- module's own nvim/ goes first on both, or a checkout other than the
-- installed one (a worktree) would run the installed modules.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
vim.opt.rtp:prepend(here .. "/../..")
package.path = here .. "/../?.lua;" .. here .. "/../?/init.lua;" .. package.path

local snippet = require("desk.snippet")
local git = require("desk.git")
local ledger = require("desk.ledger")
local proposal = require("desk.proposal")

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

local args = arg or {}
local verb = args[1]

if verb == "proposal-build" then
	-- Usage: proposal-build <repo> <pass> <scheduled-date> <items-json-file> <file>...
	-- The pass's one proposal commit (desk.proposal.build): the user's newest HEAD
	-- plus the previous proposal's untaken, undeclined items plus the new
	-- items in <items-json-file> ({"items": [...]}), all applied, written as
	-- the tip of refs/desk/proposal. Prints {sha, stats} or {error}.
	local repo, pass, scheduled_date, path = args[2], args[3], args[4], args[5]
	if not repo or not pass or not scheduled_date or not path or not args[6] then
		fail("usage: nvim -l nvim/lua/desk/cli.lua proposal-build <repo> <pass> <scheduled-date> <items-json-file> <file>...")
	end
	local ok, parsed = pcall(vim.json.decode, read_file(path))
	if not ok or type(parsed) ~= "table" then
		fail("invalid JSON in " .. path)
	end
	local files = {}
	for i = 6, #args do
		files[#files + 1] = args[i]
	end
	local sha, stats = proposal.build(repo, pass, scheduled_date, parsed.items or {}, files)
	if not sha then
		print_json({ error = stats })
		os.exit(1)
	end
	print_json({ sha = sha, stats = stats })
	os.exit(0)
elseif verb == "proposal-read" then
	-- Usage: proposal-read <repo>
	-- Every item of the tip proposal, taken or not.
	local repo = args[2]
	if not repo then
		fail("usage: nvim -l nvim/lua/desk/cli.lua proposal-read <repo>")
	end
	print_json({ items = proposal.read_items(repo) })
	os.exit(0)
elseif verb == "proposal-open" then
	-- Usage: proposal-open <repo>
	-- The tip proposal's items still waiting on the user: not taken, not
	-- declined, and applied (a deferred item has no hunk to take).
	local repo = args[2]
	if not repo then
		fail("usage: nvim -l nvim/lua/desk/cli.lua proposal-open <repo>")
	end
	print_json({ items = proposal.open_items(repo) })
	os.exit(0)
elseif verb == "taken-sync" then
	-- Usage: taken-sync <repo>
	-- Records, as taken, every tip-proposal item whose `after` is now in the user's
	-- HEAD (desk.proposal.sync_taken). The runner calls it after its own
	-- daily commit. Prints {recorded: [ids]}.
	local repo = args[2]
	if not repo then
		fail("usage: nvim -l nvim/lua/desk/cli.lua taken-sync <repo>")
	end
	local ids = {}
	for _, item in ipairs(proposal.sync_taken(repo)) do
		ids[#ids + 1] = item.id
	end
	print_json({ recorded = ids })
	os.exit(0)
elseif verb == "taken-lines" then
	-- Usage: taken-lines <repo> <file>
	-- The agent-originated lines of `file`: every taken item's `after`
	-- lines, for the runner's marked copy of the user's notes. Prints {lines}.
	local repo, file = args[2], args[3]
	if not repo or not file then
		fail("usage: nvim -l nvim/lua/desk/cli.lua taken-lines <repo> <file>")
	end
	local lines = {}
	for _, rec in pairs(ledger.taken_by_id(ledger.read(repo))) do
		if rec.file == file and rec.kind ~= "remove" and rec.after and rec.after ~= "" then
			for _, l in ipairs(snippet.split_lines(rec.after)) do
				lines[#lines + 1] = l
			end
		end
	end
	table.sort(lines)
	print_json({ lines = lines })
	os.exit(0)
elseif verb == "notes-diff" then
	-- Usage: notes-diff <repo> <file> <since>
	-- The weekly tab's own notes-diff input:
	-- the user's own additions/removals in `file` between `since` (any commit-
	-- ish) and HEAD, with every line the taken-provenance records call
	-- agent-originated excluded on its own side. Records any item newly in
	-- the user's HEAD as taken first, so a commit made outside the review key or
	-- the runner is still attributed.
	--
	-- Additions: every taken item's own `after` lines. Removals: every
	-- taken item's own `before` lines — a plain content lookup, so a line
	-- the user took into HEAD and later moved or replaced is still excluded.
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

	proposal.sync_taken(repo)
	local exclude_add, exclude_remove = {}, {}
	for _, rec in pairs(ledger.taken_by_id(ledger.read(repo))) do
		if rec.file == file then
			if rec.after and rec.after ~= "" then
				for _, l in ipairs(snippet.split_lines(rec.after)) do
					exclude_add[l] = true
				end
			end
			if rec.before and rec.before ~= "" then
				for _, l in ipairs(snippet.split_lines(rec.before)) do
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
	-- `---`/`+++` are file headers only before a file's first `@@`: after
	-- it a removed `---` rule reads `----`, an added `++ x` reads `+++ x`.
	local in_hunks = false
	for _, line in ipairs(snippet.split_lines(diff_out)) do
		local head3 = line:sub(1, 3)
		if line:sub(1, 2) == "@@" then
			in_hunks = true
		elseif line:sub(1, 5) == "diff " then
			in_hunks = false
		elseif not in_hunks and (head3 == "+++" or head3 == "---") then
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
else
	fail("unknown verb: "
		.. tostring(verb)
		.. " (expected: proposal-build, proposal-read, proposal-open, taken-sync, taken-lines, notes-diff)")
end
