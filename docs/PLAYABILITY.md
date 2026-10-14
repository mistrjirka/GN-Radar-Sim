# Exploration controls and the current radar display

This supersedes older bearing-only RWR and returns-only/no-player-mark descriptions for **endless exploration**. Finite reference/sortie modes remain regression content. User requirements and corrections are retained in `USER_REQUESTS.md`.

## Play

```sh
cd ~/programovani/GN-Radar-Sim
./play-cockpit.sh
```

The aircraft marker is fixed **bottom-center**, pointing upward. The paper translates and rotates beneath it using the aircraft's actual heading, not the commanded heading. Shift-click a direction on paper to ask the pilot to turn; the aircraft follows a gradual curved path, then holds that heading. Ctrl+Shift-click can still append navigation fixes.

Click the paper to position four physical guide bars. Wheel/AREA changes their square width from 400 to 4000 metres; Z changes paper scale independently. RES is a knurled three-position rotary selector; 1/2/3 selects FAST/MED/FINE. Settings and status are on the bezel, not a digital menu inside the returns.

## Stable acquisition

SCAN/Space latches the ground center, size, heading, aircraft pose and resolution. Both paper projection and guide positions hold until the acquisition settles; the aircraft itself keeps flying and the warning receiver keeps updating. Area/zoom/resolution edits cannot silently change an in-flight acquisition. Completed chart sheets wait for the hold to release.

The full oriented square must lie ahead of the aircraft. Self/nadir, rear, side and out-of-range requests are refused before terrain allocation. Current fictional instrument limits are in `game/cockpit/scan_limits.json`: minimum 500m forward, +/-60 degrees, maximum 12km ground range, measured at the square's corners. These are gameplay constraints, not specifications for real equipment.

Heading-up is not a cosmetic rotation of a north-up scan: the selected terrain grid, directional scattering fields and acquisition pose are transformed together. Stored-image coordinates retain that acquisition orientation while the aircraft continues to turn.

## Whole image, gradually resolving detail

The user's latest correction is **not a wipe or travelling sweep**. Once the worker supplies the real frame, the complete image is visible, initially soft. Detail gradually resolves everywhere into the original acquired image. There is no blank half-screen or moving write edge.

The background transport creates filtered whole-image levels without changing the original grayscale bytes. The shader gradually selects finer levels, ending at the original base image. It adds no sharpening overshoot, fabricated structures or new returns. The existing CRT tint, barrel curvature, vignette and fine display lines remain.

This is explicitly a **display effect after computation**, not a claim that new radar measurements are progressively arriving. While computation runs, the previous complete frame remains visible. Display settling lasts 1.0/1.5/2.2 seconds for FAST/MED/FINE, separate from measured compute and terrain-generation time. New target marking becomes available once the image is fully resolved.

## Receiver and coordinate rounds

The left display uses the supplied visual direction: a circular green scope with cross axes, center/middle rings and bearing ticks. Radius represents an uncertain range estimate. The current receiver span is 20km; source-strength variation and quantization make the estimate imperfect. Its view receives estimates, not exact world-coordinate records. This is a fictional game receiver, not a claim that the photographed reference measures range this way.

Click a point on the completed radar image to mark it. M enables master arm; F/FIRE sends a provisional coordinate round to that marked point. No emitter selection is required and clicks do not snap to hidden sites. The coordinate comes from the clicked radar pixel and the stored scan's geometry, including CRT curvature, orientation and floating-origin conversion.

A launched round keeps its original destination if the player marks a different point. On arrival, the game tests the local impact area; missing does not auto-correct toward an emitter. Travel, range, impact area and damage remain replaceable fictional rules, not real guidance or weapon-delivery simulation.

## Ownership and verification

- `paper_chart.gd` / `world_stream.gd`: heading-up projection, stable acquisition hold and bounded sheet handoff.
- `radar_acquisition.gd`: request/frame identity and resolving lifecycle.
- `scan_geometry.gd` / `backend/scan_geometry.py`: matched forward-envelope and stored-image transforms.
- `radar_mailbox.gd`: background file transfer and filtered display levels; no game-state mutation.
- `analogue_radar.gdshader`: whole-field soft-to-resolved display and one user-authored marker.
- `range_receiver.gd` / `coordinate_weapon.gd`: receiver presentation and abstract point-destination projectile, respectively.

```sh
godot --headless --path . --script game/cockpit/tests/test_playability.gd
python -m unittest discover -s game/cockpit/tests -p 'test_*.py' -v
python -m unittest discover -s game/radar/tests -v
# Native shader checks: full field visible from the start; final pixels match.
godot --path . --script game/cockpit/tests/test_crt_resolving.gd
# Actual projected clicks, turn, scans, guide hold and coordinate-round interaction.
godot --path . -- --playability-test --capture-dir=/absolute/path/visual
# Same interaction path without screenshot readback for frame timing.
godot --path . -- --playability-test --no-captures --capture-dir=/absolute/path/timing
```

Native shader tests compare the fully resolved image against the original CRT shader, not only the saved raw radar bytes. Screenshot-enabled runs include readback/PNG costs and must not be presented as ordinary gameplay frame-time measurements. Infinite exploration is a generation mechanism; finite tests do not prove indefinite stability. The radar remains the approved statistical/2.5D approximation.
