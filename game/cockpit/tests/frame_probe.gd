extends Node
## Optional measured frame trace; enabled only by --performance-test.
## No screenshots, fixed-delta substitution, printing or disk I/O during samples.
var game
var output_dir := ""
var frames: Array=[]
var spans: Array=[]
var last_usec := 0
var started_usec := 0
var finished := false
var native_draws := 0
var native_draw_ms:Array[float]=[]

func configure(controller, directory: String) -> void:
	game=controller;output_dir=directory
	process_priority=100
	started_usec=Time.get_ticks_usec()

func record_span(label: String, start_usec: int, end_usec: int) -> void:
	spans.append({"name":label,"start_ms":float(start_usec-started_usec)/1000,"duration_ms":float(end_usec-start_usec)/1000})

func _process(_dt: float) -> void:
	if finished:return
	if DisplayServer.get_name()!="headless":
		var render_started:=Time.get_ticks_usec()
		RenderingServer.force_draw(false,_dt)
		native_draws+=1
		native_draw_ms.append(float(Time.get_ticks_usec()-render_started)/1000.0)
	var now:=Time.get_ticks_usec()
	if last_usec>0:
		var phase: String="loading"
		if game.prepared_world:phase="intro" if not game.intro_done else "flight"
		if game.help_visible:phase="briefing_or_notes"
		if game.mission and game.mission.finished:phase="debrief"
		frames.append([float(now-started_usec)/1000,float(now-last_usec)/1000,
			Performance.get_monitor(Performance.TIME_PROCESS)*1000,
			phase,game.link.busy if game.link else false,game.scan_count])
	last_usec=now

func finish() -> void:
	if finished:return
	finished=true
	DirAccess.make_dir_recursive_absolute(output_dir)
	var report:Dictionary={"units":"milliseconds","columns":["time_ms","wall_frame_ms","engine_process_ms","phase","worker_busy","completed_scans"],
		"frames":frames,"spans":spans,"forced_native_draws":native_draws,"native_draw_ms":native_draw_ms,"screen_capture_enabled":false,"duration_ms":float(Time.get_ticks_usec()-started_usec)/1000,
		"renderer":RenderingServer.get_video_adapter_name(),"resolution":[get_viewport().size.x,get_viewport().size.y]}
	var f:=FileAccess.open(output_dir.path_join("frame_trace.json"),FileAccess.WRITE)
	if f:f.store_string(JSON.stringify(report));f.close()
