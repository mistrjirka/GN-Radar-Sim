extends Node3D
## Ground-mapping radar prototype. Python computes scans, Godot stays interactive.
const Terrain = preload("res://game/radar/shared_terrain.gd")
const FIXTURE = "res://game/radar/reference/approved_valley_south.png"

var worker_pid := -1
var session_path := ""
var request_id := 0
var pending_id := -1
var handled_id := -1
var busy := false
var terrain_ready := false
var closing := false
var poll_elapsed := 0.0
var elapsed := 0.0
var last_scan_time := -100.0
var next_scan_time := 0.0
var scan_interval := 10.0
var last_compute := 0.0
var scan_count := 0
var orbit_angle := 0.0
var flight_altitude := 1450.0
var orbit_radius := 2400.0
var speed_mps := 120.0
var paused := true
var focus_index := 0
var validation_mode := false
var validation_data: Dictionary = {}
var last_state: Dictionary = {}
var selected_scene := "valley"
var selected_models := "preferred"
var selected_quality := "detail"
var terrain_seed := 42
var current_texture: Texture2D
var reference_texture: Texture2D
var current_manifest: Dictionary = {}
var frame_times: Array[float] = []
var last_frame_usec: int = 0
var capture_dir := ""
var automated_test := false
var cycle_test := false
var cycle_results: Array = []
var test_capture_started := false
var test_scene := "valley"

var viewport: SubViewport
var camera: Camera3D
var world: Node3D
var terrain
var columns: HBoxContainer
var scene_column: VBoxContainer
var radar_column: VBoxContainer
var reference_column: VBoxContainer
var radar_image: TextureRect
var reference_image: TextureRect
var reference_caption: Label
var state_label: Label
var telemetry: Label
var radar_caption: Label
var validation_label: Label
var scene_label: Label
var pause_button: Button
var quality_option: OptionButton
var scene_option: OptionButton
var model_option: OptionButton
var seed_edit: LineEdit
var focus_option: OptionButton
var validation_button: Button

func _ready() -> void:
	get_tree().auto_accept_quit = false
	for arg in OS.get_cmdline_user_args():
		if arg == "--test": automated_test = true
		if arg == "--cycle-test": automated_test=true;cycle_test=true
		if arg.begins_with("--capture-dir="): capture_dir = arg.trim_prefix("--capture-dir=")
		if arg.begins_with("--scenario="): test_scene = arg.trim_prefix("--scenario=")
	selected_scene = test_scene
	_build_ui()
	_build_world()
	var stamp := "%d_%d" % [OS.get_process_id(), Time.get_ticks_msec()]
	session_path = ProjectSettings.globalize_path("user://radar_sessions/" + stamp)
	DirAccess.make_dir_recursive_absolute(session_path)
	var python := OS.get_environment("RADAR_PYTHON")
	if python.is_empty(): python = "/usr/bin/python3" if OS.get_name() == "Linux" else "python3"
	var script := ProjectSettings.globalize_path("res://game/radar/backend/worker.py")
	var cache := ProjectSettings.globalize_path("user://radar_world_cache")
	if not OS.get_environment("RADAR_CACHE").is_empty(): cache = OS.get_environment("RADAR_CACHE")
	worker_pid = OS.create_process(python, PackedStringArray([script,"--session",session_path,"--cache",cache,"--parent",str(OS.get_process_id())]),false)
	if worker_pid == -1:
		state_label.text = "Python worker did not start. Set RADAR_PYTHON; see game/radar/README.md"
		return
	_send("prepare")

func _panel_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style

func _label(text: String, size: int = 16) -> Label:
	var node := Label.new()
	node.text = text
	node.add_theme_font_size_override("font_size",size)
	return node

