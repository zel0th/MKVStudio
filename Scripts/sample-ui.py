"""Read-only CPU/RSS sampling for a specified app PID and its direct children on macOS."""
import ctypes as c, csv, sys, time
from pathlib import Path
pid, duration, output, control = int(sys.argv[1]), float(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
lib = c.CDLL('/usr/lib/libproc.dylib')
class TaskInfo(c.Structure):
    _fields_ = [(name,c.c_uint64) for name in ('virtual','resident','user','system','threads_user','threads_system')] + [(f'i{i}',c.c_int32) for i in range(12)]
class Timebase(c.Structure):
    _fields_ = [('numer',c.c_uint32),('denom',c.c_uint32)]
tb=Timebase(); c.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(c.byref(tb))
scale=tb.numer/tb.denom/1e9
start=time.monotonic(); previous={}; rows=0
with output.open('w') as f:
    writer=csv.writer(f); writer.writerow(['elapsed_s','phase','pid','role','rss_mib','cpu_percent','cpu_seconds'])
    while time.monotonic()-start<duration:
        phase=control.read_text().strip() if control.exists() else 'idle'
        if phase=='stop': break
        ids=(c.c_int32*256)(); count=lib.proc_listchildpids(pid,ids,c.sizeof(ids))
        for process in [pid]+list(ids)[:max(0,count)]:
            if process<=0: continue
            info=TaskInfo(); result=lib.proc_pidinfo(process,4,0,c.byref(info),c.sizeof(info))
            if result!=c.sizeof(info): continue
            now=time.monotonic(); cpu=(info.user+info.system)*scale
            old=previous.get(process); percent=100*(cpu-old[1])/(now-old[0]) if old else 0
            previous[process]=(now,cpu)
            writer.writerow([now-start,phase,process,'app' if process==pid else 'utility',info.resident/1048576,percent,cpu]); rows+=1
        f.flush(); time.sleep(.05)
print(f'{rows} samples written to {output}')
