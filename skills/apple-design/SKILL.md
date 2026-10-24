---
name: apple-design
description: Apple's approach to fluid, physical interface motion and design foundations, platform-neutral with SwiftUI and web mappings. Use when building or reviewing gesture-driven UI, springs, drag/swipe/sheet interactions, interruptible transitions, translucent materials and depth, typography (tracking, leading, Dynamic Type), reduced motion, multimodal feedback, or the design principles (purpose, agency, familiarity, simplicity, craft) behind Apple-style interfaces.
---

# Apple Design

## Overview

Principles distilled from Apple's WWDC design talks, chiefly *Designing Fluid Interfaces* (2018), *Designing Audio-Haptic Experiences*, *The Details of UI Typography* (2020), and *Principles of Great Design* (2026). This file is platform-neutral. For API mappings read:

- `references/swiftui.md` for SwiftUI and UIKit.
- `references/web.md` for CSS, Pointer Events, and spring libraries.

The through-line: **an interface feels alive when motion starts from the current on-screen value, inherits the user's velocity, projects momentum forward, and can be grabbed and reversed at any instant.** Springs make all of this natural because they are interruptible and velocity-aware by construction.

Apple frames design as serving four human needs: safety and predictability, understanding, achievement, and joy. Every rule below serves one of them.

## When to use this skill

- Designing or reviewing any interaction a user can drag, flick, swipe, or dismiss.
- Choosing animation curves, spring parameters, or transition directions.
- Deciding where translucent materials, scrims, and shadows belong.
- Setting type sizes, tracking, and leading.
- Adding haptics or sound.
- Handling reduced motion, reduced transparency, or increased contrast.
- Judging whether a feature or control earns its place.

Pair with the platform skill that owns the code: `swiftui-ui-patterns`, `swiftui-liquid-glass`, or `swiftui-performance-audit` for SwiftUI.

## 1. Response: kill latency

The moment lag appears, directness falls off a cliff.

- Respond on press, not on release. Highlight a control the instant it is touched.
- Audit every debounce, artificial timer, and transition wait on the input path.
- Feedback is continuous during the interaction, not only at the end. A drag, slider, or drawer updates 1:1 with the pointer the whole way.

## 2. Direct manipulation: 1:1 tracking

Touch and content move together. Respect the offset from where the user grabbed, never snap to the element's centre on grab. Keep a short position and timestamp history so velocity is known at release.

## 3. Interruptibility: the most important principle

The thought and the gesture happen in parallel. Every animation must be interruptible and redirectable at any moment.

- Never lock out input during a transition.
- Always animate from the presentation (current on-screen) value, never from the logical target. Starting from the target causes a visible jump on interrupt.
- Avoid fixed-duration, pre-scripted animations for anything gesture-driven. They cannot be grabbed mid-flight.
- When a gesture reverses, blend velocity instead of hard-cutting it. Replacing one animation with another at a reversal creates a velocity discontinuity, a "brick wall".
- Decompose 2D motion into independent X and Y springs. A single spring on a 2D distance desyncs when the axes have different velocities.

## 4. Behaviour over animation: use springs

Think of animation as a conversation between the user and the object, not something prescribed by the interface. A spring responds to new input because new input only changes the target.

Apple replaced the physics triplet (mass, stiffness, damping) with two designer-facing parameters:

- **Damping ratio** controls overshoot. `1.0` is critically damped with no bounce. Below `1.0` overshoots. Lower is bouncier.
- **Response** is roughly how long the value takes to approach the target, in seconds. Lower is snappier. It is not a duration; settle time emerges from the parameters.

Defaults:

- Start most UI at damping `1.0`. Graceful and non-distracting.
- Add bounce (damping about `0.8`) only when the gesture itself carried momentum: a flick, a throw, a drag release. Overshoot on a menu that faded in feels wrong. Overshoot on a card you flicked feels right.

Values Apple ships:

| Interaction | Damping | Response |
| --- | --- | --- |
| Move or reposition (Picture in Picture) | `1.0` | `0.4` |
| Rotation | `0.8` | `0.4` |
| Drawer or sheet | `0.8` | `0.3` |

