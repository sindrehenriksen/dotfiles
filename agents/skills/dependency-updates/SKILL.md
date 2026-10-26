---
name: dependency-updates
description: 'Keeping a repo''s dependencies current: its open Dependabot PRs and alerts, and the versions Dependabot does not see (toolchain pins, language constraints, platform runtimes, dev tools it cannot read). Triage, the order and batches to land them in, checks on Dependabot branches, paired bumps, splitting major groups and landing majors on the new version''s own defaults, reporting what can''t land yet, keeping dependabot.yml in shape. USE FOR: "pick off the dependabot PRs", a dependency or version-update sweep, a stale toolchain pin, a Dependabot security PR or alert, setting up or changing dependabot.yml, adding or removing an ignore. DO NOT USE FOR: a dependency change that is part of feature work, reviewing other PRs, debugging an unrelated CI failure (ci-debugging). A repo or workspace may layer its own skill on top of this one: read both.'
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

The alerts call needs `--paginate` and `per_page`, or it returns only the first 30. **List `classification=malware` alerts first**: they outrank every severity. An alert with no PR is still in the set, and alerts dismissed because no patched version existed don't reopen on their own: re-check them each sweep and reopen once a fix ships. Dependabot regroups between runs, so PR numbers aren't stable: re-derive the set each time, read each diff (`gh pr diff <n>`) for the actual bumps, and close what is superseded.

**Check each group PR against its job's log.** Dependabot silently drops a dependency it can't resolve from a group PR that still opens; the log's error tables, and the Dependabot updates page under Insights → Dependency graph, name it. "Nothing to update" is a quiet week, not a failure.

Its PRs are a starting point, not the unit of work. Split one, combine several, or bump on a branch of your own whenever that lands the change better, then close the PRs it replaces, except a split major group's, which stays open (see Majors).

## What Dependabot doesn't see

Dependabot reads the package ecosystems its config lists, and nothing else. Look for the rest, compare each against the latest its upstream releases and its platform supports, and add what is behind to the set, aiming straight for that latest rather than each version in between:

- **Toolchain pins**: mise (`.mise.toml`), `.nvmrc`, `.python-version`, `packageManager` in `package.json`, a Docker base image in a file it doesn't scan, the `python-version` / `node-version` inputs in CI workflows.
- **Runner image**: pin `runs-on` to a specific Ubuntu image (`ubuntu-YY.04`), not `ubuntu-latest`, and move it by hand in every workflow at once, once GitHub's newer image is out of preview.
- **Language constraints**: `requires-python`, `engines`, and the linter and type-checker targets that follow them.
- **Platform runtimes**: a hosting project's runtime or Node version setting, a managed database's or edge runtime's version.
- **Dev tools it can't read**: for Python it reads PEP 621 `[project]` and `[project.optional-dependencies]` and PEP 735 `[dependency-groups]`, not tool-specific environment tables (hatch envs, say). Dev and test tools belong in `[dependency-groups]`, or Dependabot never proposes them.
- **Tools a runner fetches at launch**: `uvx pkg@1.2.3`, `npx -y pkg@1.2.3` and the like in setup scripts and MCP client configs, which no updater reads. Each stays pinned to an exact version.
- **Ecosystems without an entry** in `dependabot.yml`, or a repo with no config at all: add the entry (see Config) rather than bumping them by hand each time. That includes `pre-commit`, which Dependabot supports as an ecosystem since 2026-03, updating hook revs.

**Latest means the upstream's stable channel**, not its newest release. A release list can run ahead of it, pnpm's for one, which tags releases `next` and promotes them weeks later: for a tool published on npm, read the `latest` dist-tag (`npm view <package> dist-tags`).

They take the same order as the PRs, a toolchain or runtime major with the other majors. **One version everywhere**: a tool or runtime used in several places (repos, setup scripts, MCP client configs, CI) runs at one version in all of them (one Python, say), unless there is a reason, written beside the divergent pin. It moves everywhere in one change, one commit per repo in the same sweep, even across separate release pipelines; rolling out one area after another is for when that pays off, with the reason beside each pin still behind.

## Order

1. **Security updates first**, in their own group (see Config). One can carry a major: the Majors rules apply inside it.
2. **No runtime impact:** CI and Actions pins, pre-commit hooks, test-only and dev tooling.
3. **Minor/patch groups**, the least critical surface first.
4. **Library majors**, split and decided per bump: usage grep, changelog, the covering tests.
5. **Runtime, framework, language or base-image majors last.**

## Majors

Majors are part of the sweep, not a separate project. **Split the major group each sweep**: land what can land, with the code adapted to the new version, and leave a heavyweight or coupled set (a language runtime, the framework the product is built on, a set that moves only with a coordinated change) open in the group PR as the visible backlog, reported to the user (below). The landable bumps go on your own branch; the Dependabot group PR stays open and untouched. Who does the work follows `team`, as for any other work.

