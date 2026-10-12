// Generates offline map style templates for Tropa from the Protomaps basemap definitions.
// Placeholders {{PMTILES}} and {{FONTS}} are filled in by the app at run time.
import fs from 'node:fs';
import { layers, namedFlavor } from '@protomaps/basemaps';

const outDir = process.argv[2];
fs.mkdirSync(outDir, { recursive: true });

for (const flavor of ['light', 'dark']) {
  let ls = layers('protomaps', namedFlavor(flavor), { lang: 'ru' });
  // No sprite sheet is bundled: drop icon references so the renderer does not look for them.
  ls = ls.map((l) => {
    if (l.layout && 'icon-image' in l.layout) {
      const layout = { ...l.layout };
      delete layout['icon-image'];
      delete layout['icon-size'];
      return { ...l, layout };
    }
    return l;
  });
  const style = {
    version: 8,
    name: `tropa-${flavor}`,
    glyphs: '{{FONTS}}/{fontstack}/{range}.pbf',
    sources: {
      protomaps: {
        type: 'vector',
        url: 'pmtiles://{{PMTILES}}',
        attribution: '© OpenStreetMap contributors, Protomaps',
      },
    },
    layers: ls,
  };
  fs.writeFileSync(`${outDir}/style_${flavor}.json`, JSON.stringify(style));
  const fonts = new Set();
  for (const l of ls) {
    const f = l.layout && l.layout['text-font'];
    if (Array.isArray(f)) f.forEach((x) => fonts.add(x));
  }
  console.log(flavor, 'layers', ls.length, 'fonts', [...fonts].join(' | '));
}
