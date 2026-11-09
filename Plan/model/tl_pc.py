#!/usr/bin/env python3
# tl_pc.py <dir> <elf> <lo> <hi> <n> : after tl.py, the n pcs in [lo, hi) where the RTL's dispatch falls behind the model's most (Plan/OOC.md 29.45)
import sys,pickle,subprocess,bisect
S,elf=sys.argv[1:3]; lo=int(sys.argv[3],16); hi=int(sys.argv[4],16); top=int(sys.argv[5])
P=pickle.load(open(S+'/tl.pkl','rb'))['pcs']
dis={}
for l in subprocess.check_output(['riscv64-unknown-elf-objdump','-d','-M','no-aliases',elf],text=True).splitlines():
    p=l.split('\t')
    if len(p)>=4 and p[0].strip().endswith(':'):
        try: dis[int(p[0].strip()[:-1],16)]=p[2]+' '+p[3]
        except: pass
rows=[(c[4]-c[9],a,c) for a,c in P.items() if lo<=a<hi]
rows.sort(reverse=True)
print('sum dDS %d, dCMT %d'%(sum(r[0] for r in rows),sum(r[2][5]-r[2][10] for r in rows)))
print('pc n | dDSgap total, per exec | RTL is-ds done-is cmt-done | mod is-ds done-is cmt-done | insn')
for x,a,c in sorted(rows[:top],key=lambda r:r[1]):
    N=c[0]
    print('%x %6d | %7d %5.2f | %5.2f %5.2f %5.2f | %5.2f %5.2f %5.2f | %s'%(a,N,x,x/N,c[1]/N,c[2]/N,c[3]/N,c[6]/N,c[7]/N,c[8]/N,dis.get(a,'?')[:40]))
