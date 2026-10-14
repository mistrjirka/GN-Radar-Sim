extends SceneTree
const Route = preload("res://game/cockpit/navigation_route.gd")
const Mission = preload("res://game/cockpit/mission_state.gd")
const Intro = preload("res://game/cockpit/intro_sequence.gd")
const Game = preload("res://game/cockpit/cockpit_game.gd")
var passed := 0
var failed := 0


class OverlayStub:
	extends RefCounted
	var modal_open := false

	func blocks_cockpit_input() -> bool:
		return modal_open

	func debrief_visible() -> bool:
		return modal_open

	func show_notes(_visible: bool, _entries: Array) -> void:
		pass

	func say(_text: String, _seconds: float) -> void:
		pass


func check(condition: bool, text: String) -> void:
	if condition:
		passed += 1
		print("PASS ", text)
	else:
		failed += 1
		push_error("FAIL " + text)


func scene_data() -> Dictionary:
	return {
		"seed": 42,
		"start": [0, -1870],
		"target": [565, 235],
		"egress": [850, -1500],
		"emitters":
		[
			{"id": 0, "position": [-500, -450], "power": 1.0, "phase": 0.0, "disabled": false},
			{"id": 1, "position": [650, -560], "power": 0.8, "phase": 0.5, "disabled": false}
		],
		"suspected": [{"center": [-420, -380], "radius": 260, "label": "SAM ?"}]
	}


func fresh():
	var m = Mission.new()
	m.setup(scene_data())
	return m


func _initialize() -> void:
	var route = Route.new()
	route.replace(Vector2(0, 100))
	check(route.append(Vector2(100, 200)), "Can append a second chart fix")
	check(not route.append(Vector2(100, 200)), "Duplicate trailing fix rejected")
	check(
		route.advance(Vector2(0, 0), Vector2(0, 200), 5) == 1,
		"Swept waypoint crossing survives a long frame"
	)
	check(
		route.points.size() == 1 and route.points[0] == Vector2(100, 200),
		"Only crossed waypoint is consumed"
	)
	check(route.undo() and route.points.is_empty(), "Undo removes only the last fix")
	for i in range(8):
		route.append(Vector2(i * 100, 0))
	check(not route.append(Vector2(900, 0)), "Route queue is bounded at eight fixes")
	check(not route.append(Vector2(NAN, 0)), "Non-finite navigation rejected")
	route.replace(Vector2(10, 10))
	check(route.points.size() == 1, "New course replaces queued route")
	check(
		is_equal_approx(route.remaining_distance(Vector2.ZERO), sqrt(200)),
		"Route distance measures only player's plan"
	)

	var s = fresh()
	s.begin()
	check(s.command_waypoint(Vector2(-100, -900)), "Course command accepted in active mission")
	check(
		s.command_waypoint(Vector2(150, -200), true) and s.route.points.size() == 2,
		"Appending does not discard the current course"
	)
	s.command_course(10)
	check(s.route.points.is_empty(), "Manual heading clears autopilot route")
	check(
		s.command_waypoint(Vector2(0, -600)), "Waypoint following re-engages after manual heading"
	)
	s.missile_time = 3
	s.arm_count = 0
	s.integrity = 0.2
	s.fuel = 0.1
	s.payload_released = true
	s.finished = true
	s.setup(scene_data())
	check(
		(
			not s.finished
			and not s.payload_released
			and s.integrity == 1
			and s.arm_count == 2
			and s.missile_time < 0
		),
		"Setup resets reused mission state completely"
	)
	check(s.journal.is_empty() and s.elapsed == 0, "New mission clears journal and flight clock")
	check(not s.command_waypoint(Vector2.ZERO), "Navigation rejected before orders")
	s.begin()
	s.speed = 0
	s.position = s.target
	check(
		s.release_payload() and s.route.active_point() == s.egress,
		"Release replaces route with egress"
	)
	s.position = s.egress
	s.tick(0.1)
	var report: Dictionary = s.debrief()
	check(
		report["survived"] and report["phase"] == "EGRESS COMPLETE",
		"Debrief derives outcome from mission state"
	)
	check(
		not report.has("emitters") and not report.has("enemy_positions"),
		"Debrief does not leak threat positions"
	)

	var timeline = Intro.new()
	var cues: Array[String] = []
	timeline.cue.connect(func(cue): cues.append(cue))
	timeline.advance(5)
	check(timeline.elapsed == 0, "Intro waits for prepared world")
	timeline.start()
	timeline.advance(3.35)
	check(cues == ["flash", "shutter"], "Intro cues triggered once when time crosses boundaries")
	check(
		float(timeline.snapshot(true)["flash"]) < float(timeline.snapshot(false)["flash"]),
		"Reduced-flash option changes intensity only"
	)
	timeline.advance(2.5)
	check(timeline.snapshot()["blackout"], "Shutter sequence contains actual blackout phase")
	timeline.skip()
	timeline.skip()
	timeline.advance(20)
	check(cues.count("begin_mission") == 1 and timeline.complete, "Skip cannot start mission twice")
	check(
		timeline.snapshot()["shutters"] == 1 and timeline.snapshot()["flash"] == 0,
		"Skip leaves shutters closed and flash cleared"
	)

	var controller = Game.new()
	controller.mission = fresh()
	controller.overlay = OverlayStub.new()
	controller.paused = true
	controller._toggle_help()
	controller._toggle_help()
	check(controller.paused and not controller.help_visible, "Closing help preserves manual pause")
	controller.paused = false
	controller._toggle_help()
	check(controller.help_visible and not controller.paused, "Help has an independent pause reason")
	controller._toggle_pause()
	check(controller.help_visible and controller.paused, "P during help cannot bypass help pause")
	controller._toggle_help()
	check(controller.paused, "Closing help after P still respects user pause")
	controller.overlay.modal_open = true
	controller.dragging_head = true
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	controller._input(click)
	check(not controller.dragging_head, "Modal notes/debrief block clicks into cockpit")
	controller.free()

	_test_frame_rates()
	_test_full_flight()
	print("FLIGHT_SYSTEM_TESTS ", JSON.stringify({"passed": passed, "failed": failed}))
	quit(0 if failed == 0 else 1)


