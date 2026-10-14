extends RefCounted
## Small reusable pieces of cockpit art; no mission state or gameplay input.
## Returns stable hit surfaces and optional moving parts to its owning rig.


static func bevel_mesh(width: float, height: float, depth: float, bevel: float) -> ArrayMesh:
	var x := width / 2
	var y := height / 2
	var b := minf(bevel, minf(x, y) * 0.45)
	var ring := [
		Vector2(-x + b, -y),
		Vector2(x - b, -y),
		Vector2(x, -y + b),
		Vector2(x, y - b),
		Vector2(x - b, y),
		Vector2(-x + b, y),
		Vector2(-x, y - b),
		Vector2(-x, -y + b)
	]
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(ring.size()):
		var a: Vector2 = ring[i]
		var c: Vector2 = ring[(i + 1) % ring.size()]
		for vertex in [
			Vector3(0, 0, depth / 2),
			Vector3(c.x, c.y, depth / 2),
			Vector3(a.x, a.y, depth / 2),
			Vector3(a.x, a.y, -depth / 2),
			Vector3(a.x, a.y, depth / 2),
			Vector3(c.x, c.y, depth / 2),
			Vector3(a.x, a.y, -depth / 2),
			Vector3(c.x, c.y, depth / 2),
			Vector3(c.x, c.y, -depth / 2)
		]:
			surface.add_vertex(vertex)
	surface.generate_normals()
	return surface.commit()


static func build_control(
	rig: Node3D, text: String, pos: Vector3, action: String, is_red: bool, width: float
) -> Dictionary:
	var root := Node3D.new()
	root.position = pos
	root.name = action.capitalize() + "Control"
	rig.add_child(root)
	var plate := MeshInstance3D.new()
	plate.mesh = bevel_mesh(width, 0.095, 0.020, 0.012)
	plate.material_override = rig.dark
	root.add_child(plate)
	var moving := Node3D.new()
	root.add_child(moving)
	var is_knob := action in ["gain", "range", "select"]
	var is_toggle := action in ["arm_guard", "hold"]
	if is_knob:
		rig.cylinder(moving, Vector3(0, 0, 0.025), 0.036, 0.035, rig.steel)
		rig.cylinder(moving, Vector3(0, 0, 0.047), 0.030, 0.015, rig.dark)
		for i in range(18):
			var angle := TAU * i / 18
			var ridge = rig.box(
				moving,
				Vector3(sin(angle) * 0.033, cos(angle) * 0.033, 0.037),
				Vector3(0.003, 0.008, 0.022),
				rig.worn
			)
			ridge.rotation.z = -angle
		rig.box(
			moving,
			Vector3(0, 0.018, 0.057),
			Vector3(0.004, 0.014, 0.002),
			rig.material(Color(0.58, 0.52, 0.37))
		)
		for i in range(7):
			var angle := deg_to_rad(-120 + i * 40)
			var tick = rig.box(
				root,
				Vector3(sin(angle) * 0.044, cos(angle) * 0.044, 0.013),
				Vector3(0.002, 0.006, 0.002),
				rig.worn
			)
			tick.rotation.z = -angle
	elif is_toggle:
		rig.cylinder(root, Vector3(0, 0, 0.015), 0.020, 0.012, rig.worn)
		rig.cylinder(root, Vector3(0, 0, 0.024), 0.012, 0.012, rig.dark)
		moving.position.z = 0.027
		var lever = rig.box(
			moving, Vector3(0, 0.018, 0.012), Vector3(0.011, 0.048, 0.013), rig.steel
		)
		lever.rotation.x = -0.4
		rig.sphere(moving, Vector3(0, 0.039, 0.020), 0.010, rig.worn)
		if is_red:
			var guard = rig.material(Color(0.33, 0.046, 0.026), 0.55, 0.65)
			for side in [-1, 1]:
				rig.box(
					root, Vector3(side * 0.035, 0.010, 0.035), Vector3(0.010, 0.079, 0.05), guard
				)
			rig.box(root, Vector3(0, 0.047, 0.044), Vector3(0.079, 0.01, 0.037), guard)
	else:
		var key := MeshInstance3D.new()
		key.mesh = bevel_mesh(width - 0.024, 0.064, 0.032, 0.009)
		key.position.z = 0.024
		key.material_override = rig.material(
			Color(0.26, 0.039, 0.025) if is_red else Color(0.105, 0.117, 0.113), 0.25, 0.66
		)
		moving.add_child(key)
	# Engraved name plates; text never overlays the radar pixels.
	var label_y := (0.073 if pos.y < 0.32 else -0.058) if is_knob or is_toggle else 0.0
	rig.label(
		root,
		text,
		Vector3(0, label_y, 0.047 if not is_knob else 0.02),
		0.00042,
		Color(0.68, 0.60, 0.44)
	)
	var hit = rig.quad(root, Vector3(0, 0, 0.067), Vector2(width, 0.10), rig.dark)
	hit.visible = false
	return {
		"mesh": hit,
		"size": Vector2(width, 0.10),
		"action": action,
		"moving": moving,
		"is_knob": is_knob,
		"is_toggle": is_toggle,
		"rest_z": moving.position.z,
		"angle": 0.0
	}


static func add_bezel(rig: Node3D) -> void:
	# Rounded metal frame and a deep rubber gasket around, not over, the CRT.
	var rubber = rig.material(Color(0.013, 0.018, 0.017), 0.0, 0.96)
	for side in [-1, 1]:
		rig.box(rig, Vector3(side * 0.574, 1.02, 0.207), Vector3(0.023, 0.97, 0.046), rubber)
		rig.box(rig, Vector3(0, 1.02 + side * 0.502, 0.21), Vector3(1.12, 0.020, 0.043), rubber)
		for end in [-1, 1]:
			rig.sphere(rig, Vector3(side * 0.566, 1.02 + end * 0.49, 0.211), 0.029, rubber)


static func add_station_details(rig: Node3D) -> void:
	# Fasteners, small service plates and handle rails fill the blank shelf.
	for side in [-1, 1]:
		for i in range(9):
			rig.box(
				rig,
				Vector3(side * 1.58, 0.18, 0.398) + Vector3(i * 0.011 * side, 0, 0),
				Vector3(0.003, 0.066, 0.003),
				rig.dark
			)
	var legend = rig.label(
		rig,
		"RAVEN  /  WSO STATION\nFRAME HELD UNTIL NEXT ACQUISITION",
		Vector3(-0.14, 0.235, 0.383),
		0.00033,
		Color(0.36, 0.32, 0.23)
	)
	legend.name = "StationPlacard"
	# Threaded roller endcaps and grooves (the rollers themselves still move).
	for side in [-1, 1]:
		for y in [0.46, 1.62]:
			rig.cylinder(rig, Vector3(1.24 + side * 0.485, y, 0.18), 0.018, 0.019, rig.worn)
