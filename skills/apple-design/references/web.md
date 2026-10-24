# Apple design principles on the web

Section numbers refer to `../SKILL.md`. Tools: CSS, Pointer Events, `requestAnimationFrame`, and a spring library that re-targets from the current value and velocity (Motion / Framer Motion).

## §1 Response

Feedback lives on the press and it is instant.

```css
.button:active {
  transform: scale(0.97);
  transition: transform 100ms ease-out;
}
```

Audit debounces, artificial timers, transition waits, and the legacy 300 ms tap delay (`touch-action: manipulation`).

## §2 Direct manipulation

Use Pointer Events with `setPointerCapture` so tracking continues when the pointer leaves the element. Respect the grab offset. Keep a short history of positions and timestamps for velocity at release.

```js
el.addEventListener('pointerdown', (e) => {
  el.setPointerCapture(e.pointerId);
  const grabOffset = e.clientY - el.getBoundingClientRect().top;
  // track position + timestamp history for velocity
});
```

## §3 Interruptibility

- Avoid CSS transitions and `@keyframes` for anything gesture-driven. They cannot be grabbed and reversed mid-flight.
- On interrupt, read the live transform (`getComputedStyle` or the library's current value) and start the new animation from there.
- Choose a spring library that carries velocity through a re-target. This is the web equivalent of iOS additive animations.
- Run independent springs for X and Y.

## §4 Springs

Motion's `bounce` + `duration` spring API maps closely to Apple's damping + response.

```js
import { animate } from 'motion';

// Critically damped default (no overshoot)
animate(el, { y: 0 }, { type: 'spring', bounce: 0, duration: 0.4 });

// Momentum interaction, a little bounce because a flick preceded it
animate(el, { y: target }, { type: 'spring', bounce: 0.2, duration: 0.4 });
```

House style: `bounce: 0` everywhere by default; reserve bounce for momentum-driven interactions.

## §5 Velocity handoff

Motion and Framer Motion take absolute px/s velocity directly through the `velocity` option. For APIs that want relative velocity, normalise by remaining distance:

```
relativeVelocity = gestureVelocity / (targetValue - currentValue)
```

Example: element at `y=50`, target `y=150`, finger moving 50 px/s, so initial relative velocity is `50 / 100 = 0.5`.

## §6 Momentum projection

Apple's projection function from the *Designing Fluid Interfaces* sample code:

```js
// decelerationRate ≈ 0.998 for normal scroll feel; 0.99 for snappier
function project(initialVelocity /* px/s */, decelerationRate = 0.998) {
  return (initialVelocity / 1000) * decelerationRate / (1 - decelerationRate);
}

const projectedEndpoint = currentPosition + project(releaseVelocity);
const target = nearestSnapPoint(projectedEndpoint);
animateSpringTo(target, { velocity: releaseVelocity });
```

Good bottom sheets and carousels (Vaul, Embla) already do this.

## §7 Spatial consistency

Set `transform-origin` to the trigger so popovers and menus scale from their source, not their centre. Mirror the easing on reversible transitions with inverse cubic-bézier control points.

## §9 Rubber-banding

```js
function rubberband(overshoot, dimension, constant = 0.55) {
  return (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot));
}
```

## §10 Gesture feel

- Tap: highlight on `pointerdown`, commit on `pointerup`, about 10 px of hit padding, cancel on drag-away.
- Drag: about 10 px threshold before committing to a direction.
- Avoid `swipeleft`-style events that report only a final state.

## §11 Frame-level smoothness

`requestAnimationFrame` is the display-synced clock (Apple's `CADisplayLink`). Animate only `transform` and `opacity`. Hint with `will-change` where motion is imminent.

## §12 Materials and depth

```css
.toolbar {
  background: rgba(255, 255, 255, 0.6);
  backdrop-filter: blur(20px) saturate(180%);
  border-top: 1px solid rgba(255, 255, 255, 0.4); /* bright top edge = light catching the material */
}
```

- Build nav, toolbars, and sheets as `backdrop-filter` layers with content scrolling underneath.
- Bigger surfaces: stronger blur and deeper shadow. Consider heavier shadow over busy content.
- Vibrancy: higher contrast, slightly heavier weight, a small letter-spacing bump over blurred surfaces.
- Scroll edge effect: a mask-image gradient where content meets floating chrome, not a 1 px border.
- Materialise: animate `backdrop-filter` blur radius and `transform: scale()` together with opacity.

## §13 Multimodal feedback

Trigger the Vibration API and any audio on the same frame as the visual commit. Do not let a CSS transition lag them.

## §14 Reduced motion and accessibility

```css
@media (prefers-reduced-motion: reduce) {
  .sheet { transition: opacity 200ms ease; transform: none !important; }
}
@media (prefers-reduced-transparency: reduce) {
  .toolbar { background: white; backdrop-filter: none; }
}
@media (prefers-contrast: more) {
  .toolbar { background: white; border: 1px solid currentColor; }
}
```

Ease dark/light theme changes rather than jumping.

## §15 Typography

```css
:root { font: 100%/1.5 system-ui, sans-serif; } /* body: system font, comfortable leading */

.display {
  font-size: clamp(2rem, 5vw, 4rem);
  line-height: 1.05;        /* tight leading for large text */
  letter-spacing: -0.02em;  /* negative tracking as it grows */
  font-optical-sizing: auto;
}
```

Spacing in `rem` or `em` so a larger user font size does not break layout.
