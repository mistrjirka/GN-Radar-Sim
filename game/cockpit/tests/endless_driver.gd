extends Node
## Optional end-to-end explorer exercise. No teleports, no synthetic radar images.
## --no-captures separates frame timing from synchronous screenshot encoding.
## --endless-realtime keeps flight time at 1x; default test accelerates cruising only.
var game
var capture_dir:=""
var clock:=0.0
var stage:=0
var stage_clock:=0.0
var captures:Array[String]=[]
var scans:Array=[]
var checks:Dictionary={}
var no_captures:=false
var realtime:=false
var turn_samples:Array=[]
var initial_heading:=0.0
var first_sheet:=""
var previous_scans:=0
var frame_rows:Array=[]
var last_usec:=0
var completed:=false
var timing_spans:Array=[]
var draw_ms:=0.0
var before_distance:=0.0
var navigation_start:=0.0
var last_test_event:=0.0

func configure(controller,folder:String) -> void:
	game=controller;capture_dir=folder
	game.link.diagnostic_span.connect(func(label,begin,end):timing_spans.append({"label":label,"time":clock,"duration_ms":float(end-begin)/1000}))
	DirAccess.make_dir_recursive_absolute(capture_dir)
	no_captures="--no-captures" in OS.get_cmdline_user_args()
	realtime="--endless-realtime" in OS.get_cmdline_user_args()

func capture(name_:String) -> void:
	if no_captures or captures.has(name_) or DisplayServer.get_name()=="headless":return
	RenderingServer.force_draw(false)
	var image:=get_viewport().get_texture().get_image()
	if image and not image.is_empty() and image.save_png(capture_dir.path_join(name_+".png"))==OK:captures.append(name_)

func click_paper(uv:Vector2,shift:bool=false) -> void:
	var local:=Vector3((uv.x-.5)*.87,(.5-uv.y)*1.12,0)
	var event:=InputEventMouseButton.new()
	event.button_index=MOUSE_BUTTON_LEFT;event.pressed=true;event.shift_pressed=shift
	event.position=game.rig.camera.unproject_position(game.rig.chart_quad.to_global(local))
	game._input(event)

func click_control(action:String) -> bool:
	for c in game.rig.controls:
		if c["action"]==action:
			var event:=InputEventMouseButton.new()
			event.button_index=MOUSE_BUTTON_LEFT;event.pressed=true
			event.position=game.rig.camera.unproject_position(c["mesh"].global_position)
			game._input(event)
			return true
	return false