func _test_frame_rates() -> void:
	var slow = fresh()
	var fast = fresh()
	slow.begin()
	fast.begin()
	slow.command_waypoint(Vector2(-250, -1100))
	fast.command_waypoint(Vector2(-250, -1100))
	for i in range(300):
		slow.tick(1.0 / 30.0)
	for i in range(1440):
		fast.tick(1.0 / 144.0)
	check(
		slow.position.distance_to(fast.position) < 2,
		"Navigation remains within 2m across 30/144 FPS"
	)
	check(absf(slow.fuel - fast.fuel) < 0.0001, "Fuel clock is frame-rate independent")


func _test_full_flight() -> void:
	var flight = fresh()
	flight.begin()
	flight.toggle_arm()
	var release_ok := false
	for i in range(60 * 180):
		if flight.finished:
			break
		if flight.incoming and flight.countermeasures > 0 and flight.evade_time <= 0:
			flight.deploy_countermeasure()
		if flight.tracking > 0.35 and flight.arm_count > 0 and flight.missile_time <= 0:
			flight.cycle_emitter()
			flight.fire_arm()
		if (
			not flight.payload_released
			and flight.position.distance_to(flight.target) < flight.tuning.release_radius
		):
			release_ok = flight.release_payload()
		flight.tick(1.0 / 60)
	check(release_ok, "Scripted flight reaches release area without teleporting")
	check(
		flight.finished and flight.survived,
		"Scripted flight reaches egress using normal route/defense rules"
	)
	check(
		flight.distance_flown > 3500 and flight.elapsed > 50,
		"Flight/debrief count travelled distance and elapsed time"
	)
	print("FULL_FLIGHT ", JSON.stringify(flight.debrief()))
