extends Node3D
## Four real slider bars above the paper. Their intersections delimit the scan.
## Two horizontal and two vertical members run to opposite instrument edges.
var bars:Array[Node3D]=[]
var rig
const WIDTH:=.87
const HEIGHT:=1.12
const ORIGIN:=Vector3(1.24,1.04,.178)

func build(owner_rig) -> void:
	rig=owner_rig
	var bar_mat=rig.material(Color(.19,.18,.125),.75,.38)
	var edge_mat=rig.material(Color(.48,.42,.26),.68,.5)
	for axis in range(2):
		for side in range(2):
			var bar:=Node3D.new();add_child(bar);bars.append(bar)
			var horizontal:=axis==0
			var length:=WIDTH if horizontal else HEIGHT
			var dimensions:=Vector3(length,.005,.004) if horizontal else Vector3(.005,length,.004)
			rig.box(bar,Vector3.ZERO,dimensions,bar_mat)
			var line:=Vector3(length,.0012,.001) if horizontal else Vector3(.0012,length,.001)
			rig.box(bar,Vector3(0,0,.003),line,edge_mat)
			for end in [-1,1]:
				var p:=Vector3(end*WIDTH/2,0,.004) if horizontal else Vector3(0,end*HEIGHT/2,.004)
				rig.box(bar,p,Vector3(.021,.023,.012),rig.steel)
				rig.cylinder(bar,p+Vector3(0,0,.008),.0045,.003,rig.worn)
			# Engraved divisions distinguish a physical guide from colored UI lines.
			for i in range(1,20):
				var along:float=-length/2+length*i/20.0
				var p:=Vector3(along,0,.0035) if horizontal else Vector3(0,along,.0035)
				var tick:=Vector3(.001,.004,.0006) if horizontal else Vector3(.004,.001,.0006)
				rig.box(bar,p,tick,edge_mat)

func update_from_chart(chart) -> void:
	if bars.size()!=4:return
	var area:Rect2=chart.selection_rect()
	var normalized_position:Vector2=area.position/chart.size
	var normalized_end:Vector2=area.end/chart.size
	var values:Array[float]=[normalized_position.y,normalized_end.y,normalized_position.x,normalized_end.x]
	for i in range(4):
		bars[i].visible=values[i]>=0 and values[i]<=1
		bars[i].position=ORIGIN+(Vector3(0,(.5-values[i])*HEIGHT,0) if i<2 else Vector3((values[i]-.5)*WIDTH,0,.011))
