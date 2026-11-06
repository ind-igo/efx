#!/usr/bin/env python3
"""Aggregates bench/dispatch.zig CSVs. Usage: analyze.py <dir-with-*.csv>
Files are named <mode>-<seed>.csv. Median/min/max are taken over *processes*; 'layouts' is the
range across NOP paddings, i.e. how much the number moves when only code placement moves."""
import csv, glob, os, sys
from collections import defaultdict
from statistics import median
d=sys.argv[1]
R=[]
for f in sorted(glob.glob(os.path.join(d,'*.csv'))):
    mode,seed=os.path.basename(f)[:-4].split('-')
    for r in csv.DictReader(open(f)):
        r['ns']=float(r['ns']); r['npc']=float(r['ns_per_cycle']); r['k']=int(r['k']); r['round']=int(r['round']); r['pos']=int(r['pos'])
        r['targets']=int(r['targets']); r['mode']=mode; r['proc']=f"{mode}-{seed}"
        R.append(r)
procs=sorted({r['proc'] for r in R}); npc0=min(r['npc'] for r in R)
print(f"{len(R)} samples, {len(procs)} processes")
c=[r['npc'] for r in R]; c.sort()
if npc0: print(f"calibration: {1/npc0:.3f} GHz best; ns/cycle median {median(c):.4f}, max {c[-1]:.4f}; rounds >10% slower than best: {len({(r['proc'],r['round']) for r in R if r['npc']>npc0*1.10})} of {len({(r['proc'],r['round']) for r in R})}")
GHZ=1/median(c) if median(c) else 0 # calibration is aarch64 only
def agg(rows,key):
    """per-process medians of rounds for each `key`"""
    out=defaultdict(list)
    for r in rows: out[(r['proc'],)+key(r)].append(r['ns'])
    return {k:median(v) for k,v in out.items()}
def fmt(x): return f"{x:6.2f}"
# ---- mono
mono=[r for r in R if r['group']=='mono']
if mono:
    A=agg(mono,lambda r:(r['body'],r['case'],r['k']))
    ks=sorted({r['k'] for r in mono}); cases=['empty','inline_body','comptime_generic','direct','fn_pointer','hand_vtable','effect_unchecked','effect_plain_slot','effect']
    for body in ('tiny','rmw','mix','work'):
        print(f"\n== mono body={body}   ns/op; median [min..max over processes] | layouts [min..max over paddings] | Δ inline(ns) | Δ cycles | Δ vs direct")
        base={p:median(A[(p,body,'inline_body',k)] for k in ks) for p in procs}
        dirv={p:median(A[(p,body,'direct',k)] for k in ks) for p in procs}
        for c_ in cases:
            v={p:median(A[(p,body,c_,k)] for k in ks) for p in procs}
            bykey=[median(A[(p,body,c_,k)] for p in procs) for k in ks]
            dl=median(v[p]-base[p] for p in procs); dd=median(v[p]-dirv[p] for p in procs)
            print(f"{c_:18s} {fmt(median(v.values()))} [{min(v.values()):.2f}..{max(v.values()):.2f}]  layouts [{min(bykey):.2f}..{max(bykey):.2f}]  Δinl {dl:+.2f}  ({dl*GHZ:+.1f} cy)  Δdirect {dd:+.2f}")
        print("  per-padding medians (k: direct / fn_ptr / hand_vt / effect)")
        for k in ks:
            print(f"   k={k:2d}: "+" / ".join(f"{median(A[(p,body,c_,k)] for p in procs):.2f}" for c_ in ('direct','fn_pointer','hand_vtable','effect')))
        pair=[median(A[(p,body,'effect',k)]-A[(p,body,'hand_vtable',k)] for p in procs) for k in ks]
        pair2=[median(A[(p,body,'effect',k)]-A[(p,body,'direct',k)] for p in procs) for k in ks]
        print(f"  effect−hand_vtable by padding: median {median(pair):+.2f} range [{min(pair):+.2f}..{max(pair):+.2f}] ns; effect−direct: median {median(pair2):+.2f} range [{min(pair2):+.2f}..{max(pair2):+.2f}]")
    print("\n== order effects (mono, median over layouts+processes per order mode), ns/op")
    modes=sorted({r['mode'] for r in R})
    print(f"{'body/case':28s} "+" ".join(f"{m:>6s}" for m in modes))
    worst=0
    for body in ('tiny','rmw','mix','work'):
        for c_ in ('direct','fn_pointer','hand_vtable','effect'):
            row=[]
            for m in modes:
                ps=[p for p in procs if p.startswith(m)]
                row.append(median(median(A[(p,body,c_,k)] for k in ks) for p in ps))
            worst=max(worst,(max(row)-min(row))/min(row))
            print(f"{body+'/'+c_:28s} "+" ".join(fmt(x) for x in row))
    print(f"worst relative gap between order modes: {worst*100:.1f}%")
    # noise summary
    sp=[]
    for body in ('tiny','rmw','mix','work'):
        for c_ in cases:
            for k in ks:
                v=[A[(p,body,c_,k)] for p in procs]; sp.append((max(v)-min(v))/median(v))
    sp.sort(); print(f"process-to-process spread (max-min)/median at fixed layout: median {median(sp)*100:.1f}%, p90 {sp[int(.9*len(sp))]*100:.1f}%, worst {sp[-1]*100:.1f}%")
