extends Node
## Real-time frame audit. No time acceleration, teleporting or PNGs at any stage.
## force_draw submits native rendering when the background desktop suppresses it.
var game
var output := ""
var rows: Array = []
var events: Array = []
var clock := 0.0
var previous_usec := 0
var frame_label := "startup"
var stage := 0
var started_play := -1.0
var done := false
var scans: Array = []
var render_ms: Array[float] = []

func configure(controller, folder: String) -> void:
	game=controller;output=folder
	DirAccess.make_dir_recursive_absolute(output)
	game.link.timing_event.connect(_timing)
	game.link.scan_ready.connect(func(_texture,details):scans.append(details.duplicate(true)))

func _timing(label: String, duration: float) -> void:
	events.append({"seconds":clock,"label":label,"duration_ms":duration})

func _process(dt: float) -> void:
	if done or game.closed:return
	var now:=Time.get_ticks_usec()
	if previous_usec>0:
		rows.append([clock, float(now-previous_usec)/1000.0,frame_label])
	previous_usec=now
	clock+=dt
	frame_label="world_loading" if not game.prepared_world else ("intro" if not game.intro_done else "flight")
	if game.link.busy:frame_label+=" / worker"
	if game.help_visible:frame_label="briefing_or_notes"
	if clock>100:finish(false);return
	if game.intro_done and game.scan_count>0:
		if started_play<0:started_play=clock
		var play:=clock-started_play
		if stage==0 and play>1:
			var t:=Time.get_ticks_usec();game._toggle_briefing()
			_timing("open_briefing",float(Time.get_ticks_usec()-t)/1000);stage=1
		elif stage==1 and play>3:
			game._select_briefed_route("western");stage=2
		elif stage==2 and play>5 and not game.link.busy:
			game.focus=3;game.rig.chart.cycle_scale()
			game.rig.chart.select(game.mission.position+Vector2(500,2100))
			game._request_scan();stage=3
		elif stage==3 and play>13:
			game._toggle_help();stage=4
		elif stage==4 and play>15:
			game._toggle_help();game.focus=2;stage=5
		elif stage==5 and play>18 and not game.link.busy:
			game.selected_extent=600;game.rig.chart.change_extent(600)
			game.rig.chart.select(game.mission.position+Vector2(350,1800))
			game.current_quality="survey";game._request_scan();stage=6
		elif stage==6 and play>24:
			game.focus=0;game.rig.chart.cycle_scale();stage=7
		elif stage==7 and play>27 and not game.link.busy:
			game.current_quality="detail";game.selected_extent=2000;game.rig.chart.change_extent(2000)
			game.rig.chart.select(game.mission.position+Vector2(600,2000))
			game._request_scan();stage=8
		elif stage==8 and play>37 and not game.link.busy:
			finish(true);return
	if DisplayServer.get_name()!="headless":
		var draw_start:=Time.get_ticks_usec()
		RenderingServer.force_draw(false,dt)
		render_ms.append(float(Time.get_ticks_usec()-draw_start)/1000.0)

func distribution(values: Array) -> Dictionary:
	if values.is_empty():return {}
	values.sort()
	var over_33:=0;var over_50:=0;var over_100:=0
	for v in values:
		if v>33.33:over_33+=1
		if v>50:over_50+=1
		if v>100:over_100+=1
	return {"count":values.size(),"median_ms":values[int(values.size()*.5)],"p95_ms":values[int(values.size()*.95)],
		"p99_ms":values[int(values.size()*.99)],"max_ms":values[-1],"frames_over_33ms":over_33,"frames_over_50ms":over_50,"frames_over_100ms":over_100}

func finish(ok: bool) -> void:
	if done:return
	done=true
	var overall: Array=[];var flight: Array=[];var phases: Dictionary={};var spikes: Array=[]
	for r in rows:
		overall.append(r[1])
		if r[0]>=started_play and started_play>0:flight.append(r[1])
		if not phases.has(r[2]):phases[r[2]]=[]
		phases[r[2]].append(r[1])
		if r[1]>25:spikes.append(r)
	for key in phases:phases[key]=distribution(phases[key])
	var report:Dictionary={"success":ok,"all_frames":distribution(overall),"gameplay_frames":distribution(flight),
		"render_submission":distribution(render_ms),"phase_frames":phases,"spikes_over_25ms":spikes,
		"events":events,"scans":scans,"worker_folder":game.link.folder,"native_render_submissions":render_ms.size(),
		"screenshot_work_during_measurement":false,"time_acceleration":1,
		"scope":"Monotonic full loop intervals with forced native rendering, not an isolated GPU benchmark; No PNG capture occurs in this driver."}
	var f:=FileAccess.open(output.path_join("frame_pacing.json"),FileAccess.WRITE)
	if f:f.store_string(JSON.stringify(report,"  "));f.close()
	var ff:=FileAccess.open(output.path_join("frame_samples.json"),FileAccess.WRITE)
	if ff:ff.store_string(JSON.stringify(rows));ff.close()
	print("FRAME_AUDIT ",JSON.stringify(report))
	# Keep measurement and screenshot lifecycles separate. Let this callback
	# release local report references before the scene starts shutting down.
	game.call_deferred("_close")
