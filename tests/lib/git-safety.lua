-- Shared safety net for the headless nvim tests that run real git commands
-- (via desk.git.run, which shells out through vim.system and inherits this
-- process's environment) against a throwaway repo. Loaded from
-- nvim/tests/minimal_init.lua, so every `nvim --headless -u minimal_init.lua`
-- test run gets it, whether or not that particular test touches git —
-- see tests/lib/git-safety.sh for the bash-test twin and the header there
-- for the incident both harden against (a build test writing into the
-- real ~/dotfiles/.git/config).
local M = {}

local TMP_DIR_PATTERNS = {
	"^/tmp/",
	"^/private/tmp/",
	"^/private/var/folders/",
	"^/var/folders/",
}

--- True if `path` sits under a recognized system temp dir (vim.fn.tempname()
--- always returns one on this machine, but this is the same check the bash
--- tests make, not an assumption about tempname()'s implementation).
function M.under_tmp_dir(path)
	local tmpdir = vim.env.TMPDIR
	if tmpdir and tmpdir ~= "" and path:sub(1, #tmpdir) == tmpdir then
		return true
	end
	for _, pat in ipairs(TMP_DIR_PATTERNS) do
		if path:match(pat) then
			return true
		end
	end
	return false
end

--- Aborts unless `repo` is under a temp dir — call this before the first
--- git command against any repo a test creates.
function M.assert_repo_under_tmp(repo)
	if not M.under_tmp_dir(repo) then
		error("refusing to run: repo is not under a temp dir: " .. tostring(repo))
	end
end

--- Isolates this process's git environment: never the real global/system
--- config, never an inherited GIT_DIR/GIT_WORK_TREE (this headless nvim can
--- itself be launched from inside a real `git commit`, same as the bash
--- tests can), and no real repo hooks. Writing to vim.env reaches any
--- subprocess vim.system spawns, which is how desk.git.run picks these up.
--- Idempotent and safe to call once per process, before any test runs.
function M.init()
	vim.env.GIT_DIR = nil
	vim.env.GIT_WORK_TREE = nil
	vim.env.GIT_INDEX_FILE = nil
	vim.env.GIT_OBJECT_DIRECTORY = nil
	vim.env.GIT_ALTERNATE_OBJECT_DIRECTORIES = nil
	vim.env.GIT_CEILING_DIRECTORIES = nil
	vim.env.GIT_PREFIX = nil

	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	local hooks_dir = root .. "/no-hooks"
	vim.fn.mkdir(hooks_dir, "p")
	local global_config = root .. "/gitconfig-global"
	local fd = assert(io.open(global_config, "w"))
	fd:write(string.format(
		"[core]\n\thookspath = %s\n[user]\n\temail = test@example.invalid\n\tname = Desk Test\n[init]\n\tdefaultBranch = main\n",
		hooks_dir
	))
	fd:close()

	vim.env.GIT_CONFIG_GLOBAL = global_config
	vim.env.GIT_CONFIG_NOSYSTEM = "1"
end

return M
