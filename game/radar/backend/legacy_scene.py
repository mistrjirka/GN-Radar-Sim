"""Earlier six-launcher training terrain; original geometry adapter preserved."""
import numpy as np
from scipy import ndimage as ndi
from vendor.legacy_tactical import GroundRadarScene
from approved_renderer import g as gemini
OURS_OFFSET=1185.0
def sample(arr,srcx,srcy,X,Y,order=1):
    ix=(X-float(srcx[0]))/float(srcx[1]-srcx[0])
    iy=(Y-float(srcy[0]))/float(srcy[1]-srcy[0])
    return ndi.map_coordinates(arr,[iy,ix],order=order,mode="nearest")

def our_scene_as_gemini(w,src=None):
    """Replace only Gemini world attributes, never engine or RNG state."""
    if src is None:src=GroundRadarScene(seed=112788,n_ground=1,nx=510,ny=620)
    assert w.N==1536 and w.size_m==2000
    X,Y=w.X,w.Y
    Ysrc=Y+OURS_OFFSET
    x0,x1=float(src.x[0]),float(src.x[-1])
    y0,y1=float(src.y[0]),float(src.y[-1])
    on=(X>=x0)&(X<=x1)&(Ysrc>=y0)&(Ysrc<=y1)
    h=sample(src.height,src.x,src.y,X,Ysrc)
    dd=np.hypot(np.maximum(x0-X,np.maximum(X-x1,0)),
                np.maximum(y0-Ysrc,np.maximum(Ysrc-y1,0)))
    w.height[:]=5+(h-5)*np.maximum(1-dd/170,0)
    nmat=sample(src.material,src.x,src.y,X,Ysrc,order=0).astype(np.int32)
    # v3: ground, water, forest, road, building, concrete, metal.
    # Gemini: water, road, soil, forest, concrete, metal, field.
    lookup=np.array([gemini.MAT_SOIL,gemini.MAT_WATER,gemini.MAT_FOREST,
                     gemini.MAT_ROAD,gemini.MAT_CONCRETE,
                     gemini.MAT_CONCRETE,gemini.MAT_METAL],np.int32)
    w.mat_id[:]=np.where(on,lookup[nmat],gemini.MAT_SOIL)
    # No original Gemini-generated terrain statistics remain on our source.
    w.soil_rough.fill(1.)
    for name in ("furrow_az","furrow_str","dihedral_str","dihedral_az",
                 "wall_nx","wall_ny","trihedral_str","mp_height",
                 "mp_bounce2","mp_bounce3"):
        getattr(w,name).fill(0)
    for bx,by,ang in src.launchers:
        by-=OURS_OFFSET
        u=(X-bx)*np.cos(ang)+(Y-by)*np.sin(ang)
        v=-(X-bx)*np.sin(ang)+(Y-by)*np.cos(ang)
        mask=(abs(u)<13)&(abs(v)<4)
        w.mat_id[mask]=gemini.MAT_METAL
        w.dihedral_str[mask]=80.
        w.dihedral_az[mask]=ang+np.pi/2
        w.trihedral_str[mask]=42.
        w.mp_height[mask]=5.5
        w.mp_bounce2[mask]=22.
        w.mp_bounce3[mask]=9.
    cx,cy=src.central_xy;cy-=OURS_OFFSET
    radar=(X-cx)**2+(Y-cy)**2<5.5**2
    w.height[radar]=np.maximum(w.height[radar],35.)
    w.mat_id[radar]=gemini.MAT_METAL
    w.trihedral_str[radar]=165.
    w.mp_height[radar]=11.
    w.mp_bounce2[radar]=35.
    nwalls=0
    for bx,by,L,W,angle,roof,material in src.rects:
        if material!=4: continue
        by-=OURS_OFFSET
        u=(X-bx)*np.cos(angle)+(Y-by)*np.sin(angle)
        v=-(X-bx)*np.sin(angle)+(Y-by)*np.cos(angle)
        walls=(
          ((abs(v+W/2)<1.6)&(abs(u)<=L/2-1.5),angle-np.pi/2),
          ((abs(v-W/2)<1.6)&(abs(u)<=L/2-1.5),angle+np.pi/2),
          ((abs(u+L/2)<1.6)&(abs(v)<=W/2-1.5),angle+np.pi),
          ((abs(u-L/2)<1.6)&(abs(v)<=W/2-1.5),angle))
        for mask,az in walls:
            w.wall_nx[mask]=95*np.cos(az)
            w.wall_ny[mask]=95*np.sin(az)
            nwalls+=int(mask.sum())
    bx,by,_=src.bridge_data[0];by-=OURS_OFFSET
    bridge=(abs(X-bx)<9)&(abs(Y-by)<101)
    for r_x in (bx-7,bx+7):
        rail=(abs(X-r_x)<1.1)&(abs(Y-by)<97)
        w.height[rail]=np.maximum(w.height[rail],19.5)
        w.mat_id[rail]=gemini.MAT_METAL
        w.dihedral_str[rail]=32.
        w.dihedral_az[rail]=0.
        w.trihedral_str[rail]=7.5
        posts=rail&(abs(np.mod(Y-by+97,12)-6)<1.05)
        w.trihedral_str[posts]=22.
        w.dihedral_str[posts]=24.
    belowwater=(sample(src.water.astype(np.uint8),
              src.x,src.y,X,Ysrc,order=0)>0)
    over=bridge&belowwater
    w.mp_height[over]=11.7   # geometry-dependent 13m deck minus 1.3m water
    w.mp_bounce2[over]=20.
    w.mp_bounce3[over]=8.
    for py in np.linspace(by-70,by+70,5):
        pier=over&(abs(Y-py)<2.1)&(abs(X-bx)<5)
        w.trihedral_str[pier]=42.
        w.mp_bounce2[pier]=45.
    # Gemini's own normal calculation and same numeric thresholds.
    w.smooth_h_for_normals[:]=ndi.gaussian_filter(w.height,2.)
    w._compute_normals()
    return dict(source="our tactical scene",world_N=w.N,world_size_m=w.size_m,
                source_fraction=float(on.mean()),offset_y=-OURS_OFFSET,
                material_lookup=list(map(int,lookup)),wall_pixels=nwalls,
                bridge_over_water_pixels=int(over.sum()),
                launchers=len(src.launchers),warehouses=len(src.warehouses),
                radar_renderer_modified=False,
                strict_notes="Outside native footprint is 5m soil padding. Radar constants unchanged. Reflector geometries are translated using original Gemini strengths.")


