---
name: dependabot
description: 'Working through open Dependabot PRs in a repo, and keeping its dependabot.yml in shape: triage, the order to land them in, CI on Dependabot branches, paired bumps, handing off heavyweight upgrades. USE FOR: "pick off the dependabot PRs", a dependency sweep, a Dependabot security PR or alert, setting up or changing dependabot.yml. DO NOT USE FOR: a hand-authored dependency change, reviewing other PRs, debugging an unrelated CI failure (ci-debugging). A repo or workspace may layer its own Dependabot skill on top of this one: read both.'
allowed-tools: Bash, Read, Grep
---

# Dependabot

Land the open Dependabot PRs from least to most risky, one at a time, each green before the next. Present the ordered plan before landing anything: landing is a push to the default branch, often a deploy, so it waits for the user's go like any other.

## Snapshot the set

```bash
gh pr list --author "app/dependabot" --state open --json number,title,headRefName,mergeStateStatus,statusCheckRollup
gh api repos/{owner}/{repo}/dependabot/alerts --jq '.[] | select(.state=="open") | [.security_advisory.severity, .dependency.package.name, .security_vulnerability.first_patched_version.identifier] | @tsv'
```

Dependabot regroups between runs, so PR numbers aren't stable: re-derive the set each time, read each diff (`gh pr diff <n>`) for the actual bumps, and close what is superseded.

Its PRs are a starting point, not the unit of work. Split one, combine several, or make the bumps on a branch of your own whenever that lands the change better (a coupled set, a pair it can't make, a group that only fails together), then close the PRs it replaces.

## Order

1. **Security updates first.** They come in their own group (see Config), so the group name in the branch and title picks them out.
2. **No runtime impact:** CI and Actions pins, test-only and dev tooling.
3. **Minor/patch groups**, the least critical surface first.
4. **Library majors, one at a time:** usage grep, changelog, the covering tests.
5. **Runtime, framework, language or base-image majors last**, and usually handed off rather than landed in the sweep (below).

## CI on a Dependabot branch

- Runs triggered by Dependabot get **no repo secrets**, so a secret-dependent job fails as an artifact rather than a real red: check that the underlying tests passed. Once you push a commit to the branch, the next run is attributed to you and gets secrets.
- The common real failures are mechanical: a lockfile the bump left out of sync, a formatter whose new version reformats files. Fix them on the branch.
- **Paired bumps.** Some versions must move together and Dependabot can only move one of them: a package and the CI image tagged to it, a runtime pinned somewhere Dependabot can't read (mise, a Dockerfile it doesn't scan) and the types or SDK that follow it. The repo's `dependabot.yml` names its pairs in comments. Carry the other half in the same change, whether that lands as a PR merge or a direct push.
- A grouped set that cannot resolve together gets split: keep what resolves, revert the entangled bumps to the base versions and hand those off. Trust CI's environment over a local resolve.

## Landing

- **Rebase onto the current base before each landing**, resolving manifest conflicts by keeping the already-landed bumps and taking this one, then regenerate the lockfile. Don't use `@dependabot rebase`: it is slow, and on a grouped PR it closes and recreates the PR, regrouping it.
- Landing one PR makes Dependabot force-update its open siblings within a minute, so re-fetch a branch before pushing to it.
- How a change lands (PR merge, direct push to the default branch) and whether that deploys is the repo's own process: follow it, and watch a deploy through before the next PR.

## Heavyweights: hand off, don't land in the sweep

A framework, SDK, runtime or base-image major, a bump only exercised at deploy time, or a coupled set that needs code changes, becomes its own piece of work:

1. Record it where the repo tracks work, after checking whether in-flight work already covers it.
2. Add an `ignore` with `update-types` (`version-update:semver-major`, or minor too for a runtime), not a version range, which only moves the noise to the next release. Ignore the whole coupled set, not just the headline package, or its siblings keep failing the group.
3. Close the PR, pointing at where the work is recorded.

## Config

The shape that works: weekly, minor and patch grouped into one PR, majors in a group of their own, a low open-PR limit, and **security updates in their own group per entry** (`applies-to: security-updates`). That group is also the only way to tell security PRs apart: `labels:` applies to every PR an entry raises, security ones included, so a label cannot mark them alone.

**Every `ignore` carries a comment** saying why it exists and what would remove it (the work item, the pin it follows, the condition). An ignore without one outlives its reason unnoticed.

GitHub only reads `.github/dependabot.yml` at the repository root. Dependabot's own jobs don't use Actions minutes, but in a private repo the CI they trigger does, rebases included.
