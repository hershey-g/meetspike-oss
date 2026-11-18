#!/usr/bin/env node
// Builds the Meetspike app icons from one SVG design.
//
//   npm run icons
//
// Writes, under public/:
//   icons/icon.svg            the mark (rounded square), also the SVG favicon
//   icons/icon-maskable.svg   full-bleed square, mark inside the 80% safe zone
//   icons/icon-192.png        manifest icon
//   icons/icon-512.png        manifest icon
//   icons/icon-maskable-512.png  manifest icon, purpose "maskable"
//   icons/apple-touch-icon.png   180×180, iOS home screen
//   favicon.ico               16 + 32 px PNGs in an ICO container
//
// The PNGs are committed, so deploys do not need this script. Re-run it only
// after changing the design below, and bump ICON_VERSION in public/*.html and
// public/manifest.webmanifest so browsers fetch the new files.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Resvg } from "@resvg/resvg-js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const pub = join(root, "public");
const out = join(pub, "icons");

// Colours from public/app.css: --bg, --card, --card-2, --good (WHOOP-style green).
const BG = "#15191e";
const CARD = "#23282f";
const CARD_2 = "#2c323a";
const ACCENT = "#4ade6a";

/**
 * The mark, drawn on a 512 grid: a calendar page (body, header band, two
 * binder tabs) with a pulse line that spikes once. Shapes are thick so it
 * still reads at 16 px.
 */
function mark() {
  return `
    <rect x="80" y="112" width="352" height="312" rx="56" fill="${CARD}"/>
    <path d="M80 168a56 56 0 0 1 56-56h240a56 56 0 0 1 56 56v24H80z" fill="${CARD_2}"/>
    <rect x="158" y="76" width="36" height="76" rx="18" fill="${CARD_2}" stroke="${BG}" stroke-width="12"/>
    <rect x="318" y="76" width="36" height="76" rx="18" fill="${CARD_2}" stroke="${BG}" stroke-width="12"/>
    <polyline points="112,312 186,312 220,256 262,382 304,212 338,312 400,312"
      fill="none" stroke="${ACCENT}" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>`;
}

function svg({ maskable }) {
  // Maskable icons may be cropped to a circle of radius 40% (≈205 px of 512).
  // The mark spans roughly 352×348 around (256, 250); 0.74 keeps every corner
  // of it inside that circle.
  const inner = maskable
    ? `<g transform="translate(256 256) scale(0.74) translate(-256 -250)">${mark()}</g>`
    : mark();
  const ground = maskable
    ? `<rect width="512" height="512" fill="${BG}"/>`
    : `<rect width="512" height="512" rx="112" fill="${BG}"/>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">${ground}${inner}
</svg>
`;
}

function png(source, size) {
  return new Resvg(source, { fitTo: { mode: "width", value: size } }).render().asPng();
}

/** ICO container holding PNG images (supported by every current browser). */
function ico(images) {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(images.length, 4);
  const entries = [];
  let offset = 6 + 16 * images.length;
  for (const { size, data } of images) {
    const e = Buffer.alloc(16);
    e.writeUInt8(size >= 256 ? 0 : size, 0);
    e.writeUInt8(size >= 256 ? 0 : size, 1);
    e.writeUInt8(0, 2);
    e.writeUInt8(0, 3);
    e.writeUInt16LE(1, 4);
    e.writeUInt16LE(32, 6);
    e.writeUInt32LE(data.length, 8);
    e.writeUInt32LE(offset, 12);
    offset += data.length;
    entries.push(e);
  }
  return Buffer.concat([header, ...entries, ...images.map((i) => i.data)]);
}

mkdirSync(out, { recursive: true });
const plain = svg({ maskable: false });
const maskable = svg({ maskable: true });
const files = {
  "icons/icon.svg": plain,
  "icons/icon-maskable.svg": maskable,
  "icons/icon-192.png": png(plain, 192),
  "icons/icon-512.png": png(plain, 512),
  "icons/icon-maskable-512.png": png(maskable, 512),
  // iOS rounds the corners itself and shows transparency as black, so the
  // touch icon uses the full-bleed ground.
  "icons/apple-touch-icon.png": png(maskable, 180),
  "favicon.ico": ico([
    { size: 16, data: png(plain, 16) },
    { size: 32, data: png(plain, 32) },
  ]),
};
for (const [name, data] of Object.entries(files)) {
  writeFileSync(join(pub, name), data);
  console.log(`wrote public/${name}`);
}
