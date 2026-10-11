---
name: dependency-updates
description: 'Keeping a repo''s dependencies current: its open Dependabot PRs, and the versions Dependabot does not see (toolchain pins, language constraints, platform runtimes). Triage, the order to land them in, CI on Dependabot branches, paired bumps, landing majors on the new version''s own defaults, handing off what can''t land yet, keeping dependabot.yml in shape. USE FOR: "pick off the dependabot PRs", a dependency or version-update sweep, a stale toolchain pin, a Dependabot security PR or alert, setting up or changing dependabot.yml. DO NOT USE FOR: a dependency change that is part of feature work, reviewing other PRs, debugging an unrelated CI failure (ci-debugging). A repo or workspace may layer its own skill on top of this one: read both.'
allowed-tools: Bash, Read, Grep
---

# Dependency updates

Land the updates from least to most risky, one at a time, each green before the next. Dependabot's open PRs are most of the set; what it does not see is the rest (below). Present the ordered plan before landing anything: landing is a push to the default branch, often a deploy, so it waits for the user's go like any other.

## Snapshot the set

```bash
gh pr list --author "app/dependabot" --state open --json number,title,headRefName,mergeStateStatus,statusCheckRollup
gh api repos/{owner}/{repo}/dependabot/alerts --jq '.[] | select(.state=="open") | [.security_advisory.severity, .dependency.package.name, .security_vulnerability.first_patched_version.identifier] | @tsv'
```

Dependabot regroups between runs, so PR numbers aren't stable: re-derive the set each time, read each diff (`gh pr diff <n>`) for the actual bumps, and close what is superseded.

Its PRs are a starting point, not the unit of work. Split one, combine several, or make the bumps on a branch of your own whenever that lands the change better (a coupled set, a pair it can't make, a group that only fails together), then close the PRs it replaces.

## What Dependabot doesn't see

Dependabot reads the package ecosystems its config lists, and nothing else. Look for the rest, compare each against its upstream's latest release, and add what is behind to the set:

- **Toolchain pins**: mise (`.mise.toml`), `.nvmrc`, `.python-version`, `packageManager` in `package.json`, a Docker base image in a file it doesn't scan.
- **Language constraints**: `requires-python`, `engines`.
- **Platform runtimes**: a hosting project's runtime or Node version setting, a managed database's or edge runtime's version.
- **Ecosystems without an entry** in `dependabot.yml`, or a repo with no config at all: add the entry (see Config) rather than bumping them by hand each time.

They take the same order as the PRs, a toolchain or runtime major with the other majors. A pin repeated across repos meant to share a toolchain moves in all of them together, in one sweep.

## Order

1. **Security updates first.** They come in their own group (see Config), so the group name in the branch and title picks them out.
2. **No runtime impact:** CI and Actions pins, test-only and dev tooling.
3. **Minor/patch groups**, the least critical surface first.
4. **Library majors, one at a time:** usage grep, changelog, the covering tests.
5. **Runtime, framework, language or base-image majors last** (below).

## Majors

Majors are part of the sweep, not a separate project: land them with the code adapted to the new version, and hand off only what can't land yet (below). They are often most of the work, so give them to subagents or a team where that helps.

**Adopt the new version.** An upgrade takes the new version as it is meant to be used: its new defaults, its recommended config, its idioms. Adapt the code to them, and don't add compatibility shims that keep the old behaviour, such as an old palette re-declared under the new major, or an old spacing or hover rule restored. A changed default usually is the release's reason for existing, and a pin-back is an unowned fork of the old version that every later upgrade has to step around. Stray only for a concrete reason the code can show, such as a test or a platform constraint, written beside the deviation as for an `ignore`.

**Verify in proportion to the change.** The local gates are the floor. A language, runtime or framework major (a new Python or Node major, the UI framework) is also tried where it ships: the platform supports the version, and a preview deploy or the deployed path is exercised. That verifying is the sweep's own work, done before anything waits on the user.

**What the user sees or feels may change**, and that is not a reason to hold the upgrade back. Show it: before/after screenshots at the product's own viewport, and a line per visible change in the report. How much also waits for the user's own look follows who uses the product. A tool only the user runs takes a visible change with that report. A product with end users goes by its stage (testing, pilot, beta, live): the further along, the more verifying a change gets first and the more of what users would notice waits for the user's yes. A big change in look or feel (a redesign the version invites, an interaction that works differently) is suggested with its before/after whatever the stage, neither pinned back silently nor landed unannounced. The repo's own docs say who uses it and which stage it is in; where they don't, ask once and write the answer there.

## CI on a Dependabot branch

- Runs triggered by Dependabot get **no repo secrets**, so a secret-dependent job fails as an artifact rather than a real red: check that the underlying tests passed. Once you push a commit to the branch, the next run is attributed to you and gets secrets.
- The common real failures are mechanical: a lockfile the bump left out of sync, a formatter whose new version reformats files. Fix them on the branch.
- **Paired bumps.** Some versions must move together and Dependabot can only move one of them: a package and the CI image tagged to it, a runtime pinned somewhere Dependabot can't read (mise, a Dockerfile it doesn't scan) and the types or SDK that follow it. The repo's `dependabot.yml` names its pairs in comments. Carry the other half in the same change, whether that lands as a PR merge or a direct push.
- A grouped set that cannot resolve together gets split: keep what resolves, revert the entangled bumps to the base versions and hand those off. Trust CI's environment over a local resolve.

## Landing

- **Rebase onto the current base before each landing**, resolving manifest conflicts by keeping the already-landed bumps and taking this one, then regenerate the lockfile. Don't use `@dependabot rebase`: it is slow, and on a grouped PR it closes and recreates the PR, regrouping it.
- Landing one PR makes Dependabot force-update its open siblings within a minute, so re-fetch a branch before pushing to it.
- How a change lands (PR merge, direct push to the default branch) and whether that deploys is the repo's own process: follow it, and watch a deploy through before the next PR.

## What can't land yet: hand off

A major whose ecosystem doesn't admit it yet (a peer range that rules it out, a tool that can't load it), a bump only exercised at deploy time with no safe way to try it first, or one that turns into feature-sized work becomes its own piece of work:

1. Record it where the repo tracks work, after checking whether in-flight work already covers it.
2. Add an `ignore` with `update-types` (`version-update:semver-major`, or minor too for a runtime), not a version range, which only moves the noise to the next release. Ignore the whole coupled set, not just the headline package, or its siblings keep failing the group.
3. Close the PR, pointing at where the work is recorded.

## Config

The shape that works: weekly, minor and patch grouped into one PR, majors in a group of their own, a low open-PR limit, and **security updates in their own group per entry** (`applies-to: security-updates`). That group is also the only way to tell security PRs apart: `labels:` applies to every PR an entry raises, security ones included, so a label cannot mark them alone.

**Every `ignore` carries a comment** saying why it exists and what would remove it (the work item, the pin it follows, the condition). An ignore without one outlives its reason unnoticed.

GitHub only reads `.github/dependabot.yml` at the repository root. Dependabot's own jobs don't use Actions minutes, but in a private repo the CI they trigger does, rebases included.
