extends Node3D
## Native 3D cockpit; screen textures are live game instruments, not concept art.
const Hardware = preload("res://game/cockpit/cockpit_hardware.gd")
const Chart = preload("res://game/cockpit/paper_chart.gd")
const Receiver = preload("res://game/cockpit/receiver_scope.gd")
var revised_station:=false
var resolution_mode:=""
var chart
var chart_mechanism
var receiver
var radar_material: ShaderMaterial
var camera: Camera3D
var chart_quad: MeshInstance3D
var radar_quad: MeshInstance3D
var rwr_quad: MeshInstance3D
var chart_view: SubViewport
var rwr_view: SubViewport
var controls: Array = []
var shutters: Array = []
var red_lights: Array = []
var daylight: OmniLight3D
var defcon: Label3D
var pilot: Node3D
var needles: Dictionary = {}
var lamps: Dictionary = {}
var counters: Dictionary = {}
var roller_top: MeshInstance3D
var roller_bottom: MeshInstance3D
var paint: StandardMaterial3D
var steel: StandardMaterial3D
var dark: StandardMaterial3D
var worn: StandardMaterial3D
var glass: StandardMaterial3D
var font: Font = ThemeDB.fallback_font
var static_labels: Array = []
var powered := false
var pilot_head: Node3D
var mission_card: Label3D
var cockpit_environment: Environment
var fill_light: OmniLight3D
var instrument_lights: Array = []


func material(color: Color, metallic: float = 0.0, roughness: float = .8) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	return m


func box(parent: Node, pos: Vector3, dimensions: Vector3, mat: Material) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = dimensions
	n.mesh = m
	n.position = pos
	n.material_override = mat
	parent.add_child(n)
	return n


func cylinder(
	parent: Node, pos: Vector3, radius: float, length: float, mat: Material
) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 20
	n.mesh = mesh
	n.position = pos
	n.rotation.x = PI / 2
	n.material_override = mat
	parent.add_child(n)
	return n


func sphere(
	parent: Node, pos: Vector3, radius: float, mat: Material, scale_y: float = 1.0
) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = 2 * radius
	mesh.radial_segments = 24
	mesh.rings = 12
	n.mesh = mesh
	n.position = pos
	n.scale.y = scale_y
	n.material_override = mat
	parent.add_child(n)
	return n


func quad(parent: Node, pos: Vector3, dimensions: Vector2, mat: Material) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = dimensions
	n.mesh = mesh
	n.position = pos
	n.material_override = mat
	parent.add_child(n)
	return n


func label(
	parent: Node,
	text: String,
	pos: Vector3,
	scale_value: float = .00064,
	color: Color = Color(.48, .42, .31)
) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.font_size = 42
	l.pixel_size = scale_value * 1.45
	l.modulate = color
	l.outline_size = 0
	l.no_depth_test = false
	l.shaded = false
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(l)
	static_labels.append(l)
	return l


func display_material(texture: Texture2D, brightness: float = 1.0) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded,cull_disabled; uniform sampler2D display_tex: filter_linear, repeat_disable; uniform float brightness=1.0; void fragment(){ALBEDO=texture(display_tex,UV).rgb*brightness;}"
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("display_tex", texture)
	m.set_shader_parameter("brightness", brightness)
	return m


func make_view(size_px: Vector2i, canvas: Control) -> SubViewport:
	var v := SubViewport.new()
	v.size = size_px
	v.disable_3d = true
	v.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(v)
	canvas.size = Vector2(size_px)
	v.add_child(canvas)
	return v


