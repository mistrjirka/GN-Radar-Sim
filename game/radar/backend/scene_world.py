"""One deterministic scene description for Godot, radar and regression fixtures.

Captures base terrain before trees/buildings from the vendored reference generator
without changing its arithmetic or RNG. The detailed equipment design is shared
as primitive records. Optional radar proxies rasterize those same records; the
original approved snapshot remains available as an exact regression target.
"""
from __future__ import annotations
import copy, hashlib, inspect, json, math, os, textwrap
from pathlib import Path
import numpy as np
from scipy.ndimage import map_coordinates, maximum_filter
from PIL import Image
import approved_renderer as radar
from model_library import entity, COLORS

g=radar.g
ROOT=Path(__file__).resolve().parent
CACHE_VERSION='shared_world_3'
ARRAY_FIELDS=('X','Y','height','smooth_h_for_normals','mat_id','soil_rough','furrow_az','furrow_str',
 'dihedral_str','dihedral_az','wall_nx','wall_ny','trihedral_str','mp_height','mp_bounce2','mp_bounce3','nx','ny','nz')

# Instrument the generator with read-only snapshots. Assert each insertion so
# an upstream change cannot silently make the optical and radar worlds diverge.
source=textwrap.dedent(inspect.getsource(g.RadarTestWorldV6_5._build_scene))
def insert_once(text,anchor,replacement):
    if text.count(anchor)!=1: raise RuntimeError('Generator capture anchor changed: '+anchor)
    return text.replace(anchor,replacement)
source=insert_once(source,'    self.height[has_tree] += tree_h[has_tree]',
 '    self.height[has_tree] += tree_h[has_tree]\n    self._canopy=np.where(has_tree,tree_h,0).astype(np.float32)\n    self._water_mask=is_water.copy()')
source=insert_once(source,'    self.smooth_h_for_normals = self.height.copy()',
 '    self.smooth_h_for_normals = self.height.copy()\n    self._ground_height=(self.height-self._canopy).copy()')
source=insert_once(source,'        self.smooth_h_for_normals[berm_mask] += 4.5 * berm_profile[berm_mask]',
 '        self.smooth_h_for_normals[berm_mask] += 4.5 * berm_profile[berm_mask]\n        self._ground_height[berm_mask] += 4.5 * berm_profile[berm_mask]')
ns=dict(g.__dict__);exec(compile(source,str(ROOT/'vendor/gemini_v65.py')+'::capture','exec'),ns)

class CapturedWorld(g.RadarTestWorldV6_5):
    _build_scene=ns['_build_scene']


def atom_json(path,data):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_suffix(path.suffix+'.tmp')
    temporary.write_text(json.dumps(data,allow_nan=False))
    os.replace(temporary,path)


def sample(w,field,x,y,order=1):
    arr=getattr(w,field)
    dx=w.size_m/(w.N-1)
    return map_coordinates(arr,[(np.asarray(y)+w.size_m/2)/dx,(np.asarray(x)+w.size_m/2)/dx],
                           order=order,mode='nearest')


def ground_at(w,x,y):
    return float(sample(w,'_ground_height',np.array([x]),np.array([y]))[0])


def equipment(w,legacy=False):
    parts=[]
    if legacy:
        s=w._legacy_metadata
        for px,py,angle in s['launchers']:
            parts.append(entity('vehicle',px,py,5.1,angle))
        x,y=s['central_xy'];parts.append(entity('radar',x,y,5.1))
        for x,y,l,b,h in s['warehouses']:
            parts.append(entity('warehouse',x,y,5.1,length=l,width=b,height=h-5.1,ridge=0))
        x,y=s['bridge'];parts.append(entity('bridge',x,y,0,math.pi/2,length=194,width=18,deck=13,rail_height=19.5))
        return parts
    for k in range(6):
        angle=k*math.pi/3+math.radians(15)
        x=-500+130*math.cos(angle);y=-450+130*math.sin(angle)
        # Same primitive design as v3, scaled to reference footprint/height.
        parts.append(entity('vehicle',x,y,ground_at(w,x,y),angle,
                            scale=(1,1,1)))
    parts.append(entity('radar',-500,-450,ground_at(w,-500,-450),scale=(1,1,1)))
    for x,y,a,hvac in [(420,285,0,[[-22,-4],[8,5],[26,-3]]),(420,185,0,[[-18,4],[16,-5]]),
                         (565,235,math.radians(32),[[-16,-4],[14,3.5]])]:
        parts.append(entity('warehouse',x,y,ground_at(w,x,y),a,length=84,width=40,height=14,ridge=3,hvac=hvac))
    x=175*math.sin(60/360)+.22*60
    parts.append(entity('bridge',x,60,0,length=126,width=10.4,deck=22,rail_height=24.2))
    parts.append(entity('vehicle',-370,560,ground_at(w,-370,560),scale=(11/25,5.2/9.6,4/8.125)))
    for i in range(-4,5):
        x=-120+i*185;y=110+i*155
        if -920<x<920 and -920<y<920 and abs(x-(175*math.sin(y/360)+.22*y))>68:
            parts.append(entity('pylon',x,y,ground_at(w,x,y)))
    return parts