func _process(dt:float) -> void:
	if completed or game.closed:return
	clock+=dt;stage_clock+=dt
	var draw_started:=Time.get_ticks_usec()
	if DisplayServer.get_name()!="headless":RenderingServer.force_draw(false,dt)
	draw_ms=float(Time.get_ticks_usec()-draw_started)/1000.0
	var now:=Time.get_ticks_usec()
	if last_usec>0:
		frame_rows.append([clock,float(now-last_usec)/1000,game.link.busy,game.link.chart_busy,game.world_stream.revisions if game.world_stream else 0,stage,draw_ms])
	last_usec=now
	if game.scan_count>previous_scans:
		previous_scans=game.scan_count;scans.append(game.last_scan.duplicate(true))
	if clock>240:
		checks["completed_within_budget"]=false;finish();return
	if not game.intro_done or not game.prepared_world:return
	match stage:
		0:
			if game.scan_count>=1:
				checks["endless_default"]=game.mission.endless
				checks["four_native_bars"]=game.rig.chart_mechanism.bars.size()==4
				first_sheet=game.world_stream.last_key
				capture("01_open_flight")
				game.focus=3;stage=1;stage_clock=0
		1:
			if stage_clock>.8:
				click_paper(Vector2(.48,.40))
				var before:float=game.selected_extent
				game._resize_area(2)
				checks["area_adjusted"]=game.selected_extent==before+400
				stage=11;stage_clock=0
		11:
			if stage_clock>.3:
				capture("02_mechanical_chart")
				initial_heading=game.mission.heading
				click_paper(Vector2(.80,.25),true)
				checks["command_no_snap"]=is_equal_approx(game.mission.heading,initial_heading) and absf(wrapf(game.mission.commanded_heading-initial_heading,-PI,PI))>.1
				stage=2;stage_clock=0
		2:
			turn_samples.append([stage_clock,game.mission.heading,game.mission.commanded_heading,game.mission.heading_control.rate])
			if stage_clock>2:
				checks["gradual_turn"]=absf(wrapf(game.mission.heading-initial_heading,-PI,PI))>0 and absf(wrapf(game.mission.heading-game.mission.commanded_heading,-PI,PI))>.05
				capture("03_turn_in_progress")
				game.focus=2;stage=3;stage_clock=0
		3:
			if stage_clock>.8:
				checks["physical_resolution_button"]=click_control("resolution") and game.current_quality=="survey"
				game._request_scan();stage=4;stage_clock=0
		4:
			if not game.link.busy:
				capture("04_fast_resolution")
				checks["fast_setting_visible"]=game.rig.counters['resolution'].text.contains("FAST")
				game._set_resolution("map");game._request_scan();stage=5;stage_clock=0
		5:
			if not game.link.busy:
				game._set_resolution("detail");game._request_scan();stage=6;stage_clock=0
		6:
			if not game.link.busy:
				capture("05_fine_resolution")
				checks["fine_setting_visible"]=game.rig.counters['resolution'].text.contains("FINE")
				game.focus=0;before_distance=game.mission.distance_flown
				navigation_start=clock;stage=7;stage_clock=0
		7:
			# Ordinary mission integrator, temporarily faster only in this test.
			# Let the chart catch up before another accelerated stretch.
			if not realtime and not game.link.chart_busy:
				game.mission.tick(dt*19)
			if game.world_stream.revisions>=2 and not checks.has("streamed_sheet"):
				checks["streamed_sheet"]=game.world_stream.last_key!=first_sheet
				capture("06_new_landscape")
			if game.world_stream.revisions>=3 and not game.link.busy and scans.size()<5:
				game.rig.chart.select(game.mission.position+Vector2(0,2500))
				game._request_scan()
			var travelled:float=game.mission.distance_flown-before_distance
			var done:bool=travelled>(5000 if realtime else 27000) and game.world_stream.revisions>=2 and not game.link.chart_busy and not game.link.busy
			if done:
				checks["continued_past_old_bounds"]=not game.mission.finished and game.mission.fuel==1.0
				checks["floating_origin_used"]=game.mission.origin_shift_count>0 if not realtime else true
				game._toggle_briefing();stage=8;stage_clock=0
		8:
			if stage_clock>.5:
				capture("07_local_sheet_notes")
				game._toggle_briefing();capture("08_streamed_cockpit")
				finish()

func finish() -> void:
	if completed:return
	completed=true
	var intervals:Array=[]
	for row in frame_rows:intervals.append(row[1])
	intervals.sort()
	var above33:=0;var above50:=0
	for value in intervals:
		if value>33.333:above33+=1
		if value>50:above50+=1
	var success:=checks.size()>=9
	for value in checks.values():success=success and bool(value)
	var report:Dictionary={"success":success,"checks":checks,"captures":captures,"scans":scans,
		"wall_seconds":clock,"simulated_seconds":game.mission.elapsed,"distance_m":game.mission.distance_flown,
		"global_position":game.mission.global_position_array(),"origin_shifts":game.mission.origin_shift_count,
		"sheet_updates":game.world_stream.revisions,"current_sheet":game.world_stream.last_key,
		"turn_samples":turn_samples,"timing_spans":timing_spans,"frames":intervals.size(),"frame_p95_ms":intervals[int(intervals.size()*.95)] if intervals.size()>0 else 0,
		"frame_max_ms":intervals[-1] if intervals.size()>0 else 0,"over_33_ms":above33,"over_50_ms":above50,
		"screenshots_during_test":not no_captures,"test_time_acceleration":1 if realtime else 20,
		"position_teleports":0,"worker_folder":game.link.folder,
		"scope":"Native render submissions; screenshot runs include PNG readback costs. Exploration test is finite evidence, not literally infinite."}
	var file:=FileAccess.open(capture_dir.path_join("endless_test.json"),FileAccess.WRITE)
	if file:file.store_string(JSON.stringify(report,"  "));file.close()
	file=FileAccess.open(capture_dir.path_join("endless_frames.json"),FileAccess.WRITE)
	if file:file.store_string(JSON.stringify(frame_rows));file.close()
	print("ENDLESS_TEST ",JSON.stringify(report))
	game.call_deferred("_close")
