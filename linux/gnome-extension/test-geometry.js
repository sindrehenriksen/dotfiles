#!/usr/bin/env gjs
// Checks the placement maths against the numbers verified on the real displays.
// Run: gjs -m test-geometry.js
import {SLOTS, RAW, targetFrame, twoUpRect, screenKind} from './geometry.js';

const SCREENS = {
    ultrawide: {x: 0, y: 0, width: 3440, height: 1440},
    laptop:    {x: 0, y: 0, width: 1920, height: 1173},
};

let failures = 0;
function check(label, got, want) {
    const ok = Math.abs(got - want) <= 1;
    if (!ok) failures++;
    print(`  ${ok ? 'ok  ' : 'FAIL'} ${label}: ${got}${ok ? '' : ` (want ${want})`}`);
}

for (const [name, work] of Object.entries(SCREENS)) {
    print(`\n${name} ${work.width}x${work.height}  kind=${screenKind(work)}`);
    const cols = ['full_L', 'full_C', 'full_R'].map(s => targetFrame(work, SLOTS[s]));
    check('left column starts at gap', cols[0].x, 10);
    check('right column ends at gap', cols[2].x + cols[2].width, work.width - 10);
    check('columns are equal width', cols[0].width, cols[2].width);
    check('centre gap to left column', cols[1].x - (cols[0].x + cols[0].width), 10);
    check('centre gap to right column', cols[2].x - (cols[1].x + cols[1].width), 10);

    const up = targetFrame(work, SLOTS['upper_C']), lo = targetFrame(work, SLOTS['lower_C']);
    check('upper/lower gap', lo.y - (up.y + up.height), 10);
    check('top inset equals bottom inset', up.y, work.height - (lo.y + lo.height));

    const full = targetFrame(work, RAW['full']);
    check('fullscreen left inset', full.x, 10);
    check('fullscreen right inset', work.width - (full.x + full.width), 10);
    check('fullscreen top inset', full.y, 10);
    check('fullscreen bottom inset', work.height - (full.y + full.height), 10);

    for (const size of ['small', 'large']) {
        const l = targetFrame(work, twoUpRect(work, size, 'left'));
        const r = targetFrame(work, twoUpRect(work, size, 'right'));
        check(`two-up ${size}: sides mirror`, l.x, work.width - (r.x + r.width));
        check(`two-up ${size}: equal widths`, l.width, r.width);
    }
    const sl = targetFrame(work, twoUpRect(work, 'small', 'left'));
    const lr = targetFrame(work, twoUpRect(work, 'large', 'right'));
    const between = lr.x - (sl.x + sl.width);
    print(`  info between small-left and large-right: ${between}px ` +
          `(${between > 0 ? 'gap' : 'overlap'})`);
    check('large is vertically centred', lr.y, work.height - (lr.y + lr.height));
}
print(failures ? `\n${failures} FAILURES` : '\nall checks passed');
