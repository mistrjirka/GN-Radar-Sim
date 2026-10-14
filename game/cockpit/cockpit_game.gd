extends Node3D
## First playable cockpit slice. All combat values are fictional placeholders.
const Rig = preload("res://game/cockpit/cockpit_rig.gd")
const Mission = preload("res://game/cockpit/mission_state.gd")
const RadarLink = preload("res://game/cockpit/radar_link.gd")
const Intro = preload("res://game/cockpit/intro_sequence.gd")
const Overlay = preload("res://game/cockpit/flight_overlay.gd")
const Briefing=preload("res://game/cockpit/sortie_briefing.gd")
var briefing
var scenario_mode := "endless"
var world_stream
var endless_test:=false
var sortie_test := false
var frame_test := false
var performance_test := false
var profile_frames := false
var frame_probe
var chart_loader
@export var mission_tuning: Resource = preload("res://game/cockpit/default_mission.tres")
var intro = Intro.new()
var overlay
var test_driver: Node
var intro_clock: float:
	get:
		return intro.elapsed
var intro_done: bool:
	get:
		return intro.complete

var rig
var mission
var link
var mission_data: Dictionary = {}
var prepared_world := false
var intro_stage := "loading"
var total_time := 0.0
var ui_clock := 0.0
var trail_clock := 0.0
var paused := false
var help_visible := false
var reduced_flash := true
var closed := false
var focus := 0
var head_yaw := 0.0
var head_pitch := 0.0
var dragging_head := false
var damage_shake := 0.0
var selected_extent := 1000.0
var current_quality := "detail"
var scan_count := 0
var last_scan: Dictionary = {}
var scan_seconds := 0.0
var radar_hold := false
var engine_audio: AudioStreamPlayer
var effects_audio: AudioStreamPlayer
var radio_audio: AudioStreamPlayer
var test_mode := false
var capture_dir := ""


func _ready() -> void:
	get_tree().auto_accept_quit = false
	for arg in OS.get_cmdline_user_args():
		if arg == "--cockpit-test":
			test_mode = true
			scenario_mode="reference"
		if arg=="--performance-test":performance_test=true;profile_frames=true;scenario_mode="sortie"
		if arg=="--profile-frames":profile_frames=true
		if arg=="--reference":scenario_mode="reference"
		if arg=="--sortie":scenario_mode="sortie"
		if arg=="--endless-test":endless_test=true;scenario_mode="endless"
		if arg=="--sortie-test":sortie_test=true;scenario_mode="sortie"
		if arg=="--frame-test":frame_test=true;scenario_mode="sortie"
		if arg.begins_with("--capture-dir="):
			capture_dir = arg.trim_prefix("--capture-dir=")
	var seed_number := int(get_tree().get_meta("cockpit_seed", 42))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed=") and not get_tree().has_meta("cockpit_seed"):
			seed_number = int(arg.trim_prefix("--seed="))
	if profile_frames:
		frame_probe=load("res://game/cockpit/tests/frame_probe.gd").new()
		frame_probe.configure(self,capture_dir)
		add_child(frame_probe)
	var rig_started:=Time.get_ticks_usec()
	rig = Rig.new()
	add_child(rig)
	rig.build()
	if frame_probe:frame_probe.record_span("cockpit_mesh_build",rig_started,Time.get_ticks_usec())
	mission = Mission.new()
	mission.tuning = (preload("res://game/cockpit/sortie_mission.tres") if scenario_mode in ["sortie","endless"] else mission_tuning).duplicate(true)
	mission.radio.connect(_radio)
	mission.event.connect(_mission_event)
	link = RadarLink.new()
	add_child(link)
	link.prepared.connect(_world_prepared)
	link.scan_ready.connect(_scan_ready)
	link.failed.connect(_radar_error)
	if frame_probe:link.diagnostic_span.connect(frame_probe.record_span)
	_build_overlay()
	chart_loader=preload("res://game/cockpit/chart_loader.gd").new()
	add_child(chart_loader)
	chart_loader.decoded.connect(_chart_prepared)
	chart_loader.failed.connect(_radar_error)
	intro.cue.connect(_intro_cue)
	_setup_audio()
	link.launch(seed_number,scenario_mode)
	_radio("RAVEN TWO / Loading terrain and paper charts. The cockpit will remain interactive.", "")
	if performance_test:
		test_driver=load("res://game/cockpit/tests/performance_driver.gd").new()
		test_driver.configure(self,capture_dir)
		add_child(test_driver)
	elif frame_test:
		test_driver=load("res://game/cockpit/tests/frame_pacing_driver.gd").new()
		test_driver.configure(self,capture_dir)
		add_child(test_driver)
	elif sortie_test:
		test_driver=load("res://game/cockpit/tests/sortie_visual_driver.gd").new()
		test_driver.configure(self,capture_dir)
		add_child(test_driver)
	elif endless_test:
		test_driver=load("res://game/cockpit/tests/endless_driver.gd").new()
		test_driver.configure(self,capture_dir)
		add_child(test_driver)
	elif test_mode:
		test_driver = load("res://game/cockpit/tests/cockpit_visual_driver.gd").new()
		test_driver.configure(self, capture_dir)
		add_child(test_driver)


