extends Node
## Owns chart PNG decoding off the render thread. Texture upload remains on main.
## No scene objects, GPU access or game state are touched by the background task.
signal decoded(image: Image, decode_ms: float)
signal failed(message: String)
var task: Thread
var closed := false

func load_png(path: String) -> void:
	if task!=null:
		failed.emit("A paper chart load is already pending")
		return
	task=Thread.new()
	var error:=task.start(_decode.bind(path))
	if error!=OK:
		task=null
		failed.emit("Cannot start chart decoder")

func _decode(path: String) -> Dictionary:
	var started:=Time.get_ticks_usec()
	var image:=Image.load_from_file(path)
	return {"image":image,"decode_ms":float(Time.get_ticks_usec()-started)/1000.0}

func _process(_dt: float) -> void:
	if closed or task==null or task.is_alive():return
	# Finished tasks only: no join on a still-running decoder during gameplay.
	var result:Dictionary=task.wait_to_finish()
	task=null
	var image:Image=result.get("image")
	if image==null or image.is_empty():
		failed.emit("Paper chart image is missing or invalid")
	else:decoded.emit(image,float(result["decode_ms"]))

func _exit_tree() -> void:
	closed=true
	# The decoder performs bounded local file work. Join on final scene disposal
	# so restarting/quitting never leaves a thread accessing a freed object.
	if task!=null:
		task.wait_to_finish()
		task=null
