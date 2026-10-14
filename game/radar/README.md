# Ground-mapping radar: Godot integration

Branch: `jirka-radar-integration` in `/home/jirka/programovani/GN-Radar-Sim` on homer.

## Run

From the project root:

```sh
./play-radar.sh
```

Or open the project in Godot and run `game/radar/RadarFlight.tscn` (now the default main scene).
Godot starts one local Python worker automatically. No MCP server, account, API key, model inference or network access is needed. The worker computes scans while the 3D view remains interactive.

The tested host has all dependencies installed. On another machine:

```sh
python3 -m venv .venv-radar
.venv-radar/bin/pip install -r game/radar/backend/requirements.txt
RADAR_PYTHON="$PWD/.venv-radar/bin/python" ./play-radar.sh
```

Tested on Linux with Godot 4.7.2 and the Compatibility renderer. Other operating systems and packaged executable exports have not been tested. This is a playable radar-flight/validation prototype, not a finished combat game.

## Controls and screens

The prototype starts paused at the approved south viewpoint. Press **P / Fly** to orbit the test area; **A/D** changes bearing, **W/S** changes speed, **Q/E** changes altitude. **Space** requests a scan; **1/2/3** selects survey/map/detail. **Esc** exits and stops the owned worker.

The flight camera follows the aircraft; inspection cameras do not change its radar position. South/SW/Low buttons reproduce fixed observation angles. Radar imagery is north-up, and each scan freezes the aircraft position at request time. The old scan remains visible until its replacement finishes.

- **Approved valley:** the exact 2km × 2km domain-warped reference scene, with river terraces, craggy relief, field parcels, individual canopy features, six-launcher emplacement, bridge and three warehouses.
- **Earlier training range:** the previous 640m × 790m six-launcher / five-warehouse scene, embedded in a fixed 2km simulation canvas. Its original terrain and model placement are available for comparison.
- **Seed:** regenerates terrain noise deterministically; the landmark layout remains fixed for repeatable radar validation. The first generation of a seed takes tens of seconds and is cached. This prototype is not infinite streamed terrain.
- **Preferred 3D models:** the earlier v3 vehicle and radar designs at their original dimensions—cab, chassis, four canisters, wheels, control box, lattice mast and radome. The same primitive data feeds Godot and radar top-surface/material rasterization. Graded physical terrain pads keep equipment out of slopes and are shared by both views.
- **Reference radar geometry:** restores the original reference-size radar proxies for regression testing. Optical model dimensions are scaled accordingly. Changing modes reloads the shared scene.
- **Focus dropdown:** whole map, SAM, bridge, warehouses, vehicle close-up, radar mast close-up. Radar and reference crops follow the same declared coordinates.

### Validation [V]

Validation freezes the approved south observation position and uses Detail resolution. It independently computes the reference-geometry radar image, compares it against the saved approved PNG, then renders the selected model mode.

The three panes show:
1. actual Godot 3D terrain/models;
2. newly computed radar scan;
3. frozen approved reference (or a newly computed geometry reference for the older training range).

For the approved valley, seed 42, the reference-mode replay matches all **2,359,296 pixels exactly**. Preferred full-size models intentionally change radar returns. These changes are recorded separately; the screen must not imply that new larger models are pixel-identical to the old small proxies.

The earlier training range has no historic approved PNG from this renderer. Its validation explicitly reports **geometry replay only**, not an exact pixel-match claim. Its original terrain and equipment arrangement are retained.

Difference images and machine-readable validation reports are saved in the worker session directory. Both share the same scan ID. The UI displays the regression result and keeps the reference separate from the preferred-model image.

## Image fidelity and implementation

`backend/approved_renderer.py` preserves the approved `realism_revision` image formation, including original material/roughness/furrow fields, directional scattering, horizon shadows, delayed path proxies, complex statistical image response, four statistical looks, sampling normalization, and fixed -17…17.5dB log mapping. This is deliberately **not** the earlier smooth raw-pulse experimental renderer. No target-shaped image overlays, sharpening, percentile whitening or bloom are added.

