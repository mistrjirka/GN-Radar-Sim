extends Node3D
## Renders the same exported heights, material map and equipment primitives as radar.
signal build_progress(message: String)

var manifest: Dictionary = {}
var heights := PackedFloat32Array()
var materials: Dictionary = {}
var entities_root: Node3D
var grid_n: int = 0
var grid_step: float = 1.0
var world_extent: float = 2000.0

func _v(a) -> Vector3:
	return Vector3(float(a[0]), float(a[2]), -float(a[1]))

func _mat(name: String) -> StandardMaterial3D:
	if materials.has(name):
		return materials[name]
	var m := StandardMaterial3D.new()
	var rgb = manifest.get("colors", {}).get(name, [0.4, 0.45, 0.4])
	m.albedo_color = Color(float(rgb[0]), float(rgb[1]), float(rgb[2]))
	m.roughness = 0.82
	if name.begins_with("metal") or name in ["bridge", "bridge_dark", "radar_mast", "roof"]:
		m.metallic = 0.55
		m.roughness = 0.57
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	materials[name] = m
	return m

func terrain_height(x: float, north: float) -> float:
	if grid_n < 2 or heights.is_empty(): return 0.0
	var ix := clampi(int(round((x + world_extent / 2.0) / grid_step)), 0, grid_n - 1)
	var iy := clampi(int(round((north + world_extent / 2.0) / grid_step)), 0, grid_n - 1)
	return heights[iy * grid_n + ix]

func build(data: Dictionary) -> void:
	for node in get_children(): node.queue_free()
	await get_tree().process_frame
	manifest = data
	materials.clear()
	grid_n = int(data["mesh_n"])
	grid_step = float(data["grid_step"])
	world_extent = float(data["world_size"])
	var file := FileAccess.open(str(data["height_path"]), FileAccess.READ)
	if not file:
		push_error("Missing shared heightfield")
		return
	heights = file.get_buffer(file.get_length()).to_float32_array()
	file.close()
	if heights.size() != grid_n * grid_n:
		push_error("Heightfield size mismatch")
		return
	var ground_material := StandardMaterial3D.new()
	var color_image := Image.load_from_file(str(data["albedo_path"]))
	if color_image:
		color_image.generate_mipmaps()
		ground_material.albedo_texture = ImageTexture.create_from_image(color_image)
	if data.has("normal_path"):
		var normals_image := Image.load_from_file(str(data["normal_path"]))
		if normals_image:
			normals_image.generate_mipmaps(true)
			ground_material.normal_enabled=true
			ground_material.normal_texture=ImageTexture.create_from_image(normals_image)
			ground_material.normal_scale=0.85
	ground_material.roughness = 1.0
	ground_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	ground_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Build bounded chunks between frames rather than a long main-thread stall.
	var chunk_cells := 64
	for y0 in range(0, grid_n - 1, chunk_cells):
		for x0 in range(0, grid_n - 1, chunk_cells):
			_build_chunk(x0, y0, chunk_cells, ground_material)
		build_progress.emit("Terrain row %d / %d" % [y0 / chunk_cells + 1, (grid_n - 1) / chunk_cells])
		await get_tree().process_frame
	_build_water(float(data["water_level"]))
	_build_trees(str(data["trees_path"]), int(data["tree_count"]))
	entities_root = Node3D.new()
	entities_root.name = "SharedEquipment"
	add_child(entities_root)
	for e in data["entities"]:
		_build_entity(e)
	build_progress.emit("Shared terrain and equipment ready")

func _build_chunk(x0: int, y0: int, cells: int, mat: Material) -> void:
	var nx := mini(cells, grid_n - x0 - 1) + 1
	var ny := mini(cells, grid_n - y0 - 1) + 1
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var tangents := PackedFloat32Array()
	vertices.resize(nx * ny)
	normals.resize(nx * ny)
	uvs.resize(nx * ny)
	tangents.resize(nx * ny * 4)
	for y in range(ny):
		for x in range(nx):
			var gx := x0 + x
			var gy := y0 + y
			var i := y * nx + x
			var h := heights[gy * grid_n + gx]
			vertices[i] = Vector3(gx * grid_step - world_extent/2, h, world_extent/2 - gy * grid_step)
			var hx := heights[gy * grid_n + mini(gx+1,grid_n-1)] - heights[gy * grid_n + maxi(gx-1,0)]
			var hy := heights[mini(gy+1,grid_n-1) * grid_n + gx] - heights[maxi(gy-1,0) * grid_n + gx]
			normals[i] = Vector3(-hx / (2*grid_step), 1, hy / (2*grid_step)).normalized()
			var tangent := Vector3(1,hx/(2*grid_step),0).normalized()
			tangents[i*4]=tangent.x;tangents[i*4+1]=tangent.y;tangents[i*4+2]=tangent.z;tangents[i*4+3]=1
			uvs[i] = Vector2(float(gx)/(grid_n-1), float(gy)/(grid_n-1))
	var indices := PackedInt32Array()
	for y in range(ny-1):
		for x in range(nx-1):
			var p := y*nx+x
			indices.append_array(PackedInt32Array([p,p+1,p+nx,p+1,p+nx+1,p+nx]))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = vertices
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_TANGENT] = tangents
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	add_child(node)

