extends Node
## Integration harness loaded ONLY by --cockpit-test; not gameplay code.
var render_every_frame := false
var forced_draw_count := 0
var initial_draw_count := 0
var game: Node3D
var capture_dir := ""
var test_state := 0
var test_timer := 0.0
var test_records: Dictionary = {}
var frame_times: Array[float] = []
var previous_frame_usec := 0
var captures: Array[String] = []
var test_suppressed_id := -1


func configure(controller: Node3D, directory: String) -> void:
	game = controller
	render_every_frame = "--render-every-frame" in OS.get_cmdline_user_args()
	initial_draw_count = Engine.get_frames_drawn()
	capture_dir = directory
	if not capture_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(capture_dir)


func _process(dt: float) -> void:
	if game.closed:
		return
	var now := Time.get_ticks_usec()
	if previous_frame_usec > 0 and game.intro_done:
		frame_times.append(float(now - previous_frame_usec) / 1000)
	previous_frame_usec = now
	if render_every_frame and DisplayServer.get_name() != "headless":
		RenderingServer.force_draw(false, dt)
		forced_draw_count += 1
	_run_visual_test(dt)


func _capture(name: String) -> void:
	if capture_dir.is_empty() or DisplayServer.get_name() == "headless" or captures.has(name):
		return
	# Detached test node explicitly requests a draw. A background/minimized
	# window may not emit frame_post_draw on its own; never report unwritten files.
	RenderingServer.force_draw(false)
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		test_records["capture_error"] = "Empty viewport for " + name
		return
	var error := image.save_png(capture_dir.path_join(name + ".png"))
	if error == OK:
		captures.append(name)
	else:
		test_records["capture_error"] = "PNG write failed for " + name


func _run_visual_test(dt: float) -> void:
	test_timer += dt
	if test_timer > 160:
		test_records["timeout"] = true
		_finish_test()
		return
	if game.prepared_world and not game.intro_done:
		if game.intro_clock > .8 and game.intro_clock < 2:
			_capture("01_daylight")
		if game.intro_clock > 3.40 and game.intro_clock < 3.48:
			_capture("01b_flash")
		if game.intro_clock > 5.5 and game.intro_clock < 6.4:
			_capture("02_blackout")
		if game.intro_clock > 8 and game.intro_clock < 9:
			_capture("03_defcon")
	if not game.intro_done:
		return
	if test_state == 0 and game.mission.elapsed > 4 and game.scan_count >= 1:
		_capture("04_gameplay")
		test_records["intro_complete"] = true
		test_records["first_frame"] = game.last_scan.duplicate(true)
		test_records["paper_position_start"] = [game.mission.position.x, game.mission.position.y]
		test_state = 10
		test_timer = 0
	elif test_state == 10 and test_timer > .3:
		# Click a point on the actual 3D chart then the actual SCAN button.
		var uv := Vector2(.46, .36)
		var local := Vector3((uv.x - .5) * .87, (.5 - uv.y) * 1.12, 0)
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = game.rig.camera.unproject_position(game.rig.chart_quad.to_global(local))
		game._input(click)
		test_records["selected_center"] = [
			game.rig.chart.selected_center.x, game.rig.chart.selected_center.y
		]
		for c in game.rig.controls:
			if c["action"] == "scan":
				click.position = game.rig.camera.unproject_position(c["mesh"].global_position)
				game._input(click)
		test_records["second_scan_requested"] = game.link.busy
		game.mission.cycle_emitter()
		game.mission.toggle_arm()
		test_records["arm_launched"] = game.mission.fire_arm()
		test_suppressed_id = game.mission.missile_emitter
		test_records["countermeasure"] = game.mission.deploy_countermeasure()
		test_records["release_outside_inhibited"] = not game.mission.release_payload()
		test_state = 1
	elif test_state == 1 and game.scan_count >= 2 and game.mission.missile_time <= 0:
		test_records["second_frame"] = game.last_scan.duplicate(true)
		for e in game.mission.emitters:
			if int(e["id"]) == test_suppressed_id:
				test_records["selected_emitter_suppressed"] = e["disabled"]
		test_records["paper_position_end"] = [game.mission.position.x, game.mission.position.y]
		game.paused = true
		game.focus = 3
		test_state = 2
		test_timer = 0
	elif test_state == 2 and test_timer > 1.1:
		_capture("05_paper_chart")
		game.focus = 1
		test_state = 3
		test_timer = 0
	elif test_state == 3 and test_timer > 1.1:
		_capture("06_bearing_only_rwr")
		game.focus = 2
		test_state = 4
		test_timer = 0
	elif test_state == 4 and test_timer > 1.1:
		_capture("07_returns_only_radar")
		game.focus = 0
		test_state = 5
		test_timer = 0
	elif test_state == 5 and test_timer > 1.1:
		_capture("08_gameplay_after_scan")
		test_state = 6
		test_timer = 0
	elif test_state == 6 and test_timer > .5:
		game.focus = 3
		game.paused = false
		_route_click(Vector2(.56, .60), false)
		_route_click(Vector2(.47, .41), true)
		test_records["route_via_projected_clicks"] = game.mission.route.points.size() == 2
		test_records["route_points"] = game.mission.route.points.map(func(p): return [p.x, p.y])
		game.paused = true
		test_state = 7
		test_timer = 0
	elif test_state == 7 and test_timer > 1.1:
		_capture("09_pencilled_route")
		game._toggle_help()
		test_state = 8
		test_timer = 0
	elif test_state == 8 and test_timer > .7:
		_capture("10_flight_notes")
		game._toggle_help()
		test_records["help_preserves_pause"] = game.paused
		game.focus = 0
		game.paused = false
		game.mission.command_waypoint(game.mission.target)
		test_state = 9
		test_timer = 0
	elif test_state == 9:
		# Continue the SAME mission using commands, never teleport to the target.
		if (
			game.mission.incoming
			and game.mission.countermeasures > 0
			and game.mission.evade_time <= 0
		):
			game._action("chaff")
		if (
			game.mission.tracking > .35
			and game.mission.arm_count > 0
			and game.mission.missile_time <= 0
		):
			game._action("select")
			game._action("arm_fire")
		if (
			not game.mission.payload_released
			and (
				game.mission.position.distance_to(game.mission.target)
				< game.mission.tuning.release_radius
			)
		):
			game._action("release")
		if game.mission.finished:
			test_records["full_flight_debrief"] = game.mission.debrief()
			test_records["debrief_visible"] = game.overlay.result_panel.visible
			test_state = 11
			test_timer = 0
	elif test_state == 11 and test_timer > .8:
		_capture("11_mission_debrief")
		test_state = 12
		test_timer = 0
	elif test_state == 12 and test_timer > .5:
		_finish_test()


