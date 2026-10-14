# Procedural region, scan performance and frame pacing

Measured and implemented on homer, branch `jirka-cockpit-game`, 2026-10-14.
The user's requirements remain in `docs/USER_REQUESTS.md`. Numerical map size,
mission duration, route suggestions and weapon values below are prototypes,
not new requirements assigned to the user.

## What exists now

The cockpit's default sortie covers a **12 x 18 km seeded region**, rather than
stretching the old 2 km image. Ground height, river, field parcels, roughness,
forest crowns, roads, bridges, warehouse compounds and seven six-launcher sites
are sampled in geographic coordinates. The paper chart and radar use that same
world. Intelligence circles are offset and include stale reports; the paper and
RWR do not receive exact emitter positions.

Only the requested radar patch is generated at fine resolution. A bounded cache
holds three patches. The full paper atlas is a lower-resolution representation
of the finite region, not an enormous fine-grid radar atlas. The provider avoids
repeating a test tile along the route. Feature foundation heights are derived
from world coordinates once, not from whichever subset of a roof is inside the
current crop. Access roads clear vegetation rather than retaining canopy height.

The original approved 2 km reference path remains available with `--reference`.
The new region is **not infinite terrain, erosion simulation or a finished
campaign**. The terrain fields are deterministic, but the whole radar image also
depends on view position, sampling and statistical scattering. A changed scene
is not expected to be pixel-identical to the old approved scene.

## Where the scan time went

A profile of a warm 2 km Detail scan found approximately:

| Work | Time in the profiled baseline |
| --- | ---: |
| Sampling terrain/material/reflector fields | 1.59 s |
| Filtering complex return fields | 0.98 s |
| Slant-range accumulation | 0.41 s |
| PNG encoding | 0.08 s |

These are overlapping function-level categories from a profiler, not a sum of
independent end-to-end stages. The largest useful optimization was scheduling
independent numerical output rows/columns concurrently, not changing resolution
or deleting radar effects.

### Implemented acceleration

`game/cockpit/backend/scan_acceleration.py` binds the **same approved Python code
objects** to parallel implementations of two numerical leaves: `map_coordinates`
and `convolve1d`. Each thread writes a disjoint output region. The exact SciPy
kernels, dtypes, RNG order, filtering order, visibility logic, multipath proxies,
log mapping and phosphor shader are unchanged. No global module monkey patch is
used and no separate rewritten image algorithm needs maintaining.

The ordinary game uses **three numerical worker threads**. This leaves headroom
for Godot on the tested 8-core CPU. `RADAR_NUMERIC_WORKERS=1` disables parallelism;
2–4 can be selected for hardware-specific testing. No GPU compute dependency was
added. Each serialized Python worker owns and closes its own bounded pool.

| Same-scene Detail calculation | Reference | Three workers | Speed-up |
| --- | ---: | ---: | ---: |
| 2 km selected area | 3.53 s | 1.87 s | 1.89x |
| 1 km selected area | 4.50 s | 2.17 s | 2.07x |

These are medians of alternating reference/parallel runs on **Ryzen 7 5700X3D**.
They exclude terrain generation and file publication. The 1 km scan has longer
sampled filter kernels at the same physical resolution and ray sample counts;
its higher calculation cost is not a typo. Four threads measured another roughly
9–10% improvement, but three is the conservative game default.

All **32 measured outputs** in the scheduling sweep matched their reference
measurement arrays, floating-point powers and floating-point displayed images
exactly. Additional tests cover different bearings, elevation, interpolation
orders and filter axes. This is not an image-quality-versus-speed trade.

A live game run measured new 2 km areas at **2.85–2.98 s** from worker request
processing to published scan, including **0.86–0.98 s** of new terrain generation.
The comparable prior live scans took **4.47–4.75 s**. Request polling and the next
Godot frame add a small delivery delay; those timings are not silently included
in the numerical calculation column.

## Freeze / lag investigation

