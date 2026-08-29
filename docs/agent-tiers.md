# Wiring agent config across a public and a private repo

Agent configuration — instruction files, skills, permission rules — wants to live
in version control, but not all of it can live in the *same* version control.
This repo is public. Work configuration names an employer, internal hosts and
project keys, so it is private. And a team repo checked out inside that private
tree has its own agent config, read by teammates who have neither of the other
two. This is the pattern for wiring the three together: what belongs where, what
the discovery rules force, and what breaks.

For the two-account isolation (`CLAUDE_CONFIG_DIR` / `GH_CONFIG_DIR`), see the
AI agents section of `README.md` — that is a separate concern from tiering.

## Three tiers, and why the middle one exists

| Tier | Repo | Visible where | Holds |
|---|---|---|---|
| Personal | this one, public | everywhere | the generic craft — how work runs, how to review, how to drive a browser |
| Bridging | a private work repo, above the team checkouts | its instruction file everywhere below it; its skills only at its own level | this machine's wiring, what this account may do, the seams between the other two |
| Team | a repo cloned inside the bridging one | only with cwd inside that checkout | everything about the product — its lifecycle, its gates, its tooling |

The middle tier is not organisational tidiness, it is forced. A public repo
cannot reference a private one: the reference itself leaks the name, and it is
dead weight on any machine that lacks the private repo. A private repo should not
be *depended on* by a public one for the same reason from the other side. And the
team repo can assume neither, since it is read by people with no access to
either. So anything that spans two tiers has nowhere to live but a third home
that knows about both — and only the bridging tier does.

The rule that falls out: **generic mechanism public, specific content private.**
The public tier describes a shape; the private tier fills it with names, paths
and hosts.

Its corollary is a pruning rule. The bridging tier earns only what neither
neighbour can hold — machine wiring, account privileges, divergences between the
two. Anything there that merely restates the team repo is duplication, and worse
than untidy: the bridging repo's instruction file is a parent of every team
checkout, so a stale copy auto-loads *ahead* of the team repo's own guidance.

## The discovery asymmetry

The two kinds of config are found by different rules, and the difference drives
the whole design.

- **Instruction files walk the whole tree.** `CLAUDE.md` loads from cwd and
  *every* directory above it, with no repository boundary, plus the user-level
  one. A bridging-tier instruction file therefore reaches every session below it
  for free.
- **Skills stop at the repository root.** Project skills load from
  `.claude/skills/` in cwd and its parents only *up to the enclosing
  repository's root*, plus user level. A nested checkout is a wall.

Three consequences:

**A bridging-tier skill is invisible where the work happens.** With cwd inside a
team checkout (or one of its worktrees), the upward walk stops at that checkout's
root and never reaches the bridging repo's `.claude/skills/` — while its
`CLAUDE.md`, one directory further up, loads fine. The fix is to force-link it
up: the private installer symlinks each skill directory into
`~/.claude/skills/<name>` and `~/.agents/skills/<name>`. Those links are the
*only* reason such a skill is discoverable, they are invisible in both repos, and
a stale one fails silently — so re-run the private installer after adding,
renaming or moving any skill, and treat "the skill didn't load" as a missing link
before anything else.

**The skill namespace is flat, so two tiers can collide.** User-level and
repo-level skills share one name space; give a team-repo skill a name the
personal tier already uses and the two land on one path, with one silently
clobbering the other. Prevent it by construction rather than by discipline: name
team-tier copies for their subject rather than their vendor, or prefix them, so a
collision cannot arise.

**Where two tiers disagree, the repo wins on repo matters.** A personal skill and
a team-repo skill often cover the same ground — the personal one complete because
it is used on personal projects too, the repo one trimmed so a teammate with no
personal config can work. When they conflict about that repo's history, gates or
conventions, the repo's copy is authoritative and the personal one is only a
delta. Record the divergence in the repo file, deliberately, beside the rule it
contradicts. Otherwise it gets silently resolved by whichever guidance happened
to load last, differently each session.