def _load_scene_unlocked(cache,seed=42,scenario='valley'):
    seed=int(seed)
    if not 0<=seed<=2147483647: raise ValueError('Seed must be 0..2147483647')
    if scenario not in ('valley','legacy'):raise ValueError('Unknown scene')
    digest=hashlib.sha256((radar.SRC.read_text()+source+CACHE_VERSION).encode()).hexdigest()[:16]
    folder=Path(cache)/f'{scenario}_{seed}_{digest}';folder.mkdir(parents=True,exist_ok=True)
    npz=folder/'world.npz';meta=folder/'world.json'
    if npz.exists() and meta.exists():
        info=json.loads(meta.read_text());w=CapturedWorld.__new__(CapturedWorld)
        with np.load(npz,allow_pickle=False) as z:
            for key in z.files:setattr(w,key,z[key])
        w.size_m=2000.;w.N=1536;w.dx=w.size_m/w.N
        w.rng=np.random.default_rng();w.rng.bit_generator.state=info['rng_state']
        if 'legacy_metadata' in info:w._legacy_metadata=info['legacy_metadata']
    else:
        w=CapturedWorld(size_m=2000,N=1536,seed=seed)
        if scenario=='legacy':
            from legacy_scene import adapt_legacy
            adapt_legacy(w,seed)
        info={'seed':seed,'scenario':scenario,'rng_state':copy.deepcopy(w.rng.bit_generator.state),'schema':digest}
        if hasattr(w,'_legacy_metadata'):info['legacy_metadata']=w._legacy_metadata
        arrays={k:v for k,v in vars(w).items() if isinstance(v,np.ndarray)}
        with (folder/'world.tmp').open('wb') as f:np.savez(f,**arrays)
        os.replace(folder/'world.tmp',npz);atom_json(meta,info)
    w._initial_rng=copy.deepcopy(w.rng.bit_generator.state)
    w._entities=equipment(w,scenario=='legacy')
    w._seed=seed;w._scenario=scenario;w._cache_dir=folder
    return w


def load_scene(cache,seed=42,scenario='valley'):
    # Separate game windows can share a seed cache without racing on .tmp files.
    cache=Path(cache);cache.mkdir(parents=True,exist_ok=True)
    if scenario not in ('valley','legacy'):raise ValueError('Unknown scene')
    seed=int(seed)
    if not 0<=seed<=2147483647:raise ValueError('Seed out of range')
    with (cache/f'.{scenario}_{seed}.lock').open('a') as lock:
        if os.name=='posix':
            import fcntl
            fcntl.flock(lock,fcntl.LOCK_EX)
        return _load_scene_unlocked(cache,seed,scenario)


