extends Node
## Owns radar process and accepts completed frames; no runtime disk I/O on main.
const Mailbox=preload("res://game/cockpit/radar_mailbox.gd")
signal prepared(data: Dictionary)
signal chart_ready(image:Image,data:Dictionary)
signal chart_failed(message:String)
signal scan_ready(texture: Texture2D, details: Dictionary)
signal status_changed(message: String)
signal failed(message: String)
signal timing_event(label: String,duration_ms: float)
signal diagnostic_span(label: String,start_usec:int,end_usec:int)

var pid := -1
var folder := ""
var rid := 0
var waiting_id := -1
var handled_id := -1
var busy := false
var world_ready := false
var seed_value := 42
var scenario := "reference"
var poll_clock := 0.0
var launch_time := 0.0
var texture: ImageTexture
var last_result: Dictionary = {}
var closed := false
var mailbox
var chart_busy:=false
var chart_rid:=0
var chart_last:Dictionary={}

func launch(seed_number: int=42, mode: String="reference") -> void:
	scenario=mode;seed_value=seed_number
	folder=ProjectSettings.globalize_path("user://cockpit_sessions/%d_%d" % [OS.get_process_id(),Time.get_ticks_msec()])
	DirAccess.make_dir_recursive_absolute(folder)
	var python:=OS.get_environment("RADAR_PYTHON")
	if python.is_empty():python="/usr/bin/python3" if OS.get_name()=="Linux" else "python3"
	var cache:=OS.get_environment("RADAR_CACHE")
	if cache.is_empty():cache=ProjectSettings.globalize_path("user://radar_world_cache")
	mailbox=Mailbox.new()
	mailbox.progressive_display=scenario=="endless"
	if mailbox.start(folder)!=OK:
		failed.emit("Cannot start background radar transport");return
	pid=OS.create_process(python,PackedStringArray([ProjectSettings.globalize_path("res://game/cockpit/backend/mission_worker.py"),
		"--session",folder,"--cache",cache,"--parent",str(OS.get_process_id())]),false)
	launch_time=Time.get_ticks_msec()/1000.0
	if pid<0:
		failed.emit("Radar worker could not start. Set RADAR_PYTHON to an interpreter with the radar dependencies.")
		return
	_send({"action":"prepare"})

func _send(data: Dictionary) -> bool:
	if busy or pid<0 or closed:return false
	rid+=1;waiting_id=rid;busy=true
	data["id"]=rid;data["seed"]=seed_value;data["scenario"]=scenario
	mailbox.submit(data)
	return true

func scan(pose:Array,center,extent:float,quality:String="detail",heading:float=0.0) -> bool:
	if not world_ready:return false
	var xy:Array=center if center is Array else [center.x,center.y]
	return _send({"action":"scan","pose":pose,"center":xy,"extent":extent,"quality":quality,"heading":heading})

func _process(dt:float) -> void:
	if closed or pid<0:return
	poll_clock+=dt
	if poll_clock>.5:
		poll_clock=0
		if Time.get_ticks_msec()/1000.0-launch_time>3 and not OS.is_process_running(pid):
			busy=false;failed.emit("Radar worker stopped. See "+folder+"/worker.log");pid=-1;return
	for packet in mailbox.take_updates():
		if packet.get("channel")=="stream":
			_receive_chart(packet)
			continue
		if packet.has("span"):diagnostic_span.emit(packet["span"],int(packet["begin"]),int(packet["end"]))
		if not packet.has("status"):continue
		var s:Dictionary=packet["status"]
		var id:=int(s.get("id",-1))
		if id!=waiting_id or id<=handled_id:continue
		var stage:=str(s.get("stage",""))
		if stage in ["generating","scanning"]:
			status_changed.emit(stage);continue
		if stage=="ready":
			busy=false;handled_id=id;world_ready=true
			prepared.emit(packet.get("manifest",{}))
		elif stage=="error":
			busy=false;handled_id=id;failed.emit(str(s.get("message","Radar error")))
		elif stage=="complete":
			busy=false;handled_id=id
			if packet.has("error"):
				failed.emit(packet["error"]);continue
			var image:Image=packet.get("image")
			if image==null:
				failed.emit("Radar frame missing");continue
			var begun:=Time.get_ticks_usec()
			if scenario!="endless" and texture and texture.get_width()==image.get_width() and texture.get_height()==image.get_height():texture.update(image)
			else:texture=ImageTexture.create_from_image(image)
			diagnostic_span.emit("radar_texture_upload_main",begun,Time.get_ticks_usec())
			timing_event.emit("radar_texture_upload_main",float(Time.get_ticks_usec()-begun)/1000)
			last_result=s
			scan_ready.emit(texture,s)

func shutdown() -> void:
	if closed:return
	closed=true
	if mailbox:mailbox.shutdown();mailbox=null
	if pid>0 and OS.is_process_running(pid):OS.kill(pid)
	pid=-1

func _exit_tree() -> void:
	shutdown()


func request_chart(position:Array) -> bool:
	if closed or pid<0 or chart_busy or not world_ready or scenario!="endless":return false
	chart_rid+=1;chart_busy=true
	mailbox.submit({"_channel":"stream","id":chart_rid,"seed":seed_value,"position":position})
	return true

func _receive_chart(packet:Dictionary) -> void:
	var status:Dictionary=packet.get("status",{})
	if int(status.get("id",-1))!=chart_rid:return
	if status.get("stage")=="error":
		chart_busy=false;chart_failed.emit(str(status.get("message","Chart update failed")))
	elif status.get("stage")=="chart_ready":
		chart_busy=false
		var image:Image=packet.get("image")
		if image==null or image.is_empty():
			chart_failed.emit("Chart update has no image");return
		chart_last=packet.get("manifest",{})
		chart_ready.emit(image,chart_last)
