extends Node
## End-to-end actual input, worker scans, native draws and no-teleport turns.
## --no-captures runs the same path for frame timing without PNG readback.
var game
var output:=""
var stage:=0
var timer:=0.0
var clock:=0.0
var snapshots:Array=[]
var checks:Dictionary={}
var scan_records:Array=[]
var frames:Array[float]=[]
var last_usec:=0
var native_draws:=0
var no_captures:=false
var finished:=false
var latched_rect:Rect2
var latched_center:Array=[]
var latched_projected:Vector2
var launch_target:Array=[]
var error_message:=""
var initial_scan_count:=0

func configure(controller,folder:String) -> void:
	game=controller;output=folder
	no_captures="--no-captures" in OS.get_cmdline_user_args()
	DirAccess.make_dir_recursive_absolute(output)
	game.link.failed.connect(func(message):error_message=message)

func capture(name_:String) -> void:
	if no_captures or snapshots.has(name_) or DisplayServer.get_name()=="headless":return
	RenderingServer.force_draw(false)
	var image:=get_viewport().get_texture().get_image()
	if image and not image.is_empty() and image.save_png(output.path_join(name_+".png"))==OK:snapshots.append(name_)

func click_quad(quad:MeshInstance3D,dimensions:Vector2,uv:Vector2) -> void:
	var e:=InputEventMouseButton.new();e.button_index=MOUSE_BUTTON_LEFT;e.pressed=true
	e.position=game.rig.camera.unproject_position(quad.to_global(Vector3((uv.x-.5)*dimensions.x,(.5-uv.y)*dimensions.y,0)))
	game._input(e)

func click_control(action:String) -> void:
	for control in game.rig.controls:
		if control["action"]==action:
			click_quad(control["mesh"],control["size"],Vector2(.5,.5));return

