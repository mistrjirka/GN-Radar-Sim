#!/usr/bin/env python3
"""Geometry-driven radar image-formation experiment, not a raw-pulse SAR solver.

Retains original Gemini V6.5 material/incidence/roughness/wall fields, sharp
geometry, horizon occlusion, slant-range accumulation and delayed path proxies.
Replaces its arbitrary bright-peak cross addition with an instrument-scale
complex point response applied to ALL measured returns. Four statistical
coherent looks model unresolved scatterers. No display blur, bloom, sharpening,
per-target gains, percentage-based white clipping or semantic pixel overlays.

The PSF model approximates a locally shift-invariant focused SAR instrument;
angle scale is chosen at reference range. Multipath strengths/delays remain
Gemini's uncalibrated heuristic proxies, not a full EM ray-tracing solution.
"""
from pathlib import Path
from dataclasses import dataclass,asdict
import importlib.util,inspect,textwrap,hashlib,json,copy,time
import numpy as np
from scipy.ndimage import convolve1d,map_coordinates
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

ROOT=Path(__file__).resolve().parent
SRC=ROOT/'vendor'/'gemini_v65.py'
spec=importlib.util.spec_from_file_location('gemini_original',SRC)
g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)

# Reuse the original scene-to-measurements mathematics verbatim. Everything
# before stage 5 is radar/scene modeling, not rendering from an existing PNG.
source=textwrap.dedent(inspect.getsource(g.CoherentMultipathRadarEngineV6_5.render_radar_patch))
assert '# 5. Multi-Look Gamma' in source
prefix=source[:source.index('    # 5. Multi-Look Gamma')]
prefix+='    return locals()\n'
ns=dict(g.__dict__);exec(compile(prefix,str(SRC)+'::measurement_prefix','exec'),ns)
scene_to_measurements=ns['render_radar_patch']

@dataclass
class Instrument:
    name:str='coherent_psf'
    range_resolution_m:float=2.0
    azimuth_resolution_m:float=2.5
    range_window:str='rectangular'
    azimuth_window:str='hamming'
    looks:int=4
    noise_power:float=.026
    db_min:float=-17.0
    db_max:float=17.5
    gamma:float=.92
    seed:int=867531
    normalize_sampling:bool=False

def kernel(scale,window):
    if not np.isfinite(scale) or scale<=0:raise ValueError(scale)
    half=max(8,int(np.ceil(20*scale)))
    u=np.arange(-half,half+1,dtype=np.float64)/scale
    if window=='rectangular':h=np.sinc(u)
    elif window=='hamming':h=(.54*np.sinc(u)+.23*(np.sinc(u-1)+np.sinc(u+1)))/.54
    elif window=='hann':h=(.5*np.sinc(u)+.25*(np.sinc(u-1)+np.sinc(u+1)))/.5
    elif window=='tukey25':
        from scipy.signal.windows import tukey
        freq=np.linspace(-.5,.5,2049)
        spectral=tukey(len(freq),alpha=.25,sym=True)
        # Numerical inverse Fourier integral of the specified passband.
        h=np.cos(2*np.pi*u[:,None]*freq[None,:])@spectral/spectral.sum()
    else:raise ValueError(window)
    # A white complex random field of variance P must remain variance P
    # after filtering. Unit L2 is the energy-preserving normalization.
    h/=np.sqrt(np.sum(h*h))
    return h.astype(np.float32)

def load_world():
    cache=ROOT/'world_cache.npz';meta=ROOT/'world_cache.json'
    sha=hashlib.sha256(SRC.read_bytes()).hexdigest()
    if cache.exists() and meta.exists() and json.loads(meta.read_text())['sha256']==sha:
        z=np.load(cache);w=g.RadarTestWorldV6_5.__new__(g.RadarTestWorldV6_5)
        for k in z.files:setattr(w,k,z[k])
        info=json.loads(meta.read_text());w.size_m=2000.;w.N=1536;w.dx=w.size_m/w.N
        w.rng=np.random.default_rng();w.rng.bit_generator.state=info['rng_state']
        return w
    w=g.RadarTestWorldV6_5(size_m=2000.,N=1536,seed=42)
    arrays={k:v for k,v in vars(w).items() if isinstance(v,np.ndarray)}
    np.savez(cache,**arrays)
    meta.write_text(json.dumps({'sha256':sha,'rng_state':w.rng.bit_generator.state}))
    return w

def measure(w,pos=(0.,-2400.,1450.),n_az=1800,n_rg=2000):
    engine=g.CoherentMultipathRadarEngineV6_5(w)
    start=time.perf_counter()
    state=scene_to_measurements(engine,ac_pos=pos,looks=4,n_az=n_az,n_rg=n_rg)
    keep=['polar_slant_img','r_s_min','r_s_max','az_min','az_max','los_center_az',
          'n_az','n_r_slant','ac_x','ac_y','ac_z','is_shadowed','WX','WY','d_rg']
    out={k:state[k] for k in keep}
    out['elapsed_s']=time.perf_counter()-start
    return out

