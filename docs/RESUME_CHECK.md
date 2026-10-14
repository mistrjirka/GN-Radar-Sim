# Resume checkpoint — stable, heading-up acquisitions and full-field resolving

Host: homer. Existing session: s_69643662437ac484.
Repository: ~/programovani/GN-Radar-Sim. Branch: jirka-cockpit-game.
Check live Git status/log before continuing. The previous pushed checkpoint is 702d0bd; this revision follows it. Do not include the unrelated untracked radar_experiments directory in routine commits.

## Latest user correction

The complete radar image must be visible, initially soft, with detail becoming crisp across the whole screen. NOT a side-to-side reveal or travelling beam. The aircraft index stays bottom-center, pointing up; paper moves/rotates below it. Latest exploration changes supersede older bearing-only/no-user-mark instructions. Requirements are in USER_REQUESTS.md; current operation and ownership are in PLAYABILITY.md.

## Implemented and exercised

- Bottom-center heading-up paper, gradual turns, four physical adjustable guides.
- Scan acquisition latches center, heading, pose, width and mode; paper projection/controls hold while the aircraft continues flying. Streamed sheets defer installation until acquisition hold ends.
- Entire heading-oriented square is validated against fictional forward limits before terrain generation. Self/rear/side/too-far areas are rejected. Radar sampling, directional fields and stored-image coordinate conversion share the acquisition orientation.
- Circular green RWR based on the user's reference, with uncertain range estimates and 20km span.
- Knurled resolution selector and simpler bezel information.
- Player marks a point on the resolved radar image and sends a provisional coordinate round there, without hidden emitter snapping or homing. Original finite-mode ARM rules remain reference content.
- Whole-field soft-to-resolved display: filtered texture levels are prepared in the background mailbox; the original base pixels are untouched. The effect follows receipt of a completed real scan, not progressive backend calculation. Native tests verify the completed display matches the original CRT shader pixel-for-pixel.

## Verification this revision

Python cockpit suites: 44 passed. Original approved-radar suite: 11 passed.
Headless gameplay/ownership checks and counts are recorded individually in .radar_runtime/playability/delivery/raven_playability_validation.json; new playability suite has47 checks, mailbox suite11. Native CRT tests run31 checks on synthetic and real data separately. Do not present repeated fixtures as distinct gameplay requirements.

The native interaction driver exercised projected guide/control/radar clicks, acquisition locking, actual turning, a new oriented scan, far RWR contacts and coordinate rounds. Screenshot runs are separate from no-capture frame timing. The no-capture resolve_realtime run measured3158 frame intervals, p95 19.842ms, maximum24.892ms, none above33.33ms on homer at1600x900 with a60fps cap. This excludes initial scene construction and is not a universal hitch-free claim.

One screenshot-enabled run (resolve_visual) reported two ObjectDB instances/one resource retained at exit. Neither no-capture run nor the same-code verbose capture repeat (resolve_capture_check) reproduced it. Cause unconfirmed; retain the original log rather than claiming it was fixed. There were no gameplay script errors in those successful interaction runs. Capture readback remains synchronous test-only work.

## Evidence and screenshots

- .radar_runtime/playability/start.tar.gz and start.diff: preserved pre-revision work.
- protected.json: approved renderer, Gemini source and original finite-mode display source hashes.
- crt_synthetic/, crt_real/: native full-field stages and pixel-equality reports.
- resolve_visual/, resolve_realtime/, resolve_verbose/, resolve_capture_check/: exercised runs; inspect actual logs and reports.
- delivery/: GIF made from native shader frames using an acquired scan; actual cockpit/map/RWR captures; documentation and validation JSON.

Only original reference renderer/CRT/RWR sources are hash-protected. The new analogue_radar shader and range_receiver are intentionally separate exploration views. Combat remains fictional and provisional; terrain is statistical/2.5D, not an infinite optical mesh or full electromagnetic/weapon simulator.
