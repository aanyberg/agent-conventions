# Apple design principles in SwiftUI

Section numbers refer to `../SKILL.md`. Prefer the newest API that fits the deployment target and call out the minimum OS when a pattern depends on it. Use web search to confirm current Apple Developer documentation when an API may have changed.

## §1 Response

Press feedback belongs in a `ButtonStyle`, driven by `configuration.isPressed`, so it fires on touch-down.

```swift
struct PressableStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.spring(duration: 0.15, bounce: 0), value: configuration.isPressed)
  }
}
```

Audit for latency: `DispatchQueue.main.asyncAfter`, `Task.sleep` before UI updates, `.onTapGesture(count: 2)` next to single taps, and `.debounce` on anything driving visible state.

## §2 Direct manipulation

Use `DragGesture` with `@GestureState` for transient offset so the value resets on cancel. Store the grab offset on the first change. `minimumDistance: 10` gives the hysteresis from §10.

```swift
@GestureState private var dragOffset: CGSize = .zero
@State private var position: CGSize = .zero

var drag: some Gesture {
  DragGesture(minimumDistance: 10)
    .updating($dragOffset) { value, state, _ in state = value.translation }
    .onEnded { value in
      // see §5 and §6
    }
}
```

Offset the view by `position + dragOffset` so the content stays glued to the finger.

## §3 Interruptibility

SwiftUI animations are additive and retarget from the presentation value by default. The rules therefore become:

- Drive gesture-related state with `withAnimation(.spring(...))` or `.animation(_:value:)`. Never `.linear` or `.easeInOut` on anything a finger can grab.
- Never chain animations with timers. A timer-driven second step cannot be interrupted.
- Never reset state to a logical value before animating. Set the target once and let the spring carry.
- Split 2D motion into two values (`x`, `y`) or animate `CGSize` and let SwiftUI interpolate the components independently.
- `Transaction` and `.transaction { $0.animation = ... }` override animation per update when a parent `withAnimation` would otherwise apply the wrong curve.

Custom simulations use the `Spring` struct (iOS 17): `Spring(duration:bounce:)` exposes `value(target:initialVelocity:time:)` and `settlingDuration` for `TimelineView` or `KeyframeAnimator` driven motion.

## §4 Springs

`Animation.spring(duration:bounce:)` maps directly to Apple's response and damping. `bounce: 0` is critically damped (damping `1.0`). `bounce` about `0.2` is damping about `0.8`. `duration` is the perceptual response, not a hard stop.

| Apple value | SwiftUI |
| --- | --- |
| damping `1.0`, response `0.4` | `.spring(duration: 0.4, bounce: 0)` or `.smooth(duration: 0.4)` |
| damping `0.8`, response `0.4` | `.spring(duration: 0.4, bounce: 0.2)` or `.snappy(duration: 0.4, extraBounce: 0.05)` |
| damping `0.8`, response `0.3` | `.spring(duration: 0.3, bounce: 0.2)` |

Presets: `.smooth` (no bounce), `.snappy` (slight bounce), `.bouncy` (more). `.interactiveSpring` is tuned for tracking during a drag. Use `.spring(response:dampingFraction:)` only when matching an existing UIKit value.

## §5 Velocity handoff

`DragGesture.Value.velocity` (iOS 17) is the release velocity in points per second. Pass it with `withAnimation(.spring(...))` from the current offset; SwiftUI carries the gesture's observed velocity into the animation when the animated value was tracking the gesture 1:1. For a custom `Spring`, pass it as `initialVelocity`.

## §6 Momentum projection

`DragGesture.Value.predictedEndTranslation` and `predictedEndLocation` already apply Apple's deceleration projection. Choose the snap target nearest the predicted end, not nearest the current position.

```swift
.onEnded { value in
  let projected = position.height + value.predictedEndTranslation.height
  let target = snapPoints.min(by: { abs($0 - projected) < abs($1 - projected) })!
  withAnimation(.spring(duration: 0.3, bounce: 0.2)) { position.height = target }
}
```

For scroll views, `.scrollTargetBehavior(.viewAligned)` or `.paging` does the projection and snapping. For a custom rate, `UIScrollView.DecelerationRate.normal` is `0.998` and `.fast` is `0.99`.

Commit versus reverse: compare the sign of `value.velocity.height` (or `width`), not the travelled distance.

## §7 Spatial consistency

- `.transition(.move(edge:))` is symmetric by default. Use `.asymmetric` only when the design deliberately differs and say why.
- `.popover` and `.confirmationDialog` anchor to their source automatically. For custom presentations use `matchedGeometryEffect` or `navigationTransition(.zoom(sourceID:in:))` with `matchedTransitionSource` (iOS 18) so the destination grows from its trigger. See `swiftui-ui-patterns/references/matched-transitions.md`.
- Sheets with `.presentationDetents` already dismiss along the entry path.

## §8 Hint toward the gesture

Drive intermediate state from a single normalised progress value derived from the gesture or scroll offset, so every property (offset, scale, opacity, blur) points at the same outcome. `swiftui-ui-patterns/references/scroll-reveal.md` is the worked example.

## §9 Rubber-banding

`ScrollView` and `List` rubber-band natively. For a custom drag past a bound:

```swift
func rubberband(_ overshoot: CGFloat, dimension: CGFloat, c: CGFloat = 0.55) -> CGFloat {
  (overshoot * dimension * c) / (dimension + c * abs(overshoot))
}
```