## 5. Velocity handoff

When a gesture ends, the animation continues at the finger's exact velocity so there is no seam between dragging and animating. Pass the release velocity as the spring's initial velocity. Some APIs want it normalised by remaining distance:

```
relativeVelocity = gestureVelocity / (target - current)
```

## 6. Momentum projection

Take a small input and make a big output. Do not snap to the nearest boundary from the release point. Project where the gesture is going, then snap to the target nearest that projected point. This is what makes a flick feel like a throw.

Apple's projection, from the *Designing Fluid Interfaces* sample code:

```
project(velocity, decelerationRate) = (velocity / 1000) * decelerationRate / (1 - decelerationRate)
```

`decelerationRate` is about `0.998` for normal scroll feel and `0.99` for snappier. This is exponential decay, not the textbook `v² / 2a`.

Decide commit versus reverse by the **sign of the velocity** at release, not by how far the element has travelled.

## 7. Spatial consistency

If something disappears one way, it emerges from where it came.

- Enter and exit along the same path. A panel that slides in from the right dismisses to the right.
- Anchor presentations to their source. A menu, popover, or sheet originates from the control that triggered it.
- Mirror the easing on reversible transitions so the return path matches the outbound path.

## 8. Hint in the direction of the gesture

People predict a final state from a trajectory. Intermediate frames should telegraph where things are going. Control Center modules grow up and out toward the finger.

## 9. Rubber-banding

At an edge, resist progressively instead of stopping hard. A hard stop reads as frozen. Continuous resistance reads as responsive, with nothing more here.

```
rubberband(overshoot, dimension, c = 0.55) = (overshoot * dimension * c) / (dimension + c * |overshoot|)
```

## 10. Gesture feel checklist

- Tap: highlight on touch-down, commit on touch-up, about 10 pt of hysteresis, allow cancel by dragging away and back.
- Drag or swipe: require a small movement threshold (about 10 pt) before committing to a direction, then track 1:1.
- Recognise all plausible gestures in parallel from the first move, then cancel the losers once intent is clear. Avoid recognisers that report only a final state.
- Minimise disambiguation delays. Double-tap detection delays single taps, so pay that cost only where double-tap exists.

## 11. Frame-level smoothness

Smoothness is about what is in the frames, not only frame rate. Keep per-frame positional change below the strobing threshold. For very fast motion a subtle stretch or blur reads better than a sharp streak. Animate only cheap properties (transform, opacity, their platform equivalents).

## 12. Materials and depth

Translucent materials are a floating functional layer that brings structure without stealing focus.

- Build bars, toolbars, and sheets as translucent layers with content scrolling underneath, not opaque strips.
- Material weight encodes hierarchy. Heavier materials separate structural regions (sidebars). Lighter materials draw attention to interactive elements. Never stack a light translucent surface on another; legibility collapses.
- Bigger surfaces read as thicker: stronger blur and a deeper shadow than small chips.
- Dim to focus, separate to keep flow. A modal task pairs the surface with a dimming scrim and pushes the background back. A parallel, non-blocking panel uses translucency and offset without a scrim. Stacked sheets progressively dim and push back each parent.
- Vibrancy keeps text legible over changing backgrounds. Over translucent surfaces use higher contrast and slightly heavier weight, never flat grey. Put colour on a solid layer, not on the translucent foreground.
- Scroll edge effects, not hard dividers. Where content meets floating chrome, fade with a small blur or gradient mask rather than a 1 pt border.
- Materialise, do not just fade. Animate blur and scale together on enter and exit so the surface reads as a material arriving.

## 13. Multimodal feedback

Three rules for combining motion, sound, and haptics:

1. **Causality.** It must be obvious what caused the feedback. Fire on the causal event (the toggle flipping, the item snapping home) and match its character to the action's physicality.
2. **Harmony.** Visual, sound, and haptic fire on the same frame. Latency between them destroys the illusion.
3. **Utility.** Add feedback only where it earns its place: success, error, commit, snap. Over-feedback trains people to ignore all of it.

## 14. Reduced motion and accessibility