func _button(text: String, callable: Callable, parent: Node) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(callable)
	parent.add_child(b)
	return b

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var background := ColorRect.new()
	background.color = Color(0.025,0.035,0.045)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]: margin.add_theme_constant_override("margin_"+side,12)
	layer.add_child(margin)
	var main := VBoxContainer.new()
	main.add_theme_constant_override("separation",10)
	margin.add_child(main)
	var title := HBoxContainer.new()
	main.add_child(title)
	var heading := _label("GROUND MAPPING  /  FLIGHT LAB",23)
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_child(heading)
	title.add_child(_label("SHARED WORLD  ·  STATISTICAL RADAR  ·  10s REVISIT",13))
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation",8)
	main.add_child(toolbar)
	scene_option = OptionButton.new()
	scene_option.add_item("Approved valley")
	scene_option.add_item("Earlier training range")
	scene_option.select(1 if selected_scene=="legacy" else 0)
	scene_option.item_selected.connect(_scene_changed)
	toolbar.add_child(scene_option)
	seed_edit = LineEdit.new()
	seed_edit.text = "42"
	seed_edit.custom_minimum_size.x = 76
	seed_edit.placeholder_text = "Seed"
	seed_edit.tooltip_text = "Terrain seed. Seed 42 reproduces the reference scene."
	toolbar.add_child(seed_edit)
	_button("Generate",_generate,toolbar)
	model_option = OptionButton.new()
	model_option.add_item("Preferred 3D models")
	model_option.add_item("Reference radar geometry")
	model_option.item_selected.connect(_models_changed)
	toolbar.add_child(model_option)
	quality_option = OptionButton.new()
	quality_option.add_item("Survey · 6m / 8m")
	quality_option.add_item("Map · 4m / 5m")
	quality_option.add_item("Detail · 2m / 2.5m")
	quality_option.select(2)
	quality_option.item_selected.connect(_quality_changed)
	toolbar.add_child(quality_option)
	_button("Scan [Space]",_force_scan,toolbar)
	pause_button = _button("Fly [P]",_toggle_pause,toolbar)
	validation_button = _button("Validate [V]",_toggle_validation,toolbar)
	_button("South",func(): _pose_preset(0,1450,2400),toolbar)
	_button("SW",func(): _pose_preset(-PI/4,1550,2616),toolbar)
	_button("Low",func(): _pose_preset(-PI/4,620,2758),toolbar)
	var second := HBoxContainer.new()
	main.add_child(second)
	focus_option = OptionButton.new()
	for name in ["Aircraft camera / whole map","Inspect SAM site","Inspect bridge","Inspect warehouses","Vehicle close-up","Radar mast close-up"]:focus_option.add_item(name)
	focus_option.item_selected.connect(_focus_changed)
	second.add_child(focus_option)
	state_label = _label("Starting radar worker…",15)
	state_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	second.add_child(state_label)
	telemetry = _label("",14)
	second.add_child(telemetry)
	columns = HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation",12)
	main.add_child(columns)
	scene_column = VBoxContainer.new()
	scene_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(scene_column)
	scene_label = _label("NORMAL CAMERA  ·  Same terrain and model manifest",15)
	scene_column.add_child(scene_label)
	var view_container := SubViewportContainer.new()
	view_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view_container.stretch = true
	view_container.custom_minimum_size = Vector2(200,300)
	scene_column.add_child(view_container)
	viewport = SubViewport.new()
	viewport.size = Vector2i(800,700)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_2X
	view_container.add_child(viewport)
	radar_column = VBoxContainer.new()
	radar_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(radar_column)
	radar_caption = _label("RADAR  ·  Waiting for first scan",15)
	radar_column.add_child(radar_caption)
	radar_image = _image_panel(radar_column)
	reference_column = VBoxContainer.new()
	reference_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(reference_column)
	reference_caption=_label("APPROVED / FROZEN REFERENCE",15)
	reference_column.add_child(reference_caption)
	reference_image = _image_panel(reference_column)
	reference_column.hide()
	validation_label = _label("",14)
	validation_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	validation_label.custom_minimum_size.y = 38
	main.add_child(validation_label)
	main.add_child(_label("A / D orbit  ·  W / S speed  ·  Q / E altitude  ·  P pause  ·  1 / 2 / 3 radar resolution  ·  V validation  ·  Esc exit",14))
	main.add_child(_label("A scan freezes the aircraft pose. Displayed image stays unchanged while the next scan is calculated. Models use shared 2.5D radar proxies, not full-wave mesh scattering.",12))

func _image_panel(parent: Node) -> TextureRect:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",_panel_style(Color(0.005,0.008,0.01)))
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var image := TextureRect.new()
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	panel.add_child(image)
	return image