func _build_overlay() -> void:
	overlay = Overlay.new()
	add_child(overlay)
	overlay.build()
	briefing=Briefing.new();overlay.add_child(briefing);briefing.build()
	briefing.close_requested.connect(_toggle_briefing)
	briefing.route_requested.connect(_select_briefed_route)
	overlay.resume_requested.connect(_toggle_help)
	overlay.restart_requested.connect(_restart)
	overlay.new_seed_requested.connect(_new_seed)
	overlay.quit_requested.connect(_close)
	overlay.briefing_requested.connect(_toggle_briefing)
	overlay.reduced_flash_changed.connect(func(value): reduced_flash = value)


func _setup_audio() -> void:
	engine_audio = AudioStreamPlayer.new()
	engine_audio.volume_db = -15
	var sound = load("res://game/cockpit/assets/engine.wav")
	engine_audio.stream = sound
	add_child(engine_audio)
	engine_audio.finished.connect(_engine_repeat)
	engine_audio.play()
	effects_audio = AudioStreamPlayer.new()
	effects_audio.volume_db = -13
	add_child(effects_audio)
	radio_audio = AudioStreamPlayer.new()
	radio_audio.volume_db = -3
	add_child(radio_audio)


func _engine_repeat() -> void:
	if not closed:
		engine_audio.play()


func _play(cue: String, voice: bool = false) -> void:
	if cue.is_empty():
		return
	var path := "res://game/cockpit/assets/" + cue + ".wav"
	if not ResourceLoader.exists(path):
		path = "res://game/cockpit/assets/click.wav"
	var player: AudioStreamPlayer = radio_audio if voice else effects_audio
	var audio_started:=Time.get_ticks_usec()
	player.stream = load(path)
	player.play()
	if frame_probe:frame_probe.record_span("audio_"+cue,audio_started,Time.get_ticks_usec())


func _radio(text: String, cue: String) -> void:
	if not overlay:
		return
	overlay.say(text, 14 if cue == "orders" else 7)
	if not cue.is_empty():
		_play(cue, cue in ["orders", "flash", "silent", "success"])


func _world_prepared(data: Dictionary) -> void:
	if data.is_empty():
		_radar_error("Mission chart missing")
		return
	mission_data = data
	chart_loader.load_png(str(data["chart"]))


func _chart_prepared(image: Image, decode_ms: float) -> void:
	var prepare_started:=Time.get_ticks_usec()
	var data:Dictionary=mission_data
	if frame_probe:frame_probe.record_span("chart_decode_background",prepare_started-int(decode_ms*1000),prepare_started)
	mission.setup(data)
	prepared_world = true
	intro.start()
	intro_stage = "daylight"
	if image:
		rig.chart.chart = ImageTexture.create_from_image(image)
	rig.chart.target = mission.target
	rig.chart.egress = mission.egress
	rig.chart.suspected = mission.suspected
	rig.chart.aircraft = mission.position
	rig.chart.heading = mission.heading
	rig.chart.endless=mission.endless
	rig.chart.configure_region(data.get("bounds",[-1000,1000,-1000,1000]))
	selected_extent=float(data.get("initial_scan_extent",1000))
	rig.chart.change_extent(selected_extent)
	var scan_center:Array=data.get("initial_scan_center",[-220,-150])
	rig.chart.select(Vector2(scan_center[0],scan_center[1]))
	if mission.endless:
		world_stream=preload("res://game/cockpit/world_stream.gd").new()
		add_child(world_stream)
		world_stream.configure(mission,rig.chart,link,data)
		world_stream.sheet_changed.connect(_sheet_changed)
		briefing.configure(world_stream.local_public(),rig.chart.chart)
	elif scenario_mode=="sortie":briefing.configure(data,rig.chart.chart)
	rig.chart.queue_redraw()
	_radio("PILOT / Steady on course. Ground control has gone quiet.", "")
	if frame_probe:frame_probe.record_span("chart_load_and_prepare",prepare_started,Time.get_ticks_usec())
	link.timing_event.emit("chart_texture_upload_and_setup",float(Time.get_ticks_usec()-prepare_started)/1000.0)
	_request_scan(true)


