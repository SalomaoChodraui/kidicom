# Architecture review, end of M2

5,225 lines (without the generated tag table). Largest file 293 lines. No file near 600 lines.

## Self-test split by feature  [Worth exploring]

Files: Sources/Kidicom/SelfTest.swift (261 lines, one function)
Signal: grows with every story; M3 and M4 will add volume and comparison checks.
Proposal: one `static func` per feature (`importChecks`, `viewerChecks`, `measureChecks`) called in order from `runIfRequested`.
Plan: split when M3 starts adding checks.

## Viewport geometry as the single source  [Done in M2]

`ViewportGeometry` (Kit, tested) now drives both the image layer and the measurement overlay, so drawing and hit testing cannot drift apart. MPR crosshairs in M3 should use it too.

## Top recommendation

Nothing urgent. Start M3 with the `Volume` module (previous review, card 1), and split the self-test when adding its checks.
