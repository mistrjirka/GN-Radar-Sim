extends SceneTree
## Exercises the asynchronous boundary with a deliberately slow decoder.
## No rendering or radar physics is changed; the slowdown exists only in this test.
const Loader=preload("res://game/cockpit/chart_loader.gd")
var passed:=0
var failed:=0

class SlowLoader extends "res://game/cockpit/chart_loader.gd":
	func _decode(_path: String) -> Dictionary:
		OS.delay_msec(80)
		var image:=Image.create(64,64,false,Image.FORMAT_RGB8)
		image.fill(Color(.75,.65,.45))
		return {"image":image,"decode_ms":80.0}

func check(ok:bool,name_:String) -> void:
	if ok:passed+=1;print("PASS ",name_)
	else:failed+=1;push_error(name_)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var loader=SlowLoader.new();root.add_child(loader)
	var result:Array=[]
	loader.decoded.connect(func(image,elapsed):result.append([image,elapsed]))
	var t:=Time.get_ticks_usec();loader.load_png("unused")
	check(float(Time.get_ticks_usec()-t)/1000<20,"Submitting a slow chart decoder does not block the main thread")
	var heartbeat:=0
	while result.is_empty() and heartbeat<150:
		heartbeat+=1
		await create_timer(.003).timeout
	check(not result.is_empty(),"Background result is delivered on the main thread")
	check(heartbeat>2,"Main event loop remains active during chart decode")
	check(loader.task==null,"Completed thread is joined and released")
	if not result.is_empty():
		check(result[0][0].get_size()==Vector2i(64,64),"Decoded pixel dimensions are preserved")
	loader.free()
	var closing=SlowLoader.new();root.add_child(closing);closing.load_png("unused")
	closing.free()
	check(not is_instance_valid(closing),"Closing during load disposes the owned thread safely")
	print("CHART_LOADING_TESTS ",JSON.stringify({"passed":passed,"failed":failed}))
	quit(0 if failed==0 else 1)
