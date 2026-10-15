import re,json,os
out=r'C:\Users\Nikita\Desktop\Coder\Projects\Tropa\dist\slide_preview'
imgdir=os.path.join(out,'img')
loc={f[:-4]:'img/'+f for f in os.listdir(imgdir)}
deck=json.load(open('deck/project/deck.json',encoding='utf-8'))
head='<!doctype html><meta charset="utf-8"><style>*{box-sizing:border-box}p,h1,h2,h3{margin:0}@font-face{font-family:Rubik;src:url(Rubik-Variable.ttf);font-weight:300 700}@font-face{font-family:Unbounded;src:url(Unbounded-Variable.ttf);font-weight:200 900}body{margin:0;background:#222}.cell{width:960px;height:540px;position:relative;overflow:hidden}.cell>section{position:absolute;left:0;top:0;width:1920px;height:1080px;transform:scale(.5);transform-origin:0 0;overflow:hidden}</style>'
for i,sid in enumerate(deck['order'],1):
    t=open(f'deck/project/slides/{sid}.html',encoding='utf-8').read()
    t=re.sub(r'<aside>.*?</aside>','',t,flags=re.S)
    for k,v in loc.items(): t=t.replace('/_blob/'+k,v)
    open(os.path.join(out,f's{i}.html'),'w',encoding='utf-8').write(head+'<div class="cell">'+t+'</div>')
print(len(deck['order']))
