# System configuration

Scripts and configs for Linux (Ubuntu/GNOME) system-level setup.

## General (any Linux desktop)

### GNOME keybindings & input (`gnome-keybindings.sh`)

Run once (idempotent):

```bash
~/dotfiles/system/gnome-keybindings.sh
```

Sets up:
- **Super+Q** → lock screen (frees Super+L for dock)
- **Super+L** → dock overlay numbers (dash-to-dock)
- **Alt+Shift** → switch input method (default Super+Space conflicts)
- **Right Alt** → AltGr/Level 3 (Norwegian letters å ø æ via RAlt+a/o/e on Programmer Dvorak)
- **Caps Lock** ↔ **Escape** swap

To adapt for another machine: edit the `input-sources` and `xkb-options`
lines for your keyboard layout. The keybindings are layout-independent.

### Power button (`logind.conf.override`)

Hold power button ~1 second to suspend. `HandlePowerKey=ignore` in logind
lets firmware handle it directly (avoids double-suspend quirks).

```bash
sudo mkdir -p /etc/systemd/logind.conf.d
sudo cp ~/dotfiles/system/logind.conf.override /etc/systemd/logind.conf.d/override.conf
sudo systemctl restart systemd-logind
```

### Battery optimization

TLP handles most tuning automatically:

```bash
sudo apt install tlp
sudo systemctl enable --now tlp
```

Verify: `sudo tlp-stat -s` (enabled), `sudo tlp-stat -r` (wifi power saving on).

### Claude Code OOM kills and Ghostty tabs

Symptom: a Ghostty tab goes sluggish, then closes outright and takes its
scrollback with it. Always while agents are running.

Cause is Claude Code's memory, which grows with session length and with the
number of subagents — `fork` agents especially, since each inherits the
parent's whole context. On this 13 GiB machine it has reached 7-11 GB and been
OOM-killed seven times in the month to 14 Aug 2026. Nothing else on this
machine has *ever* been OOM-killed; every victim in the journal is Claude.

The tab dies as a side effect rather than directly. These are all *global*
kernel OOMs (`constraint=CONSTRAINT_NONE`), which kill a single chosen process,
and `memory.oom.group` is 0, so nothing else in the tab is touched. But Ghostty
runs each tab in its own transient systemd scope, and systemd's stock
`DefaultOOMPolicy=stop` then terminates that whole scope, shell included.

Why the victim is always something in a terminal: the GNOME session runs
launched apps at `oom_score_adj=200` and keeps `gnome-shell` and
`systemd --user` at 100, so Ghostty sits at 200 and **everything spawned in a
tab inherits it**. Claude does not set this — nor does Ghostty; it is
session-wide policy, and it applies to any process you start in a terminal.
The kernel therefore prefers a tab process over the browser regardless of which
is actually larger. On 18 Aug 2026 that picked `ld` (6.08 GB) during a kernel
build while Chrome sat untouched.

