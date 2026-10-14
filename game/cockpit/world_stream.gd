extends Node
## Rolling-chart prefetch and local/global coordinate handoff; no terrain math here.
signal sheet_changed(data:Dictionary)
var mission
var chart
var link
var clock:=0.0
var last_key:=""
var global_bounds:Array=[]
var latest:Dictionary={}
var stream_step:=2000.0
var sheet_forward:=4000.0
var revisions:=0
var retry_seconds:=0.0
var pending_image:Image
var pending_data:Dictionary={}

func configure(state,display,transport,manifest:Dictionary) -> void:
	mission=state;chart=display;link=transport
	stream_step=float(manifest.get("stream_step_m",2000))
	sheet_forward=float(manifest.get("sheet_forward_m",4000))
	latest=manifest;last_key=str(manifest.get("sheet_key",""));global_bounds=manifest["bounds"]
	link.chart_ready.connect(_accept)
	link.chart_failed.connect(_failed)
	mission.origin_shifted.connect(_rebase)
	chart.endless=true
	_apply_nearby(manifest)

func _process(dt:float) -> void:
	if mission==null or not mission.active or mission.finished:return
	if chart.acquisition_locked:return
	if not pending_data.is_empty():
		var data:Dictionary=pending_data;var image:Image=pending_image
		pending_data={};pending_image=null
		_accept(image,data)
	retry_seconds=maxf(0,retry_seconds-dt)
	clock+=dt
	if clock<.4 or retry_seconds>0:return
	clock=0
	var p:Array=prefetch_position()
	var key:="%d:%d" % [int(floor(float(p[0])/stream_step)*stream_step),int(floor(float(p[1])/stream_step)*stream_step+sheet_forward)]
	if key!=last_key and not link.chart_busy:
		link.request_chart(p)

func _local_bounds(bounds:Array) -> Rect2:
	var p:Vector2=mission.local_point([bounds[0],bounds[2]])
	return Rect2(p,Vector2(float(bounds[1])-float(bounds[0]),float(bounds[3])-float(bounds[2])))

func _accept(image:Image,data:Dictionary) -> void:
	if int(data.get("seed",-1))!=mission.seed_value:return
	if chart.acquisition_locked:
		pending_image=image;pending_data=data
		return
	var started:=Time.get_ticks_usec()
	global_bounds=data["bounds"];latest=data;last_key=str(data.get("sheet_key",last_key))
	# Retain previous paper until the full next sheet is ready. No texture blanking.
	var texture:=ImageTexture.create_from_image(image)
	chart.install_sheet(texture,_local_bounds(global_bounds))
	_apply_nearby(data)
	revisions+=1
	link.diagnostic_span.emit("stream_chart_upload_main",started,Time.get_ticks_usec())
	sheet_changed.emit(local_public())

func _apply_nearby(data:Dictionary) -> void:
	mission.update_endless_nearby(data)
	chart.suspected=mission.suspected
	chart.world_bounds=_local_bounds(data["bounds"])
	chart.aircraft=mission.position
	chart.follow_paper()

func local_public() -> Dictionary:
	# UI schema explicitly omits live emitter records.
	var b:Rect2=_local_bounds(global_bounds)
	return {"endless":true,"scenario":"endless","seed":mission.seed_value,
		"bounds":[b.position.x,b.end.x,b.position.y,b.end.y],
		"start":[mission.position.x,mission.position.y],
		"target":[mission.position.x,mission.position.y],"egress":[mission.position.x,mission.position.y],
		"suspected":mission.suspected,"suggested_routes":{}}

func _rebase(offset:Vector2) -> void:
	chart.world_bounds.position-=offset
	chart.selected_center-=offset
	chart.rebase_acquisition(offset)
	chart.aircraft=mission.position
	chart.target-=offset;chart.egress-=offset
	for i in range(chart.trail.size()):chart.trail[i]-=offset
	chart.follow_paper();chart.queue_redraw()
	sheet_changed.emit(local_public())

func _failed(_message:String) -> void:
	# The installed key changes only on success; a failed request retries later.
	retry_seconds=3.0


func prefetch_position() -> Array:
	# Centre the square cache on the visible map, whichever way the aircraft faces.
	# Round the 2km grid using its half-step; subtract the provider's north offset.
	var p:Array=mission.global_position_array()
	var lead:float=(chart.anchor().y-chart.size.y*.5)/chart.scale_px+mission.speed*8.0
	return [float(p[0])+sin(mission.heading)*lead+stream_step*.5,
		float(p[1])+cos(mission.heading)*lead+stream_step*.5-sheet_forward]
