#!/usr/bin/env python3
# byfn.py : cycles by function, the RTL against the model (Plan/OOC.md 29.30, 29.44):
#   CORE_BYPC=<rtl> tb_core ...; OOO_BYPC=<mod> model ooo ...; ./byfn.py <elf> <rtl> <mod> [the n pcs most above the model]
import sys,subprocess,bisect
elf,rtl,mod=sys.argv[1:4]
syms=[]
for l in subprocess.check_output(['riscv64-unknown-elf-nm','-n',elf],text=True).splitlines():
    p=l.split()
    if len(p)==3 and p[1] in 'tT': syms.append((int(p[0],16),p[2]))
ad=[a for a,_ in syms]
def fn(pc):
    i=bisect.bisect_right(ad,pc)-1
    return syms[i][1] if i>=0 else '?'
def load(f):
    d={}
    for l in open(f):
        a,c=l.split(); a=int(a,16); c=int(c)
        d[a]=d.get(a,0)+c
    return d
def byf(d):
    r={}
    for a,c in d.items(): r[fn(a)]=r.get(fn(a),0)+c
    return r
R=load(rtl);M=load(mod)
# the model's pcs: halfword or byte?
print('rtl total',sum(R.values()),'model total',sum(M.values()), 'rtl min pc %x model min pc %x'%(min(R),min(M)))
fr=byf(R);fm=byf(M)
rows=sorted(set(fr)|set(fm),key=lambda k:-(fr.get(k,0)-fm.get(k,0)))
print('%-28s %9s %9s %8s %6s'%('function','RTL','model','diff','%'))
for k in rows:
    r,m=fr.get(k,0),fm.get(k,0)
    if abs(r-m)>=500: print('%-28s %9d %9d %8d %6.1f'%(k,r,m,r-m,100.0*(r-m)/m if m else 0))
inm=[k for k in fr if fm.get(k,0)>0]
ro=sum(fr[k] for k in inm); mo=sum(fm.values())
print('in the model\'s functions: RTL %d, model %d, RTL above %.1f %%; outside them %d'%(ro,mo,100.0*(ro-mo)/mo,sum(fr.values())-ro))
print('CoreMark/MHz of that part, 1e7/cycles: RTL %.2f model %.2f'%(1e7/ro,1e7/mo))
if len(sys.argv)>4:
    d=[(R.get(a,0)-M.get(a,0),a) for a in set(R)|set(M) if fn(a) in inm]
    d.sort(reverse=True)
    print('the pcs most above the model:')
    for x,a in d[:int(sys.argv[4])]: print('  %x %-24s RTL %7d model %7d  %+d'%(a,fn(a),R.get(a,0),M.get(a,0),x))
