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

### Display freeze on resume

Resume from s2idle intermittently returns with a dead display (backlight on,
black screen) and then wedges; only a 7-10 second power-off recovers. This is the
reason the machine runs a mainline kernel. **Still open** — it recurred on 7.2.0
on 2026-09-20.

**The failure logs nothing, and that is what locates it.** The failing boot ends
at `PM: suspend entry (s2idle)` with nothing after it. `PM: suspend exit` prints
only once `enter_state()` returns, that is after every device has resumed
(`kernel/power/suspend.c`), so the hang is inside the device-resume phase with
userspace still frozen, and nothing can reach disk from there. `efi_pstore` is
registered and captured nothing, so it is a stall rather than a panic or an oops.
Five of the seven pre-switch failures look exactly like this; the other two had
the cascade below.

**The signature changed between kernels.** On 7.0.x the freeze was preceded by a
`dc_dmub_srv_log_diagnostic_data: DMCUB error` storm with
`mpc2_assert_mpcc_idle_before_connect` warnings (`dcn20_mpc.c:500-502`) and
`optc31_disable_crtc` timeouts. That cascade fired twice, 2026-07-02 and
2026-08-16, each a few minutes before a power-off, and has not fired once on
7.2.0. What 7.2.0 has instead is a quieter failure in the same block, roughly
every other day and twice within seconds of a resume:

```
amdgpu: [drm] REG_WAIT timeout 1us * 100 tries - dcn31_program_compbuf_size line:141
WARNING: .../display/dc/hubbub/dcn31/dcn31_hubbub.c:151
```

Line 141 waits 100us for a detile-buffer resize to take effect; line 151 then
catches `CONFIG_ERROR` on the compbuf write. Zero of these in the last clean
20-day stretch on 7.0.x, nine in the first 15 days on 7.2.0. So 7.2 changed the
shape of the failure rather than removing it.

**Rate, counted from the journal.** Hard power-offs at a suspend boundary:
2026-05-28, 05-30, 07-02, 07-03, 07-19, 08-01 and 08-16 on 7.0.x, then 09-20 on
7.2.0. Seven in 100 days against one in 15 is indistinguishable, and 7.0.x had
already produced quiet stretches of 33 and 20 days, both longer than 7.2.0 has
run in total. Beating 33 quiet days is the bar. (An earlier version of this file
claimed five power-offs in the four weeks before the switch. Those four weeks
hold one; the five span six and a half weeks.)

**`pm_trace` is on**, so the next failure names a device instead of leaving
nothing behind:

```bash
sudo cp ~/dotfiles/system/pm-trace.conf /etc/tmpfiles.d/pm-trace.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/pm-trace.conf
cat /sys/power/pm_trace   # 1
```

Then after a freeze and power-on, read the hash back:

```bash
journalctl -b 0 | grep -iE "Magic number|hash matches"
cat /sys/power/pm_trace_dev_match
```

Several devices can share a hash, so treat the output as a shortlist rather than
an answer. Both kernels support this (`CONFIG_PM_TRACE_RTC=y` in the 7.2.0 build
and in Ubuntu's 7.0.0-31), and the machine has the legacy `rtc_cmos` the tracer
needs.

**It costs a wrong clock after every resume, not only after a failure.** The
kernel writes hashes over the RTC, the system clock follows the RTC on resume and
at boot, and `systemd-timesyncd` then pulls it back, so expect a jump lasting
seconds to a minute. That is the trade, and it is deliberately time-boxed:
**take it out once a failure has been captured**, or by 2026-11-05 if none has,
with `sudo rm /etc/tmpfiles.d/pm-trace.conf` and a reboot.

**Ruled out:** PSR. The panel reports `eDP-1: PSR support 0`, so panel self
refresh is already disabled and `amdgpu.dcdebugmask=0x10` would be a no-op.

**Nothing is filed upstream.** AMD's advice on bug 221383 was that this belongs
in a report of its own, and "resume hangs, no log, no stack" is not something a
maintainer can act on. A `pm_trace` device name is what would make it filable.

### Mainline kernel (self-built)

This machine runs a **self-built mainline kernel**, not Ubuntu's. `uname -r`
says `7.2.0` where Ubuntu ships `7.0.0-NN`.

Why: the display freeze documented just above. AMD fixed part of it in 7.2-rc7 /
7.1.8. **`7.0.y` is EOL upstream**, so neither 24.04's HWE stack nor 26.04 (which also ships 7.0)
will ever receive it, and Ubuntu's mainline PPA had no amd64 builds for the
fixed versions. Building was the only route. It also brings the `amd_pmc` fix
in-tree, which is why the kernel is untainted again.

**Verdict still open.** Running 7.2.0 since 2026-09-05. The cascade signature is
gone, but the freeze itself recurred on 2026-09-20, so the arrangement is only
partly earning its keep. Nothing short of a quiet stretch beating the old
kernel's own 33 days settles it, and another rebuild is not the next step:
"Display freeze on resume" holds the numbers and what is now instrumented.
**Reassess 2026-11-05.** Worth also confirming the Fn media keys survive a long
suspend, since the in-tree driver now does that job instead of the DKMS module.

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
