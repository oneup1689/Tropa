// Round 2: refine v3b (rising tail). Spacing variants, icon from "t", notification silhouette.
// Run: node gen2.js  -> sheet2.html, out2/*.svg
const fs = require('fs');
const path = require('path');
const R = 20;

function word({ g = 0, sw = 9 }) {
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

// icon: letter t whose hook rises into the trail and ends in the accent dot
function icon({ sw = 11 }) {
  const S = (d) => `<path d="${d}" fill="none" stroke="currentColor" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"/>`;
  return S('M50 16 V60 A20 20 0 0 0 70 80 C92 80 92 56 114 56 M34 40 H68') + `<circle cx="122" cy="56" r="8.5" fill="var(--ac)"/>`;
}

const palettes = [
  { n: 'earth', bg: '#F2E8CF', fg: '#1B3A34', ac: '#C8553D' },
  { n: 'night', bg: '#121A17', fg: '#E8F0EC', ac: '#C6F432' },
  { n: 'sea', bg: '#0F4C5C', fg: '#FFF8EE', ac: '#FF6F59' },
];
const style = (p) => `color:${p.fg};--ac:${p.ac}`;
const wsvg = (p, o) =>
  `<svg viewBox="-16 -10 420 140" style="${style(p)}"><rect x="-16" y="-10" width="420" height="140" fill="${p.bg}"/>${word(o)}</svg>`;
// icon box 100x100: t spans x 29..130, y 11..88 -> scale .72, center (79.5,50)
const isvg = (p, size, mono) => {
  const pp = mono ? { bg: '#1c1c1e', fg: '#fff', ac: '#fff' } : p;
  const inner = `<g transform="translate(50 50) scale(${mono ? .9 : .84}) translate(-79.5 -50)">${icon({ sw: mono ? 17 : 12 })}</g>`;
  return `<svg width="${size}" height="${size}" viewBox="0 0 100 100" style="${style(pp)}"><rect width="100" height="100" rx="${mono ? 0 : 22}" fill="${pp.bg}"/>${inner}</svg>`;
};

fs.mkdirSync(path.join(__dirname, 'out2'), { recursive: true });
let h = '<h4>Spacing: tight / base / loose</h4>';
for (const [n, g] of [['tight', -5], ['tighter', -8]])
  h += `<div class="row"><div class="n">${n}</div>${[palettes[0], palettes[1]].map((p) => wsvg(p, { g })).join('')}</div>`;
h += '<h4>Icon: 96 / 48 / notification 24 / 16</h4>';
for (const p of palettes) {
  h += `<div class="ic">${isvg(p, 96)}${isvg(p, 48)}<span class="bar">${isvg(p, 24, true)}${isvg(p, 16, true)}</span></div>`;
  fs.writeFileSync(path.join(__dirname, 'out2', `icon_${p.n}.svg`), isvg(p, 512).replace(/width="512" height="512"/, 'width="512" height="512"'));
}
fs.writeFileSync(path.join(__dirname, 'out2', 'word_earth.svg'), wsvg(palettes[0], { g: -5 }));
fs.writeFileSync(
  path.join(__dirname, 'sheet2.html'),
  `<!doctype html><meta charset="utf-8"><style>body{margin:0;padding:12px;font:13px sans-serif;background:#888;color:#fff}
.row{display:grid;grid-template-columns:50px 1fr 1fr;gap:6px;margin-bottom:8px;align-items:center}.row svg{width:100%;display:block}
.ic{display:flex;gap:14px;align-items:center;margin-bottom:10px}.bar{background:#1c1c1e;padding:6px 10px;display:inline-flex;gap:10px;align-items:center;border-radius:8px}
.bar svg rect{fill:none}</style>${h}`
);
console.log('ok');