func _build_world() -> void:
	world = Node3D.new()
	viewport.add_child(world)
	terrain = Terrain.new()
	world.add_child(terrain)
	terrain.build_progress.connect(func(message): state_label.text = message)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.32,0.49,0.62)
	sky_material.sky_horizon_color = Color(0.69,0.74,0.72)
	sky_material.ground_horizon_color = Color(0.50,0.54,0.49)
	sky_material.ground_bottom_color = Color(0.47,0.55,0.57)
	sky.sky_material = sky_material
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.77,0.82,0.87)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var environment := WorldEnvironment.new()
	environment.environment = env
	world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52,-35,0)
	sun.light_color = Color(1.0,0.95,0.85)
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 4500
	world.add_child(sun)
	camera = Camera3D.new()
	camera.near = 3.0
	camera.far = 18000
	camera.fov = 45
	world.add_child(camera)
	camera.current = true
	_update_camera()

func _pose() -> Array:
	return [orbit_radius*sin(orbit_angle),-orbit_radius*cos(orbit_angle),flight_altitude]

func _update_camera() -> void:
	if not camera: return
	var pose := _pose()
	var target := Vector3(0,30,0)
	if validation_mode and focus_index==0:
		camera.projection=Camera3D.PROJECTION_ORTHOGONAL
		camera.keep_aspect=Camera3D.KEEP_WIDTH
		camera.size=640 if selected_scene=="legacy" else 2000
		camera.position=Vector3(0,3000,0)
		camera.look_at(Vector3.ZERO,Vector3(0,0,-1))
		return
	camera.projection=Camera3D.PROJECTION_PERSPECTIVE
	camera.keep_aspect=Camera3D.KEEP_HEIGHT
	if focus_index == 0:
		camera.position = Vector3(pose[0],pose[2],-pose[1])
		camera.fov = 44
	else:
		var center := _focus_center()
		target = Vector3(center.x,terrain.terrain_height(center.x,center.y),-center.y)
		if focus_index==4:
			target.y+=4
			camera.position=target+Vector3(24,18,30)
			camera.fov=58
		elif focus_index==5:
			target.y+=16
			camera.position=target+Vector3(44,18,50)
			camera.fov=48
		else:
			camera.position = target + Vector3(100,230,260)
			camera.fov = 54
	camera.look_at(target,Vector3.UP)

func _focus_center() -> Vector2:
	if focus_index==4:
		for e in current_manifest.get("entities",[]):
			if e["kind"]=="vehicle":return Vector2(float(e["x"]),float(e["y"]))
	if focus_index==5:
		for e in current_manifest.get("entities",[]):
			if e["kind"]=="radar":return Vector2(float(e["x"]),float(e["y"]))
	if selected_scene == "legacy":
		return [Vector2.ZERO,Vector2(-55,-170),Vector2(-170,20),Vector2(200,-160)][mini(focus_index,3)]
	return [Vector2.ZERO,Vector2(-500,-450),Vector2(42,60),Vector2(480,235)][mini(focus_index,3)]

func _texture_crop(tex: Texture2D) -> Texture2D:
	if not tex: return tex
	if focus_index==0:
		if selected_scene!="legacy":return tex
		var small := AtlasTexture.new()
		small.atlas=tex
		var px := tex.get_size()
		small.region=Rect2(Vector2(680.0/2000*px.x,605.0/2000*px.y),Vector2(640.0/2000*px.x,790.0/2000*px.y))
		return small
	var center := _focus_center()
	var extent := (95.0 if focus_index>=4 else (420.0 if focus_index==1 else 460.0))
	var size := tex.get_size()
	var a := AtlasTexture.new()
	a.atlas = tex
	a.region = Rect2(Vector2((center.x-extent/2+1000)/2000*size.x,(1000-center.y-extent/2)/2000*size.y),Vector2(extent/2000*size.x,extent/2000*size.y))
	return a

func _refresh_textures() -> void:
	radar_image.texture = _texture_crop(current_texture)
	reference_image.texture = _texture_crop(reference_texture)

func _send(action: String) -> void:
	if worker_pid < 0 or busy: return
	request_id += 1
	pending_id = request_id
	busy = true
	if action=="prepare": terrain_ready = false
	var data := {"id":request_id,"action":action,"seed":terrain_seed,"scenario":selected_scene,
		"models":selected_models,"quality":selected_quality,"pose":_pose()}
	var file := FileAccess.open(session_path.path_join("request.json.tmp"),FileAccess.WRITE)
	if not file:
		state_label.text = "Cannot write request to "+session_path
		busy = false
		return
	file.store_string(JSON.stringify(data))
	file.close()
	DirAccess.rename_absolute(session_path.path_join("request.json.tmp"),session_path.path_join("request.json"))
	state_label.text = "Generating shared world…" if action=="prepare" else "Calculating new scan; previous image retained…"

