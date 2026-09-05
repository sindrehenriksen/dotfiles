// Three-column placement grid and directional focus.
//
// The geometry here is a port of hammerspoon/init.lua and must stay in step
// with it — same slots, same gaps, same screen-cycling rule, same two-window
// specs. docs/window-layout.md is the shared description both serve.
//
// Wayland is why this is an extension at all: nothing outside the compositor
// can move a window, so there is no external-tool version of this.

import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import Clutter from 'gi://Clutter';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {SLOTS, RAW, targetFrame, twoUpRect, shouldCycle} from './geometry.js';

function workArea(monitorIndex) {
    const ws = global.workspace_manager.get_active_workspace();
    return ws.get_work_area_for_monitor(monitorIndex);
}

// `rectFor` takes a work area and returns fractions, so a layout whose shape
// differs between displays still lands correctly after a monitor hop.
function placeBy(rectFor) {
    const win = global.display.focus_window;
    if (!win || win.is_override_redirect())
        return;
    let monitor = win.get_monitor();
    let work = workArea(monitor);
    let target = targetFrame(work, rectFor(work));

    if (shouldCycle(win.get_frame_rect(), target, work)) {
        const n = Main.layoutManager.monitors.length;
        if (n > 1) {
            monitor = (monitor + 1) % n;
            work = workArea(monitor);
            target = targetFrame(work, rectFor(work));
        }
    }
    if (win.get_maximized())
        win.unmaximize(Meta.MaximizeFlags.BOTH);
    win.move_resize_frame(true, target.x, target.y, target.width, target.height);
}

const placeSlot = name => placeBy(() => SLOTS[name]);
const placeRaw = name => placeBy(() => RAW[name]);
const placeTwoUp = (size, side) => placeBy(work => twoUpRect(work, size, side));

// Nearest window whose centre lies in `dir`, preferring ones roughly in line.
function focusDirection(dir) {
    const win = global.display.focus_window;
    if (!win)
        return;
    const from = win.get_frame_rect();
    const cx = from.x + from.width / 2, cy = from.y + from.height / 2;
    let best = null, bestScore = Infinity;

    for (const other of global.get_window_actors().map(a => a.meta_window)) {
        if (other === win || other.minimized || other.is_override_redirect())
            continue;
        if (!other.located_on_workspace(global.workspace_manager.get_active_workspace()))
            continue;
        const r = other.get_frame_rect();
        const dx = r.x + r.width / 2 - cx, dy = r.y + r.height / 2 - cy;
        const along = {west: -dx, east: dx, north: -dy, south: dy}[dir];
        const across = (dir === 'west' || dir === 'east') ? Math.abs(dy) : Math.abs(dx);
        if (along <= 0)
            continue;
        const score = along + across * 2;
        if (score < bestScore) {
            bestScore = score;
            best = other;
        }
    }
    if (best)
        best.activate(global.get_current_time());
}

// Dvorak home row for the columns, top and bottom rows for the halves — the
// same letters as the macOS picker, since the point is one muscle memory.
const PICKER = {
    h: () => placeSlot('full_L'),  t: () => placeSlot('full_C'),  n: () => placeSlot('full_R'),
    g: () => placeSlot('upper_L'), c: () => placeSlot('upper_C'), r: () => placeSlot('upper_R'),
    m: () => placeSlot('lower_L'), w: () => placeSlot('lower_C'), v: () => placeSlot('lower_R'),
    H: () => placeRaw('half_L'),   T: () => placeRaw('half_C'),   N: () => placeRaw('half_R'),
    s: () => placeRaw('full'),
    ',': () => placeTwoUp('small', 'left'),  '.': () => placeTwoUp('small', 'right'),
    o: () => placeTwoUp('large', 'left'),    e: () => placeTwoUp('large', 'right'),
};

export default class WindowGridExtension extends Extension {
    enable() {
        this._settings = this.getSettings();
        this._grab = null;
        this._keyHandler = null;
        this._label = null;

        Main.wm.addKeybinding('show-picker', this._settings,
            Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
            () => this._openPicker());

        for (const dir of ['west', 'north', 'south', 'east']) {
            Main.wm.addKeybinding(`focus-${dir}`, this._settings,
                Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
                () => focusDirection(dir));
        }
    }

    disable() {
        this._closePicker();
        for (const k of ['show-picker', 'focus-west', 'focus-north', 'focus-south', 'focus-east'])
            Main.wm.removeKeybinding(k);
        this._settings = null;
    }

    _openPicker() {
        if (this._grab)
            return;
        const grab = Main.pushModal(global.stage, {actionMode: Shell.ActionMode.SYSTEM_MODAL});
        if (!grab) {
            return;
        }
        this._grab = grab;

        this._label = new St.Label({text: 'Layout', style_class: 'window-grid-hint'});
        this._label.set_style('background-color: rgba(0,0,0,0.75); color: #fff; ' +
            'padding: 10px 22px; border-radius: 10px; font-size: 15pt;');
        Main.layoutManager.uiGroup.add_child(this._label);
        const mon = Main.layoutManager.primaryMonitor;
        this._label.set_position(
            Math.round(mon.x + (mon.width - this._label.width) / 2),
            Math.round(mon.y + mon.height * 0.75));

        this._keyHandler = global.stage.connect('key-press-event', (_a, event) => {
            const sym = event.get_key_symbol();
            if (sym === Clutter.KEY_Escape) {
                this._closePicker();
                return Clutter.EVENT_STOP;
            }
            const ch = String.fromCharCode(Clutter.keysym_to_unicode(sym));
            const action = PICKER[ch];
            if (action) {
                this._closePicker();
                action();
            }
            return Clutter.EVENT_STOP;
        });
    }

    _closePicker() {
        if (this._keyHandler) {
            global.stage.disconnect(this._keyHandler);
            this._keyHandler = null;
        }
        if (this._label) {
            this._label.destroy();
            this._label = null;
        }
        if (this._grab) {
            Main.popModal(this._grab);
            this._grab = null;
        }
    }
}
