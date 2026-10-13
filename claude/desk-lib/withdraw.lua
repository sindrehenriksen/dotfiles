-- desk-propose --withdraw, under `nvim -l`: records the given proposal items
-- as declined in the ledger, then rebuilds the proposal without them, as a
-- decline in the review does. The items come from the caller, read by id
-- from the tip proposal.
--
-- Usage: nvim -l withdraw.lua <repo dir of this checkout> <notes repo> <pass> <date> <items-json-file> <file>...
-- Prints {sha, stats} or {error}.
local args = arg or {}
local dotfiles, repo, pass, date, path = args[1], args[2], args[3], args[4], args[5]
-- This checkout's nvim/ first, as cli.lua does, so a worktree runs its own modules.
vim.opt.rtp:prepend(dotfiles .. "/nvim")
package.path = dotfiles .. "/nvim/lua/?.lua;" .. dotfiles .. "/nvim/lua/?/init.lua;" .. package.path

local ledger = require("desk.ledger")
local proposal = require("desk.proposal")

local function out(v, code)
	io.write(vim.json.encode(v) .. "\n")
	os.exit(code)
end

local fd = io.open(path, "r")
if not fd then
	out({ error = "could not open " .. tostring(path) }, 1)
end
local ok, items = pcall(vim.json.decode, fd:read("*a"))
fd:close()
if not ok or type(items) ~= "table" then
	out({ error = "invalid items JSON" }, 1)
end
local files = {}
for i = 6, #args do
	files[#files + 1] = args[i]
end
if not ledger.record_declines(repo, items) then
	out({ error = "could not record the declines" }, 1)
end
local sha, stats = proposal.build(repo, pass, date, {}, files)
if not sha then
	out({ error = stats }, 1)
end
out({ sha = sha, stats = stats }, 0)