The original Gemini V6.5 source is vendored unchanged (`vendor/gemini_v65.py`, SHA256 `4b06e1b8dd00d45db3fef2491d27c07b39d6ade3e16bc48d585e108750ca96d1`). The earlier v3 primitive model design is ported in `model_library.py` without VTK or asset downloads.

Godot world coordinates are `(world_x, elevation, -world_north)`. Terrain, normal texture, water mask, equipment placement and radar fields come from one scene. Water is masked to the actual river rather than flooding every low patch of ground. Forest rendering is batched using MultiMesh.

Radar calculations still use **2.5D height/material/reflector fields**, not an electromagnetic simulation of every rendered triangle. Sub-grid wheels, radome materials and thin lattice details use approximate scattering proxies. Adding a large model changes its rasterized footprint, height and radar returns; cosmetic color alone does not control radar brightness.

## Scan timing

Normal operation targets one completed scan roughly every 10 seconds, with one outstanding computation. If a scan takes longer than the interval, the game skips a backlog rather than freezing or showing stale results out of order.

The tested end-to-end live-pose cycle measured approximately:

| Mode | Nominal range / azimuth response | CPU calculation | Request-to-display |
| --- | --- | ---: | ---: |
| Survey | 6m / 8m | 0.83s | 1.52s |
| Map | 4m / 5m | 1.96s | 2.68s |
| Detail | 2m / 2.5m | 4.34s | 5.25s |

All modes produce a 1536² display, while instrument response and internal sample counts change. These are measured examples on homer, not guaranteed rates on another CPU. Validation computes two images and therefore takes longer than an ordinary scan. Cache generation and screenshot encoding are not included in the calculation column.

Completed scans are transferred as raw grayscale bytes for low-latency texture updates; PNG copies are retained for inspection. A regression test verifies raw upload bytes equal the PNG's grayscale pixels.

## Tests

```sh
python3 -m unittest discover -s game/radar/tests -v
# Automated Godot run: validation, screenshots and clean worker shutdown.
godot --path . -- --test --capture-dir=/absolute/path/to/output
# Repeat on earlier terrain.
godot --path . -- --test --scenario=legacy --capture-dir=/absolute/path/to/output
# Exercise three observation poses and resolution changes through the UI/IPC path.
godot --path . -- --cycle-test --capture-dir=/absolute/path/to/output
```

The backend suite covers source hash, six-launcher layout, original vehicle/mast parts, source-field preservation, non-mutating reference geometry, localized model changes, shared manifest, exact approved-image replay, quality validation, deterministic static views and changed observation angles.

Game-run JSON includes requested/received IDs and poses, image mode, timings, scene fingerprint, per-pixel comparison and frame-time observations. Frame times use a monotonic wall clock, not the engine's smoothed simulation delta.

## Files and preserved work

- `RadarFlight.tscn`, `radar_flight.gd`: game/validation UI and worker lifecycle.
- `shared_terrain.gd`: source-driven meshes, models, river and forest.
- `backend/worker.py`: private atomic file IPC, serialized requests, bounded scan history.
- `backend/scene_world.py`: captured reference terrain, preferred-model proxies and shared export.
- `backend/model_library.py`: earlier vehicle/radar geometry as reusable primitives.
- `reference/approved_valley_south.png`: user-approved regression fixture.

Original `scenes/World.tscn`, the old raycasting radar and experimental renderers remain available. To run the previous scene:

```sh
godot --path . res://scenes/World.tscn
```

Pre-existing project changes were preserved before integration in `.radar_runtime/project.before-integration.godot` and `.radar_runtime/git-before.diff`. The new main scene is set in `project.godot`; previous input mappings were retained. Generated caches, logs and render results are ignored by Git.
