-- Git plumbing shared by the desk his-text, ledger and apply pieces. Every
-- function takes the repo directory explicitly (never a hardcoded path) so
-- the same code runs against a real notes repo, a test's throwaway one, or
-- (via `nvim -l`) the runner's. Nothing here ever touches a working file —
-- only the index and refs, per design.md §2/§9.
local M = {}

--- Runs `git -C repo_dir <args>` synchronously, optionally feeding `input`
--- to stdin. Returns ok, stdout, stderr.
function M.run(repo_dir, args, input)
	local cmd = { "git", "-C", repo_dir }
	for _, a in ipairs(args) do
		cmd[#cmd + 1] = a
	end
	local res = vim.system(cmd, { text = true, stdin = input }):wait()
	return res.code == 0, res.stdout or "", res.stderr or ""
end

--- Writes `content` as a blob (never touching the working tree or index)
--- and returns its sha, or nil, err on failure.
function M.hash_object_write(repo_dir, content)
	local ok, out, err = M.run(repo_dir, { "hash-object", "-w", "--stdin" }, content)
	if not ok then
		return nil, err
	end
	return vim.trim(out)
end

--- `git cat-file -p <sha>`'s content, or nil if the object doesn't exist.
function M.cat_file(repo_dir, sha)
	if not sha or sha == "" then
		return nil
	end
	local ok, out = M.run(repo_dir, { "cat-file", "-p", sha })
	if not ok then
		return nil
	end
	return out
end

--- The current sha a ref points at, or nil if it doesn't exist.
function M.ref_sha(repo_dir, ref)
	local ok, out = M.run(repo_dir, { "rev-parse", "--verify", "--quiet", ref })
	if not ok then
		return nil
	end
	local sha = vim.trim(out)
	return sha ~= "" and sha or nil
end

--- Compare-and-swap a ref to `new_sha`, requiring its current value to be
--- `old_sha` (or, if `old_sha` is nil, that the ref not exist yet).
function M.update_ref_cas(repo_dir, ref, new_sha, old_sha)
	local ok = M.run(repo_dir, { "update-ref", ref, new_sha, old_sha or "" })
	return ok
end

--- Retries `compute(old_sha) -> new_sha` against `ref` under compare-and-
--- swap, re-supplying whatever the ref's latest value is on each conflict.
--- `compute` must be pure in the sense of depending only on `old_sha` (or
--- content read via it) — it may be called more than once.
function M.cas_retry(repo_dir, ref, compute, max_attempts)
	max_attempts = max_attempts or 5
	for _ = 1, max_attempts do
		local old = M.ref_sha(repo_dir, ref)
		local new, err = compute(old)
		if new == nil then
			return nil, err or "compute returned nil"
		end
		if M.update_ref_cas(repo_dir, ref, new, old) then
			return new
		end
	end
	return nil, "update-ref compare-and-swap failed after retries"
end

--- The git index's current entry for `path`: { mode, sha }, or nil if the
--- path isn't in the index at all.
function M.index_entry(repo_dir, path)
	local ok, out = M.run(repo_dir, { "ls-files", "-s", "--", path })
	if not ok or vim.trim(out) == "" then
		return nil
	end
	local mode, sha = out:match("^(%d+) (%x+) %d+\t")
	if not mode then
		return nil
	end
	return { mode = mode, sha = sha }
end

--- The content the index currently holds for `path`, or nil if there is no
--- index entry for it.
function M.index_content(repo_dir, path)
	local entry = M.index_entry(repo_dir, path)
	if not entry then
		return nil
	end
	return M.cat_file(repo_dir, entry.sha)
end

--- Points the index's entry for `path` at a new blob (write-then-cacheinfo)
--- — never `git add`, which would also require the file to exist on disk.
function M.update_index_cacheinfo(repo_dir, mode, sha, path)
	return M.run(repo_dir, { "update-index", "--cacheinfo", string.format("%s,%s,%s", mode, sha, path) })
end

--- The absolute path to the repo's index file, for the "unchanged since
--- read" check below — cheaper than re-reading every tracked path's
--- content to compare.
function M.index_file_path(repo_dir)
	local ok, out = M.run(repo_dir, { "rev-parse", "--path-format=absolute", "--git-dir" })
	if not ok then
		return nil
	end
	return vim.trim(out) .. "/index"
end

--- A cheap fingerprint (mtime + size) of the index file, to detect whether
--- it moved between a read and a later write.
function M.index_fingerprint(repo_dir)
	local path = M.index_file_path(repo_dir)
	if not path then
		return nil
	end
	local stat = vim.uv.fs_stat(path)
	if not stat then
		return "absent"
	end
	return string.format("%d.%d:%d", stat.mtime.sec, stat.mtime.nsec, stat.size)
end

return M