**Adopt the new version.** Take its new defaults, recommended config, tooling and idioms, adapt the code to them rather than adding shims that keep the old behaviour (an old palette re-declared, an old spacing or hover rule restored), and remove what the release makes obsolete. A changed default is usually why the release exists, and a pin-back is an unowned fork every later upgrade has to step around. Stray only for a concrete reason the code can show, such as a test or a platform constraint, written beside the deviation. A heavyweight's tracked work covers the same adoption, not just the bump.

**Verify in proportion to the change and to who uses it.** The local gates are the floor. A language, runtime or framework major (a new Python or Node major, the UI framework) is also tried where it ships: the platform supports the version, and a preview deploy or the deployed path is exercised. A product with end users gets more the further along it is (testing, pilot, beta, live). All of this comes before anything waits on the user.

**What the user sees or feels may change**, and that is not a reason to hold the upgrade back. Show it: before/after screenshots at the product's own viewport, and a line per visible change in the report. How much of it waits for the user's yes goes the same way: little for a tool only they run, more the further along a product with end users is. The repo's docs say who uses it and its stage; where they don't, ask once and write it there. A big change in look or feel (a redesign the version invites, an interaction that works differently) is suggested with its before/after whatever the stage, neither pinned back silently nor landed unannounced.

## Checks on a Dependabot branch

A sweep's evidence is CI on the PR, which says which bumps go green, plus the branch run locally; landing then runs the repo's normal checks (the pre-push hooks, CI on the default branch).

- Runs triggered by Dependabot get **no repo secrets**, so the jobs that need them skip (see Config). Where a required check waits on one, push a commit (the lockfile fix, or an empty one): its run is yours and gets secrets, which a re-run's doesn't.
- **Check a bump before its first run with secrets** (that push, or your own branch carrying it): no bumped version younger than the cooldown, indirect packages a lockfile regeneration adds or moves included, and none flagged as malware. That run is where a fresh package's install code first meets the repo's credentials. A security fix skips the cooldown: it still gets the malware check, and its age is weighed against the advisory.
- The common real failures are mechanical: a lockfile the bump left out of sync, a formatter whose new version reformats files. Fix them on the branch. A formatter bump (ruff, prettier) reformats even where CI doesn't check formatting: run the formatter on the bump branch and commit the result, or the next unrelated commit picks up the reformat.
- **Pre-commit hook bumps** are usually exercised by nothing in CI: run `pre-commit run --all-files` on the branch before merging.
- **Paired bumps.** Some versions must move together and Dependabot can only move one of them: a package and the CI image tagged to it, a runtime pinned somewhere Dependabot can't read (mise, a Dockerfile it doesn't scan) and the types or SDK that follow it. The repo's `dependabot.yml` names its pairs in comments. Carry the other half in the same change.
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

**Set the cooldown on every entry** rather than leaving GitHub's 3-day default, so it is yours and testable: pip and npm at `semver-patch-days: 3`, `semver-minor-days: 7`, `semver-major-days: 14`, `default-days: 7`; ecosystems without semver keys (github-actions, docker, pre-commit) at `default-days: 7`. Security updates are exempt by design, but a lockfile Dependabot regenerates for any other PR honours the cooldown, so it can put a fresh security relock back to the vulnerable version. The cooldown does nothing for a build outside Dependabot, so **lock indirect dependencies** for anything that deploys: a build that resolves them fresh can pull a malicious indirect release with no PR and no cooldown. Turn on malware alerts too (Settings → Advanced security → Dependabot).

**Pin every action to a full commit SHA** with a trailing `# vX.Y.Z`. Dependabot keeps those pins current, a hijacked tag can no longer land silently, and a small test that fails on an unpinned or comment-less `uses:` keeps it that way.

**Every `ignore` carries a comment** saying why it exists and what would remove it (the work item, the pin it follows, the condition). An ignore without one outlives its reason unnoticed.

GitHub only reads `.github/dependabot.yml` at the repository root. Dependabot's own jobs don't use Actions minutes, but in a private repo the CI they trigger does, rebases included. **Keep tests and lint running on Dependabot's PRs**: their runs get no secrets, which makes them the safest place for a fresh package's install code to run first. Skip only the jobs that need secrets, with a job-level `if` on the triggering run's actor (`github.actor != 'dependabot[bot]'`) rather than the PR's author, so a commit you push gets a full run with secrets and a re-run keeps Dependabot's privileges. With no secrets in CI, nothing needs skipping. If a required check would read such a skip as a pass, make it fail instead.
