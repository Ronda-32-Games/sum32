# Sonidos de Sum 32 generados desde cero por Lía (síntesis propia, sin muestras de terceros).
import numpy as np, subprocess, os, json
SR=22050
OUT='/home/claude/lia/entrega/sum32/sonidos'
def hz(n): return 440*2**((n-69)/12)  # MIDI
def env(n,a=0.003,d=0.25):
    t=np.arange(n)/SR; e=np.minimum(1,t/a)*np.exp(-t/d); return e
def mar(note,dur=0.35,d=0.18,bright=1.0):
    n=int(SR*dur); t=np.arange(n)/SR; f=hz(note)
    # marimba-ish: fundamental + 4x parcial que cae rápido + click
    s=np.sin(2*np.pi*f*t)*env(n,0.002,d)
    s+=0.35*bright*np.sin(2*np.pi*f*3.93*t)*env(n,0.001,d*0.25)
    s+=0.12*bright*np.sin(2*np.pi*f*9.2*t)*env(n,0.0005,d*0.08)
    return s
def seq(notes, gap, **k):
    parts=[(i*gap, mar(n,**k)) for i,n in enumerate(notes)]
    L=int(SR*(parts[-1][0]))+len(parts[-1][1]); o=np.zeros(L)
    for st,p in parts: i=int(SR*st); o[i:i+len(p)]+=p
    return o
def shimmer(dur=0.5,f0=2400):
    n=int(SR*dur); t=np.arange(n)/SR; rng=np.random.default_rng(32)
    s=np.zeros(n)
    for k in range(10):
        f=f0*(1+0.15*k); ph=rng.uniform(0,6.28); st=rng.uniform(0,0.12)
        e=np.where(t>st, np.exp(-(t-st)/0.12),0)
        s+=np.sin(2*np.pi*f*t+ph)*e*0.08
    return s
def norm(x,peak=0.8):
    x=x-np.mean(x); m=np.max(np.abs(x)) or 1
    fade=int(SR*0.01); x[-fade:]*=np.linspace(1,0,fade); return x/m*peak
def save(name,x,q='1'):
    x=norm(x); wav=f'/tmp/{name}.wav'
    import wave
    w=wave.open(wav,'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes((x*32767).astype('<i2').tobytes()); w.close()
    subprocess.run(['ffmpeg','-y','-loglevel','error','-i',wav,'-c:a','libvorbis','-q:a',q,'-ac','1',f'{OUT}/{name}.ogg'],check=True)
    return os.path.getsize(f'{OUT}/{name}.ogg')
os.makedirs(OUT,exist_ok=True); sizes={}
C5=72
sizes['toque']=save('toque', mar(C5,0.22,0.09))
sizes['justo']=save('justo', seq([C5+7,C5+12],0.06,dur=0.3,d=0.12))
n=int(SR*0.22); t=np.arange(n)/SR
pas=np.sin(2*np.pi*(hz(C5-12)*(1-0.25*t/0.22))*t)*env(n,0.004,0.07)
sizes['pasado']=save('pasado', pas*0.7)
a=seq([C5,C5+4,C5+7,C5+12],0.055,dur=0.45,d=0.2); sh=shimmer(0.55); L=max(len(a),len(sh)); o=np.zeros(L); o[:len(a)]+=a; o[:len(sh)]+=sh
sizes['clear_32']=save('clear_32', o)
a=seq([C5+7,C5+11,C5+14,C5+19],0.045,dur=0.45,d=0.2,bright=1.4); sh=shimmer(0.6,3200); L=max(len(a),len(sh)); o=np.zeros(L); o[:len(a)]+=a; o[:len(sh)]+=sh*1.3
sizes['combo']=save('combo', o)
n=int(SR*0.35); t=np.arange(n)/SR
sw=np.sin(2*np.pi*np.cumsum(np.linspace(hz(C5),hz(C5+24),n))/SR)*np.sin(np.pi*t/0.35)**2*0.4
ding=np.zeros(n+int(SR*0.4)); ding[:n]+=sw; dd=mar(C5+24,0.4,0.2); ding[int(SR*0.3):int(SR*0.3)+len(dd)]+=dd
sizes['tiempo_extra']=save('tiempo_extra', ding)
n=int(SR*0.06); t=np.arange(n)/SR; rng=np.random.default_rng(1)
tick=(np.sin(2*np.pi*1800*t)+0.3*rng.standard_normal(n))*env(n,0.0005,0.012)
sizes['tick']=save('tick', tick*0.6)
fin=seq([C5+12,C5+7,C5+4,C5],0.11,dur=0.9,d=0.35)
sizes['fin']=save('fin', fin)
rec=seq([C5,C5+4,C5+7,C5+12,C5+16,C5+19,C5+24],0.07,dur=0.6,d=0.25,bright=1.2); sh=shimmer(0.9,3000); o=np.zeros(max(len(rec),len(sh)+int(SR*0.4))); o[:len(rec)]+=rec; o[int(SR*0.4):int(SR*0.4)+len(sh)]+=sh*1.4
sizes['record']=save('record', o)
n=int(SR*0.05); t=np.arange(n)/SR
sizes['boton']=save('boton', np.sin(2*np.pi*hz(C5+19)*t)*env(n,0.0005,0.015)*0.5)
# loop base: 96 BPM, 8 compases de 4/4 = 20 s. Pad + marimba suave + pulso. Cierra perfecto.
bpm=96; beat=60/bpm; bars=8; L=int(SR*beat*4*bars); t=np.arange(L)/SR; mus=np.zeros(L)
prog=[(57,[57,60,64]),(53,[53,57,60]),(48,[48,52,55]),(55,[55,59,62])]*2  # Am F C G
for b,(root,ch) in enumerate(prog):
    st=int(SR*b*4*beat); ln=int(SR*4*beat); tt=np.arange(ln)/SR
    pad=sum(np.sin(2*np.pi*hz(n)*tt)+0.3*np.sin(2*np.pi*hz(n)*2.003*tt) for n in ch)/len(ch)
    pe=np.minimum(1,tt/0.4)*np.minimum(1,(ln/SR-tt)/0.4)
    mus[st:st+ln]+=0.22*pad*pe
    bass=np.sin(2*np.pi*hz(root-12)*tt)*np.exp(-(tt%(2*beat))/0.35)
    mus[st:st+ln]+=0.25*bass
    for k in range(8):
        n=ch[[0,1,2,1,0,2,1,2][k]]+12; p=mar(n,0.4,0.15,0.6)*0.18
        i=st+int(SR*k*beat/2); seg=min(len(p),L-i); mus[i:i+seg]+=p[:seg]
        if i+len(p)>L: mus[:i+len(p)-L]+=p[seg:]
for k in range(bars*4):
    i=int(SR*k*beat); n=int(SR*0.12); tt=np.arange(n)/SR
    mus[i:i+n]+=0.18*np.sin(2*np.pi*(60+60*np.exp(-tt/0.03))*tt)*np.exp(-tt/0.05)
mus=mus/np.max(np.abs(mus))*0.6
import wave
w=wave.open('/tmp/loop.wav','wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes((mus*32767).astype('<i2').tobytes()); w.close()
subprocess.run(['ffmpeg','-y','-loglevel','error','-i','/tmp/loop.wav','-c:a','libvorbis','-q:a','0','-ac','1',f'{OUT}/musica_loop_base.ogg'],check=True)
sizes['musica_loop_base']=os.path.getsize(f'{OUT}/musica_loop_base.ogg')
print(json.dumps(sizes,indent=1)); print('total KB', sum(sizes.values())/1024)
