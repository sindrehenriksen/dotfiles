---
name: accessibility-check
description: 'The WCAG 2.2 AA check for a change people see or operate (a web UI, widget, dashboard or docs site), read from the diff and source, with what only the running page can show marked as such. USE FOR: verifying a user-facing change before review, the accessibility step of a code review, judging a built surface, operating one as a user would. DO NOT USE FOR: backend-only or infrastructure changes, API message strings no screen renders, a formal conformance audit.'
---

# Accessibility check

WCAG 2.2 AA is the floor for every surface a person sees or operates. It holds in every theme value and language the code accepts, not only the default: light, dark and auto themes, and every shipped translation.

Check what the change touched and what it newly reaches. Asked to check a whole surface, take its controls and states one by one in the same way.

## From the diff and source

The list holds the failures most often found, not every AA criterion. Read the templates, styles, theme tokens and handlers, and follow a token to its value rather than trusting its name.

- **Name, role and state** (4.1.2): every control has an accessible name, the right role and its state (`aria-pressed`, `aria-expanded`, `aria-selected`). An `aria-label` on an element with no role is ignored. An icon-only control needs a name; a visible label or tooltip helps sighted users, and a tooltip must stay while hovered, be dismissible without moving pointer or focus (Escape is the usual way) and not vanish on its own (1.4.13).
- **Labels and structure** (1.3.1, 2.5.3, 3.3.2): a field has a programmatic label (`<label for>`, wrapping, or `aria-labelledby`), and a placeholder is never the only one. Where a control has visible text, its accessible name contains it. Headings, lists and regions are marked up as such.
- **Consistent names** (3.2.4): a control or region with the same function has the same name everywhere it appears. A stricter house rule worth keeping: the product is called the same in every string, visible or not.
- **Text alternatives** (1.1.1): an informative image or icon has a text alternative; a decorative one is hidden (`alt=""`, `aria-hidden`).
- **Contrast** (1.4.3, 1.4.11): text 4.5:1, large text (24 px, or 18.66 px bold) 3:1; the boundary that identifies a control (its border or its fill), meaningful icons and the focus indicator 3:1 against what is next to them. Compute the ratio from the actual colour pairs in every theme, including hover, focus, placeholder, warning and error states. Disabled controls, incidental text and logos are exempt. A pair not resolvable from source, such as a ring drawn on an unknown host page, is listed as not verified.
- **Colour alone** (1.4.1): an error or a selected state is not told apart by colour only, nor is a link inside text unless it has 3:1 against the text around it and hover and focus add another cue.
- **Focus visible and not hidden** (2.4.7, 2.4.11): no `outline: none` without a visible replacement, and nothing sticky or floating hides the focused element entirely.
- **Focus management** (2.4.3): when something opens, focus moves into it; when it closes or the focused element disappears, focus goes back to what opened it. Landing on `body` is the usual sign it was lost.
- **Keyboard** (2.1.1, 2.1.2): everything a pointer can do, a keyboard can. A click handler on a `div` or `span` needs a role, `tabindex` and key handling, or better, a `button`. Nothing traps focus. Stricter house rules worth keeping: a modal closes on Escape, an action is a `button` and a link goes somewhere; `href="#"` is neither.
- **Dragging** (2.5.7): anything done by dragging, such as resizing, also works with a single click or tap, not only by keyboard.
- **Target size** (2.5.8): at least 24x24 CSS px, or spaced so a 24 px circle on each does not overlap another. Links inside text are exempt, and so is a target with an equivalent control on the same page that meets the size.
- **Errors** (3.3.1, 3.3.2): an error says what is wrong in text, and a limit (length, format) is stated before the user hits it.
- **Status messages** (4.1.3): a new answer, an error, a loading state, a counter reaching its limit or a "copied" confirmation reaches a screen reader through a live region or role without moving focus.
- **Language** (3.1.1, 3.1.2): `lang` is set on the page or the host element to the language in use and changes with it; content in another language carries its own. Every string, `aria-label`s included, goes through the translations rather than being hard-coded.

Beyond AA, but a good habit: animation and smooth scrolling stop or shrink under `prefers-reduced-motion: reduce` (2.3.3).

## What needs the running page

When a change makes these matter, run them by hand in a local demo or dev build:

- **Keyboard walk-through**: Tab through every new or changed control in order, open and close what opens, and watch where focus lands.
- **Zoom and reflow** (1.4.4, 1.4.10): 200% browser zoom, and a 320 CSS px wide viewport, with no lost content and no two-way scrolling. Content that needs two dimensions, such as a table or a document editor, is exempt.
- **Screen reader**: NVDA or VoiceOver over the changed flow, listening for names, roles, states and announcements.
- **Browsers**: a style or API whose support differs between browsers (`:host-context()`, for one) is checked in Firefox and Safari as well as Chrome.
- **axe**: the axe DevTools extension against the page. It reaches into open shadow roots.

In a review these are listed as **not verified** unless someone ran them and said so.

## Output

Each finding names the element (`file:line` and the control), the criterion, what is wrong and the fix; for contrast, the pair and the ratio found. In a review, an AA failure is a should-fix, and a line marked as a house rule or beyond AA is a nit. Close with the runtime items left not verified. Nothing found is a real answer.