**The trap: the memory cap manufactures oomd's kill trigger.** `MemoryHigh`
works BY forcing reclaim. Ubuntu's systemd-oomd kills on *pressure with reclaim
activity*. Ghostty opts every surface scope into oomd itself
(`ManagedOOMMemoryPressure=kill`, matching its docs' advice to "configure
something like systemd-oom"). So capping a tab creates exactly the condition
oomd hunts for — and an oomd kill SIGKILLs the **whole cgroup**, shell
included, which `DefaultOOMPolicy=continue` cannot save. Adding part 1 alone
trades a kernel kill that spares the tab for an oomd kill that destroys it.
That happened on 16 Aug 2026: `Killed …transient-5090.scope due to memory
pressure for …user@1000.service being 89.32% > 50.00% for > 20s with reclaim
activity`. Parts 4 and 5 exist to close that path.

Five parts, all needed:

1. `linux-cgroup-memory-limit` in `ghostty/config` — 6 GiB per tab. This is
   `MemoryHigh`, a *soft* limit: a runaway tab gets throttled and reclaimed
   rather than killed, so it crawls instead of dragging the machine into swap.
2. `DefaultOOMPolicy=continue` here — if a process is OOM-killed anyway, the
   shell and scrollback survive and the tab just shows `killed`.
3. `!mem:<rss>` in the Claude Code status line (`claude/statusline.sh`), shown
   above 3 GiB — the cue to `/clear` or start a fresh session.
4. `user-service-oomd-off.conf` — drops Ubuntu's session-wide 50% oomd rule.
5. `oomd-no-pressure-kill.conf` — raises the per-scope limit Ghostty sets
   directly, which part 4 cannot reach.

Parts 4 and 5 are root-owned and cannot be symlinked, so they are copied:

```bash
sudo mkdir -p /etc/systemd/system/user@.service.d /etc/systemd/oomd.conf.d
sudo cp ~/dotfiles/system/user-service-oomd-off.conf \
        /etc/systemd/system/user@.service.d/oomd-off.conf
sudo cp ~/dotfiles/system/oomd-no-pressure-kill.conf \
        /etc/systemd/oomd.conf.d/no-pressure-kill.conf
sudo systemctl daemon-reload && sudo systemctl restart systemd-oomd
```

Do not restart `user@1000.service` to apply part 4 — that logs you out;
`daemon-reload` is enough for PID 1 to re-push the setting to oomd.

`continue` applies to every user unit, not only Ghostty: Ghostty exposes no
per-surface OOM policy, and the scope names are PID-based
(`app-ghostty-surface-transient-6451.scope`), so no drop-in can target them.
The cost is that a multi-process user service losing one process to the OOM
killer now limps on instead of being stopped cleanly. Weighed against a journal
in which every OOM kill was Claude Code in a Ghostty tab, that's a theoretical
cost against a measured benefit.

`DefaultOOMPolicy` needs `systemctl --user daemon-reexec` (or a re-login), and
then applies to *every* scope, existing tabs included — Ghostty never sets
`OOMPolicy` itself, so the value resolves from the manager default at query
time rather than being stamped at scope creation.

`MemoryHigh` is the opposite: stamped at creation, from whatever config the
running Ghostty process loaded **at startup**. Editing `ghostty/config` and
opening a new tab is *not* enough — the new tab inherits the old config. Reload
with `ctrl+shift+,` first, then open a tab. Tabs already open keep `max` for
life.

```bash
systemctl --user show -p DefaultOOMPolicy                        # continue
cat /sys/fs/cgroup$(cut -d: -f3 /proc/$$/cgroup)/memory.high     # 6442450944
systemctl show user@1000.service -p ManagedOOMMemoryPressure     # auto
oomctl | grep -E 'Default Memory Pressure Limit|Pressure Limit'  # all 100.00%
```

`oomctl` is the one that matters after any change here: it shows what oomd is
actually monitoring and at what limit, rather than what the units claim.

If it recurs, start here:

```bash
journalctl -b --no-pager | grep -E 'Out of memory: Killed|ghostty-surface.*oom-kill'
```

The victim appears under its own process name — the native Claude binary's
`comm` is its version string (e.g. `2.1.232`), not `claude`, which is why the
status-line check keys on the largest-RSS ancestor instead of a name.

Three gotchas when reading that output:

- `journalctl -k` has under-reported these kills here (it missed six of seven).
  Grep the unfiltered journal instead.
- A `systemd-oomd invoked oom-killer` line does *not* mean oomd killed
  anything — it names whichever process's allocation happened to fail. A real
  oomd kill says `systemd-oomd killed some process(es) in this unit` and, in
  `systemd-oomd`'s own journal, `Killed <cgroup> due to memory pressure`.
- An oomd kill leaves **no failed unit and no kernel OOM line**, so the greps
  above miss it entirely. If a tab vanished and those come back empty, check
  `journalctl -u systemd-oomd` and `journalctl --user | grep oomd` before
  concluding nothing happened.

Status as of 19 Aug 2026: **proven in the wild.** On 18 Aug at 00:25 a kernel
build's `ld` was OOM-killed at 6.08 GB inside
`app-ghostty-surface-transient-6270.scope`, and the scope stayed
`ActiveState=active, Result=success` — the tab and its scrollback survived a
kill that would previously have closed it.

Corollary for heavy builds in a tab: the 6 GiB cap is per-tab, and everything
in the tab inherits `oom_score_adj=200`, so a big `make -j` is both memory-
capped and first in line to be killed. Build with low parallelism (`-j2` for a
kernel link, which alone wants ~6 GB) rather than one job per core.

### Note: avoid Toshy

[Toshy](https://github.com/RedBearAK/toshy) (Mac-style keybindings for Linux) conflicts
badly with Programmer Dvorak and custom keybindings — it remaps at a layer that
fights both the layout engine and personal shortcuts.

## Lenovo-specific

### Battery conservation mode (`battery-limit.service`)

Caps charge at ~80% via ideapad_acpi driver.

```bash
sudo cp ~/dotfiles/system/battery-limit.service /etc/systemd/system/
sudo systemctl enable --now battery-limit.service
```

For non-Lenovo laptops, use TLP thresholds instead:
`START_CHARGE_THRESH_BAT0=75` / `STOP_CHARGE_THRESH_BAT0=80` in `/etc/tlp.conf`
(if your hardware supports it — check `sudo tlp-stat -b`).

### Lid close

Lid-close suspend is inconsistent due to Modern Standby (s2idle) firmware
on some Lenovo Ryzen models. Use the power button to suspend instead.

### Fn media keys stop working after long suspend

After s2idle resumes past roughly 15 minutes, all Fn media keys
(brightness, volume, mic-mute, airplane) stop emitting events. The EC
forwards raw scancodes to i8042 instead of translating them to media
keycodes, so `KEY_F1..F12` appear on the AT keyboard where
`KEY_VOLUMEUP` etc. should. `/dev/input/event6` ("Ideapad extra
buttons") goes silent.

Only a reboot resolves a broken state. The same EC race also killed the internal
keyboard outright on resume; a `system-sleep` hook that re-scanned the i8042
controller carried that until the real fix landed, and `git log` has it.

Upstream bug: https://bugzilla.kernel.org/show_bug.cgi?id=221383 — reported and
tested from this machine, merged 2026-07-25 and backported to the 6.6 / 6.12 /
6.18 / 7.1-stable trees. Fixed in the running mainline kernel; on the 7.0
fallback the DKMS module still provides it, because 7.0.y is not a longterm
branch and never received the backport. `git log` has the year of diagnosis if
it is ever needed again.

Two device caveats that survive the fix, both harmless: while charging, s2idle
never reaches the deepest state and the `Delaying suspend by 2.5s` line spams
the log — it scales with charging time, not suspend duration, and self-clears.
And timer/wakealarm wakeups still break the keyboard on some Zen3 models
(`i8042.nopnp` helps there); this 83K6 is unaffected.

**DKMS module** (https://github.com/DanielGibson/amd_pmc-ideapad, at
`~/src/amd_pmc-ideapad/`) is still installed and still needed — but only for
7.0.x. Check which driver a kernel is using:

```bash
modinfo -k <version> amd_pmc | grep filename   # updates/dkms = out-of-tree
cat /proc/sys/kernel/tainted                   # 0 = nothing out-of-tree loaded
```

**Retire it when the 7.0 fallback goes** — not before, and note the MOK keys are
now load-bearing for signing mainline kernels, so they stay regardless:
- `sudo dkms remove amd_pmc/0.0.3 --all`, then `rm -rf ~/src/amd_pmc-ideapad`
- Keep `~/mok.key` / `~/mok.crt` / `~/mok.der` unless self-built kernels are
  also gone

### Mainline kernel (self-built)

This machine runs a **self-built mainline kernel**, not Ubuntu's. `uname -r`
says `7.2.0` where Ubuntu ships `7.0.0-NN`.

Why: resume from s2idle intermittently came back with a dead display — backlight
on, black screen, then a wedge needing a 7-second power-off, roughly once or
twice a week. The journal shows a DMCUB storm and `mpc2_assert_mpcc_idle_before_connect`
warnings from amdgpu on resume. AMD fixed it in 7.2-rc7 / 7.1.8. **`7.0.y` is
EOL upstream**, so neither 24.04's HWE stack nor 26.04 (which also ships 7.0)
will ever receive it, and Ubuntu's mainline PPA had no amd64 builds for the
fixed versions. Building was the only route. It also brings the `amd_pmc` fix
in-tree, which is why the kernel is untainted again.

**Still unverified.** Running 7.2.0 since 2026-09-05; the fix is not confirmed on
this hardware yet. The failure was intermittent, five hard power-offs in the four
weeks before the switch, so only a quiet stretch settles it. **Check again after
2026-10-05.** Two quiet months means it worked and this paragraph can go. A
recurrence means 7.2 was the wrong answer, and the next step is the amdgpu bug
that was never filed (AMD's advice was that it belongs separately from 221383,
which covers the EC hotkey bug only) rather than another rebuild. Worth also
confirming the Fn media keys survive a long suspend, since the in-tree driver now
does that job instead of the DKMS module.

**Nothing updates it.** `apt` has no repository for `linux-image-7.2.0` — its
only source is the local dpkg status — so it receives no security patches at
all. Ubuntu's own kernel line keeps updating and stays patched as the fallback,
and all userspace packages update normally. The exposure is kernel-local
privilege escalation, which needs an attacker already on the machine; real, but
not the class a laptop behind NAT meets first.

**Rebuild:** `~/dotfiles/system/kernel-mainline-build.sh 7.2.3` — fetches,
verifies against kernel.org's checksums, configures from the running kernel,
builds outside the terminal's cgroup, installs and signs. Roughly 40 minutes,
mostly unattended. GRUB then defaults to the highest version on its own.

**Check every month or so** whether a newer 7.2.x exists (`https://kernel.org`),
and rebuild if so. Last checked: **2026-09-05**, on 7.2.0, with 7.2 the current
mainline.

**Stop doing this when either trigger fires:**
- **Ubuntu ships ≥7.1** in the HWE stack or a release upgrade. Then drop back:
  `sudo apt remove linux-image-7.2.0 linux-headers-7.2.0`, reboot, confirm the
  display bug stays away on the stock kernel. This is the preferred exit —
  supported kernels get security updates.
- **7.2 goes EOL** (it will, once 7.3 ships — 7.2 is not a longterm branch
  either). Move to the next mainline with the same script, or take the exit
  above if it is available by then.

Do not delete `~/src/kernel-mainline` casually: an existing tree makes a rebuild
incremental. It is safe to delete, just slower afterwards.

### MOK signing key

A Machine Owner Key was enrolled (2026-04-27) to load test modules under Secure
Boot. Key files at `~/mok.key` / `~/mok.crt` — reuse to sign without another
enrollment reboot.

**Now load-bearing:** every self-built kernel is signed with it, or Secure Boot
refuses to boot. Do not delete these while a mainline kernel is installed. A
capsule BIOS flash resets firmware settings and can clear enrolled MOKs, so
re-enrol afterwards before rebooting into a self-built kernel.
