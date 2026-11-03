# Fix log

## 2026-11-03 Window/level did nothing on ultrasound

Symptom: left-drag on a color ultrasound changed nothing; the overlay showed no WL/WW.
Cause: `Viewport.adjustWindow` returned early for color frames, and the renderer ignored the window for RGB. Separately, drag deltas came from `NSEvent.deltaX/Y`, which some event sources leave at 0, and the additive width step could collapse the width to 1 (all white).
Fix: color frames get the same linear window per channel (brightness and contrast); deltas come from pointer positions; width changes by a factor (`exp(dx * 0.004)`) with a floor of 2. Verified with real pointer drags and scrolls through computer use.
Rule: every viewport gesture works on grayscale and color images, and gesture deltas come from positions, never from `NSEvent.deltaX/Y`.

## 2026-11-03 An empty "Viewer" window reopened at launch

Symptom: after a restart, a blank Viewer window appeared.
Cause: SwiftUI restored the viewer `WindowGroup` with a study id from another store.
Fix: `.restorationBehavior(.disabled)` on the viewer windows.
Rule: windows bound to a database id never restore.

## 2026-11-03 Zoomed or panned image covered the series strip

Symptom: after zoom or pan, the ultrasound image drew over the series thumbnails.
Cause: the viewport's layer did not clip its image sublayer.
Fix: `masksToBounds` on the viewport layer and `.clipped()` on the SwiftUI view.
Rule: every image surface clips to its own bounds.

## 2026-11-03 Opening thousands of files made the window flicker and resize

Symptom: opening 8,671 files with Kidicom (Dock, Finder, `open -a`) made the worklist window flicker, resize, and stop answering; files sent while an import ran were dropped.
Cause: SwiftUI's app delegate adaptor routes Open Documents through its window controller, which activates and orders a window once per file. The importer also ignored requests while busy.
Fix: Kidicom installs its own Open Documents Apple event handler (before and after SwiftUI sets up), gathers bursts for half a second into one import, and queues requests that arrive during an import.
Rule: file-open events go straight to the importer, never through SwiftUI's window routing; imports queue, never drop.