Apply it to the translation beyond the limit, keep 1:1 inside the limit.

## §10 Gesture feel

- `Button` already highlights on touch-down and cancels on drag-away. Prefer it over `.onTapGesture` for anything that is a button.
- `.simultaneousGesture` recognises in parallel. `.highPriorityGesture` and `.exclusively(before:)` cancel losers once intent is clear.
- `.contentShape(.rect)` with padding extends the hit target.
- Keep `.onTapGesture(count: 2)` away from single-tap controls unless double-tap is essential.

## §11 Frame-level smoothness

Cheap to animate: `offset`, `scaleEffect`, `rotationEffect`, `opacity`, `blur` on small views. Expensive: `frame`, `padding`, layout-affecting changes, `blur` on large hierarchies. `swiftui-performance-audit` covers the diagnosis. Use `drawingGroup()` only after measuring.

## §12 Materials and depth

- System materials: `.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial`, `.thickMaterial`, `.bar`. Heavier material for structural regions, thinner for small interactive chips. Never place one material directly on another.
- iOS 26 Liquid Glass: `.glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`. `swiftui-liquid-glass` owns the API rules; this skill owns when glass is appropriate and how prominence maps to hierarchy.
- Vibrancy: text over a material uses `.foregroundStyle(.primary)` or `.secondary`, which are vibrant by default. Do not hard-code grey. Put tint colour on a solid layer under the material, not on vibrant text.
- Scroll edge effects: `.scrollEdgeEffectStyle(_:for:)` (iOS 26). Before that, `.safeAreaInset` with a gradient mask rather than a `Divider`.
- Dim to focus: `.presentationBackground(.regularMaterial)` plus the system scrim for modal sheets. Non-blocking panels use `.presentationBackgroundInteraction(.enabled)` and no scrim.
- Materialise: animate `blur(radius:)` and `scaleEffect` together with `opacity` on enter and exit.

## §13 Multimodal feedback

`.sensoryFeedback(_:trigger:)` (iOS 17) fires on the same update as the state change, which satisfies harmony. Attach it to the causal state, not to a parent view's unrelated state.

```swift
.sensoryFeedback(.selection, trigger: selectedIndex)
.sensoryFeedback(.success, trigger: didSave) { _, new in new }
```

For custom intensity or pre-iOS 17, `swiftui-ui-patterns/references/haptics.md` shows the `UIFeedbackGenerator` approach. Reserve `.success`, `.error`, `.impact` for commit, snap, and failure. Do not fire on every pixel of a drag.

## §14 Reduced motion and accessibility

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
@Environment(\.accessibilityReduceTransparency) private var reduceTransparency
@Environment(\.colorSchemeContrast) private var contrast
@Environment(\.accessibilityDimFlashingLights) private var dimFlashing
```

- Reduce motion: swap `.move` and spring transitions for `.opacity` with a short `.easeInOut(duration: 0.2)`. Set `bounce: 0`.
- Reduce transparency: swap materials for a solid `Color` background. `glassEffect` and system materials already respond, custom `blur` does not.
- Increased contrast: `contrast == .increased` adds a border and raises background opacity.
- Dynamic Type is accessibility too, see §15.

A `ViewModifier` such as `.motionAware(_:)` that reads these once and picks the animation keeps the checks out of every view.

## §15 Typography

- System text styles (`.largeTitle` through `.caption2`) carry SF's optical sizes and size-specific tracking. Prefer them over `.system(size:)`.
- When a fixed size is unavoidable, add `.tracking(-0.5)` or similar on large display text and leave body at zero. `.kerning` adjusts per character pair, `.tracking` applies uniformly; use `.tracking` for the size-specific rule.
- `.lineSpacing` adds to the font's default leading. Tighten headings, loosen body.
- Hierarchy by weight: `.fontWeight(.semibold)` on the emphasised line rather than a larger size.
- Dynamic Type: use `@ScaledMetric` for spacing and icon sizes that should grow with text. Cap with `.dynamicTypeSize(...DynamicTypeSize.accessibility2)` only where layout truly cannot adapt, and prefer `ViewThatFits` to reflow. `swiftui-ui-patterns/references/theming.md` covers theme tokens.

## §16 Design foundations

These are review questions, not APIs. When reviewing a SwiftUI screen ask:

- Purpose: what would be lost if this control were removed?
- Agency: is there an undo, and is the confirmation reserved for destructive actions? `.confirmationDialog` with a `.destructive` role, not an alert for everything.
- Familiarity: does close, back, and primary action live where the platform puts them? `.toolbar` placements, not custom bars.
- Simplicity: is the common path visible and the advanced path one level deeper (a `Menu`, a `DisclosureGroup`, a secondary screen)?
- Feedback kinds: status via `ProgressView` or `.redacted`, completion via `.sensoryFeedback` and a transient overlay, warning before the problem, error inline next to the field.
- Wayfinding: a title, a visible way back, and a visible primary action on every screen.
- Labels: `Label` text names the content ("Library"), not a generic umbrella ("Home").

## §17 Process

- Prototype in a `#Preview` and iterate live. `ios-simulator-browser` renders previews with hot reload outside Xcode Canvas.
- Review motion frame by frame with Simulator's Debug > Slow Animations (⌘T), or record with `ios-debugger-agent` screenshots at each step.
- Validate interruptibility by hand: start a transition, grab it mid-flight, reverse it. If it jumps or waits, it fails §3.
