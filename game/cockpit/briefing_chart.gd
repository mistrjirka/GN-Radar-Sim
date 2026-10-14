extends Control
## Full paper briefing from public terrain/intelligence only, never exact emitters.
var chart: Texture2D
var public_data: Dictionary = {}
var route_name := "western"
var font: Font = ThemeDB.fallback_font

func map_rect() -> Rect2:
	var b: Array=public_data.get("bounds",[-6000,6000,-9000,9000])
	var ratio := float(b[1]-b[0])/float(b[3]-b[2])
	var h := size.y-26
	var w := minf(size.x-26,h*ratio)
	h=w/ratio
	return Rect2((size-Vector2(w,h))/2,Vector2(w,h))

func project_point(p: Array) -> Vector2:
	var r := map_rect()
	var b: Array=public_data.get("bounds",[-6000,6000,-9000,9000])
	return r.position+Vector2((float(p[0])-b[0])/(b[1]-b[0])*r.size.x,(b[3]-float(p[1]))/(b[3]-b[2])*r.size.y)

func _draw() -> void:
	var r := map_rect()
	draw_rect(r,Color(.76,.69,.50))
	if chart:draw_texture_rect(chart,r,false)
	if public_data.is_empty():return
	var b: Array=public_data["bounds"]
	for intel in public_data.get("suspected",[]):
		var c:=project_point(intel["center"])
		var radius:float=float(intel["radius"])/float(b[1]-b[0])*r.size.x
		draw_arc(c,radius,0,TAU,48,Color(.42,.11,.07,.9),1.7,true)
		draw_string(font,c+Vector2(radius+2,0),"?",HORIZONTAL_ALIGNMENT_LEFT,-1,15,Color(.4,.07,.04))
	var route: Array=public_data.get("suggested_routes",{}).get(route_name,[])
	var prev:=project_point(public_data["start"])
	for p in route:
		var next:=project_point(p)
		draw_dashed_line(prev,next,Color(.12,.2,.22),1.8,5,true)
		draw_circle(next,3,Color(.12,.2,.22))
		prev=next
	var entries:Array=[["AIRCRAFT",public_data["start"]]] if public_data.get("endless",false) else [["ENTRY",public_data["start"]],["ZULU",public_data["target"]],["EGRESS",public_data["egress"]]]
	for entry in entries:
		var loc:=project_point(entry[1])
		draw_circle(loc,5,Color(.28,.08,.035),false,1.5,true)
		draw_string(font,loc+Vector2(8,-8 if entry[0]!="EGRESS" else 17),entry[0],HORIZONTAL_ALIGNMENT_LEFT,-1,16,Color(.24,.06,.025))
	draw_rect(r,Color(.28,.22,.13),false,2)
