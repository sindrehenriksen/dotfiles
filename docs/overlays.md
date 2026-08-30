# Overlaying a more specific setup on this repo

Configuration wants to live in version control, but not all of it can live in
the *same* version control. This repo is the generic base: personal, public,
carried to every machine. Layered over it are more specific setups — a machine,
an employer, a team — each with its own repo, its own agent config, and readers
who have none of this one. This is the pattern for composing them: what belongs
where, what the discovery rules force, which slots this repo leaves open, and
what breaks.

For the two-account isolation (`CLAUDE_CONFIG_DIR` / `GH_CONFIG_DIR`), see the
AI agents section of `README.md` — that is a separate concern from tiering.

## Three tiers, and why the middle one exists

| Tier | Repo | Visible where | Holds |
|---|---|---|---|
| Personal | this one, public | everywhere | the generic craft — how work runs, how to review, how to drive a browser |
| Bridging | a private work repo, above the team checkouts | its instruction file everywhere below it; its skills only at its own level | this machine's wiring, what this account may do, the seams between the other two |
| Team | a repo cloned inside the bridging one | only with cwd inside that checkout | everything about the product — its lifecycle, its gates, its tooling |

The middle tier is not organisational tidiness, it is forced. Nothing shared may
depend on one person's personal configuration, and that is what this tier is —
personal preference, personal setup — so a team repo reaching into it would be
inheriting one individual's choices. References therefore run one way only: the
specific setup reaches into the generic slots the base offers, never outward. So
anything that spans two tiers has nowhere to live but a third home that knows
about both — and only the bridging tier does.

The rule that falls out: **generic mechanism public, specific content private.**
The public tier describes a shape; the private tier fills it with names, paths
and hosts.

Its corollary is a pruning rule. The bridging tier earns only what neither
neighbour can hold — machine wiring, account privileges, divergences between the
two. Anything there that merely restates the team repo is duplication, and worse
than untidy: the bridging repo's instruction file is a parent of every team
checkout, so a stale copy auto-loads *ahead* of the team repo's own guidance.

The same test routes a lesson at the moment it is learned, which is the only
moment it is cheap: send it to the widest tier it holds for — the team repo if it
is about that product, the bridge if it is about this machine or the seams
between tiers, here if it would be just as true at a different employer with
different repos. Once it is up, what stays below is a pointer by name at most.
The upward half is the half that gets skipped, because writing it where the work
happened is always the shorter path.

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

Four consequences:

**A bridging-tier skill is invisible where the work happens.** With cwd inside a
team checkout (or one of its worktrees), the upward walk stops at that checkout's
root and never reaches the bridging repo's `.claude/skills/` — while its
`CLAUDE.md`, one directory further up, loads fine. The fix is to force-link it
up: the private installer symlinks each skill directory into the skills
directory of the *account it belongs to* — `~/.claude/skills/<name>` for a
personal overlay, `~/.claude-work/skills/<name>` for a work one — which is the
path the agent actually reads. It does not also link into the vendor-neutral
`~/.agents/skills/<name>`: nothing reads that today, and it has no account
separation, so a link there would show an overlay's skills to every account at
once. That is deferred until a vendor-neutral agent is actually in use, whose
own convention then decides where it goes.
That link is the *only* reason such a skill is discoverable, it is invisible in
both repos, and a stale one fails silently: a dangling entry raises nothing, the
skill is simply absent — so re-run the private installer after adding,
renaming or moving any skill, and treat "the skill didn't load" as a missing link
before anything else.

The reverse direction has no link to fix it. With cwd at the bridging root, a
team repo's own skills are equally undiscovered, and force-linking those up is
not the answer: several team repos legitimately define the same skill name,
which is the collision below. Nor can an undiscovered skill be invoked by name —
it is absent from the session's skill list, so the call errors rather than
loading it. Read its `SKILL.md` as a file, or start the session inside the repo.

**The skill namespace is flat, so two tiers can collide.** User-level and
repo-level skills share one name space; give a team-repo skill a name the
personal tier already uses and the two land on one path, with one silently
clobbering the other. Prevent it by construction rather than by discipline: name
team-tier copies for their subject rather than their vendor, or prefix them, so a
collision cannot arise. The sharpest case is a skill meant to *extend* the tier
above it: a same-named skill at the narrower scope replaces the wider one instead
of composing with it, so a layer over a personal skill has to be named something
else or it silently hides the half it was adding to.

**Each account needs its own skills directory**, which is where the two-account
isolation stops being a separate concern. Given a second config dir, the tempting
wiring is one symlink from its `skills` to the first account's: one directory,
both accounts, nothing to maintain. What it does is promote every tier's skills
to every account — an overlay repo links into what is correctly its own account's
directory and lands in the other one too, so private guidance is offered in
sessions that must never see it. Nothing fails; the skills simply appear where
they should not. Link each generic skill individually into each account instead.
The cost is a loop, and it is what lets a second overlay repo be added without
auditing where its skills surfaced. Settings compose where skills do not: the
extra-settings file is appended to this repo's (see the `autoMode` block below),
while a skills directory is not merged at all.

