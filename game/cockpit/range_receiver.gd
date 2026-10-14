extends Control
## Circular green game receiver based on the supplied visual reference.
## Radius is an uncertain estimate; no world positions enter this view.
var contacts: Array = []
var selected_id := -1
var powered := false
var warning := false
var signal_level := 0.0
var range_m := 20000.0

func contact_point(contact: Dictionary) -> Vector2:
	var c := size*.5
	var radius := minf(size.x,size.y)*.465
	var fraction := clampf(float(contact.get("estimated_range_m",range_m))/range_m,.14,.92)
	var a := float(contact["bearing"])
	return c+Vector2(sin(a),-cos(a))*radius*fraction

func _line(a: Vector2,b: Vector2,color: Color,width: float=1.4) -> void:
	draw_line(a,b,Color(color,.10),width+4.0,true)
	draw_line(a,b,color,width,true)

func _draw() -> void:
	var c := size*.5
	var r := minf(size.x,size.y)*.465
	draw_rect(Rect2(Vector2.ZERO,size),Color(.022,.028,.026))
	for ring in [[r+11,Color(.20,.22,.21)],[r+8,Color(.065,.08,.074)],[r+3,Color(.002,.004,.003)],[r,Color(.001,.005,.002)]]:
		draw_circle(c,float(ring[0]),ring[1],true,-1,true)
	var ink := Color(.055,.32,.06) if powered else Color(.014,.05,.019)
	for fraction in [1.0,.55,.15]:
		draw_arc(c,r*fraction,0,TAU,128,Color(ink,.15),5,true)
		draw_arc(c,r*fraction,0,TAU,128,ink,2.1,true)
	for i in range(4):
		var a := i*PI/2
		var d := Vector2(sin(a),cos(a))
		_line(c+d*r*.15,c+d*r,ink,2.0)
	for degrees in range(0,360,15):
		var a := deg_to_rad(degrees)
		var d := Vector2(sin(a),-cos(a))
		_line(c+d*r*.99,c+d*r*(.81 if degrees%30==0 else .90),ink,2)
	draw_circle(c,3,ink,true,-1,true)
	if not powered:return
	for contact in contacts:
		var point := contact_point(contact)
		var picked := int(contact["id"])==selected_id
		var strength := clampf(float(contact["strength"]),0,1)
		var bright := Color(.28,.75+.22*strength,.21)
		var d := (point-c).normalized()
		var half_width := 4.0 if not picked else 6.0
		# A short radial smear encodes uncertainty, not an exact range solution.
		_line(point-d*half_width,point+d*half_width,bright,2.0)
		draw_circle(point,5,Color(bright,.12),true,-1,true)
		draw_circle(point,2,bright,true,-1,true)
		if picked:
			draw_arc(point,9,0,TAU,24,bright,1.2,true)