func panel(pos: Vector3, dimensions: Vector2, title: String) -> void:
	box(self, pos, Vector3(dimensions.x, dimensions.y, .19), paint)
	for x in [-1, 1]:
		box(
			self,
			pos + Vector3(x * (dimensions.x / 2 - .018), 0, .104),
			Vector3(.027, dimensions.y - .015, .022),
			steel
		)
		for y in [-1, 1]:
			var screwpos := (
				pos + Vector3(x * (dimensions.x / 2 - .052), y * (dimensions.y / 2 - .05), .125)
			)
			cylinder(self, screwpos, .014, .009, worn)
			box(self, screwpos + Vector3(0, 0, .007), Vector3(.017, .002, .003), dark)
	label(self, title, pos + Vector3(0, dimensions.y / 2 - .059, .119), .00059)


func control(
	text: String, pos: Vector3, key: String, red: bool = false, width: float = .18
) -> void:
	controls.append(Hardware.build_control(self, text, pos, key, red, width))


func press_control(action: String) -> void:
	for c in controls:
		if c["action"] == action:
			var moving: Node3D = c["moving"]
			if action=="resolution":return
			if c["is_knob"]:
				c["angle"] += 0.35
				var turn := create_tween()
				turn.tween_property(moving, "rotation:z", c["angle"], 0.12)
			elif not c["is_toggle"]:
				var rest: float = c["rest_z"]
				var press := create_tween()
				press.tween_property(moving, "position:z", rest - 0.009, 0.04)
				press.tween_property(moving, "position:z", rest, 0.10)


func set_switch(action: String, on: bool) -> void:
	for c in controls:
		if c["action"] == action and c["is_toggle"]:
			var moving: Node3D = c["moving"]
			moving.rotation.z = PI if on else 0.0


func update_pilot(time: float, turn: float) -> void:
	if not pilot_head:
		return
	pilot_head.rotation.y = clampf(turn, -0.28, 0.28) + sin(time * 0.31) * 0.018
	pilot_head.rotation.x = sin(time * 0.55) * 0.008


func lamp(text: String, pos: Vector3, key: String, color: Color) -> void:
	cylinder(self, pos, .018, .012, dark)
	var m := material(color * .075)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 0
	var mesh := sphere(self, pos + Vector3(0, 0, .01), .011, m, .7)
	lamps[key] = m
	label(self, text, pos + Vector3(0, -.040, .017), .00034, Color(.49, .43, .34))


func set_lamp(key: String, on: bool, color: Color = Color(-1, -1, -1)) -> void:
	if not lamps.has(key):
		return
	var m: StandardMaterial3D = lamps[key]
	if color.r >= 0:
		m.emission = color
	m.emission_energy_multiplier = 1.3 if on else 0


func dial(pos: Vector3, radius: float, title: String, key: String) -> void:
	cylinder(self, pos, radius, .025, steel)
	cylinder(self, pos + Vector3(0, 0, .021), radius * .88, .009, dark)
	for i in range(13):
		var angle := deg_to_rad(-135 + i * 22.5)
		var tick := box(
			self,
			pos + Vector3(sin(angle), cos(angle), 0) * radius * .72 + Vector3(0, 0, .029),
			Vector3(.003, .015, .002),
			worn
		)
		tick.rotation.z = -angle
	var n := Node3D.new()
	n.position = pos + Vector3(0, 0, .034)
	add_child(n)
	box(
		n,
		Vector3(0, radius * .30, 0),
		Vector3(.004, radius * .66, .003),
		material(Color(.50, .45, .32))
	)
	cylinder(n, Vector3.ZERO, .009, .006, worn)
	needles[key] = n
	label(self, title, pos + Vector3(0, -radius - .03, .037), .0004)