**Where two tiers disagree, the repo wins on repo matters.** A personal skill and
a team-repo skill often cover the same ground — the personal one complete because
it is used on personal projects too, the repo one trimmed so a teammate with no
personal config can work. When they conflict about that repo's history, gates or
conventions, the repo's copy is authoritative and the personal one is only a
delta. Record the divergence in the repo file, deliberately, beside the rule it
contradicts. Otherwise it gets silently resolved by whichever guidance happened
to load last, differently each session.

## The local-hook inversion

Some config cannot move into the specific repo at all, because a tool reads it at
a fixed path in `~`: a shell rc, a git config. The naive fix is for the tracked
file here to name the other repo's path and source it. Don't — that is the
reference running the wrong way.

Invert it. This repo offers a **generic, untracked slot that no-ops when
absent**, and the specific side's installer symlinks its own file into that path.
The base describes the slot; only the overlay knows what fills it, and a machine
with no overlay is unaffected. The full set:

| Slot | Consumed by | Placement, and why |
|---|---|---|
| `~/.shellrc.early` | `.shellrc` sources it if present | *above* the version-manager block, because it may export the variable that block reads on activation |
| `~/.secrets.env` | `.shellrc`, last line of all | exported credentials, `chmod 600` — template in `secrets/` |
| `~/.gitconfig.local` | `.gitconfig` includes it | just after `[user]`, so it can override the identity or add conditional includes |
| `~/.claude/settings.local.json` | the agent, per config dir | what is true of this machine only — resolved temp paths, extra permission rules; wins over the tracked `settings.json` beside it, but see the `autoMode` exception below |
| `CLAUDE_PERSONAL_SETTINGS`, `CLAUDE_WORK_SETTINGS` | `.shellrc`'s `claude` wrapper, per account | exported from `~/.shellrc.early`; names a whole extra settings file, passed as `--settings`. The one slot that is a variable rather than a path, because there is no fixed location the agent reads it from |

**The `autoMode` block does not follow the rest of the settings.** It is read
only from the config dir's own `settings.json`, a `--settings` file, and
admin-managed settings; in project and local settings it is parsed, ignored, and
warned about — deliberately, since a checked-out repo could otherwise hand itself
classifier rules. So the machine-local slot above cannot carry an overlay's
`autoMode`, and the extra-settings variable exists for it. Entries there are
*appended* to this repo's — `allow`, `soft_deny`, `hard_deny` and `environment`
all concatenate across the three permitted scopes — so an overlay states only its
own facts and never restates the shared half. That makes the split clean: the
generic environment description lives here, and each overlay adds the names,
hosts and namespaces that are true only for it.

Ordering is the one real constraint. `~/.shellrc.early` runs *before* the
version-manager block because it may export what that block reads on
activation, and it fails asymmetrically when it doesn't: a hook sourced too late
still sets the variable, so a nested shell that inherited it stays quiet while a
fresh login shell errors. There is deliberately no late shell slot — one hook is
easier to reason about than two, and anything an overlay wants late it can do
from the early file. An overlay whose early file needs secrets carries its own
copy rather than waiting for `~/.secrets.env`, which is sourced last of all.

Everything else is placed by the overlay's installer, not written by hand:
`~/.shellrc.early`, `~/.gitconfig.local` and the second account's
`settings.local.json` are all symlinks into the more specific repo, which is
what keeps them version-controlled. `~/.secrets.env` is the exception and
belongs to no repo. (`~/.claude/keybindings.json` is untracked too but is not a
slot — this repo's installer only mirrors whatever is there into the second
account's config dir.)

Two guards make the arrangement safe to re-run: every shell and git slot is
conditional on the file existing, and the `link` helper in each installer refuses
to overwrite a path that exists and is not already a symlink.

## Diagnosing a break

| Symptom | First thing to check |
|---|---|
| A skill isn't listed where it used to be | the user-level symlink for it — re-run the private installer |
| Two skills' guidance blended, or one vanished | a name collision on the flat namespace |
| Wrong commit author | `git config --show-origin user.email`; then whether the `includeIf` path still resolves |
| Work env missing in a fresh shell | whether the `~/.shellrc.early` symlink exists, and whether it is sourced early enough |
| Stale guidance overriding the repo's own | the bridging tier's instruction file, which loads above every checkout |
| An overlay's `autoMode` rules having no effect | which file they are in — a `settings.local.json` or project settings is ignored for `autoMode`, and the session warns once |
