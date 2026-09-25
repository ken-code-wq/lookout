import { Resvg } from '@resvg/resvg-js'; import fs from 'fs';
// node render.mjs in.svg out.png [pad]
const [,, inp, out, padArg] = process.argv; const pad = padArg ? +padArg : 0.12; const S = 256;
let svg = fs.readFileSync(inp, 'utf8');
// Render at high res, fit into inner box, then composite into 256 canvas via a wrapper SVG.
const r = new Resvg(svg, { fitTo: { mode: 'original' } });
const bbox = r.getBBox(); // tight bbox of drawn content in user units
const inner = S * (1 - 2*pad);
const scale = Math.min(inner / bbox.width, inner / bbox.height);
const tx = (S - bbox.width*scale)/2 - bbox.x*scale, ty = (S - bbox.height*scale)/2 - bbox.y*scale;
// Wrap: strip outer svg width/height by nesting it
const b64 = Buffer.from(svg).toString('base64');
const vb = svg.match(/viewBox="([^"]+)"/)[1].split(/[ ,]+/).map(Number);
const wrapper = `<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}" viewBox="0 0 ${S} ${S}"><g transform="translate(${tx} ${ty}) scale(${scale})"><svg x="${vb[0]}" y="${vb[1]}" width="${vb[2]}" height="${vb[3]}" viewBox="${vb.join(' ')}" overflow="visible">${svg.replace(/^[\s\S]*?<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '')}</svg></g></svg>`;
const png = new Resvg(wrapper, { fitTo: { mode: 'original' }, background: 'rgba(0,0,0,0)' }).render().asPng();
fs.writeFileSync(out, png); console.log('ok', out, bbox);