func _request_scan(initial: bool = false) -> void:
	if not prepared_world or link.busy:
		if not initial:
			_play("click")
		return
	if not initial and (not mission.active or mission.finished or paused or help_visible):
		return
	if radar_hold and not initial:
		_radio("RADAR / HOLD engaged. Release HOLD before requesting a new frame.", "click")
		return
	var chosen:Array=mission.global_point(rig.chart.selected_center)
	if link.scan(mission.radar_pose(), chosen, selected_extent, current_quality):
		scan_seconds = 0
		mission.scan_transmit_time = 1.5
		rig.set_lamp("tx", true)
		_play("scan")


func _scan_ready(texture: Texture2D, details: Dictionary) -> void:
	var apply_started:=Time.get_ticks_usec()
	last_scan = details.duplicate(true)
	last_scan["global_center"]=details["center"].duplicate()
	if mission.endless:
		var p:Vector2=mission.local_point(details["center"]);last_scan["center"]=[p.x,p.y]
	scan_count += 1
	mission.record_scan()
	rig.radar_material.set_shader_parameter("radar_image", texture)
	rig.radar_material.set_shader_parameter("has_frame", 1.0)
	rig.set_lamp("tx", false)
	rig.set_lamp("frame", true)
	_play("click")
	if frame_probe:frame_probe.record_span("apply_radar_frame",apply_started,Time.get_ticks_usec())


func _radar_error(message: String) -> void:
	rig.set_lamp("tx", false)
	_radio(message + "  [H for controls]", "")
	if test_driver and test_mode:
		test_driver.test_records["radar_error"] = message


func _mission_event(kind: String) -> void:
	if kind == "impact":
		damage_shake = .5
	if kind == "release":
		damage_shake = .18
	if kind in ["success", "failure"]:
		help_visible = false
		overlay.show_debrief(mission.debrief())


func _process(dt: float) -> void:
	if closed:
		return
	total_time += dt
	if not paused and not help_visible:
		if prepared_world and not intro_done:
			_intro(dt)
		mission.tick(dt)
	if intro_done and not paused and not help_visible:
		if Input.is_physical_key_pressed(KEY_A):
			mission.command_course(-22 * dt)
		if Input.is_physical_key_pressed(KEY_D):
			mission.command_course(22 * dt)
		if Input.is_physical_key_pressed(KEY_Q):
			mission.commanded_altitude = minf(2600, mission.commanded_altitude + 150 * dt)
		if Input.is_physical_key_pressed(KEY_E):
			mission.commanded_altitude = maxf(450, mission.commanded_altitude - 150 * dt)
		if Input.is_physical_key_pressed(KEY_W):
			mission.speed = minf(110, mission.speed + 18 * dt)
		if Input.is_physical_key_pressed(KEY_S):
			mission.speed = maxf(38, mission.speed - 18 * dt)
	if prepared_world:
		rig.chart.aircraft = mission.position
		rig.chart.heading = mission.heading
		rig.chart.commanded_heading=mission.commanded_heading
		rig.chart.follow_paper()
		rig.chart_mechanism.update_from_chart(rig.chart)
		# Scrolling follows rendered frames, not the slower lamp refresh timer.
		if not paused and not help_visible:rig.chart.queue_redraw()
		rig.chart.released = mission.payload_released
		rig.chart.route_points = mission.route.points
		rig.chart.phase_text = mission.phase_name()
		if mission.active and not paused and not help_visible:rig.chart.queue_redraw()
		trail_clock += dt
		if trail_clock > .7 and mission.active:
			trail_clock = 0
			rig.chart.trail.append(mission.position)
			if rig.chart.trail.size() > 1200:
				rig.chart.trail.remove_at(0)
		# Both rollers follow the distance actually travelled over the paper.
		rig.roller_top.rotation.x = fmod(float(mission.global_position_array()[1]),1047.1975512) * .006
		rig.roller_bottom.rotation.x = fmod(float(mission.global_position_array()[1]),1047.1975512) * .006
	scan_seconds += dt
	overlay.tick(dt)
	ui_clock += dt
	if ui_clock > .09:
		ui_clock = 0
		_update_instruments()
		_update_hint()
	_update_camera(dt)
	rig.update_pilot(total_time, wrapf(mission.commanded_heading - mission.heading, -PI, PI))
	damage_shake = maxf(0, damage_shake - dt * .5)