def adapt_legacy(w,seed):
    s=GroundRadarScene(seed=112788 if seed==42 else seed,n_ground=1,nx=510,ny=620)
    our_scene_as_gemini(w,s)
    base=s.height.copy()
    base[(s.material==4)|(s.material==6)]=np.minimum(base[(s.material==4)|(s.material==6)],5.8)
    base[s.bridge_mask]=1.5
    w._ground_height=sample(base,s.x,s.y,w.X,w.Y+OURS_OFFSET)
    outside=(w.X<s.x[0])|(w.X>s.x[-1])|(w.Y+OURS_OFFSET<s.y[0])|(w.Y+OURS_OFFSET>s.y[-1])
    w._ground_height[outside]=w.height[outside]
    w._canopy=np.where(w.mat_id==gemini.MAT_FOREST,10.,0.).astype(np.float32)
    w._water_mask=w.mat_id==gemini.MAT_WATER
    w._legacy_metadata={
      'launchers':[[float(x),float(y-OURS_OFFSET),float(a)] for x,y,a in s.launchers],
      'central_xy':[float(s.central_xy[0]),float(s.central_xy[1]-OURS_OFFSET)],
      'warehouses':[[x,y-OURS_OFFSET,l,b,h] for x,y,l,b,h in s.warehouses],
      'bridge':[float(s.bridge_data[0][0]),float(s.bridge_data[0][1]-OURS_OFFSET)]}
