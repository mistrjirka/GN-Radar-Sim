extends RefCounted
## Background file transport only. Does not render, mutate game state, or spawn radar.
## Requests/status/raw pixels cross a mutex-protected mailbox; all disk I/O stays here.
var _thread: Thread
var _mutex:=Mutex.new()
var _requests:Array=[]
var _updates:Array=[]
var _stopping:=false
var _folder:=""
var _stream_last_key:=""

func start(folder:String) -> Error:
	_folder=folder
	_thread=Thread.new()
	var result:=_thread.start(_run)
	if result!=OK:_thread=null
	return result

func submit(request:Dictionary) -> void:
	_mutex.lock()
	_requests.append(request.duplicate(true))
	_mutex.unlock()

func take_updates() -> Array:
	_mutex.lock()
	var result:Array=_updates
	_updates=[]
	_mutex.unlock()
	return result

func _push(packet:Dictionary) -> void:
	_mutex.lock()
	_updates.append(packet)
	_mutex.unlock()

func _json(path:String) -> Dictionary:
	var file:=FileAccess.open(path,FileAccess.READ)
	if file==null:return {}
	var data=JSON.parse_string(file.get_as_text());file.close()
	return data if data is Dictionary else {}

func _publish(request:Dictionary) -> String:
	var name_:String="stream_request.json" if request.get("_channel")=="stream" else "request.json"
	var file:=FileAccess.open(_folder.path_join(name_+".tmp"),FileAccess.WRITE)
	if file==null:return "Cannot write radar request"
	file.store_string(JSON.stringify(request));file.close()
	var result:=DirAccess.rename_absolute(_folder.path_join(name_+".tmp"),_folder.path_join(name_))
	return "" if result==OK else "Cannot publish radar request"

func _read_frame(status:Dictionary) -> Dictionary:
	var width:=int(status.get("width",0));var height:=int(status.get("height",0))
	if width<1 or height<1 or width>4096 or height>4096:
		return {"error":"Invalid radar image dimensions"}
	var file:=FileAccess.open(str(status.get("raw_image","")),FileAccess.READ)
	if file==null:return {"error":"Radar frame missing"}
	var bytes:=file.get_buffer(file.get_length());file.close()
	if bytes.size()!=width*height:return {"error":"Incomplete radar frame"}
	return {"image":Image.create_from_data(width,height,false,Image.FORMAT_L8,bytes)}

func _run() -> void:
	var last_key:=""
	while true:
		_mutex.lock()
		var stop:=_stopping
		var requests:Array=_requests
		_requests=[]
		_mutex.unlock()
		if stop:break
		for request in requests:
			var begin:=Time.get_ticks_usec()
			var problem:=_publish(request)
			_push({"span":"request_publish_background","begin":begin,"end":Time.get_ticks_usec()})
			if not problem.is_empty():_push({"channel":"stream" if request.get("_channel")=="stream" else "radar","status":{"id":request["id"],"stage":"error","message":problem}})
		var read_started:=Time.get_ticks_usec()
		var status:=_json(_folder.path_join("status.json"))
		if not status.is_empty():
			var key:=str(status.get("id",-1))+":"+str(status.get("stage",""))
			if key!=last_key:
				last_key=key
				var packet:Dictionary={"status":status}
				if status.get("stage")=="ready":packet["manifest"]=_json(str(status["manifest"]))
				if status.get("stage")=="complete":
					packet.merge(_read_frame(status))
				packet["span"]="status_and_pixels_background"
				packet["begin"]=read_started;packet["end"]=Time.get_ticks_usec()
				_push(packet)
		_read_stream_status()
		OS.delay_msec(40)
	var file:=FileAccess.open(_folder.path_join("stop"),FileAccess.WRITE)
	if file:file.store_string("stop");file.close()

func shutdown() -> void:
	_mutex.lock();_stopping=true;_mutex.unlock()
	if _thread!=null:
		_thread.wait_to_finish()
		_thread=null


func _read_stream_status() -> void:
	var status:=_json(_folder.path_join("stream_status.json"))
	if status.is_empty():return
	var key:=str(status.get("id",-1))+":"+str(status.get("stage",""))
	if key==_stream_last_key:return
	_stream_last_key=key
	var packet:Dictionary={"channel":"stream","status":status}
	if status.get("stage")=="chart_ready":
		var data:=_json(str(status["manifest"]))
		packet["manifest"]=data
		packet["image"]=Image.load_from_file(str(data.get("chart","")))
	_push(packet)
