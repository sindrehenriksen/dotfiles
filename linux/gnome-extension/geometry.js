// Pure geometry for the placement grid — no GNOME imports, so it can be run and
// checked directly with gjs. A port of the same maths in hammerspoon/init.lua;
// the two must agree, since the point is that a key does the same thing on both
// machines. See docs/window-layout.md.

export const GAP = 10;
// macOS keeps this at 0 because the menu bar supplies the top gap. GNOME has no
// menu bar over the work area, so top and bottom match.
const TOP_GAP = GAP;
const TOL = 4;
const THIRD = 1 / 3;

export const SLOTS = {
    full_L:  [0,         0,   THIRD, 1  ],
    upper_L: [0,         0,   THIRD, 0.5],
    lower_L: [0,         0.5, THIRD, 0.5],
    full_C:  [THIRD,     0,   THIRD, 1  ],
    upper_C: [THIRD,     0,   THIRD, 0.5],
    lower_C: [THIRD,     0.5, THIRD, 0.5],
    full_R:  [2 * THIRD, 0,   THIRD, 1  ],
    upper_R: [2 * THIRD, 0,   THIRD, 0.5],
    lower_R: [2 * THIRD, 0.5, THIRD, 0.5],
};

export const RAW = {
    half_L: [0,    0, 0.5, 1],
    half_C: [0.25, 0, 0.5, 1],
    half_R: [0.5,  0, 0.5, 1],
    full:   [0,    0, 1,   1],
};

// One large window beside one small, each inset a fixed margin from its outer
// edge so the two sides mirror. The ultrawide tiles both with air around them;
// the laptop is too narrow, so the large one takes the screen and the small one
// floats over it, held high rather than centred.
export const TWO_UP = {
    wide:   {margin: 0.10,  small: {w: 0.295, h: 0.70},        large: {w: 0.48, h: 0.90}},
    narrow: {margin: 0.005, small: {w: 0.53,  h: 0.79, y: 0.06}, large: {w: 0.73, h: 0.96}},
};

export function screenKind(work) {
    return work.width / work.height > 2 ? 'wide' : 'narrow';
}

export function twoUpRect(work, size, side) {
    const spec = TWO_UP[screenKind(work)];
    const box = spec[size];
    const xf = side === 'left' ? spec.margin : 1 - spec.margin - box.w;
    return [xf, box.y ?? (1 - box.h) / 2, box.w, box.h];
}

export function targetFrame(work, [xf, yf, wf, hf]) {
    const half = GAP / 2;
    const left   = xf <= 0.001        ? GAP     : half;
    const right  = xf + wf >= 0.999   ? GAP     : half;
    const top    = yf <= 0.001        ? TOP_GAP : half;
    const bottom = yf + hf >= 0.999   ? GAP     : half;
    return {
        x: Math.round(work.x + xf * work.width + left),
        y: Math.round(work.y + yf * work.height + top),
        width: Math.round(wf * work.width - left - right),
        height: Math.round(hf * work.height - top - bottom),
    };
}

export function framesEqual(a, b) {
    return Math.abs(a.x - b.x) < TOL && Math.abs(a.y - b.y) < TOL &&
           Math.abs(a.width - b.width) < TOL && Math.abs(a.height - b.height) < TOL;
}

// Already here, and not merely matching some other known placement that happens
// to share this origin — the condition for hopping to the next monitor.
export function shouldCycle(frame, target, work) {
    const at = Math.abs(frame.x - target.x) < TOL && Math.abs(frame.y - target.y) < TOL &&
               frame.width >= target.width - TOL && frame.height >= target.height - TOL;
    if (!at)
        return false;
    for (const spec of Object.values(SLOTS).concat(Object.values(RAW))) {
        const f = targetFrame(work, spec);
        if (!framesEqual(f, target) && framesEqual(frame, f))
            return false;
    }
    for (const size of ['small', 'large'])
        for (const side of ['left', 'right']) {
            const f = targetFrame(work, twoUpRect(work, size, side));
            if (!framesEqual(f, target) && framesEqual(frame, f))
                return false;
        }
    return true;
}

