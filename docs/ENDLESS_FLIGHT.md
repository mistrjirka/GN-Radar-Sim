# Endless flight, mechanical scan guides and heading control

Implemented on `homer`, branch `jirka-cockpit-game`. The latest user request supersedes the finite-sortie default: this iteration prioritizes the endless exploration mechanism, scan controls and gradual flight. The old finite scenarios remain available for regression testing.

## Start and controls

```sh
cd ~/programovani/GN-Radar-Sim
./play-cockpit.sh
# Previous finite content:
./play-cockpit.sh -- --sortie
./play-cockpit.sh -- --reference
```

The default is open flight. The flash/shutters/DEFCON introduction stays, followed by exploration rather than a forced objective/egress route. There is no play-area wall, fuel countdown or automatic mission completion. Existing defensive controls are practice placeholders: finite stores remain, but abstract damage cannot force this mechanism test to end. This is not a finalized survival or combat balance.

| Control | Effect |
| --- | --- |
| Shift-click a direction on the paper | Command a heading; the pilot turns gradually and then holds it, including after passing the clicked location |
| A / D or COURSE buttons | Trim the commanded heading |
| Ctrl+Shift-click | Optional queued navigation fix, separate from direction-hold |
| Click paper | Move the four mechanical scan-guide bars |
| Mouse wheel over paper / AREA | Change selected width, 400–4000m in 200m steps |
| RES on upper radar bezel / 1, 2, 3 | FAST / MED / FINE acquisition resolution |
| Space / SCAN | Acquire the geographic area currently between the bars |
| Z | Change paper scale, independently of scan width/resolution |
| F1 / F2 / F3 / F4 | Inspect RWR / radar / paper / return to station |
| B / H | Local chart notes / general controls and radio journal |

Resolution and area are visible on the **physical radar bezel**, not composited into the radar returns. FAST corresponds to nominal 6m range / 8m azimuth response, MED to 4m / 5m, and FINE to 2m / 2.5m. These are settings of the statistical simulation, not a certification of real radar performance. A coarse acquisition does less numerical work; a newly visited region also requires terrain generation. Actual request time can therefore differ even at the same setting.

## Four real mechanical bars

`chart_mechanism.gd` builds four native Godot objects above the paper: two horizontal bars reaching the side rails and two vertical bars reaching the top/bottom rails. Each has a thin metal edge, engraved divisions and slider feet. Vertical bars sit slightly above horizontal bars at their crossings. There is no painted glowing rectangular selection or corner dots.

The intersections define the scan square. The bars remain at their selected instrument positions as paper rolls underneath; clicking moves them and changing area adjusts their spacing. The scan freezes the geographic area under those intersections at request time. The old radar image remains unchanged until its replacement arrives. Large scan widths automatically fit the paper scale so the hardware does not silently show a different-sized area than the acquisition requests.

The aircraft index shows current heading. The pencilled line shows commanded direction. SET and HDG are displayed separately below the chart. A new command never directly assigns the actual heading or aircraft position.

## Endless generation mechanism

`endless_terrain.py` evaluates terrain from absolute coordinates and the seed. Terrain includes drainage corridors, varied relief, woodland crowns, fields, roads and local roughness. `endless_features.py` owns deterministic geographic feature cells containing compounds, six-launcher sites, bridges and uncertain intelligence. Revisiting a cell regenerates the same content; it is not a repeated image tile.

`endless_world.py` builds only the selected detailed radar patch and the paper needed nearby. A **16 × 20 km rolling paper sheet is a cache window, not the world size**. `world_stream.gd` requests the next sheet ahead of flight, and retains the old sheet until the new one is decoded. Coincident paper samples are generated on one absolute grid, including contours and grain; overlapping sheets are tested for exact pixel agreement.

The same world definitions supply radar fields and the paper map. The paper does not rasterize exact enemy positions: it receives offset, broad suspected areas. The separate game state gets nearby emitters for the existing threat rules; the RWR still receives only bearing, strength, identifier and tracking state.

Memory remains bounded by three detailed radar patches and a 96-cell feature cache. Only three recent streamed paper PNG/manifest pairs are retained. Old regions are regenerated from their seed and coordinates when revisited. Suppressed emitters retain their game IDs; silence does not remove physical structures from radar.

This is unbounded procedural **chart/radar terrain**, not an infinite high-resolution optical mesh or finished campaign. The initial exterior scene and cockpit art remain the existing assets. Global coordinates are double precision, with a floating local origin for Godot navigation; finite machine precision still exists. Long-distance tests are finite evidence, not a claim to have run forever.

## Gradual turns

`heading_control.gd` owns a small, independently testable heading controller. It accelerates the turn rate, caps it and reduces it approaching the commanded heading. Current values are 4 degrees/second maximum and 2 degrees/second² turn acceleration. They are deliberately fictional prototype handling values and are isolated from terrain and weapon rules.

When local navigation grows beyond about 8km, its origin recenters in 4096m increments. Paper coordinates, waypoints, local emitters and flight trail shift together; global aircraft/scan coordinates do not teleport. The existing finite mission modes retain their previous flight settings so those gameplay regressions remain meaningful.

