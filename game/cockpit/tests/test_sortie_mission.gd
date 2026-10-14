extends SceneTree
## Full seeded sorties, flown by the ordinary state update without teleporting.
const State=preload("res://game/cockpit/mission_state.gd")
var passed:=0
var failed:=0

func check(ok:bool,message:String) -> void:
	if ok:passed+=1;print("PASS ",message)
	else:failed+=1;push_error(message)

func _initialize() -> void:
	var path:=".radar_runtime/sortie_expansion/public_manifest.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--manifest="):path=arg.trim_prefix("--manifest=")
	var data=JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_error("Generate preview_sortie.py manifest first");quit(1);return
	# Public briefing plus separately loaded private game actors.
	var private_path:=path.get_base_dir().path_join("private_emitters.json")
	data["emitters"]=JSON.parse_string(FileAccess.get_file_as_string(private_path)) if FileAccess.file_exists(private_path) else []
	var reports:Dictionary={}
	for route_name in ["western","direct"]:
		var mission=State.new();mission.tuning.cruise_speed=90;mission.tuning.fuel_duration=950
		mission.setup(data);mission.begin()
		check(mission.select_briefed_route(route_name),route_name+" route accepted")
		check(mission.flight_bounds.size==Vector2(12000,18000),"Flight bounds come from the actual region")
		check(not mission.command_waypoint(Vector2(99000,0)),"Out-of-region navigation is rejected")
		var released:=false
		for i in range(5000):
			if mission.finished:break
			# Fixed simple test policy, not a path optimizer or altered game state.
			if mission.tracking>.65:mission.deploy_countermeasure()
			if mission.tracking>.5 and mission.arm_count>0 and mission.missile_time<=0:
				if not mission.armed:mission.toggle_arm()
				mission.cycle_emitter();mission.fire_arm()
			if not released and mission.position.distance_to(mission.target)<mission.tuning.release_radius*.8:
				released=mission.release_payload()
			mission.tick(.2)
		check(released,route_name+" reaches the objective without teleportation")
		check(mission.finished,route_name+" produces an end state")
		check(mission.distance_flown>23000,route_name+" flies beyond the old test patch")
		check(mission.survived,route_name+" can complete egress under the provisional rules")
		var report:Dictionary=mission.debrief();reports[route_name]=report
		print("FLOWN_SORTIE ",route_name," ",JSON.stringify(report))
		mission=null
	var f:=FileAccess.open(path.get_base_dir().path_join("flown_sorties.json"),FileAccess.WRITE)
	if f:f.store_string(JSON.stringify(reports,"  "));f.close()
	print("SORTIE_MISSION_TESTS ",JSON.stringify({"passed":passed,"failed":failed}))
	quit(0 if failed==0 else 1)
