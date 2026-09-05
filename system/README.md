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

### Keyboard resume fix (`keyboard-reset`)

Some Lenovo models lose the internal keyboard entirely after s2idle resume.
Same root cause as the Fn media keys bug below (EC timing race on resume from
deep sleep). Both are fixed by the DKMS module below — script is currently
**disabled** (`chmod -x`) and kept as a fallback only.

[This Reddit thread](https://www.reddit.com/r/Lenovo/comments/1q02pr7/solved_keyboard_not_working_after_suspendsleep_on/)
suggests disabling battery optimization via a udev rule as a fix, but that trades
battery life for reliability. Our approach keeps battery optimization and re-scans
the keyboard controller on resume instead.

```bash
sudo cp ~/dotfiles/system/keyboard-reset /usr/lib/systemd/system-sleep/
sudo chmod +x /usr/lib/systemd/system-sleep/keyboard-reset
```

Manual workaround if keyboard dies: `kbr` alias (defined in `.shellrc`),
or directly: `sudo sh -c 'echo -n "rescan" > /sys/devices/platform/i8042/serio0/drvctl'`

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

Until fixed upstream, only reboot resolves a broken state.

Upstream bug: https://bugzilla.kernel.org/show_bug.cgi?id=221383

Status (2026-05-13): patch v3 submitted 2026-05-12, now `Cc: stable@vger.kernel.org`
so it'll be backported once merged. Reviewed-by from both Ilpo Järvinen (Intel) and
Mario Limonciello (AMD). Sindre credited with Reported-by and Tested-by. The 83K
prefix match covers this device; 83MM (IdeaPad Slim 3 15ARP10) added as a third
explicit DMI entry in v3.

Update (2026-05-29): still ASSIGNED upstream, not yet merged. Local DKMS module
bumped to 0.0.3 (the v2 patch series + 83MM quirk + crash fix for undetected
devices).

Update (2026-07-25): **merged upstream and backported to stable.** Patch went
v3→v6 (v4/v5 fixed series-assembly and log-spam nits), landed with Reviewed-by
from Mario Limonciello (AMD), Ilpo Järvinen (Intel) and Hans de Goede (pdx86
maintainer), then Greg KH queued it into the 6.6 / 6.12 / 6.18 / 7.1-stable
trees. Note our Ubuntu HWE base is 7.0, which is *not* a longterm branch and
isn't among those trees — so the fix won't arrive via a 7.0.y stable import.
Expect it via a Canonical cherry-pick into a later 7.0.0-NN update, or when the
24.04 HWE stack rebases onto a ≥7.1 base. DKMS workaround stays active until
then; confirm the stock kernel has the fix after any kernel update with:
`strings $(find /lib/modules/$(uname -r)/kernel -name 'amd-pmc.ko*') | grep -c 'Delaying suspend'`
(≥1 = in-tree, safe to run the teardown below).

Charging caveat: while actively charging, s2idle never reaches the deepest state
and the `Delaying suspend by 2.5s` line spams the log (~1 every 2.6s). The
`.check` callback fires once per intermediate s2idle wakeup, and the EC's charge
chatter causes constant wakeups. So the count scales with time spent *charging*,
not suspend duration: a confirmed-charging 2 min suspend logged it 51x, while a
~22 h battery suspend logged it once and reached deepest state. Not fixed by 0.0.3
(Daniel expected once-per-suspend; reported back that it isn't, for the charging
case). Charging-only and self-clearing, so no action needed. A 15ARP10 (83K7) user
reported worse symptoms on charge (userland crashes + ACPI storm, github issue #3),
but that does not reproduce on this 83K6.

Timer/wakealarm caveat: Daniel's 82XR (Zen3) still breaks with timer-based wakeups
even with the fix. Tested on this device (83K6, Zen3+) with the DKMS workaround —
timer case works fine here, and another user reported the same on 14ARP10 (also
83K). For affected Zen3 devices, `i8042.nopnp` on the kernel cmdline restores
most of the keyboard after a wakealarm-triggered suspend without impairing
regular suspend/resume.

**Workaround (active):** DKMS module from https://github.com/DanielGibson/amd_pmc-ideapad
installed at `~/src/amd_pmc-ideapad/`. Replaces the in-kernel `amd_pmc` module
with a patched version that adds a 2.5s delay before deep sleep. Auto-rebuilds
on kernel updates. Verify with:
```bash
ls /sys/module/amd_pmc/parameters/delay_suspend   # file exists = patched module loaded
journalctl -b | grep "platform bug"               # appears after first suspend
```
Prefer retiring this before any release upgrade (24.04 → 26.04): an out-of-tree
module has to rebuild against the new release's kernel, and a major-version jump
is where that's most likely to break. If it's still installed, re-verify the
keyboard after upgrading.

**When the upstream fix lands in an Ubuntu kernel update, clean up:**
- `sudo dkms remove amd_pmc/0.0.3 --all` and `rm -rf ~/src/amd_pmc-ideapad`
- Re-enable or remove the keyboard-reset script
- Remove `~/mok.key`, `~/mok.crt`, `~/mok.der` and `/var/lib/dkms/mok.*`
- Remove `~/kernel-bug-221383/` (diagnostic artifacts, no longer needed)
- Remove this section and the keyboard-reset section from this README

### MOK signing key

A Machine Owner Key was enrolled (2026-04-27) to load test modules under
Secure Boot. Key files at `~/mok.key` / `~/mok.crt` — reuse to sign future
test modules without another enrollment reboot.
