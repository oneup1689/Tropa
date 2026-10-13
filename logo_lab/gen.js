// Logo lab: builds candidate SVGs into out/ and a contact sheet sheet.html.
// Run: node gen.js   (no dependencies). Edit variants below, rerun, look at sheet.html.
const fs = require('fs');
const path = require('path');

const SW = 9; // stroke width
const R = 20; // circle radius, x-height 40..80, baseline 80

// geometric letters on a grid; fg = currentColor, accent = var(--ac)
const L = {
  t: `M50 16 V60 A${R} ${R} 0 0 0 70 80 M34 40 H68`,
  r: `M100 40 V80 M100 60 A${R} ${R} 0 0 1 120 40`,
  p: `M220 40 V112`,
  aStem: `M320 40 V80`,
};
const circ = (cx, cy, r = R) => `M${cx - r} ${cy} A${r} ${r} 0 1 0 ${cx + r} ${cy} A${r} ${r} 0 1 0 ${cx - r} ${cy}`;
const O = circ(170, 60), P = circ(240, 60), A = circ(300, 60);

const stroke = (d, extra = '') =>
  `<path d="${d}" fill="none" stroke="currentColor" stroke-width="${SW}" stroke-linecap="round" stroke-linejoin="round" ${extra}/>`;
const acStroke = (d, extra = '') =>
  `<path d="${d}" fill="none" stroke="var(--ac)" stroke-width="${SW}" stroke-linecap="round" stroke-linejoin="round" ${extra}/>`;
const dot = (x, y, r) => `<circle cx="${x}" cy="${y}" r="${r}" fill="var(--ac)"/>`;

const variants = {
  v1_mono: () => [L.t, L.r, O, L.p, P, A, L.aStem].map((d) => stroke(d)).join(''),
  v2_target: () =>
    [L.t, L.r, L.p, P, A, L.aStem].map((d) => stroke(d)).join('') + stroke(O) + dot(170, 60, 6),
  v3_trail: () =>
    [L.t, L.r, O, L.p, P, A].map((d) => stroke(d)).join('') +
    stroke('M320 40 V60 A20 20 0 0 0 340 80 H362') +
    stroke('M34 40 H4', 'stroke-dasharray="0.1 14"') +
    dot(376, 80, 7),
  v4_gps: () =>
    [L.t, L.r, O, L.p, P].map((d) => stroke(d, 'class="dots"')).join('') +
    acStroke(A) + acStroke(L.aStem),
  v5_road: () => {
    const all = [L.t, L.r, O, L.p, P, A, L.aStem];
    return (
      all.map((d) => `<path d="${d}" fill="none" stroke="currentColor" stroke-width="17" stroke-linecap="round" stroke-linejoin="round"/>`).join('') +
      all.map((d) => `<path d="${d}" fill="none" stroke="var(--ac)" stroke-width="2.2" stroke-dasharray="4 6"/>`).join('')
    );
  },
  v6_linked: () =>
    stroke('M50 16 V60 A20 20 0 0 0 70 80 H100 V40') +
    stroke('M34 40 H68') +
    stroke('M100 60 A20 20 0 0 1 120 40 H170') +
    stroke(O) + stroke(L.p) + stroke(P) + stroke(A) +
    stroke('M320 40 V60 A20 20 0 0 0 340 80 H362') + dot(376, 80, 7),
};

const body3 = (tail, lead) =>
  [L.t, L.r, O, L.p, P, A].map((d) => stroke(d)).join('') + stroke(tail.d) + tail.end + lead;
const grow = (x0) =>
  [[x0, 2.2], [x0 + 10, 3.2], [x0 + 21, 4.4]].map(([x, r]) => `<circle cx="${x}" cy="40" r="${r}" fill="currentColor"/>`).join('');
variants.v3a_dots_in = () =>
  body3({ d: 'M320 40 V60 A20 20 0 0 0 340 80 H360', end: dot(376, 80, 7) }, grow(-8));
variants.v3b_rise = () =>
  body3({ d: 'M320 40 V60 A20 20 0 0 0 340 80 C362 80 362 56 384 56', end: dot(392, 56, 7) }, grow(-8));
variants.v3c_ring_end = () =>
  body3({ d: 'M320 40 V60 A20 20 0 0 0 340 80 H358', end: `<circle cx="372" cy="80" r="7" fill="none" stroke="var(--ac)" stroke-width="5"/>` }, `<circle cx="6" cy="40" r="6" fill="var(--ac)"/>` + stroke('M16 40 H34', 'stroke-dasharray="0.1 9"'));

const only = process.argv[2];
if (only) for (const k of Object.keys(variants)) if (!k.startsWith(only)) delete variants[k];

const palettes = [
  { n: 'earth', bg: '#F2E8CF', fg: '#1B3A34', ac: '#C8553D' },
  { n: 'night', bg: '#121A17', fg: '#E8F0EC', ac: '#C6F432' },
  { n: 'sea', bg: '#0F4C5C', fg: '#FFF8EE', ac: '#FF6F59' },
];

const out = path.join(__dirname, 'out');
fs.mkdirSync(out, { recursive: true });
let cards = '';
for (const [name, fn] of Object.entries(variants)) {
  const body = fn();
  const svg = (p) =>
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-6 -10 404 140" style="color:${p.fg};--ac:${p.ac}"><rect x="-6" y="-10" width="404" height="140" fill="${p.bg}"/>${body}</svg>`;
  fs.writeFileSync(path.join(out, name + '.svg'), svg(palettes[0]));
  cards += `<div class="c"><div class="n">${name}</div>${palettes.map(svg).join('')}</div>`;
}
const html = `<!doctype html><meta charset="utf-8"><style>
body{margin:0;padding:12px;font:13px sans-serif;background:#888}
.c{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-bottom:10px}
.n{grid-column:1/-1;color:#fff}svg{width:100%;display:block}
</style>${cards}
<script>document.querySelectorAll('.dots').forEach(e=>{const L=e.getTotalLength();const n=Math.max(2,Math.round(L/16));e.setAttribute('stroke-dasharray','0.1 '+(L/n-0.1))})</script>`;
fs.writeFileSync(path.join(__dirname, 'sheet.html'), html);
console.log('ok', Object.keys(variants).length, 'variants');
