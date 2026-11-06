# Kidicom app icon: brief for proposals

Kidicom is a light, native macOS DICOM viewer (ultrasound, X-ray, CT, MR) for radiologists, built in SwiftUI. Name: "Kidicom" ("kid" + "DICOM").

## Direction from the owner

Playful, something to do with "kid". A mix of:
- Joan Miró: free organic shapes, primary colors (red, blue, yellow, green) on a light field, black lines, stars and dots. Inspiration only; do not copy any real artwork.
- Toy building bricks: chunky blocks with round studs on top. No brand name, logo, or trademarked shape details.
- Byte blocks: pixels, voxels, bits stacked like blocks (a nod to imaging and data).

It must still read as a medical image viewer at a glance (a hint of a scan, a slice, a cross-section, an eye, a skeleton, or a layered stack is welcome) and stay legible at 16 and 32 pt.

## Format (macOS 26 Liquid Glass)

Each proposal is an Icon Composer file: a folder `<Name>.icon/` with `icon.json` and SVG layers in `Assets/`, each SVG on a 1024 x 1024 canvas. macOS adds glass, highlights, shadow, mask, and the dark, tinted, and clear looks; do not draw those. Format rules: ~/.claude/skills/app-icon/SKILL.md and the current app icon at Icon/AppIcon.icon (read it, do not edit it). Two to four layers is plenty. Keep shapes bold; thin lines vanish at small sizes.

Render each proposal with Icon Composer's ictool (inside Xcode):

    ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
    "$ictool" <path>.icon --export-image --output-file <out>.png --platform macOS --rendition Default --width 256 --height 256 --scale 2

Renditions to export: Default, Dark, TintedDark, ClearLight at 256, and Default at 32 and 16.
