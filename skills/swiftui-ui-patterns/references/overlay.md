# Overlay and toasts

## Intent

Use overlays for transient UI (toasts, banners, loaders) without affecting layout.

## Core patterns

- Use `.overlay(alignment:)` to place global UI without changing the underlying layout.
- Keep overlays lightweight and dismissible.
- Use a dedicated `ToastCenter` (or similar) for global state if multiple features trigger toasts.

## Example: toast overlay

```swift
struct AppRootView: View {
  @State private var toast: Toast?

  var body: some View {
    content
      .overlay(alignment: .top) {
        if let toast {
          ToastView(toast: toast)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task {
              try? await Task.sleep(for: .seconds(2))
              withAnimation { self.toast = nil }
            }
        }
      }
  }
}
```

## Design choices to keep

- Prefer overlays for transient UI rather than embedding in layout stacks.
- Use transitions and short auto-dismiss timers. Run the timer in `.task` so it cancels when the toast is replaced or swiped away, and let a drag dismiss it early (`apple-design` §3).
- Keep the overlay aligned to a clear edge (`.top` or `.bottom`).

## Pitfalls

- Avoid overlays that block all interaction unless explicitly needed.
- Don’t stack many overlays; use a queue or replace the current toast.