Reduced motion means a gentler, non-vestibular equivalent, not no feedback. Respond to three independent signals:

- **Reduce motion:** replace slides, springs, and parallax with short cross-fades. Drop overshoot. Keep opacity and colour changes that aid comprehension.
- **Reduce transparency:** make translucent surfaces frostier or solid. Raise background opacity, drop the blur.
- **Increase contrast:** near-solid backgrounds with a defined, contrasting border.

Also avoid full-viewport moving backgrounds, slow loops near one cycle per five seconds, and abrupt brightness jumps. Make large moving objects semi-transparent while they travel.

## 15. Typography

- Tracking is size-specific, never one value for all sizes. Large display text wants negative tracking. Small text wants slightly positive tracking. Tighten headings, leave body near zero.
- Leading tracks size inversely. Tight on large headings, looser on body. Increase it for scripts with tall ascenders and descenders.
- Build hierarchy from weight, size, and leading as a set, not size alone. Emphasise with weight.
- Respect the user's text-size setting. Scale layout with the text.
- Default to the platform system font. It already ships optical sizing, tracking tables, and legibility tuning. Override only with a reason.

## 16. Design foundations: the eight principles

1. **Purpose.** Make with intention and decide what not to build. Every feature spends the user's time, attention, and trust.
2. **Agency.** Keep people in control. Offer choices, make undo easy, and confirm only genuinely destructive, irreversible actions.
3. **Responsibility.** Act in the user's interest. Ask for permissions at the right moment, only for what is needed. Anticipate misuse and harm, especially with AI. Cut a feature whose risk outweighs its value.
4. **Familiarity.** Build on what people know. Use metaphors that are neither too literal nor too abstract, and honour their physics. Things that look the same must behave the same and live in the same place. Break a pattern only when you can prove the replacement is better.
5. **Flexibility.** Design for different contexts, devices, and abilities. Adapt to the platform. When no single layout fits everyone, let people personalise.
6. **Simplicity, not minimalism.** Strip the unnecessary so the core purpose shines. Use hierarchy so the most important thing is the most obvious. Show the common path first and advanced options one level deeper. Sometimes adding context simplifies.
7. **Craft.** Every spacing, timing, and alignment value is a deliberate choice you can defend. Jitter, misalignment, and layouts that break on rotation read as carelessness.
8. **Delight.** The result of the other seven, not confetti on top. Decide the emotion you want and reinforce it in every decision.

Tactical rules that serve them:

- Feedback comes in four kinds: status, completion, warning, error. Validate inline, not on submit.
- Wayfinding. Every screen answers: Where am I? Where can I go? What is there? How do I get out?
- Grouping and mapping. Proximity implies relationship. Place a control near what it affects. If a label is needed to explain a control, the mapping is weak.
- Direct, specific labels beat safe generic ones. "Library" over "Home".

## 17. Process

- Prototype interactively. An interactive demo is worth a million static designs, and it sets a concrete bar for the final implementation.
- Design interaction and visuals together. You should not be able to tell where one ends and the other begins.
- Review motion with fresh eyes, in slow motion or frame by frame, to catch what is invisible at full speed.

## Quick reference

| Need | Technique | Value |
| --- | --- | --- |
| Default UI spring | Critically damped | damping `1.0`, response `0.3` to `0.4` |
| Momentum or flick spring | Slight bounce | damping about `0.8`, response `0.3` to `0.4` |
| Gesture to spring | Hand off release velocity | `velocity / (target - current)` if normalised |
| Flick landing point | Project momentum | `current + (v / 1000) * d / (1 - d)`, `d` about `0.998` |
| Interrupt cleanly | Start from presentation value | read the live on-screen value |
| Reversal | Carry velocity through re-target | spring that blends velocity |
| Reverse vs. commit | Velocity sign at release | not position |
| Boundary | Rubber-band | progressive resistance |
| Feedback | On press, continuous | never only at the end |
| Translucent chrome | Material layer | content scrolls under |
| Type tracking | Size-specific | tighten large text, body near zero |
| Reduced motion | Cross-fade | no slide, no spring, no overshoot |
