@tool
extends Node3D
## Automatically creates trimesh collision shapes for all MeshInstance3D children.
## Attach this script to any imported model node (like a GLTF scene) to make it raycastable.

@export var create_on_ready: bool = true  ## Create collision shapes when node enters tree

func _ready() -> void:
	if create_on_ready and not Engine.is_editor_hint():
		create_collision_for_meshes()

## Creates static body with trimesh collision for all MeshInstance3D descendants
func create_collision_for_meshes() -> void:
	var mesh_instances := _find_all_mesh_instances(self)
	print("Creating collision for %d mesh instances..." % mesh_instances.size())
	
	for mesh_instance: MeshInstance3D in mesh_instances:
		_add_trimesh_collision(mesh_instance)
	
	print("Collision shapes created successfully!")

func _find_all_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	
	if node is MeshInstance3D:
		result.append(node)
	
	for child in node.get_children():
		result.append_array(_find_all_mesh_instances(child))
	
	return result

func _add_trimesh_collision(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance.mesh == null:
		return
	
	# Create a StaticBody3D as parent for collision
	var static_body := StaticBody3D.new()
	static_body.name = mesh_instance.name + "_collision"
	
	# Create trimesh shape from the mesh
	var shape := mesh_instance.mesh.create_trimesh_shape()
	if shape == null:
		push_warning("Could not create trimesh shape for: " + mesh_instance.name)
		return
	
	# Create CollisionShape3D and assign the shape
	var collision_shape := CollisionShape3D.new()
	collision_shape.shape = shape
	
	# Add collision shape to static body
	static_body.add_child(collision_shape)
	
	# Add static body as sibling to mesh instance (with same transform)
	mesh_instance.add_sibling(static_body)
	static_body.global_transform = mesh_instance.global_transform