func _build_water(level: float) -> void:
	# Use exactly the scene water mask. An unmasked global plane would flood
	# unrelated low terrain in the earlier training map.
	var half := world_extent/2
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=PackedVector3Array([Vector3(-half,level,half),Vector3(half,level,half),Vector3(-half,level,-half),Vector3(half,level,-half)])
	arrays[Mesh.ARRAY_NORMAL]=PackedVector3Array([Vector3.UP,Vector3.UP,Vector3.UP,Vector3.UP])
	arrays[Mesh.ARRAY_TEX_UV]=PackedVector2Array([Vector2(0,0),Vector2(1,0),Vector2(0,1),Vector2(1,1)])
	arrays[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2,1,3,2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var instance := MeshInstance3D.new()
	instance.mesh=mesh
	var shader := Shader.new()
	shader.code="shader_type spatial; render_mode cull_disabled; uniform sampler2D water_mask : filter_nearest, repeat_disable; void fragment(){if(texture(water_mask,UV).r<0.5){discard;} ALBEDO=vec3(0.065,0.18,0.23); METALLIC=0.2; ROUGHNESS=0.3;}"
	var material := ShaderMaterial.new()
	material.shader=shader
	var mask := Image.load_from_file(str(manifest["water_mask_path"]))
	material.set_shader_parameter("water_mask",ImageTexture.create_from_image(mask))
	instance.material_override=material
	add_child(instance)

func _build_trees(path: String, count: int) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file: return
	var values := file.get_buffer(file.get_length()).to_float32_array()
	file.close()
	if values.size() != count*4: return
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = 0.31
	mesh.height = 1.0
	mesh.radial_segments = 7
	var forest := MultiMesh.new()
	forest.transform_format = MultiMesh.TRANSFORM_3D
	forest.use_colors = true
	forest.mesh = mesh
	forest.instance_count = count * 2
	for i in range(count):
		var h := values[4*i+3]
		var pos := Vector3(values[4*i], values[4*i+2], -values[4*i+1])
		for crown in range(2):
			var scale_h := h * (0.75 if crown == 0 else 0.62)
			var center := h * (0.58 if crown == 0 else 0.80)
			var basis := Basis.IDENTITY.scaled(Vector3(h,scale_h,h))
			forest.set_instance_transform(i*2+crown,Transform3D(basis,pos+Vector3(0,center,0)))
			forest.set_instance_color(i*2+crown,Color(0.65+float(i%5)*0.045,0.73+float(i%7)*0.025,0.64))
	var node := MultiMeshInstance3D.new()
	node.multimesh = forest
	var mat := _mat("pine")
	mat.vertex_color_use_as_albedo = true
	node.material_override = mat
	add_child(node)

func _build_entity(e: Dictionary) -> void:
	var root := Node3D.new()
	root.name = str(e["kind"]).capitalize()
	root.position = Vector3(float(e["x"]),float(e["base"]),-float(e["y"]))
	root.rotation.y = float(e["angle"])
	var s = e["scale"]
	root.scale = Vector3(float(s[0]),float(s[2]),float(s[1]))
	root.set_meta("shared_entity",e)
	entities_root.add_child(root)
	for p in e["parts"]:
		var instance := MeshInstance3D.new()
		var shape := str(p["shape"])
		if shape == "box":
			var box := BoxMesh.new()
			var v = p["size"]
			box.size = Vector3(float(v[0]),float(v[2]),float(v[1]))
			instance.mesh = box
			instance.position = _v(p["position"])
		elif shape == "sphere":
			var sphere := SphereMesh.new()
			var v = p["size"]
			sphere.radius = float(v[0])/2
			sphere.height = float(v[2])
			sphere.radial_segments = 24
			sphere.rings = 12
			instance.mesh = sphere
			instance.position = _v(p["position"])
		elif shape == "tube":
			var a := _v(p["a"])
			var b := _v(p["b"])
			var axis := b-a
			if axis.length() < 0.001: continue
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = float(p["radius"])
			cylinder.bottom_radius = float(p["radius"])
			cylinder.height = axis.length()
			cylinder.radial_segments = 6
			instance.mesh = cylinder
			instance.position = (a+b)*0.5
			instance.basis = Basis(Quaternion(Vector3.UP,axis.normalized()))
		elif shape == "gabled_roof":
			instance.mesh = _roof_mesh(p["size"])
			instance.position = _v(p["position"])
		else: continue
		instance.material_override = _mat(str(p["material"]))
		root.add_child(instance)

func _roof_mesh(s) -> ArrayMesh:
	var l := float(s[0])/2
	var w := float(s[1])/2
	var h := float(s[2])
	var v := [Vector3(-l,0,w),Vector3(l,0,w),Vector3(-l,h,0),Vector3(l,h,0),Vector3(-l,0,-w),Vector3(l,0,-w)]
	var idx := [0,1,2,1,3,2,2,3,4,3,5,4,0,2,4,1,5,3]
	var surf := SurfaceTool.new()
	surf.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in idx: surf.add_vertex(v[i])
	surf.generate_normals()
	return surf.commit()