func _intro(dt: float) -> void:
	intro.advance(dt)
	var frame: Dictionary = intro.snapshot(reduced_flash)
	intro_stage = frame["stage"]
	overlay.flash.color = Color(1, .98, .89, frame["flash"])
	rig.set_shutters(frame["shutters"])
	rig.blackout(frame["blackout"])
	rig.combat_lighting(frame["red"])


func _intro_cue(cue: String) -> void:
	match cue:
		"flash":
			_radio("PILOT / Flash! Shutters closing. Hold on.", "flash")
		"shutter":
			_play("shutter")
		"begin_mission":
			mission.begin()


func _update_instruments() -> void:
	var contacts: Array = mission.receiver_contacts() if intro_done else []
	rig.receiver.contacts = contacts
	rig.receiver.selected_id = mission.selected_emitter
	var level := 0.0
	for c in contacts:
		if int(c["id"]) == mission.selected_emitter:
			level = float(c["strength"])
	if level == 0 and not contacts.is_empty():
		level = float(contacts[0]["strength"])
	rig.receiver.signal_level = lerpf(rig.receiver.signal_level, level, .25)
	rig.receiver.warning = mission.incoming
	rig.receiver.queue_redraw()
	rig.chart.queue_redraw()
	rig.set_lamp("search", not contacts.is_empty())
	rig.set_lamp("track", mission.tracking > .28)
	rig.set_lamp("launch", mission.incoming)
	rig.set_lamp("auth", mission.authorized and not mission.payload_released)
	rig.set_lamp(
		"zone",
		(
			mission.active
			and not mission.endless
			and not mission.payload_released
			and mission.position.distance_to(mission.target) < mission.tuning.release_radius
		)
	)
	var same_area := false
	if last_scan.has("center"):
		var center := Vector2(last_scan["center"][0], last_scan["center"][1])
		same_area = (
			center.distance_to(rig.chart.selected_center) < .5
			and absf(float(last_scan["extent"]) - selected_extent) < .5
			and str(last_scan.get("quality", "")) == current_quality
			and not radar_hold
		)
	rig.set_lamp("frame", same_area and rig.powered)
	rig.set_lamp("stored", not same_area and not last_scan.is_empty() and rig.powered)
	rig.set_lamp("tx", link.busy and rig.powered)
	rig.counters["stores"].text = (
		"ARM %d / CM %d %s"
		% [mission.arm_count, mission.countermeasures, "LIVE" if mission.armed else "SAFE"]
	)
	rig.needles["alt"].rotation.z = lerpf(
		deg_to_rad(125), deg_to_rad(-125), clampf(mission.altitude / 3000, 0, 1)
	)
	rig.needles["fuel"].rotation.z = lerpf(deg_to_rad(125), deg_to_rad(-125), mission.fuel)
	rig.needles["integrity"].rotation.z = lerpf(
		deg_to_rad(125), deg_to_rad(-125), mission.integrity
	)
	rig.needles["heading"].rotation.z = -mission.heading
	rig.set_switch("arm_guard", mission.armed)
	rig.set_switch("hold", radar_hold)
	rig.mission_card.text = (
		mission.phase_name()
		+ (
			(
				" / %d CHART FIX%s"
				% [mission.route.points.size(), "" if mission.route.points.size() == 1 else "ES"]
			)
			if not mission.route.points.is_empty()
			else " / MANUAL"
		)
	)
	if mission.finished:
		rig.mission_card.text = mission.phase_name()
	var settings:Dictionary={"survey":"FAST 6x8m","map":"MED 4x5m","detail":"FINE 2x2.5m"}
	rig.counters["resolution"].text=str(settings[current_quality])
	rig.counters["scan_area"].text="AREA %.1fkm" % (selected_extent/1000)
	rig.counters["heading_command"].text="SET %03d / HDG %03d" % [posmod(int(round(rad_to_deg(mission.commanded_heading))),360),posmod(int(round(rad_to_deg(mission.heading))),360)]


