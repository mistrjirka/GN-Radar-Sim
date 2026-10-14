"""Scheduling-only acceleration of the immutable approved radar implementation.

Each output coordinate and each filtered row/column is independent. Split that
independent dimension across a SMALL CPU pool, preserving SciPy's exact kernels,
dtypes, RNG sequence, filtering order, visibility and accumulation arithmetic.

No module-global monkey patches. Private function bindings use the SAME approved
code objects with only two numerical leaf functions replaced. Byte-level and
float-array regression tests guard this adapter. Its worker count is bounded so
radar computation leaves CPU capacity for Godot.
"""
from __future__ import annotations
from concurrent.futures import ThreadPoolExecutor
from types import FunctionType
import os
import numpy as np
from scipy.ndimage import map_coordinates, convolve1d
import approved_renderer as reference


def _bind(fn, **overrides):
    env=dict(fn.__globals__)
    env.update(overrides)
    copy=FunctionType(fn.__code__,env,fn.__name__,fn.__defaults__,fn.__closure__)
    copy.__kwdefaults__=fn.__kwdefaults__
    return copy


class ParallelRadar:
    """Private numerical scheduling; use one instance per serialized scan worker."""
    def __init__(self, workers=3):
        available=len(os.sched_getaffinity(0)) if hasattr(os,'sched_getaffinity') else (os.cpu_count() or 1)
        self.workers=max(1,min(int(workers),4,max(1,available-2)))
        self.pool=ThreadPoolExecutor(max_workers=self.workers,thread_name_prefix='radar-numeric')
        self._image=_bind(reference.image_measurements,convolve1d=self.convolve,map_coordinates=self.map)
        model=_bind(reference.scene_to_measurements,map_coordinates=self.map)
        self._measure=_bind(reference.measure,scene_to_measurements=model)

    def close(self):
        self.pool.shutdown(wait=True,cancel_futures=True)

    def _ranges(self,n):
        edges=np.linspace(0,n,self.workers+1,dtype=int)
        return [(int(a),int(b)) for a,b in zip(edges[:-1],edges[1:]) if b>a]

    def map(self, data, coordinates, **kwargs):
        # Reference calls only order0/order1 without output buffers. For any new
        # unsupported call, keep SciPy's public implementation unchanged.
        coords=np.asarray(coordinates)
        if self.workers==1 or coords.ndim!=3 or coords.shape[1]*coords.shape[2]<200_000 or kwargs.get('order',3)>1 or kwargs.get('output') is not None:
            return map_coordinates(data,coordinates,**kwargs)
        result=np.empty(coords.shape[1:],dtype=data.dtype)
        def run(bounds):
            first,last=bounds
            map_coordinates(data,coords[:,first:last,:],output=result[first:last,:],**kwargs)
        list(self.pool.map(run,self._ranges(coords.shape[1])))
        return result

    def convolve(self, data, weights, axis=-1, **kwargs):
        if self.workers==1 or data.ndim!=2 or data.size<200_000 or kwargs.get('output') is not None:
            return convolve1d(data,weights,axis=axis,**kwargs)
        axis=axis%data.ndim
        independent=1-axis
        result=np.empty_like(data)
        def run(bounds):
            first,last=bounds
            region=(slice(first,last),slice(None)) if independent==0 else (slice(None),slice(first,last))
            convolve1d(data[region],weights,axis=axis,output=result[region],**kwargs)
        list(self.pool.map(run,self._ranges(data.shape[independent])))
        return result

    def measure(self,world,pose,**kwargs):
        return self._measure(world,pose,**kwargs)

    def image(self,world,measurement,instrument):
        power,image,report=self._image(world,measurement,instrument)
        report['execution_backend']='same_scipy_kernels_parallel'
        report['numeric_workers']=self.workers
        return power,image,report
