# Cockpit frame-pacing investigation

Measured on homer, NVIDIA RTX 3090, Godot Compatibility renderer, 1600×900, 60fps cap. These are observations from named test runs, not a guarantee for every machine or every workload.

## What was found

The first 90-second real-time gameplay trace recorded a **70.455ms frame** when the paper chart arrived. Its main-thread `chart_load_and_prepare` span took **52.428ms**. This was actual synchronous image decoding/preparation, not a radar calculation or screenshot.

Moving PNG decoding to `chart_loader.gd` reduced that span to **11.087ms** in the first repeat; its corresponding worst frame was **28.487ms**. The approximately43ms decode still happened, but on the owned background thread.

Further runs found isolated **224.704ms** and **903.361ms** intervals around request handoff. Their gaps fell between chart/request preparation and the subsequent scan sound, outside measured chart decoding. The exact operating-system cause was not independently traced. We removed the remaining synchronous request/status/raw-frame disk access from the main thread rather than declaring these unexplained pauses harmless.

## Changes

- `radar_mailbox.gd` owns request publication, status polling, manifest reads and grayscale-frame reads on one background transport thread. A mutex protects only small queues, never disk access. The game receives completed `Image` data and creates/updates the GPU texture on the main thread.
- `chart_loader.gd` owns paper PNG decoding. Completed tasks are joined after they finish. Restart/exit disposes owned work rather than leaving a thread attached to a freed scene.
- Paper movement is redrawn during flight; long off-screen route segments are clipped before dash drawing, bounding chart work at high magnification.
- `scan_acceleration.py` runs independent numerical rows/columns on a small bounded CPU pool. It retains the approved SciPy kernels, random sequence, accumulation order and image mathematics. Full image and float-array comparisons against the unaccelerated path pass exactly for the tested cases.
- Profilers and visual capture drivers are separate. Ordinary gameplay takes no screenshots, writes no frame trace and performs no forced rendering.

## Native-rendering verification

A window on a background/minimized desktop may not render every ordinary update. Therefore the final native audit explicitly submits actual rendering every frame and does **not** read back or encode PNGs while measuring. A steady timer in a non-rendering window alone is not used as evidence of graphical performance.

The first successful final native audit (`sortie_expansion/native_final`) recorded3028 actual render submissions:

| Phase | Observed result |
| --- | ---: |
| Gameplay median | 16.666ms |
| Gameplay95th percentile | 16.860ms |
| Gameplay99th percentile | 16.942ms |
| Worst gameplay frame | 18.701ms |
| Worst frame including startup | 32.151ms |
| Frames over33.33ms /50ms /100ms | 0 /0 /0 |
| Main-thread radar texture upload | 0.061–0.491ms |
| Main-thread chart upload/setup | 5.966ms |
| Open briefing callback | 0.293ms |

The largest startup interval overlapped an initial native-render submission. It was not a multi-second radar or terrain calculation. These figures include display pacing and scheduling; they are not isolated GPU kernel measurements.

The separate complete-sortie trace (`native_fullflight`) used the normal game-state update at test-time acceleration with native rendering and no captures. It exercised objective completion and the flight record, not just the first few seconds:

- 1954 measured frames; overall maximum22.841ms.
- Flight maximum18.520ms; debrief maximum18.446ms.
- No observed frames above25ms.

The accelerated flight is a test harness, not ordinary gameplay timing. Its purpose is to traverse the whole state sequence without teleporting or granting extra stores. The real-time audit above measures normal simulation timing.

## Scan latency is separate from frame time

The native audit's three Detail calculations took approximately1.90–1.92s and its Survey calculation0.55s. Terrain-field generation and PNG/raw-file output are recorded separately in each result; a new2000m patch added roughly0.8s in the observed full-sortie run. The old radar image remains visible while this work is pending.

A fast radar calculation does not prove a smooth frame, and a smooth frame does not make the completed image live at the new aircraft pose. Reports retain acquisition pose, selected area and request ID.

## Reproduce

```sh
# Standard real-time transitions, with actual native rendering and no captures.
godot --path . --resolution 1600x900 --max-fps 60 -- --frame-test --capture-dir=/absolute/path/native_audit

# Longer timestamped trace (native rendering enabled in probe).
godot --path . --resolution 1600x900 --max-fps 60 -- --performance-test --perf-seconds=90 --capture-dir=/absolute/path/trace
python game/cockpit/tests/analyze_frame_trace.py /absolute/path/trace

# Full objective/egress sequence, test-time acceleration, no screenshots.
godot --path . -- --sortie-test --profile-frames --no-captures --capture-dir=/absolute/path/full_sequence

# Deliberately slow I/O tests prove event-loop progress during blocked work.
godot --headless --path . --script game/cockpit/tests/test_chart_loading.gd
godot --headless --path . --script game/cockpit/tests/test_radar_mailbox.gd
```

Keep raw trace JSON, script logs and capture directories. Invalid runs with compile errors or missing screenshots are not acceptance evidence. Screenshot encoding remains synchronous in visual-only harnesses and can cause large test-only intervals. Restart/exit includes cleanup and is not included in the normal-flight maxima; the startup rendering/texture upload is still finite work, not an unconditional zero-stall promise.

## Clean repeat after final transport changes

`native_repeat` submitted3030 real frames: gameplay median16.666ms, p95 16.854ms, p99 16.907ms, maximum17.564ms. Maximum including startup32.566ms. No frames exceeded33.33ms,50ms or100ms. This repeat exited without script/resource warnings. A screenshot-related shutdown warning in the earlier native audit was removed by keeping its screenshot work in the separate visual driver and deferring scene closure until the reporting callback returned.

All metrics above describe observed runs. Earlier invalid `perf_after` / `perf_mailbox` attempts had integration errors and are excluded. The 224/903ms request-window spikes are retained in the diagnostic history, not deleted from the evidence.
