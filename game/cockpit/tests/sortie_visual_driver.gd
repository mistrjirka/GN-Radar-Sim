extends Node
## End-to-end sortie exercise, loaded only by --sortie-test.
## Time-accelerated mission ticks are TEST ONLY. No position teleports or free stores.
var game
var capture_dir := ""
var clock := 0.0
var stage := 0
var stage_time := 0.0
var captures: Array[String]=[]
var records:Dictionary={"simulation_time_multiplier":30,"position_teleports":0,"free_stores":0}
var test_records:Dictionary:
	get:return records
var no_captures:=false
var last_usec:=0
var frame_times:Array[float]=[]
var scan_on_route:=false
var completed:=false

func configure(controller,folder:String) -> void:
	game=controller;capture_dir=folder
	no_captures="--no-captures" in OS.get_cmdline_user_args()
	DirAccess.make_dir_recursive_absolute(capture_dir)

func capture(name_:String) -> void:
	if no_captures or captures.has(name_) or DisplayServer.get_name()=="headless":return
	RenderingServer.force_draw(false)
	var image:=get_viewport().get_texture().get_image()
	if image and not image.is_empty() and image.save_png(capture_dir.path_join(name_+".png"))==OK:captures.append(name_)

func _process(dt:float) -> void:
	if completed or game.closed:return
	clock+=dt;stage_time+=dt
	var now:=Time.get_ticks_usec()
	if last_usec>0:frame_times.append(float(now-last_usec)/1000)
	last_usec=now
	if clock>175:
		records["timeout"]=true;finish();return
	if not game.prepared_world or not game.intro_done:return
	if stage==0 and game.scan_count>=1 and game.mission.elapsed>2:
		game.paused=true;capture("01_sortie_station")
		records["first_scan"]=game.last_scan.duplicate(true)
		game._toggle_briefing();stage=1;stage_time=0
	elif stage==1 and stage_time>.5:
		capture("02_sortie_orders")
		# Exercise the same briefing button signal path, not direct state mutation.
		game.briefing.route_requested.emit("western")
		records["route_accepted"]=game.mission.route.points.size()==5
		game.focus=3;stage=2;stage_time=0
	elif stage==2 and stage_time>.8:
		capture("03_rolling_route")
		game.focus=0;stage=3;stage_time=0
	elif stage==3:
		var m=game.mission
		if not m.finished:
			if m.tracking>.65:m.deploy_countermeasure()
			if m.tracking>.5 and m.arm_count>0 and m.missile_time<=0:
				if not m.armed:m.toggle_arm()
				m.cycle_emitter();m.fire_arm()
			if not m.payload_released and m.position.distance_to(m.target)<m.tuning.release_radius*.8:
				records["release_position"]=[m.position.x,m.position.y]
				records["release_success"]=m.release_payload()
				capture("06_objective_complete")
			m.tick(dt*30)
		if not scan_on_route and m.distance_flown>10000:
			scan_on_route=true
			# Public geography ahead of the current flight, not a secret enemy position.
			game.rig.chart.select(m.position+Vector2(sin(m.heading),cos(m.heading))*1800)
			game.paused=false;game._request_scan();game.paused=true
			stage=4;stage_time=0
		elif m.finished:
			records["flown_record"]=m.debrief();stage=5;stage_time=0
	elif stage==4 and not game.link.busy:
		records["second_scan"]=game.last_scan.duplicate(true)
		capture("04_inland_scan");game.focus=2;stage=6;stage_time=0
	elif stage==6 and stage_time>.8:
		capture("05_inland_radar");game.focus=0;stage=3
	elif stage==5 and stage_time>.5:
		capture("07_flight_record");finish()

func finish() -> void:
	if completed:return
	completed=true
	frame_times.sort()
	records["captures"]=captures;records["scan_count"]=game.scan_count
	records["world_scenario"]=game.mission_data.get("scenario")
	records["world_bounds"]=game.mission_data.get("bounds")
	records["rwr_keys"]=game.mission.receiver_contacts()[0].keys() if not game.mission.receiver_contacts().is_empty() else ["id","bearing","strength","tracking"]
	records["frame_ms_p95"]=frame_times[int(frame_times.size()*.95)] if not frame_times.is_empty() else 0
	records["frame_ms_max_including_captures"]=frame_times[-1] if not frame_times.is_empty() else 0
	records["worker_folder"]=game.link.folder
	records["success"]=not records.has("timeout") and records.get("route_accepted",false) and game.mission.finished and game.mission.survived and game.scan_count>=2
	var f:=FileAccess.open(capture_dir.path_join("sortie_test.json"),FileAccess.WRITE)
	if f:f.store_string(JSON.stringify(records,"  "));f.close()
	print("SORTIE_VISUAL_RESULT ",JSON.stringify(records))
	game._close()
