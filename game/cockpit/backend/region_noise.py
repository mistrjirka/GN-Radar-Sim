"""Deterministic coordinate noise, independent of tile, crop and request order.

World generation only: no radar processing, game threat state or display code.
Coordinates use metres. No global RNG, periodic tile copies or stored fine atlas.
"""
import numpy as np


def lattice_hash(ix, iy, seed):
    x = np.asarray(ix).astype(np.uint32)
    y = np.asarray(iy).astype(np.uint32)
    with np.errstate(over='ignore'):
        value = x * np.uint32(0x9E3779B1) ^ y * np.uint32(0x85EBCA77) ^ np.uint32(int(seed) & 0xffffffff)
        value ^= value >> np.uint32(16)
        value *= np.uint32(0x7FEB352D)
        value ^= value >> np.uint32(15)
        value *= np.uint32(0x846CA68B)
        value ^= value >> np.uint32(16)
    return (value >> np.uint32(8)).astype(np.float32) * np.float32(1.0 / 16777216.0)


def noise(x, y, wavelength, seed):
    """Quintic-interpolated value noise. Coincident world points are identical."""
    x = np.asarray(x, dtype=np.float32) / np.float32(wavelength)
    y = np.asarray(y, dtype=np.float32) / np.float32(wavelength)
    ix = np.floor(x).astype(np.int32)
    iy = np.floor(y).astype(np.int32)
    fx = x - ix; fy = y - iy
    fx = (fx*fx*fx*(fx*(fx*6-15)+10)).astype(np.float32)
    fy = (fy*fy*fy*(fy*(fy*6-15)+10)).astype(np.float32)
    a = lattice_hash(ix, iy, seed); b = lattice_hash(ix+1, iy, seed)
    c = lattice_hash(ix, iy+1, seed); d = lattice_hash(ix+1, iy+1, seed)
    return ((a+(b-a)*fx)*(1-fy)+(c+(d-c)*fx)*fy).astype(np.float32)


def river_x(y, seed):
    phase = (int(seed) % 101) * .061
    return (320*np.sin(np.asarray(y)/1800+phase) + 140*np.sin(np.asarray(y)/470+phase*.7)).astype(np.float32)


def land_fields(x, y, seed):
    """Same ground/materials at any sampling scale; sub-grid detail is not invented.

Reference material IDs: water0 road1 soil2 forest3 concrete4 metal5 field6.
Normal-map-like clutter is represented by physical relief/roughness fields.
"""
    x=np.asarray(x,dtype=np.float32);y=np.asarray(y,dtype=np.float32)
    distance=np.abs(x-river_x(y,seed))
    valley=np.clip((distance-58)/600,0,1)
    broad=noise(x,y,2100,seed+201)
    hills=noise(x+130*noise(x,y,800,seed+2),y,620,seed+202)
    ridge=np.maximum(0,noise(x*.8+y*.2,y*.9-x*.15,260,seed+203)-.28)
    relief=(noise(x,y,90,seed+204)-.5)*18+(noise(x,y,27,seed+205)-.5)*6
    height=3+valley*(18+240*broad*broad+125*hills*hills+48*ridge)+relief*valley
    height+=np.minimum(distance/50,1)*2
    water=distance<(40+12*np.sin(y/700+seed*.17))
    height=np.where(water,-1.5,np.maximum(height,1)).astype(np.float32)
    forest=(noise(x,y,470,seed+301)>.52)&(distance>150)&(noise(x,y,135,seed+302)>.36)
    field=(~forest)&(distance>110)&(height<220)
    mat=np.full(x.shape,2,np.int32);mat[forest]=3;mat[field]=6;mat[water]=0
    # Fields have coherent parcel-scale orientations, not uniform image noise.
    cellx=np.floor(x/210).astype(np.int32);celly=np.floor(y/180).astype(np.int32)
    parcel=lattice_hash(cellx,celly,seed+411)
    furrow_az=np.where(field,np.floor(parcel*4)*np.pi/4,0).astype(np.float32)
    furrow_str=np.where(field,.20+.38*parcel,0).astype(np.float32)
    soil_rough=(.62+.8*noise(x,y,140,seed+303)+.1*noise(x,y,10,seed+304)).astype(np.float32)
    # Crowns are globally anchored; crop origin never reseeds vegetation.
    # Warp the crown coordinates so forestry does not become a regular grid.
    tx=x+24*(noise(x,y,73,seed+319)-.5)
    ty=y+24*(noise(x,y,81,seed+320)-.5)
    cx=np.floor(tx/11).astype(np.int32);cy=np.floor(ty/11).astype(np.int32)
    jitterx=lattice_hash(cx,cy,seed+321);jittery=lattice_hash(cx,cy,seed+322)
    dx=tx-(cx+.08+.84*jitterx)*11;dy=ty-(cy+.08+.84*jittery)*11
    crown=np.clip(1-(dx*dx+dy*dy)/(22+18*jittery),0,1)
    canopy=np.where(forest,(6+14*lattice_hash(cx,cy,seed+323))*np.sqrt(crown),0).astype(np.float32)
    return dict(ground=height,mat=mat,water=water,canopy=canopy,
                soil_rough=soil_rough,furrow_az=furrow_az,furrow_str=furrow_str)
