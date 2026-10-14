"""Shared native geometry for Godot and radar height/material rasterization.

Vehicle cab, four launch canisters, wheels, control box and lattice radar mast
are the same primitive design used in v3/render_camera.py, expressed locally.
They can be scaled to the approved reference footprints or shown at original
training-range dimensions. No VTK or downloaded asset dependency.
"""
from __future__ import annotations
import math

COLORS = {
    'metal_green': [.27,.32,.24], 'metal_dark': [.17,.20,.19],
    'tires': [.09,.11,.105], 'radome': [.84,.86,.81],
    'radar_mast': [.42,.49,.46], 'warehouse_wall': [.62,.61,.57],
    'roof': [.38,.42,.43], 'concrete': [.52,.51,.47],
    'bridge': [.49,.52,.54], 'bridge_dark': [.31,.35,.38],
    'road': [.26,.27,.29], 'pine': [.15,.29,.17],
}

def box(material, position, size, **extra):
    return dict(shape='box', material=material, position=list(position), size=list(size), **extra)

def tube(material, a, b, radius):
    return dict(shape='tube', material=material, a=list(a), b=list(b), radius=radius)

def vehicle():
    # Coordinates: local x=length, y=width, z=height; ground is z=0.
    p=[box('metal_green',(0,0,2.9),(25,8,3.3)),
       box('metal_green',(9,0,5.55),(7,7.5,2.6))]
    for lateral in (-2.6,-.85,.85,2.6):
        p.append(box('metal_dark',(-3.5,lateral,7.4),(14,1.15,1.45)))
    for longitudinal in (-8.2,7.2):
        for lateral in (-4.4,4.4):
            p.append(box('tires',(longitudinal,lateral,1.7),(2.6,1.6,2.5)))
    # Small control enclosure. Actual material/geometry, not a target marker.
    p.append(box('metal_dark',(0,6,.9),(2.4,2.4,1.5)))
    return p

def radar():
    # v3 control hut and lattice mast, with dielectric radome enclosing antenna.
    p=[box('warehouse_wall',(0,0,4.55),(18,16,9.1)),
       box('roof',(0,0,9.7),(18.6,16.6,.6)),
       box('metal_dark',(-13,20,1.7),(11,8,3.6)),
       box('metal_green',(0,0,10.9),(7,7,2.1))]
    for h in (12.9,18.9,24.9):
        for i in range(4):
            a=i*math.pi/2; b=a+math.pi/2
            p.append(tube('radar_mast',(3*math.cos(a),3*math.sin(a),h),
                          (3*math.cos(a),3*math.sin(a),h+6),.28))
            p.append(tube('radar_mast',(3*math.cos(a),3*math.sin(a),h),
                          (3*math.cos(b),3*math.sin(b),h+5.6),.19))
    p.append(dict(shape='sphere',material='radome',position=[0,0,29.9],size=[10.6,10.6,10.6],
                  radar_material='antenna_inside_radome'))
    return p

def warehouse(length, width, height=14, ridge=3, hvac=()):
    p=[box('warehouse_wall',(0,0,height/2),(length,width,height)),
       dict(shape='gabled_roof',material='roof',position=[0,0,height],size=[length,width,ridge])]
    for x,y in hvac:
        p.append(box('metal_dark',(x,y,height+ridge+1.1),(3,3,2.2)))
    for x in (-length/4,length/4):
        p.append(box('metal_dark',(x,-width/2-.12,2),(length*.18,.25,4)))
    return p

def bridge(length, width, deck, rail_height):
    p=[box('concrete',(0,0,deck-.5),(length,width,1)),
       box('road',(0,0,deck+.05),(length,width-.8,.1))]
    segments=max(6,round(length/8))
    for side in (-1,1):
        y=side*(width/2-.4)
        p.extend([tube('bridge',(-length/2,y,rail_height),(length/2,y,rail_height),.23),
                  tube('bridge_dark',(-length/2,y,deck+.3),(length/2,y,deck+.3),.23)])
        for i in range(segments):
            a=-length/2+i*length/segments;b=a+length/segments
            p.append(tube('bridge',(a,y,deck),(a,y,rail_height),.18))
            p.append(tube('bridge',(a,y,deck),(b,y,rail_height),.16))
            p.append(tube('bridge',(a,y,rail_height),(b,y,deck),.16))
    for x in (-length*.27,0,length*.27):
        p.append(box('concrete',(x,0,deck/2),(3.5,width*.65,deck)))
    return p

def pylon(height=28):
    p=[]
    for side in (-1,1):
        for other in (-1,1):
            p.append(tube('radar_mast',(side*2.2,other*2.2,0),(side*.65,other*.65,height),.2))
    for z in (7,14,21,27):
        p.append(tube('radar_mast',(-5,0,z),(5,0,z),.18))
    return p

def entity(kind,x,y,base,angle=0,scale=(1,1,1),**properties):
    if kind=='vehicle': parts=vehicle()
    elif kind=='radar': parts=radar()
    elif kind=='warehouse': parts=warehouse(properties['length'],properties['width'],properties.get('height',14),properties.get('ridge',3),properties.get('hvac',()))
    elif kind=='bridge': parts=bridge(properties['length'],properties['width'],properties['deck'],properties['rail_height'])
    elif kind=='pylon': parts=pylon(properties.get('height',28))
    else: raise ValueError(kind)
    return dict(kind=kind,x=float(x),y=float(y),base=float(base),angle=float(angle),scale=list(scale),parts=parts,**properties)
