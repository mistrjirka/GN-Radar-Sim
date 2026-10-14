extends SceneTree
## Test-only slow disk publication proves the game thread is not doing file I/O.
const Mailbox=preload("res://game/cockpit/radar_mailbox.gd")
var passed:=0
var failed:=0

class SlowMailbox extends "res://game/cockpit/radar_mailbox.gd":
	func _publish(request:Dictionary) -> String:
		OS.delay_msec(160)
		return super._publish(request)

func check(ok:bool,title:String) -> void:
	if ok:passed+=1;print("PASS ",title)
	else:failed+=1;push_error(title)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var directory:=ProjectSettings.globalize_path("user://mailbox_test_"+str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	var raw:=PackedByteArray();raw.resize(32*32);raw.fill(99)
	var file:=FileAccess.open(directory.path_join("radar.r8"),FileAccess.WRITE);file.store_buffer(raw);file.close()
	var status:Dictionary={"id":1,"stage":"complete","width":32,"height":32,"raw_image":directory.path_join("radar.r8")}
	file=FileAccess.open(directory.path_join("status.json"),FileAccess.WRITE);file.store_string(JSON.stringify(status));file.close()
	var mailbox=SlowMailbox.new()
	check(mailbox.start(directory)==OK,"Background transport starts")
	var begin:=Time.get_ticks_usec();mailbox.submit({"id":1,"action":"scan"})
	check(float(Time.get_ticks_usec()-begin)/1000<20,"Slow request publication does not block the submitting game thread")
	var heartbeat:=0;var frame_received:=false;var published:=false
	while heartbeat<150 and not (frame_received and published):
		for packet in mailbox.take_updates():
			if packet.get("span")=="request_publish_background":
				published=true
				check(float(packet["end"]-packet["begin"])/1000>=150,"Injected file delay is recorded on the background transport")
			if packet.has("image"):
				frame_received=true
				check(packet["image"].get_data()==raw,"Transferred grayscale pixels are unchanged")
		heartbeat+=1
		await create_timer(.005).timeout
	check(heartbeat>3,"Main event loop continues while request file publication is stalled")
	check(frame_received and published,"Frame and publication completion both arrive")
	await create_timer(.08).timeout
	check(mailbox.take_updates().is_empty(),"Unchanged worker status is not delivered repeatedly")
	mailbox.shutdown()
	var progressive=Mailbox.new();progressive.progressive_display=true
	var packet:Dictionary=progressive._read_frame(status)
	check(packet.has("image"),"Real transport prepares the progressive image")
	if packet.has("image"):
		check(packet["image"].has_mipmaps(),"Transport supplies filtered full-image levels")
		check(packet["image"].get_data().slice(0,raw.size())==raw,"Progressive display preserves every original grayscale byte")
	check(mailbox._thread==null,"Transport thread is joined on shutdown")
	for name_ in ["radar.r8","status.json","request.json","stop"]:DirAccess.remove_absolute(directory.path_join(name_))
	DirAccess.remove_absolute(directory)
	print("RADAR_MAILBOX_TESTS ",JSON.stringify({"passed":passed,"failed":failed}))
	quit(0 if failed==0 else 1)