def native_models_world(reference):
    """Rasterize equipment upper surfaces. Reference mode remains bit-exact.

The primitive model geometry controls radar top heights/material areas. Facet,
corner and delayed-reflection coefficients remain the approved empirical laws;
tiny wheels/lattice gaps below the 1.3m grid are not a full-wave solution.
"""
    w=copy.copy(reference)
    w._entities=copy.deepcopy(reference._entities)
    w._ground_height=reference._ground_height.copy()
    for key in ('height','mat_id','dihedral_str','dihedral_az','trihedral_str','mp_height','mp_bounce2','mp_bounce3'):
        setattr(w,key,getattr(reference,key).copy())
    altered=np.zeros((w.N,w.N),bool)
    for e in w._entities:
        if e['kind'] not in ('vehicle','radar'):continue
        x,y,ang=e['x'],e['y'],e['angle'];sx,sy,sz=e['scale']
        u=(w.X-x)*math.cos(ang)+(w.Y-y)*math.sin(ang)
        v=-(w.X-x)*math.sin(ang)+(w.Y-y)*math.cos(ang)
        radius=16 if e['kind']=='vehicle' else 20
        clear=(abs(u)<radius*sx+2)&(abs(v)<25*sy+2)
        # Preserve terrain/roads while removing the old primitive equipment.
        old=clear&(reference.mat_id==g.MAT_METAL)
        w.height[old]=reference._ground_height[old]
        w.mat_id[old]=g.MAT_SOIL
        for key in ('dihedral_str','dihedral_az','trihedral_str','mp_height','mp_bounce2','mp_bounce3'):
            getattr(w,key)[old]=0
        altered|=old
        # A physical level pad prevents the original model's wheels/hut being
        # buried by terrain slopes. This pad is shared with Godot, not visual-only.
        half_l=14 if e['kind']=='vehicle' else 12
        half_w=7.5 if e['kind']=='vehicle' else 12
        pad=(abs(u)<half_l)&(abs(v)<half_w)
        base=float(np.median(reference._ground_height[pad]))
        e['base']=base
        # Grade the prepared pad into the terrain instead of making a vertical
        # block cliff. Identical graded heights feed the mesh and radar shadows.
        distance=np.hypot(np.maximum(abs(u)-half_l,0),np.maximum(abs(v)-half_w,0))
        blend=np.clip(1-distance/18.,0,1)
        blend=blend*blend*(3-2*blend)
        graded=reference._ground_height*(1-blend)+base*blend
        region=blend>0
        delta=graded-w._ground_height
        w.height[region]+=delta[region]
        w._ground_height[region]=graded[region]
        w.height[pad]=base
        w.mat_id[pad]=g.MAT_ROAD
        altered|=region
        mask_all=np.zeros_like(altered)
        for p in e['parts']:
            if p['shape']=='tube':
                a=np.asarray(p['a']);b=np.asarray(p['b'])
                center=(a+b)*.5;size=np.abs(a-b)+2*p['radius']
            else:center=np.asarray(p['position']);size=np.asarray(p['size'])
            cu,cv=center[0]*sx,center[1]*sy
            hu,hv=max(size[0]*sx/2,.45),max(size[1]*sy/2,.45)
            m=(abs(u-cu)<=hu)&(abs(v-cv)<=hv)
            top=e['base']+(center[2]+size[2]/2)*sz
            visible=m&(top>w.height)
            w.height[visible]=top
            mat=p['material']
            metal=mat.startswith('metal') or mat in ('roof','radar_mast','bridge','radome')
            w.mat_id[visible]=g.MAT_METAL if metal else g.MAT_CONCRETE if mat in ('concrete','warehouse_wall') else g.MAT_ROAD
            mask_all|=visible;altered|=visible
        # Same strength conventions, not an additional gain on a sparse list.
        if e['kind']=='vehicle':
            w.dihedral_str[mask_all]=80;w.dihedral_az[mask_all]=ang+math.pi/2
            w.trihedral_str[mask_all]=42;w.mp_height[mask_all]=5.5
            w.mp_bounce2[mask_all]=22;w.mp_bounce3[mask_all]=9
        else:
            w.trihedral_str[mask_all]=165;w.mp_height[mask_all]=11;w.mp_bounce2[mask_all]=35
    w.rng=np.random.default_rng();w.rng.bit_generator.state=copy.deepcopy(reference._initial_rng)
    w._changed_mask=altered
    return w