func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path,FileAccess.READ)
	if not file:return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

func _poll() -> void:
	if closing or worker_pid < 0:return
	if elapsed>4 and not OS.is_process_running(worker_pid):
		busy=false
		state_label.text="Radar worker stopped. Log: "+session_path+"/worker.log"
		worker_pid=-1
		return
	var status := _read_json(session_path.path_join("status.json"))
	if status.is_empty():
		if elapsed>4 and not OS.is_process_running(worker_pid): state_label.text="Radar worker stopped. See "+session_path+"/worker.log"
		return
	var sid := int(status.get("id",-1))
	if sid != pending_id:return
	var stage := str(status.get("stage",""))
	if stage in ["generating","scanning"]:
		state_label.text = str(status.get("message",stage))
		return
	if sid<=handled_id:return
	if stage=="error":
		handled_id=sid;busy=false;next_scan_time=elapsed+scan_interval
		state_label.text="Radar error: "+str(status.get("message"))
		validation_label.text="Log: "+str(status.get("log",session_path+"/worker.log"))
		return
	if stage=="ready":
		handled_id=sid
		current_manifest=_read_json(str(status["manifest"]))
		await terrain.build(current_manifest)
		terrain_ready=true;busy=false
		_update_camera()
		if automated_test or validation_mode:_validate()
		else:_force_scan()
	elif stage=="complete":
		handled_id=sid;busy=false;last_state=status
		var im: Image
		if status.has("raw_image"):
			var raw_file := FileAccess.open(str(status["raw_image"]),FileAccess.READ)
			if raw_file:
				var bytes := raw_file.get_buffer(raw_file.get_length())
				raw_file.close()
				if bytes.size()==int(status["width"])*int(status["height"]):
					im=Image.create_from_data(int(status["width"]),int(status["height"]),false,Image.FORMAT_L8,bytes)
		else: im=Image.load_from_file(str(status["image"]))
		if im:
			if current_texture is ImageTexture and current_texture.get_width()==im.get_width():
				current_texture.update(im)
			else: current_texture=ImageTexture.create_from_image(im)
		last_compute=float(status.get("stats",{}).get("total_s",status.get("wall_seconds",0)))
		last_scan_time=elapsed
		next_scan_time=elapsed+maxf(0,scan_interval-float(status.get("wall_seconds",last_compute)))
		scan_count+=1
		var value=status.get("validation")
		if value is Dictionary:
			validation_data=value
			reference_caption.text="APPROVED / FROZEN REFERENCE" if selected_scene=="valley" and terrain_seed==42 else "REFERENCE GEOMETRY / NEW RENDER"
			var reference_path=str(value.get("fixture", ""))
			if reference_path=="<null>" or reference_path=="":reference_path=str(value["reference_render"])
			var ref_img := Image.load_from_file(reference_path)
			if ref_img:reference_texture=ImageTexture.create_from_image(ref_img)
			var regression=value.get("regression",{})
			if regression.get("match")==true:
				validation_label.text="PASS: reference-mode replay matches the approved PNG pixel-for-pixel. Detailed model geometry is compared separately."
			elif regression.get("match")==false:
				validation_label.text="Reference replay: mean error %.5f / 255, max %.0f; %d changed pixels. Native-model changes are expected and separate." % [float(regression.get("mean_pixel_error",0)),float(regression.get("max_pixel_error",0)),int(regression.get("changed_pixels",0))]
			else:validation_label.text=str(regression.get("reason","No historical image fixture for this terrain."))
		state_label.text="Scan complete  ·  %.2f s calculation  ·  pose frozen at acquisition" % last_compute
		radar_caption.text="RADAR  /  %s  /  %s" % [str(status.get("quality",selected_quality)).to_upper(),str(status.get("model_mode",selected_models)).to_upper()]
		_refresh_textures()
		if automated_test and not test_capture_started:
			test_capture_started=true
			_capture_test()

