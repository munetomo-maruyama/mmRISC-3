#!/usr/bin/env python3
# tl_seq.py <dir> <elf> <pc> <occurrence> <n> : n instructions from the occurrence of pc, RTL and model side by side (Plan/OOC.md 29.45)
import sys,subprocess
S,elf=sys.argv[1:3]; pc=int(sys.argv[3],16); occ=int(sys.argv[4]); cnt=int(sys.argv[5])
dis={}
for l in subprocess.check_output(['riscv64-unknown-elf-objdump','-d','-M','no-aliases',elf],text=True).splitlines():
    p=l.split('\t')
    if len(p)>=4 and p[0].strip().endswith(':'):
        try: dis[int(p[0].strip()[:-1],16)]=p[2]+' '+p[3]
        except: pass
def rd(f):
    return [tuple(int(x,16) if i==0 else int(x) for i,x in enumerate(l.split())) for l in open(f)]
M=rd(S+'/tl_mod.txt'); R=rd(S+'/tl_rtl.txt')
off=1 if M[1][0]==R[0][0] else 0
M=M[off:]
n=0
for i,r in enumerate(R):
    if r[0]==pc:
        n+=1
        if n==occ: st=i; break
b=R[st]; mb=M[st]
print('pc                  RTL  ds  is  dn cm  |  model ds is dn cm | insn   (relative to the first)')
for j in range(st,st+cnt):
    r=R[j]; m=M[j]
    print('%8x | %4d %4d %4d %4d | %4d %4d %4d %4d | %s'%(r[0],r[1]-b[1],r[2]-b[1],r[3]-b[1],r[4]-b[1],m[1]-mb[1],m[2]-mb[1],m[3]-mb[1],m[4]-mb[1],dis.get(r[0],'?')[:36]))
