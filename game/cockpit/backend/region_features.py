"""Scene-space feature rasterization using the approved material/reflector fields.

Radar consumes these physical footprints before image formation; no target icons
or cross-shaped display overlays are added. Small geometry remains a 2.5D proxy.
"""
import math
import numpy as np


def foundation(w,x,y):
    key=(float(x),float(y))
    if hasattr(w,'_feature_bases') and key in w._feature_bases:
        return w._feature_bases[key]
    return float(w._region.ground(np.array([x],np.float64),np.array([y],np.float64))['ground'][0])


def near_patch(w,x,y,radius):
    c=w._world_center;half=w.size_m*.5
    return abs(x-c[0])<=half+radius and abs(y-c[1])<=half+radius


def building(w,x,y,length,width,angle=0,height=14,ridge=3):
    if not near_patch(w,x,y,max(length,width)):return
    X,Y=w._global_x,w._global_y
    u=(X-x)*math.cos(angle)+(Y-y)*math.sin(angle)
    v=-(X-x)*math.sin(angle)+(Y-y)*math.cos(angle)
    mask=(abs(u)<=length/2)&(abs(v)<=width/2)
    if not mask.any():return
    base=foundation(w,x,y)
    w.height[mask]=base+height+ridge*(1-abs(v[mask])/(width/2))
    w.mat_id[mask]=4
    # Original outward wall convention, one-sided normals; no extra MP halo.
    width_px=max(1.5,w.dx*.8)
    walls=[((abs(v-width/2)<width_px)&(abs(u)<length/2-1.5),angle+math.pi/2),
           ((abs(v+width/2)<width_px)&(abs(u)<length/2-1.5),angle-math.pi/2),
           ((abs(u-length/2)<width_px)&(abs(v)<width/2-1.5),angle),
           ((abs(u+length/2)<width_px)&(abs(v)<width/2-1.5),angle+math.pi)]
    for wall,az in walls:
        w.wall_nx[wall]=95*math.cos(az);w.wall_ny[wall]=95*math.sin(az)


def equipment(w,x,y,angle,kind='vehicle'):
    if not near_patch(w,x,y,50):return
    X,Y=w._global_x,w._global_y
    u=(X-x)*math.cos(angle)+(Y-y)*math.sin(angle)
    v=-(X-x)*math.sin(angle)+(Y-y)*math.cos(angle)
    if kind=='radar':
        building(w,x,y,18,16,0,9,0)
        mask=(u*u+v*v)<5.3**2
        if mask.any():
            base=foundation(w,x,y)
            w.height[mask]=base+35;w.mat_id[mask]=5
            w.trihedral_str[mask]=165;w.mp_height[mask]=11;w.mp_bounce2[mask]=35
        return
    mask=(abs(u)<12.5)&(abs(v)<4.8)
    if not mask.any():return
    base=foundation(w,x,y)
    w.height[mask]=base+4.55;w.mat_id[mask]=5
    cab=mask&(u>5.5);w.height[cab]=base+6.85
    for lateral in (-2.6,-.85,.85,2.6):
        canister=(abs(u+3.5)<7)&(abs(v-lateral)<max(.575,w.dx*.3))
        w.height[canister]=base+8.125;w.mat_id[canister]=5
    w.dihedral_str[mask]=80;w.dihedral_az[mask]=angle+math.pi/2
    w.trihedral_str[mask]=42;w.mp_height[mask]=5.5;w.mp_bounce2[mask]=22;w.mp_bounce3[mask]=9


def site(w,record):
    x,y=record['position']
    if not near_patch(w,x,y,230):return
    X,Y=w._global_x,w._global_y
    d=np.hypot(X-x,Y-y)
    clearing=(d<158)&(~w._water_mask)
    w.height[clearing]=w._ground_height[clearing]
    w.mat_id[clearing]=2
    # Six vehicles, central mast and physical access ring as in approved scene.
    ring=abs(d-92)<4;w.mat_id[ring]=1
    w.height[ring]=w._ground_height[ring]
    a0=record['layout_angle']
    equipment(w,x,y,0,'radar')
    for k in range(6):
        angle=a0+k*math.pi/3
        px=x+132*math.cos(angle);py=y+132*math.sin(angle)
        equipment(w,px,py,angle)
        u=(X-x)*math.cos(angle)+(Y-y)*math.sin(angle)
        v=-(X-x)*math.sin(angle)+(Y-y)*math.cos(angle)
        track=(u>88)&(u<124)&(abs(v)<2.4)
        w.mat_id[track]=1
        w.height[track]=w._ground_height[track]


def bridge(w,x,y,length=150,width=12):
    if not near_patch(w,x,y,length):return
    X,Y=w._global_x,w._global_y
    deck=(abs(X-x)<length/2)&(abs(Y-y)<width/2)
    if not deck.any():return
    h=12.0
    w.height[deck]=h;w.mat_id[deck]=4
    for side in (-1,1):
        rail=(abs(X-x)<length/2)&(abs(Y-y-side*(width/2-.4))<max(1.0,w.dx*.65))
        w.height[rail]=h+4;w.mat_id[rail]=5
        w.dihedral_str[rail]=32;w.dihedral_az[rail]=math.pi/2;w.trihedral_str[rail]=7.5
        posts=rail&(abs(np.mod(X-x+length/2,12)-6)<1.2)
        w.trihedral_str[posts]=22
    over=deck&w._water_mask
    w.mp_height[over]=h;w.mp_bounce2[over]=20;w.mp_bounce3[over]=8


def add_features(w,region,include_emitters=True):
    for warehouse in region.warehouses:
        building(w,**warehouse)
    for b in region.bridges:bridge(w,**b)
    if include_emitters:
        for record in region.sites:site(w,record)