func _update_camera(dt: float) -> void:
	var pos := Vector3(0, 1.60, 2.43)
	var aim := Vector3(0, .96, -.2)
	var fov := 52.0
	if prepared_world and not intro_done:
		if intro_clock < 6.8:
			aim = Vector3(0, 1.74, -2.7)
		else:
			aim = Vector3(-.55, 1.95, -1.9)
	elif focus > 0:
		var x: float = [0, -1.22, 0, 1.24][focus]
		pos = Vector3(x, 1.42, 1.85)
		aim = Vector3(x, .95, .05)
		fov = 58
	var shake := Vector3(sin(total_time * 42), cos(total_time * 51), 0) * damage_shake * .025
	rig.camera.position = rig.camera.position.lerp(pos + shake, 1 - exp(-dt * 5))
	var desired: Transform3D = rig.camera.global_transform.looking_at(aim, Vector3.UP)
	desired.basis = desired.basis * Basis(Vector3.UP, head_yaw) * Basis(Vector3.RIGHT, head_pitch)
	rig.camera.basis = rig.camera.basis.slerp(desired.basis, 1 - exp(-dt * 5))
	rig.camera.fov = lerpf(rig.camera.fov, fov, 1 - exp(-dt * 5))


func _update_hint() -> void:
	if help_visible:
		return
	var pointer := get_viewport().get_mouse_position()
	var action: String = rig.action_at(pointer)
	if not action.is_empty():
		overlay.hint.text = action.replace("_", " ").to_upper() + "   /   CLICK"
	elif rig.uv_hit(rig.chart_quad, Vector2(.87, 1.12), pointer).x >= 0:
		overlay.hint.text = "CHART / CLICK GUIDES · WHEEL SIZE · SHIFT HEADING · CTRL+SHIFT ADD FIX" if mission.endless else "CHART / CLICK SCAN · SHIFT COURSE · CTRL+SHIFT ADD FIX · DEL UNDO"
	else:
		overlay.hint.text = "H / NOTES   B / LOCAL CHART   Z / PAPER SCALE" + ("    P / RESUME" if paused else "")


func _action(action: String) -> void:
	if (paused or help_visible) and action not in ["help", "pause", "ack"]:
		return
	rig.press_control(action)
	match action:
		"help":
			_toggle_help()
		"pause":
			_toggle_pause()
		"scan":
			_request_scan()
		"resolution":
			var modes:Array[String]=["survey","map","detail"]
			_set_resolution(modes[(modes.find(current_quality)+1)%3])
		"range":
			_resize_area(1)
		"gain":
			var value: float = rig.radar_material.get_shader_parameter("intensity")
			rig.radar_material.set_shader_parameter(
				"intensity", 1.25 if value > 1.9 else value + .35
			)
			_play("click")
		"hold":
			radar_hold = not radar_hold
			_radio(
				(
					"RADAR / "
					+ ("HOLD — stored returns retained." if radar_hold else "HOLD released.")
				),
				"click"
			)
		"select":
			mission.cycle_emitter()
			_play("click")
		"arm_guard":
			mission.toggle_arm()
			_play("click")
		"arm_fire":
			mission.fire_arm()
		"chaff":
			mission.deploy_countermeasure()
		"release":
			mission.release_payload()
		"left":
			mission.command_course(-10)
			_play("click")
		"right":
			mission.command_course(10)
			_play("click")
		"ack":
			overlay.caption_panel.hide()
			overlay.caption_seconds = 0
			_play("click")


func _resize_area(direction: int) -> void:
	if mission.endless:
		selected_extent=clampf(selected_extent+direction*200.0,400.0,4000.0)
	else:
		var sizes:Array=[600.,1000.,1600.,2000.,3200.,4000.] if scenario_mode=="sortie" else [600.,1000.,1600.,2000.]
		selected_extent=sizes[posmod(sizes.find(selected_extent)+direction,sizes.size())]
	rig.chart.change_extent(selected_extent)
	_play("click")

func _set_resolution(mode:String) -> void:
	if mode not in ["survey","map","detail"]:return
	current_quality=mode
	_update_instruments()
	_play("click")