## Responsiveness and image preservation

The existing approved radar source and phosphor shader remain untouched. Numerical acceleration still schedules the same tested SciPy operations. Chart generation and radar acquisition share one owned Python worker, with radar requests serviced before another queued chart job. Chart file decoding, request publication and status/raw-pixel reading are kept off the render thread. Only completed texture creation/upload and scene updates occur on the game thread.

A scan arriving while a chart job is already running may wait for that job. That affects acquisition latency, not cockpit frame rate; the current image and paper stay visible. No screenshot encoding runs in normal gameplay.

The old reference radar scene is still the image-regression fixture. New procedural landscapes are intentionally not pixel-identical to that old terrain. The simulation remains statistical/2.5D; small geometry, material strengths and multipath are approximate. Large selected areas also share a maximum 1536² scene grid, so a 4km view has coarser terrain sampling than a close-up.

## Verification

- `test_endless_world.py`: unrestricted coordinates, varied seeds, repeatable feature IDs/cache eviction, query-order-independent terrain, exact overlapping paper pixels, streamed sheet publication and real scans across resolution settings.
- `test_endless_flight.gd`: no snap, gradual turn/hold/reversal, long-distance floating origin, no fuel/area termination, suppressed-emitter persistence, physical guide dimensions and separate paper scale.
- `endless_driver.gd`: actual projected paper/control clicks, FAST/MED/FINE acquisitions, changing chart sheets, native rendering and photographed instrument inspection.
- `--endless-realtime --no-captures`: real-time flight and chart updates, without accelerated mission time or synchronous PNG cost.

```sh
python -m unittest discover -s game/cockpit/tests -p 'test_endless_world.py' -v
godot --headless --path . --script game/cockpit/tests/test_endless_flight.gd

godot --path . --max-fps 60 -- --endless-test \
  --capture-dir=/absolute/path/visual

godot --path . --max-fps 60 -- --endless-test --endless-realtime --no-captures \
  --capture-dir=/absolute/path/frame_test
```

Reports and screenshots live under `.radar_runtime/endless/`. Separate screenshot-run maxima from no-capture frame traces. Measurements apply to the tested host, seed, viewport and route; they are not a guarantee for every machine or indefinitely long session.

## Latest measured evidence

The final visual run travelled **28.33km**, installed **17 new paper sections**, performed two origin shifts and acquired five actual radar frames. The headless flight test crossed130km without a map/fuel end. The regression suites currently total **161 checks**, with protected source hashes unchanged.

The latest instrumented real-time run covered6.51km, four paper updates and5,238 rendered frame intervals at1600×900 on homer. Its p95 was18.06ms and maximum20.92ms, with no frames over33.3ms. Paper texture upload took3.33–3.74ms. An earlier real-time repeat had a short burst including a367.17ms interval; the same-code instrumented repeat did not reproduce it. That outlier remains in the supplied report: its cause is not established, and these results do not prove hitch-free behavior in every run.

On the latest moving-aircraft test, numerical scan calculation was about 0.43s FAST,1.03s MED and1.9–2.0s FINE. Fresh-terrain generation and image publication raised worker completion time to roughly2.5–4.2s for those particular requests. These were different frozen poses, not a same-scene comparative benchmark.

## Final measured validation of this iteration

- **188 passing checks** across mission/flight, origin shifting, guide geometry, chart loading/IPC, terrain continuity, scan acceleration and the original renderer. Test logs were checked for runtime errors as well as summary counters.
- The actual native-rendered exploration driver flew **28.52km**, installed **15 new paper sheets** and recentered the flight origin **twice**, without teleporting. Cruising was accelerated in the test only; screenshot writing was enabled and is not a normal-game frame-time measurement.
- A separate **87.2-second real-time** run rendered **5,224 intervals**, flew 6.51km and installed 4 sheets, with no screenshots or flight-time acceleration. Frame p95 **17.947ms**, maximum **22.053ms**, and **zero intervals above 33.33ms or 50ms**. Those measurements exclude scene construction before the first sampled frame. They are observations on homer, not a universal no-hitch guarantee.
- In that real-time run, radar calculation examples were **FAST 0.443s**, **MED 1.029s**, **FINE 1.89–1.99s**. New terrain cost 1.08–1.89s and file encoding about 0.1s; complete worker acquisitions took **2.54–3.82s**. Positions differ between sequential scans, so these are live examples rather than a controlled same-pose benchmark.
- Overlap tests verify identical chart pixels at coincident world positions; largest paper zoom has extra streaming margin. Old reference images and protected renderer/RWR/phosphor source hashes remain unchanged.
- Actual final screenshots of guide bars, visible resolution readout, gradual heading command and newly streamed terrain were opened and inspected. In the turn screenshot, SET 023 precedes HDG 004: it does not snap to the commanded direction.

Evidence: `.radar_runtime/endless/final_checks.json`, `final_visual/`, `final_realtime/`, and `delivery/raven_endless_validation.json`. The screenshot-enabled exploration run includes several >50ms capture intervals; they are retained in its JSON rather than presented as ordinary gameplay freezes.