func build() -> void:
	paint = material(Color(.64, .64, .62), .25, .85)
	paint.albedo_texture = load("res://game/cockpit/assets/panel_paint.png")
	steel = material(Color(.12, .14, .14), .72, .58)
	dark = material(Color(.017, .023, .021), .14, .87)
	worn = material(Color(.27, .26, .22), .60, .68)
	glass = material(Color(.019, .03, .027), .40, .18)
	# Pressure hull, frames, sidewall equipment, and overhead conduits.
	box(self, Vector3(0, -.17, -.6), Vector3(4.4, .12, 6), dark)
	for side in [-1, 1]:
		box(self, Vector3(side * 2.17, 1.35, -1), Vector3(.13, 3.1, 6), paint)
		for z in [-2.8, -1.5, -.2, 1.1]:
			box(self, Vector3(side * 2.06, 1.55, z), Vector3(.08, 2.5, .065), steel)
		for i in range(3):
			var pipe := cylinder(
				self, Vector3(side * (1.83 + i * .08), 2.66, -.8), .018, 5.0, steel
			)
			pipe.rotation.x = PI / 2
	box(self, Vector3(0, 2.9, -1), Vector3(4.4, .15, 6), paint)
	box(self, Vector3(0, 1.53, -3.12), Vector3(4.1, 2.4, .15), dark)
	# Window panes above the pilot. Shutters descend as physical geometry.
	var horizon = display_material(load("res://game/cockpit/assets/cloud_horizon.png"), 1.2)
	for i in range(3):
		var x: float = (i - 1) * 1.22
		quad(self, Vector3(x, 2.16, -2.995), Vector2(1.16, .87), horizon)
		var sh := Node3D.new()
		sh.position = Vector3(x, 3.16, -2.92)
		add_child(sh)
		box(sh, Vector3.ZERO, Vector3(1.16, .95, .035), paint)
		for j in range(9):
			box(sh, Vector3(0, -.42 + j * .105, .026), Vector3(1.15, .012, .015), steel)
		shutters.append(sh)
		for side in [-1, 1]:
			box(self, Vector3(x + side * .61, 2.16, -2.89), Vector3(.053, 1.05, .07), steel)
	# Pilot as an actual silhouette with helmet, seat and controls.
	pilot = Node3D.new()
	pilot.position = Vector3(-.68, .25, -1.96)
	add_child(pilot)
	box(pilot, Vector3(0, .94, .22), Vector3(.64, .79, .14), dark)
	box(pilot, Vector3(0, .58, 0), Vector3(.68, .15, .62), dark)
	var fabric := material(Color(.055, .061, .043), 0, .95)
	sphere(pilot, Vector3(0, 1.09, .03), .26, fabric, 1.45)
	pilot_head = Node3D.new()
	pilot_head.position = Vector3(0, 1.58, 0)
	pilot.add_child(pilot_head)
	sphere(pilot_head, Vector3.ZERO, .183, material(Color(.092, .10, .084), .12, .85), 1.12)
	var rim = cylinder(pilot_head, Vector3(0, -.05, 0), .179, .018, dark)
	rim.rotation = Vector3.ZERO
	box(pilot_head, Vector3(0, .005, -.159), Vector3(.25, .06, .018), glass)
	for side in [-1, 1]:
		var strap := box(
			pilot,
			Vector3(side * .15, 1.11, .25),
			Vector3(.04, .62, .023),
			material(Color(.13, .11, .074))
		)
		strap.rotation.z = -side * .12
		sphere(pilot_head, Vector3(side * .18, -.02, .02), .062, dark, .9)
		var arm := box(pilot, Vector3(side * .27, .94, -.19), Vector3(.15, .16, .49), fabric)
		arm.rotation.x = .25
	# Empty second seat / forward analog flight panel gives depth behind station.
	box(self, Vector3(.72, .95, -1.74), Vector3(.64, .9, .19), dark)
	box(self, Vector3(.72, .52, -1.97), Vector3(.64, .15, .61), dark)
	box(self, Vector3(0, 1.14, -2.64), Vector3(3.75, .55, .3), paint)
	for i in range(10):
		dial(Vector3(-1.64 + i * .35, 1.28, -2.465), .09, "", "background_%d" % i)
	# Emergency annunciator behind / above pilot, readable by the WSO.
	box(self, Vector3(-.54, 2.22, -1.67), Vector3(.87, .23, .06), dark)
	defcon = label(self, "DEFCON 1", Vector3(-.54, 2.22, -1.626), .0030, Color(.025, 0, 0))
	# Main WSO instrument station: RWR left, returns-only CRT center, chart right.
	panel(Vector3(-1.22, .91, .01), Vector2(1.06, 1.24), "RADAR WARNING RECEIVER")
	panel(Vector3(0, .91, .05), Vector2(1.29, 1.25), "GROUND MAPPING")
	panel(Vector3(1.24, 1.0, .015), Vector2(1.10, 1.43), "NAVIGATION / ROLL CHART")
	receiver = preload("res://game/cockpit/range_receiver.gd").new() if revised_station else Receiver.new()
	rwr_view = make_view(Vector2i(512,512) if revised_station else Vector2i(512,620),receiver)
	rwr_quad = quad(
		self,
		Vector3(-1.22, 1.02, .124),
		Vector2(.94,.94) if revised_station else Vector2(.91,.98),
		display_material(rwr_view.get_texture(), .86)
	)
	chart = Chart.new()
	chart_view = make_view(Vector2i(640, 800), chart)
	chart_quad = quad(
		self,
		Vector3(1.24, 1.04, .129),
		Vector2(.87, 1.12),
		display_material(chart_view.get_texture(), .64)
	)
	# Perimeter lip on CRT, a rounded phosphor shader; no digital overlay at all.
	box(self, Vector3(0, 1.02, .15), Vector3(1.16, 1.04, .08), dark)
	radar_material = ShaderMaterial.new()
	radar_material.shader = load("res://game/cockpit/shaders/analogue_radar.gdshader" if revised_station else "res://game/cockpit/shaders/phosphor.gdshader")
	var empty := Image.create(8, 8, false, Image.FORMAT_L8)
	empty.fill(Color.BLACK)
	radar_material.set_shader_parameter("radar_image", ImageTexture.create_from_image(empty))
	radar_quad = quad(self, Vector3(0, 1.02, .202), Vector2(1.08, .96), radar_material)
	# Exposed mechanical chart rollers and retaining rails.
	roller_top = cylinder(self, Vector3(1.24, 1.62, .18), .033, .92, worn)
	roller_top.rotation = Vector3(0, 0, PI / 2)
	roller_bottom = cylinder(self, Vector3(1.24, .46, .18), .039, .92, worn)
	roller_bottom.rotation = Vector3(0, 0, PI / 2)
	for side in [-1, 1]:
		box(self, Vector3(1.24 + side * .46, 1.04, .17), Vector3(.026, 1.17, .018), steel)
	Hardware.add_bezel(self)
	chart_mechanism=preload("res://game/cockpit/chart_mechanism.gd").new()
	add_child(chart_mechanism);chart_mechanism.build(self)
	# Functional controls on metal, not on the radar picture.
	control("SCAN", Vector3(-.40, .385, .22), "scan", false, .21)
	control("AREA", Vector3(-.13, .385, .22), "range", false, .20)
	control("GAIN", Vector3(.12, .385, .22), "gain", false, .18)
	control("HOLD", Vector3(.36, .385, .22), "hold", false, .18)
	lamp("TX", Vector3(-.50, .51, .22), "tx", Color(.92, .38, .02))
	lamp("FRAME", Vector3(.50, .51, .22), "frame", Color(.3, .75, .2))
	lamp("STORED", Vector3(.28, .51, .22), "stored", Color(.90, .38, .055))
	control("CONTACT" if revised_station else "SELECT", Vector3(-1.44, .295, .14), "select", false, .25)
	control("ARM", Vector3(-1.12, .295, .14), "arm_guard", true, .20)
	control("FIRE", Vector3(-.86, .295, .14), "arm_fire", true, .19)
	if revised_station:
		label(self,"RWR / 20 km EST",Vector3(-1.22,.485,.15),.00044,Color(.42,.54,.34))
	lamp("SEARCH", Vector3(-1.55, .43, .16), "search", Color(.55, .62, .2))
	lamp("TRACK", Vector3(-1.23, .43, .16), "track", Color(.95, .32, .035))
	lamp("LAUNCH", Vector3(-.91, .43, .16), "launch", Color(1, .055, .012))
	control("COURSE <", Vector3(.97, .295, .15), "left", false, .27)
	control("> COURSE", Vector3(1.31, .295, .15), "right", false, .27)
	control("CLEAR" if revised_station else "ACK",Vector3(1.60,.295,.15),"clear_point" if revised_station else "ack",false,.19)
	box(self,Vector3(0,1.645,.25),Vector3(1.25,.12,.028),dark)
	control("RES",Vector3(-.52,1.638,.283),"resolution",false,.13)
	counters["resolution"]=label(self,"FINE 2x2.5m",Vector3(-.17,1.655,.275),.00048,Color(.60,.46,.25))
	counters["scan_area"]=label(self,"AREA 1.6km",Vector3(.36,1.655,.275),.00045,Color(.60,.46,.25))
	counters["heading_command"]=label(self,"SET 000 / HDG 000",Vector3(1.24,.39,.22),.00044,Color(.60,.46,.25))
	# Lower utility and weapon shelves.
	panel(Vector3(0, .12, .23), Vector2(3.42, .25), " ")
	control("COUNTERMEASURES", Vector3(-1.12, .13, .37), "chaff", false, .46)
	control("RELEASE", Vector3(.70, .13, .37), "release", true, .29)
	control("HELP", Vector3(1.12, .13, .37), "help", false, .22)
	control("PAUSE", Vector3(1.42, .13, .37), "pause", false, .22)
	lamp("AUTH", Vector3(.42, .14, .38), "auth", Color(.97, .26, .022))
	lamp("ZONE", Vector3(.70, .242, .38), "zone", Color(.4, .80, .20))
	counters["stores"] = label(
		self, "ARM  2  /  CM  4", Vector3(-.52, .14, .38), .00048, Color(.42, .29, .13)
	)
	dial(Vector3(-1.76, 1.0, .12), .085, "ALT", "alt")
	dial(Vector3(-1.76, .72, .12), .085, "FUEL", "fuel")
	dial(Vector3(1.89, 1.13, .09), .075, "HDG", "heading")
	dial(Vector3(1.89, .84, .09), .075, "AIRFRAME", "integrity")
	Hardware.add_station_details(self)
	if revised_station:
		counters["scan_status"]=label(self,"READY",Vector3(0,.47,.263),.00038,Color(.62,.45,.25))
	box(
		self,
		Vector3(1.24, 1.84, .06),
		Vector3(1.03, .115, .035),
		material(Color(.29, .25, .16), 0, .95)
	)
	mission_card = label(
		self, "FLIGHT / AWAIT ORDERS", Vector3(1.24, 1.84, .083), .00051, Color(.38, .32, .20)
	)
	# Clipboards, visible red-rimmed pipe work, no decorative digital screens.
	box(self, Vector3(-1.86, 1.82, -.40), Vector3(.28, .42, .028), material(Color(.23, .19, .12)))
	label(
		self,
		"NAV\nRADAR\nCOMMS\nDEFENSE",
		Vector3(-1.86, 1.82, -.375),
		.00062,
		Color(.22, .17, .10)
	)
	label(self, "RAVEN TWO", Vector3(1.84, 1.81, -.35), .00057, Color(.31, .14, .085))
	# Lighting keeps readable surfaces, dominated by red combat illumination.
	var env := Environment.new()
	cockpit_environment = env
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(.004, .005, .006)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(.55, .31, .24)
	env.ambient_light_energy = .45
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	for pos in [Vector3(-1.5, 2.48, .35), Vector3(1.5, 2.48, .2), Vector3(-.5, 2.3, -1.7)]:
		var light := OmniLight3D.new()
		light.position = pos
		light.light_color = Color(1, .065, .022)
		light.light_energy = .1
		light.omni_range = 4.5
		light.shadow_enabled = false
		add_child(light)
		red_lights.append(light)
	var fill := OmniLight3D.new()
	fill_light = fill
	fill.position = Vector3(0, 1.8, 1.5)
	fill.light_color = Color(.68, .22, .13)
	fill.light_energy = .7
	fill.omni_range = 4.5
	add_child(fill)
	daylight = OmniLight3D.new()
	daylight.position = Vector3(0, 2, -1)
	daylight.light_color = Color(.70, .81, 1)
	daylight.light_energy = 2.8
	daylight.omni_range = 8
	add_child(daylight)
	var chartlight := OmniLight3D.new()
	chartlight.position = Vector3(1.24, 1.3, .7)
	chartlight.light_color = Color(1, .62, .23)
	chartlight.light_energy = .14
	chartlight.omni_range = 1.0
	add_child(chartlight)
	instrument_lights.append(chartlight)
	var screenlight := OmniLight3D.new()
	screenlight.position = Vector3(0, 1.04, .6)
	screenlight.light_color = Color(.2, .75, .15)
	screenlight.light_energy = .12
	screenlight.omni_range = 1.25
	add_child(screenlight)
	instrument_lights.append(screenlight)
	camera = Camera3D.new()
	camera.position = Vector3(0, 1.60, 2.43)
	camera.fov = 52
	camera.near = .035
	camera.far = 30
	add_child(camera)
	camera.current = true
	camera.look_at(Vector3(0, 1.02, -.2), Vector3.UP)