func _process(delta: float) -> void:
	var now_usec := Time.get_ticks_usec()
	var actual_frame_ms := float(now_usec-last_frame_usec)/1000.0 if last_frame_usec>0 else delta*1000.0
	last_frame_usec=now_usec
	elapsed+=delta
	if terrain_ready:
		frame_times.append(actual_frame_ms)
		if frame_times.size()>6000:frame_times.pop_front()
		if not paused:
			orbit_angle+=speed_mps/maxf(orbit_radius,1)*delta
		if not seed_edit.has_focus():
			if Input.is_physical_key_pressed(KEY_A):orbit_angle-=0.23*delta
			if Input.is_physical_key_pressed(KEY_D):orbit_angle+=0.23*delta
			if Input.is_physical_key_pressed(KEY_Q):flight_altitude=minf(4000,flight_altitude+120*delta)
			if Input.is_physical_key_pressed(KEY_E):flight_altitude=maxf(320,flight_altitude-120*delta)
			if Input.is_physical_key_pressed(KEY_W):speed_mps=minf(300,speed_mps+50*delta)
			if Input.is_physical_key_pressed(KEY_S):speed_mps=maxf(20,speed_mps-50*delta)
		_update_camera()
		if not busy and not validation_mode and elapsed>=next_scan_time:_send("scan")
	poll_elapsed+=delta
	if poll_elapsed>.15:
		poll_elapsed=0
		_poll()
	telemetry.text="ALT %dm  /  SPD %dm/s  /  %.0f FPS  /  RECEIVED %s AGO" % [int(flight_altitude),int(speed_mps),Engine.get_frames_per_second(),"--" if last_scan_time<0 else "%.1fs" % (elapsed-last_scan_time)]
	if automated_test and elapsed>180 and not test_capture_started:
		state_label.text="Automated test timed out"
		_write_test_report(false)
		_close()

func _force_scan() -> void:
	if terrain_ready and not busy:_send("scan")
func _validate() -> void:
	if not terrain_ready or busy:return
	paused=true;pause_button.text="Fly [P]"
	selected_quality="detail";quality_option.select(2)
	orbit_angle=0;flight_altitude=1450;orbit_radius=2400
	validation_mode=true;reference_column.show();validation_button.text="Leave validation [V]"
	_send("validate")
func _toggle_validation() -> void:
	if busy:return
	if validation_mode:
		validation_mode=false;reference_column.hide();validation_button.text="Validate [V]";next_scan_time=elapsed+scan_interval
	else:_validate()
func _toggle_pause() -> void:
	paused=not paused;pause_button.text="Fly [P]" if paused else "Pause [P]"
func _pose_preset(angle: float,altitude: float,radius: float) -> void:
	orbit_angle=angle;flight_altitude=altitude;orbit_radius=radius;paused=true;pause_button.text="Fly [P]"
	_update_camera();_force_scan()
func _scene_changed(i: int) -> void:
	if busy:
		scene_option.select(0 if selected_scene=="valley" else 1)
		return
	selected_scene="valley" if i==0 else "legacy"
	validation_data={};reference_texture=null;current_texture=null;_refresh_textures()
	_send("prepare")
func _models_changed(i: int) -> void:
	if busy:
		model_option.select(0 if selected_models=="preferred" else 1)
		return
	selected_models="preferred" if i==0 else "reference"
	_send("prepare")
func _quality_changed(i: int) -> void:
	selected_quality=["survey","map","detail"][i]
	if not busy:_force_scan()
func _focus_changed(i: int) -> void:
	focus_index=i;_refresh_textures();_update_camera()
func _generate() -> void:
	if busy:return
	if not seed_edit.text.is_valid_int():
		state_label.text="Seed must be a positive integer";return
	terrain_seed=clampi(int(seed_edit.text),0,2147483647)
	validation_data={};reference_texture=null
	_send("prepare")

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo() or seed_edit.has_focus():return
	if event is InputEventKey:
		match event.physical_keycode:
			KEY_SPACE:_force_scan()
			KEY_P:_toggle_pause()
			KEY_V:_toggle_validation()
			KEY_1:quality_option.select(0);_quality_changed(0)
			KEY_2:quality_option.select(1);_quality_changed(1)
			KEY_3:quality_option.select(2);_quality_changed(2)
			KEY_ESCAPE:_close()