# ---- mixed
mx=[r for r in R if r['group']=='mixed']
if mx:
    A=agg(mx,lambda r:(r['case'],r['targets'],r['pattern'],r['k']))
    print("\n== mixed: ns/op median [min..max processes]; Δ vs no_dispatch same sequence, across paddings")
    for t,pat in ((1,'rr'),(2,'rr'),(4,'rr'),(16,'rr'),(2,'rand'),(4,'rand'),(16,'rand')):
        print(f"-- targets={t} pattern={pat}")
        ks=sorted({r['k'] for r in mx})
        base={p:median(A[(p,'no_dispatch',t,pat,k)] for k in ks) for p in procs}
        for c_ in ('no_dispatch','closed_switch','fn_table','vtable_array','effect_scopes','effect_switch'):
            v={p:median(A[(p,c_,t,pat,k)] for k in ks) for p in procs}
            dl=median(v[p]-base[p] for p in procs)
            print(f"  {c_:16s} {fmt(median(v.values()))} [{min(v.values()):.2f}..{max(v.values()):.2f}]  Δ {dl:+.2f} ns ({dl*GHZ:+.1f} cy)")
# ---- period
pr=[r for r in R if r['group']=='period']
if pr:
    A=agg(pr,lambda r:(r['case'],r['targets']))
    print("\n== period check: 16 random targets, sequence repeats every N (N=1048576 row is in mixed)")
    for c_,t in sorted({(r['case'],r['targets']) for r in pr}):
        v=[A[(p,c_,t)] for p in procs]; print(f"  {c_:16s} period {t:6d}: {median(v):.2f} [{min(v):.2f}..{max(v):.2f}]")
# ---- cold
cd=[r for r in R if r['group']=='cold']
if cd:
    A=agg(cd,lambda r:(r['body'],r['case']))
    print("\n== cold: latency of one call, serialised counter reads, minus timer_only (paired by process). ns")
    for lab in sorted({r['body'] for r in cd}):
        ps=[p for p in procs if (p,lab,'timer_only') in A]
        base={p:A[(p,lab,'timer_only')] for p in ps}
        print(f"-- {lab}: timer_only {median(base.values()):.1f} [{min(base.values()):.1f}..{max(base.values()):.1f}]")
        for c_ in ('direct','fn_pointer','hand_vtable','effect'):
            dv=[A[(p,lab,c_)]-base[p] for p in ps]; print(f"  {c_:12s} {median(dv):+7.1f} ns [{min(dv):+.1f}..{max(dv):+.1f}]")
# ---- vec
vc=[r for r in R if r['group']=='vec']
if vc:
    A=agg(vc,lambda r:(r['case'],))
    print("\n== vec: 4096 u32, sum of v*m. ns/element")
    for c_ in ('comptime_generic','direct','hand_vtable','effect','batch_8','batch_64','batch_4096'):
        v=[A[(p,c_)] for p in procs]; print(f"  {c_:18s} {median(v):.3f} [{min(v):.3f}..{max(v):.3f}]")
# ---- first-position
pf=[r for r in R if r['pos']==0]