def image_measurements(w,m,cfg:Instrument):
    t=time.perf_counter();P=np.maximum(m['polar_slant_img'],0).astype(np.float32)
    # Original Gemini multiplies by d_rg/1.55 before range splatting.
    # With an energy-normalized instrument PSF this makes brightness depend
    # on computational ray spacing. Remove that numerical sampling factor,
    # not a per-material or target brightness adjustment.
    sampling_gain=1.55/m['d_rg'] if cfg.normalize_sampling else 1.0
    P*=sampling_gain
    nr=P.shape[1]
    # Scene rays are known in azimuth and slant range. Their point response
    # must be applied here, BEFORE ground-range mapping, not to screen pixels.
    ds=(m['r_s_max']-m['r_s_min'])/(nr-1)
    da=(m['az_max']-m['az_min'])/(P.shape[0]-1)
    ref_ground=np.hypot(m['ac_x'],m['ac_y'])
    kr=kernel(cfg.range_resolution_m/ds,cfg.range_window)
    ka=kernel(cfg.azimuth_resolution_m/(ref_ground*da),cfg.azimuth_window)
    rng=np.random.default_rng(cfg.seed)
    # Gaussian phasors represent many unresolved micro-scatterers inside
    # each resolution cell. It is a stochastic coherent image approximation,
    # NOT the earlier sparse list of point reflectors and not copied pixels.
    accum=np.zeros_like(P)
    amp=np.sqrt(P*.5)
    for i in range(cfg.looks):
        re=rng.standard_normal(P.shape,dtype=np.float32)*amp
        im=rng.standard_normal(P.shape,dtype=np.float32)*amp
        re=convolve1d(convolve1d(re,kr,axis=1,mode='constant'),ka,axis=0,mode='constant')
        im=convolve1d(convolve1d(im,kr,axis=1,mode='constant'),ka,axis=0,mode='constant')
        accum+=(re*re+im*im)/cfg.looks
    # Same native receiver noise law as Gemini, so shadows are not flat black
    # DEM holes. Not classified by water, target or terrain semantics.
    rnorm=np.linspace(.8,1.35,nr,dtype=np.float32)[None,:]
    accum+=cfg.noise_power*rnorm*rng.exponential(1.,P.shape).astype(np.float32)
    # Fixed-height ground-range display keeps radar foreshortening and
    # layover. It deliberately does not turn the result into DEM imagery.
    rflat=np.sqrt((w.X-m['ac_x'])**2+(w.Y-m['ac_y'])**2+(m['ac_z']-22.)**2)
    az=m['los_center_az']+((np.arctan2(w.Y-m['ac_y'],w.X-m['ac_x'])-m['los_center_az']+np.pi)%(2*np.pi)-np.pi)
    ai=(az-m['az_min'])/(m['az_max']-m['az_min'])*(P.shape[0]-1)
    ri=(rflat-m['r_s_min'])/(m['r_s_max']-m['r_s_min'])*(nr-1)
    power=map_coordinates(accum,[ai,ri],order=1,mode='constant',cval=0)
    displayed=g.log_compress(power,db_min=cfg.db_min,db_max=cfg.db_max,gamma=cfg.gamma)
    report={**asdict(cfg),'processing_s':time.perf_counter()-t,
            'measurement_s':m['elapsed_s'],'total_s':time.perf_counter()-t+m['elapsed_s'],
            'range_sample_m':ds,'azimuth_sample_at_center_m':ref_ground*da,
            'response_taps':[len(ka),len(kr)],'white_clipped_fraction':float(np.mean(displayed>=.9999)),
            'mean_display':float(displayed.mean()),'sampling_normalization_gain':sampling_gain,
            'shadowed_measurement_fraction':float(m['is_shadowed'].mean()),
            'approximation':'complex-PSF statistical image formation, no raw pulse simulation'}
    return power,displayed,report

def save(path,array):
    plt.imsave(path,np.clip(array,0,1),cmap='gray',vmin=0,vmax=1,origin='lower')

def run():
    OUT=ROOT/'results';OUT.mkdir(exist_ok=True)
    w=load_world();state=copy.deepcopy(w.rng.bit_generator.state)
    pos=(0.,-2400.,1450.)
    print('Measuring unchanged full-resolution scene',flush=True)
    m=measure(w,pos=pos)
    versions=[Instrument(name='v1_rect_hamming'),
      Instrument(name='v2_hamming_hamming',range_window='hamming'),
      Instrument(name='v3_rect_rect',azimuth_window='rectangular'),
      Instrument(name='v4_finer',range_resolution_m=1.5,azimuth_resolution_m=1.8)]
    stats={}
    for cfg in versions:
        p,a,r=image_measurements(w,m,cfg)
        save(OUT/(cfg.name+'.png'),a)
        np.save(OUT/(cfg.name+'_power.npy'),p)
        stats[cfg.name]=r
        print(cfg.name,json.dumps(r),flush=True)
    w.rng.bit_generator.state=state
    ref,dt=g.CoherentMultipathRadarEngineV6_5(w).render_radar_patch(pos,looks=4,n_az=1400,n_rg=1600)
    save(OUT/'gemini_unchanged.png',g.log_compress(ref))
    stats['reference_ms']=dt
    (OUT/'render_metrics.json').write_text(json.dumps(stats,indent=2))
    print('DONE',OUT,flush=True)
if __name__=='__main__':run()