func _notification(what: int) -> void:
	if what==NOTIFICATION_WM_CLOSE_REQUEST:_close()
func _close() -> void:
	if closing:return
	closing=true
	var f := FileAccess.open(session_path.path_join("stop"),FileAccess.WRITE)
	if f:f.store_string("stop");f.close()
	await get_tree().create_timer(0.3).timeout
	if worker_pid>0 and OS.is_process_running(worker_pid):OS.kill(worker_pid)
	worker_pid=-1
	get_tree().quit()
func _exit_tree() -> void:
	if worker_pid>0 and OS.is_process_running(worker_pid):OS.kill(worker_pid)

func _write_test_report(success: bool) -> void:
	if capture_dir.is_empty():capture_dir=session_path
	DirAccess.make_dir_recursive_absolute(capture_dir)
	var frame_stats := frame_times.duplicate()
	frame_stats.sort()
	var report := {"success":success,"scene":selected_scene,"models":selected_models,"worker_session":session_path,"scan_count":scan_count,
		"entity_count":current_manifest.get("entities",[]).size(),"terrain_fingerprint":current_manifest.get("scene_fingerprint",""),
		"validation":validation_data,"last_worker_result":last_state,"frames_observed":frame_stats.size(),"cycle_results":cycle_results,
		"frame_ms_p50":frame_stats[int(frame_stats.size()*.50)] if frame_stats.size()>0 else 0,
		"frame_ms_p95":frame_stats[int(frame_stats.size()*.95)] if frame_stats.size()>0 else 0,
		"frame_ms_max":frame_stats[-1] if frame_stats.size()>0 else 0}
	var f := FileAccess.open(capture_dir.path_join("godot_test.json"),FileAccess.WRITE)
	if f:f.store_string(JSON.stringify(report,"  "));f.close()
	print("RADAR_TEST_COMPLETE ",JSON.stringify(report))

func _capture_test() -> void:
	if capture_dir.is_empty():capture_dir=session_path
	DirAccess.make_dir_recursive_absolute(capture_dir)
	await get_tree().create_timer(1).timeout
	if DisplayServer.get_name()!="headless" and not cycle_test:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(capture_dir.path_join("validation_overview.png"))
		focus_option.select(1);_focus_changed(1)
		await get_tree().create_timer(0.6).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(capture_dir.path_join("validation_models.png"))
		focus_option.select(4);_focus_changed(4)
		await get_tree().create_timer(0.4).timeout
		await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(capture_dir.path_join("godot_vehicle_models.png"))
		get_viewport().get_texture().get_image().save_png(capture_dir.path_join("validation_vehicle.png"))
		focus_option.select(5);_focus_changed(5)
		await get_tree().create_timer(0.4).timeout
		await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(capture_dir.path_join("godot_radar_model.png"))
		get_viewport().get_texture().get_image().save_png(capture_dir.path_join("validation_radar.png"))
	if cycle_test:
		await _run_cycle_test()
	_write_test_report(true)
	_close()

func _run_cycle_test() -> void:
	# Test pose and quality updates through the same UI -> worker -> texture path.
	frame_times.clear()
	for c in [{"quality":"survey","index":0,"angle":-PI/4,"alt":1550.0,"radius":2616.0},
		{"quality":"map","index":1,"angle":-PI/4,"alt":620.0,"radius":2758.0},
		{"quality":"detail","index":2,"angle":PI/2,"alt":1500.0,"radius":2300.0}]:
		selected_quality=c["quality"];quality_option.select(c["index"])
		orbit_angle=c["angle"];flight_altitude=c["alt"];orbit_radius=c["radius"]
		var expected_pose := _pose()
		_send("scan")
		var expected_id := pending_id
		var started := Time.get_ticks_msec()
		while busy and Time.get_ticks_msec()-started<60000:
			await get_tree().create_timer(.1).timeout
		var result := {"expected_id":expected_id,"received_id":last_state.get("id",-1),
			"expected_pose":expected_pose,"received_pose":last_state.get("pose",[]),
			"quality":selected_quality,"received_quality":last_state.get("quality",""),
			"elapsed_s":float(Time.get_ticks_msec()-started)/1000.0,
			"compute_s":last_state.get("stats",{}).get("total_s",0),
			"received_texture":current_texture!=null}
		cycle_results.append(result)
		await get_tree().create_timer(.3).timeout
