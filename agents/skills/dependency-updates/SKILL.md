---
name: dependency-updates
description: 'Keeping a repo''s dependencies current: its open Dependabot PRs and alerts, and the versions Dependabot does not see (toolchain pins, language constraints, platform runtimes, dev tools it cannot read). Triage, the order and batches to land them in, CI on Dependabot branches, paired bumps, splitting major groups and landing majors on the new version''s own defaults, reporting what can''t land yet, keeping dependabot.yml in shape. USE FOR: "pick off the dependabot PRs", a dependency or version-update sweep, a stale toolchain pin, a Dependabot security PR or alert, setting up or changing dependabot.yml, adding or removing an ignore. DO NOT USE FOR: a dependency change that is part of feature work, reviewing other PRs, debugging an unrelated CI failure (ci-debugging). A repo or workspace may layer its own skill on top of this one: read both.'
allowed-tools: Bash, Read, Grep
---

# Dependency updates

Land the updates from least to most risky, each green before the next. Batch whatever lands well together (Dependabot's groups as they are or combined, your own bumps alongside them, across ecosystems or projects where that suits), weighed against holding several deploy pipelines at once. Dependabot's open PRs are most of the set; what it does not see is the rest (below). Present the ordered plan before landing anything: landing is a push to the default branch, often a deploy, so it waits for the user's go like any other.

## Snapshot the set

```bash
gh pr list --author "app/dependabot" --state open --json number,title,headRefName,mergeStateStatus,statusCheckRollup
gh api --paginate 'repos/{owner}/{repo}/dependabot/alerts?state=open&per_page=100' --jq '.[] | [.security_advisory.severity, .dependency.package.name, .dependency.manifest_path, .security_vulnerability.first_patched_version.identifier] | @tsv'
gh run list --workflow "Dependabot Updates" --limit 30   # then: gh run view <id> --log
```

The alerts call needs `--paginate` and `per_page`, or it returns only the first 30. An alert with no PR is still in the set, and alerts dismissed because no patched version existed don't reopen on their own: re-check them each sweep and reopen once a fix ships. Dependabot regroups between runs, so PR numbers aren't stable: re-derive the set each time, read each diff (`gh pr diff <n>`) for the actual bumps, and close what is superseded.

**Check each group PR against its job's log.** Dependabot silently drops a dependency it can't resolve from a group PR that still opens; the log's error tables, and the Dependabot updates page under Insights → Dependency graph, name it. "Nothing to update" is a quiet week, not a failure.

Its PRs are a starting point, not the unit of work. Split one, combine several, or make the bumps on a branch of your own whenever that lands the change better (a coupled set, a pair it can't make, a group that only fails together), then close the PRs it replaces, except a split major group's, which stays open (see Majors).

## What Dependabot doesn't see

Dependabot reads the package ecosystems its config lists, and nothing else. Look for the rest, compare each against the latest its upstream releases and its platform supports, and add what is behind to the set:

- **Toolchain pins**: mise (`.mise.toml`), `.nvmrc`, `.python-version`, `packageManager` in `package.json`, a Docker base image in a file it doesn't scan, the `python-version` / `node-version` inputs in CI workflows.
- **Language constraints**: `requires-python`, `engines`, and the linter and type-checker targets that follow them.
- **Platform runtimes**: a hosting project's runtime or Node version setting, a managed database's or edge runtime's version.
- **Dev tools it can't read**: for Python it reads PEP 621 `[project]` and `[project.optional-dependencies]` and PEP 735 `[dependency-groups]`, not tool-specific environment tables (hatch envs, say). Dev and test tools belong in `[dependency-groups]`, or Dependabot never proposes them.
- **Ecosystems without an entry** in `dependabot.yml`, or a repo with no config at all: add the entry (see Config) rather than bumping them by hand each time. That includes `pre-commit`, which Dependabot supports as an ecosystem since 2026-03, updating hook revs.

They take the same order as the PRs, a toolchain or runtime major with the other majors. **One version everywhere**: a tool or runtime runs at the same version wherever it appears in the repo (one Python, say), and across repos meant to share a toolchain, unless there is a reason, written beside the divergent pin. Within one project every place moves in one change, even across its separate release pipelines; rolling out one area after another is for when it pays off, typically across separate projects.

## Order

1. **Security updates first**, in their own group (see Config). One can carry a major: the Majors rules apply inside it.
2. **No runtime impact:** CI and Actions pins, pre-commit hooks, test-only and dev tooling.
3. **Minor/patch groups**, the least critical surface first.
4. **Library majors**, split and decided per bump: usage grep, changelog, the covering tests.
5. **Runtime, framework, language or base-image majors last.**

## Majors

Majors are part of the sweep, not a separate project. **Split the major group each sweep**: land what can land, with the code adapted to the new version, and leave a heavyweight or coupled set (a language runtime, the framework the product is built on, a set that moves only with a coordinated change) open in the group PR as the visible backlog, reported to the user (below). The landable bumps go on your own branch; the Dependabot group PR stays open and untouched. Who does the work follows `team`, as for any other work.

**Adopt the new version.** Take its new defaults, recommended config and idioms, and adapt the code to them rather than adding shims that keep the old behaviour (an old palette re-declared, an old spacing or hover rule restored). A changed default is usually why the release exists, and a pin-back is an unowned fork every later upgrade has to step around. Stray only for a concrete reason the code can show, such as a test or a platform constraint, written beside the deviation.

**Verify in proportion to the change and to who uses it.** The local gates are the floor. A language, runtime or framework major (a new Python or Node major, the UI framework) is also tried where it ships: the platform supports the version, and a preview deploy or the deployed path is exercised. A product with end users gets more the further along it is (testing, pilot, beta, live). All of this comes before anything waits on the user.

**What the user sees or feels may change**, and that is not a reason to hold the upgrade back. Show it: before/after screenshots at the product's own viewport, and a line per visible change in the report. How much of it waits for the user's yes goes the same way: little for a tool only they run, more the further along a product with end users is. The repo's docs say who uses it and its stage; where they don't, ask once and write it there. A big change in look or feel (a redesign the version invites, an interaction that works differently) is suggested with its before/after whatever the stage, neither pinned back silently nor landed unannounced.

## CI on a Dependabot branch

- Runs triggered by Dependabot get **no repo secrets**, so a secret-dependent job fails as an artifact rather than a real red: check that the underlying tests passed. If a required check depends on a secret, the PR can't merge until you push a commit (the lockfile fix, or an empty one), whose run is attributed to you and gets secrets.
- The common real failures are mechanical: a lockfile the bump left out of sync, a formatter whose new version reformats files. Fix them on the branch. A formatter bump (ruff, prettier) reformats even where CI doesn't check formatting: run the formatter on the bump branch and commit the result, or the next unrelated commit picks up the reformat.
- **Pre-commit hook bumps** are usually exercised by nothing in CI: run `pre-commit run --all-files` on the branch before merging.
- **Paired bumps.** Some versions must move together and Dependabot can only move one of them: a package and the CI image tagged to it, a runtime pinned somewhere Dependabot can't read (mise, a Dockerfile it doesn't scan) and the types or SDK that follow it. The repo's `dependabot.yml` names its pairs in comments. Carry the other half in the same change, whether that lands as a PR merge or a direct push.
- A grouped set that cannot resolve together gets split: land what resolves, leave the entangled bumps in the group PR and report them (below). Trust CI's environment over a local resolve.

## Landing

- **Rebase onto the current base before each landing**, resolving manifest conflicts by keeping the already-landed bumps and taking this one, then regenerate the lockfile. Don't use `@dependabot rebase`: it is slow, and on a grouped PR it closes and recreates the PR, regrouping it.
- Landing one PR makes Dependabot force-update the open siblings you haven't pushed to within a minute, so re-fetch a branch before pushing to it.
- How a change lands (PR merge, direct push to the default branch) and whether that deploys is the repo's own process: follow it, and watch a deploy through before the next landing.

## What can't land yet: report it

An update the sweep can't land, or isn't sure it should yet (a peer range that rules it out, a tool that can't load it, a bump only exercised at deploy time with no safe way to try it first, one that turns into feature-sized work), goes to the user: what blocks it, what was tried, and what would unblock it. It stays in the open group PR as the backlog; with the user's yes, record it where the repo tracks work, after checking whether in-flight work already covers it.

**An `ignore` is only for what a sweep can't absorb**: a version Dependabot proposes that can't install, or a release that breaks silently where no check would see it. Having a tracked work item, or pairing with another bump, is no reason: those stay in the group PR. An ignore needs the user's yes and is scoped to its reason (`versions` for a release that won't install, `update-types` for a line that breaks silently, never a broad range that only moves the noise to the next release), covering the whole coupled set rather than just the headline package.

## Config

The shape that works: weekly, minor and patch grouped into one PR, majors in a group of their own, a low open-PR limit, and **security updates in their own group per entry** (`applies-to: security-updates`). That group is also the only way to tell security PRs apart: `labels:` applies to every PR an entry raises, security ones included, so a label cannot mark them alone. `reviewers` is no longer a Dependabot option (removed August 2025): code owners decide who reviews.

**Every `ignore` carries a comment** saying why it exists and what would remove it (the work item, the pin it follows, the condition). An ignore without one outlives its reason unnoticed.

GitHub only reads `.github/dependabot.yml` at the repository root. Dependabot's own jobs don't use Actions minutes, but in a private repo the CI they trigger does, rebases included.