A dedicated `--frame-test` replays flight, four scan deliveries, chart-scale
changes, camera leaning, briefing and notes. It records monotonic frame intervals
and explicitly submits native rendering when the background desktop suppresses
automatic drawing. **It does not save screenshots while timing** and does not
accelerate mission time. This is a whole-loop audit, not isolated GPU timing.

Baseline finding: the initial paper chart was decoded on the main thread.
The preparation callback took **49.59 ms**, producing a **66.32 ms frame**.
Radar frame delivery itself took only **0.36–1.68 ms**.

The chart is now decoded on a background task (`chart_loader.gd`). Scene state
and GPU texture creation remain on the main thread; the completed image is handed
over without waiting for an unfinished decoder. The measured texture/setup
callback took **6.78 ms** after that change.

The paper was also only redrawing with the 0.09-second lamp refresh. It now
follows rendered flight frames. Off-screen route segments are clipped before
building dashed ink geometry, so zooming the chart does not draw thousands of
unseen dashes for distant waypoints. Paper scale changes independently from radar
scan-area size, including the first scale-button press.

| Frame audit at 1600 x 900, capped at 60 FPS | Before | After |
| --- | ---: | ---: |
| Overall longest measured frame, including chart readiness | 66.32 ms | 32.02 ms |
| Frames longer than 33.33 ms | 1 | 0 |
| Longest gameplay frame | 30.78 ms | 17.93 ms |
| Gameplay p95 | 16.85 ms | 16.85 ms |
| Gameplay p99 | 16.93 ms | 17.03 ms |

The final trace has **3,032 measured/rendered loop iterations**, including 2,221
gameplay intervals. No measured interval exceeded 50 ms. This is evidence for the
exercised scenario, **not proof that all seeds, drivers, computers and long
sessions are hitch-free**. Initial application/scene construction before the
first sampled loop interval is not included. Screenshot encoding is excluded
because it is validation work, not gameplay.

## How to run and reproduce

```sh
./play-cockpit.sh
# B: full sortie briefing; Z: paper scale; Space: acquire selected area.
# 1/2/3: survey/map/detail; existing flight and provisional weapon controls remain.

# Previous small scene:
./play-cockpit.sh -- --reference

# Same-scene exact-output benchmark:
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 python game/cockpit/tests/benchmark_acceleration.py

# Rendering-enabled frame audit; no PNG saves until measurement has stopped:
godot --path . --max-fps 60 -- --frame-test --capture-dir=/absolute/output/path

# Accelerated test-only complete sortie and screenshots:
godot --path . -- --sortie-test --capture-dir=/absolute/output/path
```

`--sortie-test` uses a documented 30x simulation-clock multiplier to exercise
release and egress quickly, without teleporting or granting stores. It is not a
real-time performance test. Separate real-time frame tests must not be confused
with that accelerated playthrough.

Evidence: `.radar_runtime/performance/acceleration_benchmark.json`,
`frame_before/frame_pacing.json`, `frame_after/frame_pacing.json`, raw frame
samples, Python profiles and regression logs. The original source recovery point
is `.radar_runtime/performance/before.tar.gz`.

## Next priorities

1. **Terrain relationships and optical validation.** Improve drainage, road
   connections, prepared-site terrain and landmark variety across several seeds.
   Validate normal-camera geometry and radar views of the same coordinates.
   Larger area alone is not equivalent to better terrain realism.
2. **Sustained playtesting.** Fly complete routes in real time on multiple seeds;
   test dense sites, maximum chart zoom and 4 km scans, plus weaker hardware.
   Keep exact-output comparisons and frame-time traces as acceptance tests.
3. **Pacing only after those checks.** Adjust uncertain intelligence, route length,
   time between useful scans and provisional threat pressure. Leave detailed
   missile/seeker and payload mechanics open until the user defines them.

Do not accelerate scans by blurring them, removing shadows, changing the approved
point response, showing a cached image from a different acquisition pose, or
reducing quality without an explicit selectable mode.