func _finish_test() -> void:
	if game.closed:
		return
	if capture_dir.is_empty():
		capture_dir = game.link.folder
	DirAccess.make_dir_recursive_absolute(capture_dir)
	var sorted := frame_times.duplicate()
	sorted.sort()
	test_records["frames"] = sorted.size()
	test_records["drawn_frames"] = Engine.get_frames_drawn() - initial_draw_count
	test_records["forced_rendered_frames"] = forced_draw_count
	test_records["render_every_frame"] = render_every_frame
	test_records["timing_scope"] = "Main-loop wall intervals, includes forced GPU render submission and synchronous PNG captures; not isolated GPU time."
	test_records["frame_p95_ms"] = sorted[int(sorted.size() * .95)] if not sorted.is_empty() else 0
	test_records["frame_max_ms"] = sorted[-1] if not sorted.is_empty() else 0
	test_records["scan_count"] = game.scan_count
	test_records["worker_folder"] = game.link.folder
	test_records["rwr_keys"] = (
		game.mission.receiver_contacts()[0].keys()
		if not game.mission.receiver_contacts().is_empty()
		else []
	)
	test_records["screen_order"] = ["RWR", "RAW_RADAR", "ROLLING_CHART"]
	test_records["captures"] = captures
	var f := FileAccess.open(capture_dir.path_join("game_test.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(test_records, "  "))
		f.close()
	print("COCKPIT_TEST_RESULT ", JSON.stringify(test_records))
	game._close()


func _route_click(uv: Vector2, append_fix: bool) -> void:
	var point := Vector3((uv.x - .5) * .87, (.5 - uv.y) * 1.12, 0)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.shift_pressed = true
	click.ctrl_pressed = append_fix
	click.position = game.rig.camera.unproject_position(game.rig.chart_quad.to_global(point))
	game._input(click)
