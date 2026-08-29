#!/bin/sh
# Keyboard remapping. Run at login by com.local.KeyRemapping.plist.
#
# hidutil owns UserKeyMapping on every keyboard here. System Settings >
# Keyboard > Keyboard Shortcuts > Modifier Keys writes the *same* per-device
# property, so anything set in that panel is overwritten the next time this
# runs. Add mappings here, not there.
#
# Caps -> F18 is not Escape on its own: hammerspoon/init.lua turns a tap into
# Escape and a hold into the window-focus modal. Caps does nothing at all if
# Hammerspoon isn't running.
#
# Apply without logging out:
#   launchctl kickstart -k gui/$(id -u)/com.local.KeyRemapping

CAPS_TO_F18='{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}'
MENU_TO_RIGHT_ALT='{"HIDKeyboardModifierMappingSrc":0x700000065,"HIDKeyboardModifierMappingDst":0x7000000E6}'
FN_TO_CTRL='{"HIDKeyboardModifierMappingSrc":0xFF00000003,"HIDKeyboardModifierMappingDst":0x7000000E0}'
CTRL_TO_FN='{"HIDKeyboardModifierMappingSrc":0x7000000E0,"HIDKeyboardModifierMappingDst":0xFF00000003}'
LEFT_ALT_TO_CMD='{"HIDKeyboardModifierMappingSrc":0x7000000E2,"HIDKeyboardModifierMappingDst":0x7000000E3}'
LEFT_CMD_TO_ALT='{"HIDKeyboardModifierMappingSrc":0x7000000E3,"HIDKeyboardModifierMappingDst":0x7000000E2}'
RIGHT_ALT_TO_CMD='{"HIDKeyboardModifierMappingSrc":0x7000000E6,"HIDKeyboardModifierMappingDst":0x7000000E7}'
RIGHT_CMD_TO_ALT='{"HIDKeyboardModifierMappingSrc":0x7000000E7,"HIDKeyboardModifierMappingDst":0x7000000E6}'

# Every keyboard. The Menu key only exists on PC keyboards, where Right Option
# is the AltGr the Norwegian layout wants.
hidutil property --set \
  "{\"UserKeyMapping\":[$CAPS_TO_F18,$MENU_TO_RIGHT_ALT]}" >/dev/null

# A device-scoped --set replaces that device's whole list rather than adding to
# it, so each block below repeats what it wants to keep — and all of them have
# to run after the unscoped --set above, which would otherwise wipe them.

# Built-in keyboard: swap fn and Ctrl, putting Ctrl in the bottom-left corner
# where PC keyboards have it. fn moves to the key it displaces and is still
# needed for fn+arrows, fn+Delete and real F-keys. Leaves fn as the only Ctrl —
# MacBooks have no right Ctrl.
hidutil property --matching '{"Product":"Apple Internal Keyboard / Trackpad"}' --set \
  "{\"UserKeyMapping\":[$CAPS_TO_F18,$FN_TO_CTRL,$CTRL_TO_FN]}" >/dev/null

# Microsoft keyboard: Alt <-> Cmd, so Cmd sits next to the space bar as it
# does on a Mac keyboard.
hidutil property --matching '{"VendorID":1118,"ProductID":1957}' --set \
  "{\"UserKeyMapping\":[$CAPS_TO_F18,$LEFT_ALT_TO_CMD,$LEFT_CMD_TO_ALT,$RIGHT_ALT_TO_CMD,$RIGHT_CMD_TO_ALT]}" >/dev/null
