extends Node
## Real-time input/workload replay. No forced draws, screenshots or mission time warp.
var game
var output_dir := ""
var clock := 0.0
var flight_clock := 0.0
var next_scan := 0.0
var next_ui := 12.0
var ui_step := 0
var requested := 0
var test_records: Dictionary={"real_time_simulation":true,"screenshots":false}
var scans:Array=[]
var complete := false
var budget_seconds := 110.0

func configure(controller, directory: String) -> void:
	game=controller;output_dir=directory
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--perf-seconds="):budget_seconds=float(arg.trim_prefix("--perf-seconds="))

func _process(dt: float) -> void:
	if complete or game.closed:return
	clock+=dt
	if clock>budget_seconds+40 and not game.intro_done:
		test_records["startup_timeout"]=true;finish();return
	if not game.intro_done:return
	flight_clock+=dt
	if not game.mission.finished and not game.help_visible:
		if game.mission.tracking>.65:game.mission.deploy_countermeasure()
		if game.mission.tracking>.5 and game.mission.arm_count>0 and game.mission.missile_time<=0:
			if not game.mission.armed:game.mission.toggle_arm()
			game.mission.cycle_emitter();game.mission.fire_arm()
	if flight_clock>next_scan and not game.link.busy and not game.help_visible and not game.mission.finished:
		var extents:Array[float]=[600.,2000.,4000.,1000.,3200.,1600.]
		game.selected_extent=extents[requested%extents.size()]
		game.rig.chart.change_extent(game.selected_extent)
		var ahead:=Vector2(sin(game.mission.heading),cos(game.mission.heading))
		game.rig.chart.select(game.mission.position+ahead*(game.selected_extent*.6+900))
		game.current_quality=["detail","map","survey"][requested%3]
		game._request_scan()
		requested+=1;next_scan=flight_clock+9
	if game.scan_count>scans.size():
		scans.append(game.last_scan.duplicate(true))
	if flight_clock>next_ui:
		var started:=Time.get_ticks_usec()
		match ui_step%6:
			0:game._toggle_briefing()
			1:
				if game.briefing.visible:
					game.briefing.preview("direct" if ui_step<8 else "western")
					game._toggle_briefing()
			2:game._toggle_help()
			3:
				if game.help_visible:game._toggle_help()
			4:game.focus=(game.focus+1)%4;game.rig.chart.cycle_scale()
			5:game.focus=0;game.mission.command_course(4)
		game.frame_probe.record_span("ui_transition_"+str(ui_step),started,Time.get_ticks_usec())
		ui_step+=1;next_ui=flight_clock+(1.0 if ui_step%6 in [1,3] else 6.0)
	if flight_clock>=budget_seconds and not game.link.busy:finish()

func finish() -> void:
	if complete:return
	complete=true
	test_records["flight_seconds"]=flight_clock;test_records["wall_seconds"]=clock
	test_records["requests"]=requested;test_records["scans"]=scans
	test_records["ui_transitions"]=ui_step;test_records["worker_folder"]=game.link.folder
	test_records["radar_error"]=test_records.get("radar_error","")
	var f:=FileAccess.open(output_dir.path_join("performance_run.json"),FileAccess.WRITE)
	if f:f.store_string(JSON.stringify(test_records,"  "));f.close()
	game.frame_probe.finish()
	print("PERFORMANCE_RUN_COMPLETE ",clock," seconds / ",scans.size()," scans")
	game._close()
