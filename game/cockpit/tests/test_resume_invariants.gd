extends SceneTree
## Independent checks for the refactor resumed after the connection interruption.
## Pure state tests: do not claim these are a manually flown or visual mission.
const Intro = preload("res://game/cockpit/intro_sequence.gd")
const Route = preload("res://game/cockpit/navigation_route.gd")
const Mission = preload("res://game/cockpit/mission_state.gd")
var passed := 0
var failed := 0
var cues: Array[String] = []

func check(ok: bool, title: String) -> void:
	if ok:
		passed += 1
		print("PASS ", title)
	else:
		failed += 1
		push_error("FAIL " + title)

func data() -> Dictionary:
	return {"seed": 42, "start": [0, -1870], "target": [565, 235], "egress": [850, -1500],
		"emitters": [], "suspected": []}

func _initialize() -> void:
	_test_intro()
	_test_route()
	_test_reset_and_finish()
	print("RESUME_INVARIANTS ", JSON.stringify({"passed": passed, "failed": failed}))
	quit(0 if failed == 0 else 1)

func _test_intro() -> void:
	var intro = Intro.new()
	intro.cue.connect(func(name): cues.append(name))
	intro.advance(20)
	check(cues.is_empty() and not intro.complete, "An unloaded intro cannot begin the mission")
	intro.start()
	intro.advance(3.4)
	check(cues == ["flash", "shutter"], "Flash and shutter cues are emitted in order")
	var reduced: Dictionary = intro.snapshot(true)
	var normal: Dictionary = intro.snapshot(false)
	check(float(reduced["flash"]) < float(normal["flash"]), "Reduced flash affects presentation only")
	intro.advance(2.2)
	check(intro.snapshot()["blackout"], "Blackout exists between shutters and emergency lights")
	intro.advance(1.4)
	check(intro.snapshot()["stage"] == "defcon", "Emergency stage follows blackout")
	intro.skip()
	intro.skip()
	intro.advance(100)
	check(cues.count("begin_mission") == 1 and intro.complete, "Skip/completion issues the mission cue once")
	cues.clear()
	intro.start()
	intro.advance(100)
	check(cues == ["flash", "shutter", "begin_mission"], "A long frame does not lose ordered intro events")

func _test_route() -> void:
	var route = Route.new()
	check(route.points.is_empty() and route.remaining_distance(Vector2.ZERO) == 0, "An empty route holds no hidden destination")
	check(route.append(Vector2(0, 100)), "First navigation fix can be entered")
	check(not route.append(Vector2(0, 101)), "Repeated nearly-identical fixes are rejected")
	for i in range(1, 8):
		route.append(Vector2(100*i, 100))
	check(route.points.size() == 8 and not route.append(Vector2(1000, 100)), "Route capacity is bounded")
	check(route.undo() and route.points.size() == 7, "Undo removes only the last route fix")
	route.replace(Vector2(0, 100))
	route.append(Vector2(0, 300))
	check(is_equal_approx(route.remaining_distance(Vector2.ZERO), 300.0), "Route distance includes all pending segments")
	check(route.advance(Vector2.ZERO, Vector2(0, 150), 10) == 1 and route.active_point() == Vector2(0, 300), "Swept movement passes only the reached fix")
	check(route.advance(Vector2(0, 150), Vector2(100, 150), 10) == 0, "Passing elsewhere does not consume the next fix")
	check(not route.append(Vector2(NAN, 0)), "Invalid route coordinates are rejected")
	route.clear()
	check(route.desired_heading(Vector2.ZERO, 0.7) == 0.7, "Clearing the route preserves the commanded heading")

func _test_reset_and_finish() -> void:
	var state = Mission.new()
	state.setup(data())
	state.begin()
	state.command_waypoint(Vector2(0, -1500))
	state.command_waypoint(Vector2(200, -1200), true)
	state.tick(2)
	state.record_scan()
	check(state.distance_flown > 100 and state.scans_completed == 1, "Flight record counts travel and completed scans")
	var position: Vector2 = state.position
	state.tick(NAN)
	state.tick(-1)
	check(state.position == position, "Invalid frame durations do not corrupt mission state")
	state.integrity = 0.2
	state.arm_count = 0
	state.missile_time = 5.0
	state.setup(data())
	check(not state.active and not state.authorized and state.elapsed == 0, "Restart clears mission authorization and time")
	check(state.integrity == 1 and state.arm_count == state.tuning.initial_arm_count and state.missile_time == -1, "Restart restores stores and clears pending actions")
	check(state.journal.is_empty() and state.route.points.size() == 1 and state.route.reached_count == 0 and state.scans_completed == 0, "Restart clears journal, navigation progress and scan history")
	state.begin()
	state.command_course(5)
	check(state.route.points.is_empty(), "Manual course input releases route following")
	state.command_waypoint(Vector2(200, -1000))
	var before: Dictionary = state.debrief()
	before["journal"].clear()
	check(not state.journal.is_empty(), "Debrief snapshots cannot mutate the live journal")
	state.integrity = 0
	state.tick(0.1)
	var record: Dictionary = state.debrief()
	check(state.finished and not record["survived"] and record["reason"] == "AIRFRAME LOST", "Failure produces an explicit end-of-flight record")
	var final_time: float = state.elapsed
	state.tick(10)
	check(state.elapsed == final_time, "Completed flight record stops accumulating simulation time")
