// Round 4: develop v3b (word + rising trail) in the Earth palette. Run: node gen4.js [prefix] -> sheet4.html
const fs = require('fs');
const path = require('path');
const R = 20, SW = 9;
const P = { bg: '#F2E8CF', fg: '#1B3A34', ac: '#C8553D' };

const g = -5;
const rs = 100 + g, oc = 170 + 2 * g, ps = 220 + 3 * g, pc = ps + 20, ac = pc + 60 + g, as = ac + 20;
const S = (d, w = SW, extra = '') => `<path d="${d}" fill="none" stroke="currentColor" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round" ${extra}/>`;
const circ = (cx) => `M${cx - R} 60 A${R} ${R} 0 1 0 ${cx + R} 60 A${R} ${R} 0 1 0 ${cx - R} 60`;
const dot = (x, y, r, c = 'var(--ac)') => `<circle cx="${x}" cy="${y}" r="${r}" fill="${c}"/>`;

const T = 'M50 16 V60 A20 20 0 0 0 70 80 M34 40 H68';
const Rr = `M${rs} 40 V80 M${rs} 60 A20 20 0 0 1 ${rs + 20} 40`;
const letters = (o = {}) =>
  S(o.t || T) + S(o.r || Rr) + S(circ(oc)) + S(`M${ps} 40 V112`) + S(circ(pc)) + S(circ(ac));

// tail geometry: a stem down, hook, rising curve ending at E
const E = [as + 64, 56];
const stemHook = `M${as} 40 V60 A20 20 0 0 0 ${as + 20} 80`;
const bez = (p0, p1, p2, p3, t) => {
  const u = 1 - t;
  return [0, 1].map((i) => u * u * u * p0[i] + 3 * u * u * t * p1[i] + 3 * u * t * t * p2[i] + t * t * t * p3[i]);
};
const curve = [[as + 20, 80], [as + 42, 80], [as + 42, 56], E];
const solidTail = `${stemHook} C${as + 42} 80 ${as + 42} 56 ${E[0]} ${E[1]}`;

const lead = [[-8, 2.2], [2, 3.2], [13, 4.4]].map(([x, r]) => dot(x, 40, r, 'currentColor')).join('');

const V = {};
V.w1_base = () => letters() + S(solidTail) + dot(E[0] + 8, E[1], 7) + lead;

// tail tapers into the distance: circles along the curve, shrinking radius
V.w2_taper = () => {
  let s = '';
  for (let i = 0; i <= 70; i++) {
    const t = i / 70, [x, y] = bez(...curve, t);
    s += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${(4.5 - 3.2 * t).toFixed(2)}" fill="currentColor"/>`;
  }
  return letters() + S(stemHook) + s + dot(E[0] + 6, E[1] - 1, 5.5) + lead;
};

// trail enters from the left as a mirror of the exit
V.w3_enter_exit = () =>
  letters() + S(solidTail) + dot(E[0] + 8, E[1], 7) +
  S('M-34 80 C-14 80 -14 40 6 40 H34') + dot(-42, 80, 6, 'currentColor');

// exit is a fading dotted trail
V.w4_dots_exit = () => {
  let s = '';
  const pts = [0.08, 0.22, 0.4, 0.6, 0.8];
  pts.forEach((t, i) => {
    const [x, y] = bez(...curve, t);
    s += dot(x.toFixed(1), y.toFixed(1), 4.6 - i * 0.5, 'currentColor');
  });
  return letters() + S(stemHook) + s + dot(E[0] + 6, E[1], 7) + lead;
};

// letters linked: t hook flows into r, r arm flows into o
V.w5_linked = () =>
  S(`M50 16 V60 A20 20 0 0 0 70 80 H${rs} V40`) + S('M34 40 H68') +
  S(`M${rs} 60 A20 20 0 0 1 ${rs + 20} 40 H${oc}`) +
  S(circ(oc)) + S(`M${ps} 40 V112`) + S(circ(pc)) + S(circ(ac)) +
  S(solidTail) + dot(E[0] + 8, E[1], 7) + lead;

// ground line runs under the word and lifts off as the tail
V.w6_ground = () =>
  letters() + S(`M-14 80 H${as} C${as + 30} 80 ${as + 42} 80 ${as + 42} 68 C${as + 42} 54 ${as + 50} 56 ${E[0]} ${E[1]}`, 3.5, 'opacity="0"') +
  S(`M${as} 40 V60 A20 20 0 0 0 ${as + 20} 80 C${as + 42} 80 ${as + 42} 56 ${E[0]} ${E[1]}`) + dot(E[0] + 8, E[1], 7) +
  S(`M-22 94 H${as + 6}`, 3, 'stroke-dasharray="0.1 9"') + lead;


