extends SceneTree
const Paper=preload("res://game/cockpit/paper_chart.gd")
var passed:=0
var failed:=0
func check(ok:bool,label:String) -> void:
	if ok:passed+=1;print("PASS ",label)
	else:failed+=1;push_error(label)
func _initialize() -> void:
	var paper=Paper.new();paper.size=Vector2(640,800)
	var rect:=Rect2(0,0,100,100)
	var c:PackedVector2Array=paper.clip_chart_segment(Vector2(-1000000,50),Vector2(1000000,50),rect)
	check(c.size()==2 and c[0].distance_to(Vector2(0,50))<1 and c[1].distance_to(Vector2(100,50))<1,"Long distant route clipped to viewport")
	check(paper.clip_chart_segment(Vector2(-100,-100),Vector2(-20,-20),rect).is_empty(),"Invisible route produces no ink geometry")
	c=paper.clip_chart_segment(Vector2(20,-1000),Vector2(20,1000),rect)
	check(c.size()==2 and c[0]==Vector2(20,0) and c[1]==Vector2(20,100),"Vertical crossing retains the visible segment")
	c=paper.clip_chart_segment(Vector2(10,20),Vector2(70,80),rect)
	check(c==PackedVector2Array([Vector2(10,20),Vector2(70,80)]),"In-frame path unchanged")
	paper.configure_region([-6000,6000,-9000,9000])
	var old:float=paper.scale_px;var box:float=paper.selected_extent
	paper.cycle_scale()
	check(paper.scale_px!=old and paper.selected_extent==box,"Paper scale changes immediately without changing radar area")
	paper.change_extent(4000);paper.select(Vector2(90000,90000))
	check(paper.selected_center==Vector2(4000,7000),"Large scan selection stays inside generated region")
	paper.free()
	print("PAPER_PERFORMANCE_TESTS ",JSON.stringify({"passed":passed,"failed":failed}))
	quit(0 if failed==0 else 1)
