# Backlog

## Out-of-process UI (share sheet, Safari sheets, SpringBoard)
Today these are detected and reported as unreadable (`_UIRemoteView`, `_UISceneHostingView`); system alerts go through axe.
Options, strongest first:
1. **Inject into every simulator process.** `xcrun simctl spawn <udid> launchctl setenv DYLD_INSERT_LIBRARIES …` + respring
   (the approach simject uses for SpringBoard). Each process serves its own screen; the CLI merges them by window z-order.
   First spike: does SpringBoard / the share-sheet service load the dylib, or does library validation refuse it?
2. **System accessibility (axe / AXPTranslator)** for remote areas: crosses processes, but the share sheet comes back as
   unlabelled groups (tested 2026-11-09).
3. **Screenshot + vision model** for remote areas only: slowest, but the only option on real devices.

## Map actions (MapKit)
In-process MKMapView: read the visible region (centre, span) and annotations with titles (including just off screen);
actions `map center <place|lat,lon>`, `map zoom in|out`, `map select <title>` as model operations. react-native-maps
uses MapKit by default; Google Maps SDK / Mapbox fall back to gestures. Wikipedia's Places tab is the test bed.

## Smaller
- A do-nothing button costs ~7 s (no change → axe fallback); could skip the fallback when the in-app touch hit the target.
- iPad Split View bounds are untested.