const entryCurve=[[-44,86],[-18,86],[-18,40],[10,40]];
const grow=(rr0,rr1,n=60)=>{let o='';for(let i=0;i<=n;i++){const t=i/n,[x,y]=bez(...entryCurve,t);o+='<circle cx="'+x.toFixed(1)+'" cy="'+y.toFixed(1)+'" r="'+(rr0+(rr1-rr0)*t).toFixed(2)+'" fill="currentColor"/>';}return o;};
const taperExit=()=>{let o='';for(let i=0;i<=70;i++){const t=i/70,[x,y]=bez(...curve,t);o+='<circle cx="'+x.toFixed(1)+'" cy="'+y.toFixed(1)+'" r="'+(4.5-3.2*t).toFixed(2)+'" fill="currentColor"/>';}return o;};
const linkedLetters=()=>S('M50 16 V60 A20 20 0 0 0 70 80 H'+rs+' V40')+S('M34 40 H68')+S('M'+rs+' 60 A20 20 0 0 1 '+(rs+20)+' 40')+S(circ(oc))+S('M'+ps+' 40 V112')+S(circ(pc))+S(circ(ac));
V.c1_enter_exit_linked=()=>linkedLetters()+S('M-34 80 C-14 80 -14 40 6 40 H34')+dot(-42,80,6,'currentColor')+S(solidTail)+dot(E[0]+8,E[1],7);
V.c2_horizon=()=>grow(1.2,4.5)+S('M10 40 H34')+letters()+S(stemHook)+taperExit()+dot(E[0]+6,E[1]-1,5.5);
V.c3_horizon_linked=()=>grow(1.2,4.5)+S('M10 40 H34')+linkedLetters()+S(stemHook)+taperExit()+dot(E[0]+6,E[1]-1,5.5);
V.c4_entry_solid_taper_exit=()=>S('M-34 80 C-14 80 -14 40 6 40 H34')+dot(-42,80,6,'currentColor')+linkedLetters()+S(stemHook)+taperExit()+dot(E[0]+6,E[1]-1,5.5);

const growOn=(cv,r0,r1,n=60)=>{let o='';for(let i=0;i<=n;i++){const t=i/n,[x,y]=bez(...cv,t);o+='<circle cx="'+x.toFixed(1)+'" cy="'+y.toFixed(1)+'" r="'+(r0+(r1-r0)*t).toFixed(2)+'" fill="currentColor"/>';}return o;};
V.d1_shallow=()=>growOn([[-48,64],[-22,64],[-18,40],[10,40]],1.2,4.5)+S('M10 40 H34')+letters()+S(stemHook)+taperExit()+dot(E[0]+6,E[1]-1,5.5);
V.d2_diagonal=()=>growOn([[-50,76],[-30,66],[-12,50],[10,40]],1.2,4.5)+S('M10 40 H34')+letters()+S(stemHook)+taperExit()+dot(E[0]+6,E[1]-1,5.5);
V.d3_dots_rise=()=>{let o='';[[-44,74,1.8],[-31,66,2.4],[-18,57,3.1],[-6,48,3.8]].forEach(([x,y,r])=>o+=dot(x,y,r,'currentColor'));return o+S('M10 40 H34')+letters()+S(stemHook)+taperExit()+dot(E[0]+6,E[1]-1,5.5);};
V.d4_shallow_linked=()=>growOn([[-48,64],[-22,64],[-18,40],[10,40]],1.2,4.5)+S('M10 40 H34')+linkedLetters()+S(stemHook)+taperExit()+dot(E[0]+6,E[1]-1,5.5);
const only = process.argv[2];
let cards = '';
for (const [n, fn] of Object.entries(V)) {
  if (only && !n.startsWith(only)) continue;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-60 -10 480 140" style="color:${P.fg};--ac:${P.ac}"><rect x="-60" y="-10" width="480" height="140" fill="${P.bg}"/>${fn()}</svg>`;
  fs.mkdirSync(path.join(__dirname, 'out4'), { recursive: true });
  fs.writeFileSync(path.join(__dirname, 'out4', n + '.svg'), svg);
  cards += `<div><div class="n">${n}</div>${svg}</div>`;
}
fs.writeFileSync(
  path.join(__dirname, 'sheet4.html'),
  `<!doctype html><meta charset="utf-8"><style>body{margin:0;padding:12px;background:#888;display:grid;grid-template-columns:1fr 1fr;gap:10px;font:13px sans-serif}.n{color:#fff;margin-bottom:2px}svg{width:100%;display:block}</style>${cards}`
);
console.log('ok');