func _process(dt:float) -> void:
	if finished or game.closed:return
	clock+=dt;timer+=dt
	if DisplayServer.get_name()!="headless":RenderingServer.force_draw(false,dt);native_draws+=1
	var now:=Time.get_ticks_usec()
	if last_usec>0:frames.append(float(now-last_usec)/1000)
	last_usec=now
	if clock>140:
		checks["timeout"]=false;finish();return
	if not error_message.is_empty():checks["no_worker_error"]=false;finish();return
	if not game.intro_done or not game.prepared_world:return
	match stage:
		0:
			if game.acquisition.can_designate():
				scan_records.append(game.last_scan.duplicate(true))
				capture("01_station")
				game.focus=3;stage=1;timer=0
		1:
			if timer>.7:
				# A real click in front of the fixed bottom aircraft index.
				click_quad(game.rig.chart_quad,Vector2(.87,1.12),Vector2(.5,.41))
				game.mission.command_direction(game.mission.position+Vector2(12000,0))
				capture("02_heading_up_before")
				click_control("scan")
				checks["scan_button_submitted"]=game.acquisition.is_busy()
				latched_rect=game.rig.chart.selection_rect()
				latched_center=game.mission.global_point(game.rig.chart.selected_center)
				latched_projected=game.rig.chart.world_to_screen(game.rig.chart.selected_center)
				checks["guides_stable"]=true;checks["ground_bounds_stable"]=true
				stage=2;timer=0
		2:
			if game.acquisition.is_busy():
				checks["guides_stable"]=checks["guides_stable"] and game.rig.chart.selection_rect()==latched_rect
				var current:Array=game.mission.global_point(game.rig.chart.selected_center)
				checks["ground_bounds_stable"]=checks["ground_bounds_stable"] and Vector2(current[0]-latched_center[0],current[1]-latched_center[1]).length()<.01
				if timer>.4 and game.acquisition.stage=="computing":capture("03_map_hold")
				if timer>.85:game.focus=2
				game._set_resolution("survey")
				checks["mode_locked"]=game.current_quality=="detail"
				if game.acquisition.stage=="resolving":
					game.focus=2
					if game.acquisition.progress<.18:capture("04a_whole_soft")
					if game.acquisition.progress>.28 and game.acquisition.progress<.50:capture("04_radar_forming")
					if game.acquisition.progress>.72 and game.acquisition.progress<.9:capture("05_radar_forming_late")
			elif game.acquisition.can_designate():
				capture("05b_fully_resolved")
				scan_records.append(game.last_scan.duplicate(true));game.focus=2;stage=3;timer=0
		3:
			if timer>.6:
				click_quad(game.rig.radar_quad,Vector2(1.08,.96),Vector2(.55,.38))
				checks["radar_designation_click"]=not game.mission.designated_point.is_empty()
				launch_target=game.mission.designated_point.duplicate()
				capture("06_marked_radar")
				click_control("arm_guard");click_control("arm_fire")
				checks["coordinate_fired"]=game.mission.coordinate_weapon.active
				checks["launch_no_auto_target"]=game.mission.coordinate_weapon.destination==launch_target
				game.focus=1;stage=4;timer=0
		4:
			if timer>.8:
				capture("07_circular_rwr")
				var contacts:Array=game.mission.receiver_contacts()
				checks["rwr_estimated_range"]=not contacts.is_empty() and contacts[0].has("estimated_range_m")
				checks["rwr_far_sites"]=false
				for c in contacts:
					if c["estimated_range_m"]>5000:checks["rwr_far_sites"]=true
				game.focus=3;stage=5;timer=0
		5:
			if absf(wrapf(game.mission.heading-PI/2,-PI,PI))<.006:
				checks["turned_gradually"]=game.mission.distance_flown>1200
				checks["plane_bottom_fixed"]=game.rig.chart.world_to_screen(game.mission.position).distance_to(Vector2(320,648))<.01
				capture("08_east_heading_map")
				# Inhibit a self-scan without sending a malformed request to Python.
				var old_id:int=game.link.rid
				game.rig.chart.select(game.mission.position);game._request_scan()
				checks["self_scan_inhibited"]=game.link.rid==old_id and not game.acquisition.is_busy()
				click_quad(game.rig.chart_quad,Vector2(.87,1.12),Vector2(.5,.35))
				click_control("resolution")
				checks["rotary_mode_changed"]=game.current_quality=="survey"
				click_control("scan");initial_scan_count=game.scan_count
				stage=6;timer=0
		6:
			if game.scan_count>initial_scan_count and game.acquisition.can_designate():
				scan_records.append(game.last_scan.duplicate(true))
				checks["rotated_real_scan"]=absf(game.last_scan.get("heading",0)-PI/2)<.015
				game.focus=0;stage=7;timer=0
		7:
			if timer>1:
				capture("09_updated_cockpit")
				checks["projectile_reached_mark"]=game.mission.last_coordinate_outcome!="IN FLIGHT" and not game.mission.coordinate_weapon.active
				checks["flight_not_paused_for_scans"]=game.mission.distance_flown>1500
				finish()

func finish() -> void:
	if finished:return
	finished=true
	var summary:Dictionary={"checks":checks,"captures":snapshots,"scans":scan_records,"native_draws":native_draws,
		"screenshots":not no_captures,"elapsed_s":clock,"distance_m":game.mission.distance_flown,"error":error_message,
		"frame_scope":"Native rendered wall intervals, including capture costs only when screenshots=true.","version":"playability-heading-up"}
	var ok:=not checks.is_empty()
	for result in checks.values():ok=ok and bool(result)
	summary["success"]=ok;frames.sort()
	summary["frame_intervals"]=frames.size()
	summary["frame_p95_ms"]=frames[int(frames.size()*.95)] if not frames.is_empty() else 0
	summary["frame_max_ms"]=frames[-1] if not frames.is_empty() else 0
	summary["frames_over_33ms"]=frames.filter(func(v):return v>1000.0/30).size()
	var file:=FileAccess.open(output.path_join("playability.json"),FileAccess.WRITE)
	if file:file.store_string(JSON.stringify(summary,"  "));file.close()
	print("PLAYABILITY_RUN ",JSON.stringify(summary))
	game.call_deferred("_close")