func set_shutters(fraction: float) -> void:
	for s in shutters:
		s.position.y = lerpf(3.16, 2.16, fraction)
	daylight.light_energy = 2.8 * (1 - fraction)


func combat_lighting(level: float) -> void:
	for l in red_lights:
		l.light_energy = .9 * level
	defcon.modulate = Color(1, .06, .012) if level > .4 else Color(.025, 0, 0)
	powered = level > .4
	radar_material.set_shader_parameter("powered", 1.0 if powered else 0.0)
	receiver.powered = powered


func blackout(on: bool) -> void:
	for l in static_labels:
		l.visible = not on
	if on:
		for m in lamps.values():
			m.emission_energy_multiplier = 0
	chart_quad.material_override.set_shader_parameter("brightness", 0.0 if on else .64)
	rwr_quad.material_override.set_shader_parameter("brightness", 0.0 if on else .86)
	cockpit_environment.ambient_light_energy = 0.0 if on else .45
	fill_light.light_energy = 0.0 if on else .7
	for l in instrument_lights:
		l.light_energy = 0.0 if on else .13


func uv_hit(mesh: MeshInstance3D, dimensions: Vector2, screen: Vector2) -> Vector2:
	var origin := camera.project_ray_origin(screen)
	var direction := camera.project_ray_normal(screen)
	var normal := mesh.global_transform.basis.z.normalized()
	var denom := normal.dot(direction)
	if absf(denom) < .00001:
		return Vector2(-1, -1)
	var t: float = normal.dot(mesh.global_position - origin) / denom
	if t < 0:
		return Vector2(-1, -1)
	var local := mesh.to_local(origin + direction * t)
	var uv := Vector2(local.x / dimensions.x + .5, .5 - local.y / dimensions.y)
	if uv.x < 0 or uv.x > 1 or uv.y < 0 or uv.y > 1:
		return Vector2(-1, -1)
	return uv


func action_at(screen: Vector2) -> String:
	for c in controls:
		if uv_hit(c["mesh"], c["size"], screen).x >= 0:
			return str(c["action"])
	return ""


func set_resolution_detent(mode:String) -> void:
	if resolution_mode==mode:return
	resolution_mode=mode
	for c in controls:
		if c["action"]=="resolution":
			c["angle"]={"survey":deg_to_rad(60),"map":0.0,"detail":deg_to_rad(-60)}[mode]
			var tween:=create_tween()
			tween.tween_property(c["moving"],"rotation:z",c["angle"],.16)
