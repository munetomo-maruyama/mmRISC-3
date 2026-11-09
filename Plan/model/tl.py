#!/usr/bin/env python3
# tl.py <dir> <elf> : the timelines of RTL and model (<dir>/tl_rtl.txt from SIM/CORE/acct.patch +tl=, <dir>/tl_mod.txt from OOO_TL) by function (Plan/OOC.md 29.45)
import sys,subprocess,bisect,collections
S=sys.argv[1]; elf=sys.argv[2]
syms=[]
for l in subprocess.check_output(['riscv64-unknown-elf-nm','-n',elf],text=True).splitlines():
    p=l.split()
    if len(p)==3 and p[1] in 'tT': syms.append((int(p[0],16),p[2]))
ad=[a for a,_ in syms]
def fn(pc): return syms[bisect.bisect_right(ad,pc)-1][1]
def rd(f):
    r=[]
    for l in open(f):
        a,b,c,d,e=l.split(); r.append((int(a,16),int(b),int(c),int(d),int(e)))
    return r
M=rd(S+'/tl_mod.txt'); R=rd(S+'/tl_rtl.txt')
off=1 if M[1][0]==R[0][0] else 0
M=M[off:]; n=min(len(M),len(R))
for i in range(0,n,200000): assert M[i][0]==R[i][0],i
cls=collections.defaultdict(lambda:[0]*12)
pcs=collections.defaultdict(lambda:[0]*12)
for i in range(1,n):
    m=M[i]; r=R[i]; f=fn(r[0])
    d=[r[2]-r[1], r[3]-r[2], r[4]-r[3], r[1]-R[i-1][1], r[4]-R[i-1][4], m[2]-m[1], m[3]-m[2], m[4]-m[3], m[1]-M[i-1][1], m[4]-M[i-1][4]]
    c=cls[f]; c[0]+=1
    for k in range(10): c[k+1]+=d[k]
    c=pcs[r[0]]; c[0]+=1
    for k in range(10): c[k+1]+=d[k]
print('%-28s %8s | RTL is-ds done-is cmt-done | model is-ds done-is cmt-done | per instr, sums: dIQ(RTL-mod) dEX dCM; dDS gap, dCMT gap'%('function','n'))
rows=sorted(cls.items(),key=lambda kv:-(kv[1][5]-kv[1][10]))
for f,c in rows[:16]:
    N=c[0]
    print('%-28s %8d | %5.2f %5.2f %5.2f | %5.2f %5.2f %5.2f | %8d %8d %8d | %7d %7d'%(f,N,c[1]/N,c[2]/N,c[3]/N,c[6]/N,c[7]/N,c[8]/N,c[1]-c[6],c[2]-c[7],c[3]-c[8],c[4]-c[9],c[5]-c[10]))
import pickle
pickle.dump({'pcs':dict(pcs)},open(S+'/tl.pkl','wb'))
