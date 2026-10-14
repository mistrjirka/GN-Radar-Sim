"""Coordinate-based terrain for unbounded flight; double global, float local fields.

No finite region, repeating raster tile, terrain RNG state or crop-dependent base.
The original approved/finite generators are not modified by this module.
"""
from __future__ import annotations
import numpy as np
from region_noise import lattice_hash


def noise(x, y, wavelength, seed):
    x=np.asarray(x,dtype=np.float64)/wavelength
    y=np.asarray(y,dtype=np.float64)/wavelength
    ix=np.floor(x).astype(np.int64);iy=np.floor(y).astype(np.int64)
    fx=(x-ix).astype(np.float32);fy=(y-iy).astype(np.float32)
    fx=fx**3*(fx*(fx*6-15)+10);fy=fy**3*(fy*(fy*6-15)+10)
    a=lattice_hash(ix,iy,seed);b=lattice_hash(ix+1,iy,seed)
    c=lattice_hash(ix,iy+1,seed);d=lattice_hash(ix+1,iy+1,seed)
    return ((a+(b-a)*fx)*(1-fy)+(c+(d-c)*fx)*fy).astype(np.float32)


def river_center(y, band, seed):
    """A continuous meandering drainage corridor for each 10km landscape band."""
    band=np.asarray(band,dtype=np.float64);y=np.asarray(y,dtype=np.float64)
    return band*10000+950*(noise(y,band*8713,3200,seed+81)-.5)+290*(noise(y,band*1753,730,seed+82)-.5)


def crossing_y(row, seed):
    row=np.asarray(row,dtype=np.int64)
    return row*3500.+(lattice_hash(row,row*0,seed+92)-.5)*900


def fields(x, y, seed, canopy=True):
    x=np.asarray(x,dtype=np.float64);y=np.asarray(y,dtype=np.float64)
    band=np.floor((x+5000)/10000).astype(np.int64)
    river=river_center(y,band,seed);distance=np.abs(x-river)
    valley=np.clip((distance-65)/650,0,1).astype(np.float32)
    broad=noise(x,y,5800,seed+201)
    warp=260*(noise(x,y,1100,seed+202)-.5)
    hills=noise(x+warp,y,830,seed+203)
    ridge=1-np.abs(2*noise(x*.82+y*.18,y*.94-x*.14,390,seed+204)-1)
    mountain=np.clip((broad-.40)*2.7,0,1)
    # Drainage floor, foothills, broken ridges and small roughness. Coarse/close
    # maps sample the same functions; features do not change with a crop's origin.
    height=3+valley*(20+100*hills+210*mountain*ridge**2+90*broad**2)
    height+=valley*((noise(x,y,95,seed+205)-.5)*18+(noise(x,y,24,seed+206)-.5)*4)
    width=36+24*noise(y,band*113,960,seed+207)
    water=distance<width
    height=np.where(water,-1.5,np.maximum(height,1)).astype(np.float32)
    forest=(noise(x,y,670,seed+301)>.52)&(distance>140)&(noise(x,y,155,seed+302)>.30)
    agricultural=(~forest)&(height<205)&(distance>95)&(noise(x,y,1200,seed+303)>.25)
    material=np.full(x.shape,2,np.int32);material[forest]=3;material[agricultural]=6;material[water]=0
    px=np.floor((x+25*noise(x,y,700,seed+310))/180).astype(np.int64)
    py=np.floor((y+25*noise(x,y,700,seed+311))/210).astype(np.int64)
    parcel=lattice_hash(px,py,seed+312)
    furrow_az=np.where(agricultural,np.floor(parcel*4)*np.pi/4,0).astype(np.float32)
    furrow_str=np.where(agricultural,.16+.44*parcel,0).astype(np.float32)
    rough=(.62+.8*noise(x,y,125,seed+314)+.12*noise(x,y,13,seed+315)).astype(np.float32)
    # Roads connect to real river crossings; no arbitrary endpoints at cell seams.
    row=np.floor((y+1750)/3500).astype(np.int64)
    roads=((abs(x-(river-210))<5)|(abs(y-crossing_y(row,seed))<4.5))&(~water)
    material[roads]=1
    crowns=np.zeros(x.shape,np.float32)
    if canopy:
        tx=x+22*(noise(x,y,71,seed+319)-.5);ty=y+22*(noise(x,y,79,seed+320)-.5)
        ix=np.floor(tx/10).astype(np.int64);iy=np.floor(ty/10).astype(np.int64)
        jx=lattice_hash(ix,iy,seed+321);jy=lattice_hash(ix,iy,seed+322)
        dx=tx-(ix+.12+.76*jx)*10;dy=ty-(iy+.12+.76*jy)*10
        crown=np.sqrt(np.clip(1-(dx*dx+dy*dy)/(17+19*jy),0,1))
        crowns=np.where(forest&(~roads),(6+14*lattice_hash(ix,iy,seed+323))*crown,0).astype(np.float32)
    return dict(ground=height,water=water,mat=material,canopy=crowns,soil_rough=rough,
                furrow_az=furrow_az,furrow_str=furrow_str)
