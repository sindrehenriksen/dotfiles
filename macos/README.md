# macOS system configuration

## Keyboard remapping (`keyboard-remap.sh`, `com.local.KeyRemapping.plist`)

`install_symlinks.sh` places the launch agent; it runs the script at login.
Apply changes without logging out:

```bash
launchctl kickstart -k gui/$(id -u)/com.local.KeyRemapping
```

Current mappings:

| Keyboard | Key | Becomes |
|---|---|---|
| all | Caps Lock | F18 — Hammerspoon turns it into Escape / window-focus modal |
| all | Menu (PC keyboards only) | Right Option, the AltGr the Norwegian layout wants |
| built-in | fn | Control |
| built-in | Control | fn |
| Microsoft | Alt / Cmd | swapped, both sides |

**Don't use System Settings > Keyboard > Keyboard Shortcuts > Modifier Keys.**
It writes the same per-device `UserKeyMapping` property `hidutil` does, so a
mapping set there survives only until the next login, when this script
overwrites it. That panel is also the more limited of the two: it offers a
fixed menu of destinations (Caps Lock, Control, Option, Command, Escape, Globe)
with no way to reach F18.

Two `hidutil` gotchas the script depends on:

- A device-scoped `--set` replaces that device's *entire* mapping list rather
  than adding to it, so every scoped block repeats the mappings it wants to
  keep.
- The unscoped `--set` hits every device including the scoped ones, so it has
  to run first.

`--set` applies to the keyboards connected *at that moment*, so one attached
after login comes up with only the unscoped mappings — confirmed on the
Microsoft keyboard, which kept Alt where Cmd should be. `hammerspoon/init.lua`
therefore re-runs this script on USB attach and on wake. A Bluetooth keyboard
paired mid-session is not covered by either; run the `kickstart` above.

Mappings are simultaneous, not chained: with `fn -> Control` and
`Control -> fn` both listed, each key produces the other rather than one
feeding into the next.

### Caps Lock needs Hammerspoon

Caps is mapped to F18, which does nothing on its own —
`hammerspoon/init.lua` turns a tap into Escape and a hold into the window-focus
modal. **If Hammerspoon isn't running, Caps Lock is a dead key.**

### Why fn and Control are swapped on the built-in keyboard

fn sits in the bottom-left corner where PC keyboards put Control, which is
where the hand expects it for terminal and Neovim chords. The swap parks fn on
the key it displaces; fn is still needed for fn+arrows (Home/End/PgUp/PgDn),
fn+Delete and real F-keys, so it can't just be dropped. Note this leaves fn as
the *only* Control on that keyboard — MacBooks have no right Control.

## Chords bound in Hammerspoon

`hammerspoon/init.lua` adds three things that behave like keyboard features
rather than window management:

- **Shift+Backspace** → forward delete, which macOS itself only offers as
  fn+Delete.
- **Tap left Ctrl** → Ctrl+Tab. On the built-in keyboard that is the fn key
  position, so the tab-forward chord sits under the corner of the hand.
- **Tap left Shift** → Ctrl+Shift+Tab, the same one backwards.

A modifier tap only fires when the key goes down and up alone inside 200 ms —
holding it, or pressing any key or mouse button while it is down, is a normal
modifier. Gestures that hold a modifier over the mouse (Ctrl+scroll to zoom)
outlast the window on their own.

Shift also has to be followed by 80 ms of quiet, because a Shift released a
fraction early — just before the letter it was meant to capitalise — is
indistinguishable from a deliberate tap until that letter lands. Tapping Shift
twice in a row still gives two tabs back: the second press releases the first.
Ctrl has no such window and stays instant. Both constants are at the top of the
block in `hammerspoon/init.lua`.

Caps as a hold-modifier — window focus and jump-to-app — is documented in
`docs/window-layout.md`.

## Other keyboard settings (still in the Settings app)

These aren't key remappings and don't collide with the script above:

- **Free up Ctrl+Space** (zsh autosuggest-accept wants it): System Settings >
  Keyboard > Keyboard Shortcuts > Input Sources, uncheck "Select the previous
  input source". Ctrl+Option+Space still cycles.
- **Globe key action**: System Settings > Keyboard > "Press 🌐 key to" > Do
  Nothing. Moot on the built-in keyboard now that fn is Control.
