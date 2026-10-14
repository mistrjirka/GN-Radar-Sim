extends SceneTree
## Native shader regression and visual sequence. Requires a graphical renderer.
## --source=<real scan PNG> uses actual acquired radar for inspection captures.
## No game clock/FPS claim is made from this intentionally stepped render test.
var output:=".radar_runtime/playability/crt_test"
var source:=""
var passed:=0
var failed:=0
var view:SubViewport
var surface:MeshInstance3D
var material:ShaderMaterial
var texture:ImageTexture

func check(ok:bool,message:String) -> void:
	if ok:passed+=1;print("PASS ",message)
	else:failed+=1;push_error(message)

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):output=arg.trim_prefix("--output=")
		if arg.begins_with("--source="):source=arg.trim_prefix("--source=")
	call_deferred("run")

func render_frame(progress:float,reference:bool=false) -> Image:
	material.shader=load("res://game/cockpit/shaders/phosphor.gdshader" if reference else "res://game/cockpit/shaders/analogue_radar.gdshader")
	material.set_shader_parameter("radar_image",texture)
	material.set_shader_parameter("powered",1.0)
	material.set_shader_parameter("has_frame",1.0)
	material.set_shader_parameter("intensity",1.2)
	if not reference:
		material.set_shader_parameter("resolving",1.0 if progress<1.0 else 0.0)
		material.set_shader_parameter("resolve_progress",progress)
		material.set_shader_parameter("target_uv",Vector2(-1,-1))
	RenderingServer.force_draw(false)
	return view.get_texture().get_image()

func metrics(image:Image) -> Dictionary:
	var sums:Array[float]=[0.0,0.0,0.0,0.0]
	var counts:Array[int]=[0,0,0,0]
	var edge:=0.0;var count:=0
	var n:=image.get_width();var h:=n/2
	for y in range(n/6,n*5/6,2):
		for x in range(n/6,n*5/6,2):
			var value:=image.get_pixel(x,y).g
			var quadrant:=int(x>=h)+2*int(y>=h)
			sums[quadrant]+=value;counts[quadrant]+=1
			edge+=absf(value-image.get_pixel(x+1,y).g)+absf(value-image.get_pixel(x,y+1).g);count+=2
	for i in range(4):sums[i]/=maxi(counts[i],1)
	return {"quadrant_mean":sums,"detail_energy":edge/maxi(count,1)}

func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("This test must render pixels; do not run with --headless")
		quit(1);return
	DirAccess.make_dir_recursive_absolute(output)
	var image:Image
	if source.is_empty():
		image=Image.create(512,512,false,Image.FORMAT_L8)
		for y in range(512):
			for x in range(512):
				var value:=.26+.17*float((x/4+y/4)%2)+.15*float((x/61+y/73)%2)
				image.set_pixel(x,y,Color(value,value,value))
	else:
		image=Image.load_from_file(source)
		if image:image.convert(Image.FORMAT_L8)
	if image==null or image.is_empty():push_error("No usable source scan");quit(1);return
	var bytes:=image.get_data()
	var start:=Time.get_ticks_usec()
	check(image.generate_mipmaps()==OK,"Filtered display levels can be prepared")
	var prep_ms:=float(Time.get_ticks_usec()-start)/1000
	check(image.get_data().slice(0,bytes.size())==bytes,"Original radar bytes are preserved exactly")
	check(image.has_mipmaps(),"Whole-image multiscale data exists")
	texture=ImageTexture.create_from_image(image)
	view=SubViewport.new();view.size=Vector2i(640,640);view.own_world_3d=true
	view.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(view)
	var camera:=Camera3D.new();camera.projection=Camera3D.PROJECTION_ORTHOGONAL;camera.size=2
	camera.position=Vector3(0,0,2);view.add_child(camera);camera.current=true
	surface=MeshInstance3D.new();var quad:=QuadMesh.new();quad.size=Vector2(2,2);surface.mesh=quad
	material=ShaderMaterial.new();surface.material_override=material;view.add_child(surface)
	await process_frame
	var reference:=render_frame(1.0,true)
	var records:Array=[]
	for index in range(21):
		var progress:=float(index)/20.0
		var frame:=render_frame(progress)
		var record:=metrics(frame);record["progress"]=progress;records.append(record)
		check(not frame.is_empty(),"Native full-field frame "+str(index))
		frame.save_png(output.path_join("resolve_%02d.png"%index))
		if index==20:check(frame.get_data()==reference.get_data(),"Fully resolved display is pixel-identical to the original CRT shader")
		await process_frame
	reference.save_png(output.path_join("reference.png"))
	for q in range(4):
		check(float(records[0]["quadrant_mean"][q])>0.5*float(records[20]["quadrant_mean"][q]),"Quadrant "+str(q)+" is already visible at the start")
	check(float(records[0]["detail_energy"])<float(records[10]["detail_energy"]),"Fine detail builds across the whole image")
	check(float(records[10]["detail_energy"])<float(records[20]["detail_energy"]),"Final detail is crisper than the intermediate image")
	var report:Dictionary={"passed":passed,"failed":failed,"source":source,"display_levels_ms":prep_ms,
		"stages":records,"scope":"Native stepped display effect, not progressive radar computation or frame-rate timing"}
	var file:=FileAccess.open(output.path_join("crt_validation.json"),FileAccess.WRITE)
	if file:file.store_string(JSON.stringify(report,"  "));file.close()
	view.queue_free();texture=null;material=null;surface=null
	await process_frame
	print("CRT_RESOLVING_TESTS ",JSON.stringify({"passed":passed,"failed":failed}))
	quit(0 if failed==0 else 1)