## The local-hook inversion

Some config cannot move into the private repo at all, because a tool reads it at
a fixed path in `~`: a shell rc, a git config. The naive fix is for the public
file to name the private path and source it. Don't — that is exactly the
reference the public tier may not carry.

Invert it. The public file offers a **generic, untracked hook that no-ops when
absent**, and the private installer symlinks its own file into that path. The
public repo describes a slot; only the private side knows what fills it, and a
machine with no private repo is unaffected. This repo provides two:

| Hook | Offered by | Placement, and why |
|---|---|---|
| `~/.shellrc.early` | `.shellrc` sources it if present | *above* the version-manager block, because it may export the variable that block reads on activation |
| `~/.gitconfig.local` | `.gitconfig` includes it | just after `[user]`, so it can override the identity or add conditional includes |

`~/.shellrc.local`, sourced at the end of `.shellrc`, is the late, general-purpose
equivalent for anything with no ordering constraint.

Ordering is a real constraint, not a nicety, and it fails asymmetrically: a hook
sourced too late still sets the variable, so a nested shell that inherited it
stays quiet while a fresh login shell errors. Put the hook where the earliest
consumer can see it.

Two guards make the arrangement safe to re-run: both hooks are conditional on the
file existing, and the `link` helper in each installer refuses to overwrite a
path that exists and is not already a symlink.

## Gotchas that cost real time

**A user-level `AGENTS.md` is not discovered.** At user level Claude Code reads
`CLAUDE.md`; no setting redirects it to a vendor-neutral name. To keep one source
file with a neutral name, make the discovered path a symlink to it —
`~/.claude/CLAUDE.md` → the tracked `AGENTS.md` — which is what this repo's
installer does, for both account config dirs. One documented exception to be
aware of: in Cowork sessions on the desktop app, a `~/.claude/CLAUDE.md` that is
itself a symlink or hard link is skipped, as is any import in a user-scope file
resolving outside the session's working directory. So neither the symlink nor the
`@AGENTS.md` import route survives there, and a Cowork session runs without the
personal tier. Interactive and headless CLI sessions load it normally.

**Renaming the file behind an `includeIf` silently changes your commit author.**
Git ignores a missing include path — no warning, exit 0 — so between renaming the
included identity file and updating the path that names it, the include
evaporates and commits fall back to the outer `[user]`, landing under the wrong
identity. Check `git log --format='%an %ae'` after any such rename, and repair
with `git commit --amend --reset-author` (or a rebase with `--reset-author` over
the affected range).

**A permission rule is a convenience, not a security boundary.** Rules match the
whole command string with globs, so a rule that pins a host —
`Bash(curl * "https://api.example.com/…")` — cannot also say *and no other host
appears in this command*: the wildcard in the middle swallows one. Narrow rules
still earn their place — they cut prompts without widening much — but don't reason
about them as if they constrained the command.

**Two writers in one checkout corrupt each other.** A pre-commit framework
stashes the whole *unstaged* tree, runs the hooks, and restores; interrupt that
cycle and a concurrent writer's in-flight edits revert to HEAD mid-edit, which
reads as an agent undoing its own work rather than as a collision. File-disjoint
work is not enough, and serialising commits does not fix it. One writer per
checkout — give each its own worktree.

## Diagnosing a break

| Symptom | First thing to check |
|---|---|
| A skill isn't listed where it used to be | the user-level symlink for it — re-run the private installer |
| Two skills' guidance blended, or one vanished | a name collision on the flat namespace |
| Wrong commit author | `git config --show-origin user.email`; then whether the `includeIf` path still resolves |
| Work env missing in a fresh shell | whether the `~/.shellrc.early` symlink exists, and whether it is sourced early enough |
| Stale guidance overriding the repo's own | the bridging tier's instruction file, which loads above every checkout |
