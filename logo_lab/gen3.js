// Round 3 (final candidates): tight wordmark, Android adaptive icon with masks, notification silhouette.
// Run: node gen3.js -> sheet3.html, out3/*.svg
const fs = require('fs');
const path = require('path');
const R = 20;

function word(g = -5, sw = 9) {
  const S = (d) => `<path d="${d}" fill="none" stroke="currentColor" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"/>`;
  const circ = (cx) => `M${cx - R} 60 A${R} ${R} 0 1 0 ${cx + R} 60 A${R} ${R} 0 1 0 ${cx - R} 60`;
  const rs = 100 + g, oc = 170 + 2 * g, ps = 220 + 3 * g, pc = ps + 20, ac = pc + 60 + g, as = ac + 20;
  const lead = [[-8, 2.2], [2, 3.2], [13, 4.4]].map(([x, r]) => `<circle cx="${x}" cy="40" r="${r}" fill="currentColor"/>`).join('');
  const tail = `M${as} 40 V60 A20 20 0 0 0 ${as + 20} 80 C${as + 42} 80 ${as + 42} 56 ${as + 64} 56`;
  return (
    S('M50 16 V60 A20 20 0 0 0 70 80 M34 40 H68') +
    S(`M${rs} 40 V80 M${rs} 60 A20 20 0 0 1 ${rs + 20} 40`) +
    S(circ(oc)) + S(`M${ps} 40 V112`) + S(circ(pc)) + S(circ(ac)) + S(tail) +
    `<circle cx="${as + 72}" cy="56" r="7" fill="var(--ac)"/>` + lead
  );
}
const tGlyph = (sw) =>
  `<path d="M50 16 V60 A20 20 0 0 0 70 80 C92 80 92 56 114 56 M34 40 H68" fill="none" stroke="currentColor" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"/><circle cx="122" cy="56" r="${sw * 0.78}" fill="var(--ac)"/>`;
const tMono = (sw) =>
  `<path d="M50 16 V60 A20 20 0 0 0 70 80 M34 40 H68" fill="none" stroke="currentColor" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"/><circle cx="90" cy="80" r="${sw * 0.6}" fill="currentColor"/>`;

const palettes = [
  { n: 'earth', bg: '#F2E8CF', fg: '#1B3A34', ac: '#C8553D' },
  { n: 'night', bg: '#121A17', fg: '#E8F0EC', ac: '#C6F432' },
  { n: 'forest', bg: '#1F6B4A', fg: '#F4FBF6', ac: '#FF7043' },
];
const st = (p) => `color:${p.fg};--ac:${p.ac}`;
const wsvg = (p) =>
  `<svg viewBox="-16 -10 420 140" style="${st(p)}"><rect x="-16" y="-10" width="420" height="140" fill="${p.bg}"/>${word()}</svg>`;
// adaptive foreground: 108 canvas, glyph inside the 66-unit safe zone
const fg108 = (p) =>
  `<g style="${st(p)}"><g transform="translate(54 54) scale(.6) translate(-79.5 -50)">${tGlyph(13)}</g></g>`;
const mask = (p, size, shape) => {
  const clip = shape === 'circle' ? `<circle cx="54" cy="54" r="54"/>` : `<rect width="108" height="108" rx="30"/>`;
  return `<svg width="${size}" height="${size}" viewBox="0 0 108 108"><defs><clipPath id="c${p.n}${shape}">${clip}</clipPath></defs><g clip-path="url(#c${p.n}${shape})"><rect width="108" height="108" fill="${p.bg}"/>${fg108(p)}</g></svg>`;
};
const mono = (size) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 100 100" style="color:#fff"><g transform="translate(50 50) scale(.95) translate(-60 -49)">${tMono(17)}</g></svg>`;

fs.mkdirSync(path.join(__dirname, 'out3'), { recursive: true });
let h = '';
for (const p of palettes) {
  h += `<div class="p"><div class="w">${wsvg(p)}</div><div class="i">${mask(p, 96, 'circle')}${mask(p, 96, 'sq')}${mask(p, 48, 'circle')}<span class="bar">${mono(24)}${mono(16)}</span></div></div>`;
  fs.writeFileSync(path.join(__dirname, 'out3', `word_${p.n}.svg`), wsvg(p));
  fs.writeFileSync(path.join(__dirname, 'out3', `icon_${p.n}.svg`), mask(p, 512, 'sq').replace(/ clip-path="[^"]*"/, ''));
}
fs.writeFileSync(path.join(__dirname, 'out3', 'notification_mono.svg'), mono(96));
fs.writeFileSync(
  path.join(__dirname, 'sheet3.html'),
  `<!doctype html><meta charset="utf-8"><style>body{margin:0;padding:12px;background:#888}
.p{display:grid;grid-template-columns:1fr 330px;gap:10px;align-items:center;margin-bottom:12px}.w svg{width:100%;display:block}
.i{display:flex;gap:8px;align-items:center}.bar{background:#1c1c1e;padding:6px 8px;display:inline-flex;gap:8px;align-items:center;border-radius:8px}</style>${h}`
);
console.log('ok');