func _input(event: InputEvent) -> void:
	if overlay and overlay.blocks_cockpit_input():
		dragging_head = false
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			dragging_head = event.pressed
			return
		if not event.pressed or help_visible:
			return
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			if rig.uv_hit(rig.chart_quad, Vector2(.87, 1.12), event.position).x >= 0:
				_resize_area(1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			var uv: Vector2 = rig.uv_hit(rig.chart_quad, Vector2(.87, 1.12), event.position)
			if uv.x >= 0:
				var point: Vector2 = rig.chart.screen_to_world(uv * rig.chart.size)
				if event.shift_pressed and not paused:
					if mission.endless and not event.ctrl_pressed:mission.command_direction(point)
					else:mission.command_waypoint(point,event.ctrl_pressed)
				else:
					rig.chart.select(point)
					_play("click")
				return
			_action(rig.action_at(event.position))
	elif event is InputEventMouseMotion and dragging_head:
		head_yaw = clampf(head_yaw - event.relative.x * .002, -.45, .45)
		head_pitch = clampf(head_pitch - event.relative.y * .002, -.3, .3)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo() or not event is InputEventKey:
		return
	if overlay and overlay.debrief_visible() and event.physical_keycode not in [KEY_R, KEY_N]:
		return
	match event.physical_keycode:
		KEY_SPACE:
			_request_scan()
		KEY_C:
			_action("select")
		KEY_M:
			_action("arm_guard")
		KEY_F:
			_action("arm_fire")
		KEY_X:
			_action("chaff")
		KEY_ENTER:
			_action("release")
		KEY_B:
			_toggle_briefing()
		KEY_Z:
			rig.chart.cycle_scale()
		KEY_H:
			_toggle_help()
		KEY_ESCAPE:
			_toggle_help()
		KEY_P:
			_toggle_pause()
		KEY_R:
			_restart()
		KEY_N:
			_new_seed()
		KEY_DELETE:
			if not paused and not help_visible:
				mission.undo_waypoint()
		KEY_F1:
			focus = 1
			head_yaw = 0
			head_pitch = 0
		KEY_F2:
			focus = 2
			head_yaw = 0
			head_pitch = 0
		KEY_F3:
			focus = 3
			head_yaw = 0
			head_pitch = 0
		KEY_F4:
			focus = 0
			head_yaw = 0
			head_pitch = 0
		KEY_1:
			_set_resolution("survey")
			_radio("RADAR / Survey response selected.", "click")
		KEY_2:
			_set_resolution("map")
			_radio("RADAR / Map response selected.", "click")
		KEY_3:
			_set_resolution("detail")
			_radio("RADAR / Detail response selected.", "click")
		KEY_BACKSPACE:
			if prepared_world and not intro_done:
				intro.skip()
				intro_stage = "active"
				rig.set_shutters(1)
				rig.blackout(false)
				rig.combat_lighting(1)
				overlay.flash.color.a = 0
		KEY_F8:
			reduced_flash = not reduced_flash
			overlay.reduced_toggle.set_pressed_no_signal(reduced_flash)
			_radio("Reduced-flash option " + ("ON" if reduced_flash else "OFF"), "")


func _toggle_help() -> void:
	if briefing and briefing.visible:
		_toggle_briefing();return
	help_visible = not help_visible
	overlay.show_notes(help_visible, mission.journal)


func _toggle_pause() -> void:
	paused = not paused
	_radio("PAUSED / Press P to resume." if paused else "PILOT / Continuing on course.", "")


func _new_seed() -> void:
	get_tree().set_meta("cockpit_seed", mission.seed_value + 1)
	_restart()


func _restart() -> void:
	link.shutdown()
	get_tree().reload_current_scene()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_close()


func _close() -> void:
	if closed:
		return
	closed = true
	if frame_probe:frame_probe.finish()
	link.shutdown()
	engine_audio.stop()
	radio_audio.stop()
	effects_audio.stop()
	engine_audio.stream = null
	radio_audio.stream = null
	effects_audio.stream = null
	await get_tree().create_timer(.2).timeout
	get_tree().quit()


func _toggle_briefing() -> void:
	if scenario_mode not in ["sortie","endless"] or not prepared_world or not intro_done or mission.finished:return
	briefing.visible=not briefing.visible
	help_visible=briefing.visible
	overlay.menu.hide()
	if briefing.visible:briefing.chart.queue_redraw()

func _select_briefed_route(name_: String) -> void:
	if mission.select_briefed_route(name_):
		briefing.hide();help_visible=false
		rig.chart.queue_redraw()


func _sheet_changed(data:Dictionary) -> void:
	if last_scan.has("global_center"):
		var p:Vector2=mission.local_point(last_scan["global_center"]);last_scan["center"]=[p.x,p.y]
	briefing.configure(data,rig.chart.chart)