def export_scene(w,directory,models='preferred'):
    """Export little-endian height samples and primitive manifest for Godot."""
    directory=Path(directory);directory.mkdir(parents=True,exist_ok=True)
    mesh_n=513
    indexes=np.linspace(0,w.N-1,mesh_n,dtype=np.float32)
    xx,yy=np.meshgrid(indexes,indexes)
    heights=map_coordinates(w._ground_height,[yy,xx],order=1,mode='nearest').astype('<f4')
    # Water is a surface above an actual bed, not two nearly coplanar meshes.
    water=map_coordinates(w._water_mask.astype(np.uint8),[yy,xx],order=0)>0
    heights[water]=(1.5 if w._scenario=='legacy' else .04)-2.0
    heights.tofile(directory/'ground.f32')
    normals=np.gradient(heights,w.size_m/(mesh_n-1))
    palette=np.array([[.07,.20,.27],[.28,.29,.27],[.47,.44,.32],[.19,.28,.17],
                      [.49,.48,.43],[.48,.47,.43],[.43,.47,.28]],np.float32)
    colors=palette[w.mat_id]
    rough=np.clip(w.soil_rough,.5,1.5)
    colors*=((.68+.32*rough)[...,None])
    # Optical ground under equipment: no white target silhouette on the terrain.
    colors[w.mat_id==g.MAT_METAL]=[.38,.36,.29]
    colors[w.mat_id==g.MAT_CONCRETE]=[.49,.48,.43]
    Image.fromarray(np.uint8(np.clip(colors,0,1)*255)).save(directory/'albedo.png')
    Image.fromarray(np.uint8(w._water_mask)*255).save(directory/'water_mask.png')
    # Micro-relief normals from the SAME terrain; coarse relief is already mesh.
    coords=np.linspace(0,mesh_n-1,w.N,dtype=np.float32)
    cx,cy=np.meshgrid(coords,coords)
    coarse=map_coordinates(heights,[cy,cx],order=1,mode='nearest')
    residual=w._ground_height-coarse
    gy,gx=np.gradient(residual,w.size_m/(w.N-1))
    normal=np.stack([-gx,-gy,np.ones_like(gx)],axis=-1)
    normal/=np.linalg.norm(normal,axis=-1,keepdims=True)
    Image.fromarray(np.uint8(np.clip(normal*.5+.5,0,1)*255)).save(directory/'ground_normal.png')
    peaks=(w._canopy==maximum_filter(w._canopy,size=7))&(w._canopy>3.4)&(w.mat_id==g.MAT_FOREST)
    iy,ix=np.where(peaks)
    # Preserve strongest actual crown locations, deterministic, bounded draw cost.
    if w._scenario=='legacy':
        take=np.random.default_rng(w._seed+31).choice(len(iy),size=min(len(iy),3500),replace=False)
    else:
        take=np.argsort(w._canopy[iy,ix])[::-1][:5000]
    iy=iy[take];ix=ix[take]
    trees=np.column_stack([w.X[iy,ix],w.Y[iy,ix],w._ground_height[iy,ix],w._canopy[iy,ix]]).astype('<f4')
    trees.tofile(directory/'trees.f32')
    fingerprint=hashlib.sha256(w.height.tobytes()+w.mat_id.tobytes()).hexdigest()
    manifest=dict(version=3,seed=w._seed,scenario=w._scenario,world_size=w.size_m,
                  source_resolution=w.N,mesh_n=mesh_n,grid_step=w.size_m/(mesh_n-1),
                  godot_coordinates='x=world_x, y=elevation, z=-world_y',
                  texture_row_zero='world_y=-1000 (south)',
                  height_path=str((directory/'ground.f32').resolve()),
                  albedo_path=str((directory/'albedo.png').resolve()),
                  normal_path=str((directory/'ground_normal.png').resolve()),
                  water_mask_path=str((directory/'water_mask.png').resolve()),
                  trees_path=str((directory/'trees.f32').resolve()),tree_count=len(trees),
                  water_level=1.5 if w._scenario=='legacy' else .04,
                  entities=w._entities,colors=COLORS,scene_fingerprint=fingerprint,
                  models=models,radar_resolution=w.N,
                  site_center=[-55,-170] if w._scenario=='legacy' else [-500,-450],
                  caveat='Radar uses 2.5D surface/material/reflector fields, not triangle-by-triangle electromagnetic scattering.')
    if models=='reference' and w._scenario=='valley':
        manifest['entities']=copy.deepcopy(w._entities)
        for e in manifest['entities']:
            if e['kind']=='vehicle':e['scale']=[11/25,5.2/9.6,3.8/8.125]
            if e['kind']=='radar':e['scale']=[.5,.5,11/35.2]
    atom_json(directory/'manifest.json',manifest)
    return manifest
