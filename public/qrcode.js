/*
 * QR Code encoder for the setup page's "Connect your iPhone" code.
 *
 * Adapted from the QR Code generator library (TypeScript) by Project Nayuki:
 * https://www.nayuki.io/page/qr-code-generator-library
 * Trimmed to byte mode with medium (boosted) error correction and automatic
 * mask choice, and rewritten as a plain ES module so it runs in the browser
 * and in Node tests without a build step. No network, no dependencies.
 *
 * Copyright (c) Project Nayuki. (MIT License)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 * the Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 * - The above copyright notice and this permission notice shall be included in
 *   all copies or substantial portions of the Software.
 * - The Software is provided "as is", without warranty of any kind, express or
 *   implied, including but not limited to the warranties of merchantability,
 *   fitness for a particular purpose and noninfringement. In no event shall the
 *   authors or copyright holders be liable for any claim, damages or other
 *   liability, whether in an action of contract, tort or otherwise, arising from,
 *   out of or in connection with the Software or the use or other dealings in the
 *   Software.
 */

// Error correction levels: [ordinal, formatBits].
const ECC = { LOW: [0, 1], MEDIUM: [1, 0], QUARTILE: [2, 3], HIGH: [3, 2] };

const ECC_CODEWORDS_PER_BLOCK = [
  [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
  [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
];
const NUM_ERROR_CORRECTION_BLOCKS = [
  [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
  [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
  [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
  [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
];
const PENALTY_N1 = 3;
const PENALTY_N2 = 3;
const PENALTY_N3 = 40;
const PENALTY_N4 = 10;

function appendBits(val, len, bb) {
  if (len < 0 || len > 31 || val >>> len !== 0) throw new RangeError("Value out of range");
  for (let i = len - 1; i >= 0; i--) bb.push((val >>> i) & 1);
}

function getBit(x, i) {
  return ((x >>> i) & 1) !== 0;
}

function assert(cond) {
  if (!cond) throw new Error("Assertion error");
}

function numRawDataModules(ver) {
  let result = (16 * ver + 128) * ver + 64;
  if (ver >= 2) {
    const numAlign = Math.floor(ver / 7) + 2;
    result -= (25 * numAlign - 10) * numAlign - 55;
    if (ver >= 7) result -= 36;
  }
  return result;
}

function numDataCodewords(ver, ecl) {
  return Math.floor(numRawDataModules(ver) / 8) - ECC_CODEWORDS_PER_BLOCK[ecl[0]][ver] * NUM_ERROR_CORRECTION_BLOCKS[ecl[0]][ver];
}

function rsMultiply(x, y) {
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z;
}

function rsDivisor(degree) {
  const result = [];
  for (let i = 0; i < degree - 1; i++) result.push(0);
  result.push(1);
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < result.length; j++) {
      result[j] = rsMultiply(result[j], root);
      if (j + 1 < result.length) result[j] ^= result[j + 1];
    }
    root = rsMultiply(root, 0x02);
  }
  return result;
}

function rsRemainder(data, divisor) {
  const result = divisor.map(() => 0);
  for (const b of data) {
    const factor = b ^ result.shift();
    result.push(0);
    divisor.forEach((coef, i) => (result[i] ^= rsMultiply(coef, factor)));
  }
  return result;
}

function utf8Bytes(text) {
  return Array.from(new TextEncoder().encode(text));
}

class Matrix {
  constructor(version, ecl, dataCodewords) {
    this.version = version;
    this.ecl = ecl;
    this.size = version * 4 + 17;
    this.modules = Array.from({ length: this.size }, () => new Array(this.size).fill(false));
    this.isFunction = Array.from({ length: this.size }, () => new Array(this.size).fill(false));
    this.drawFunctionPatterns();
    this.drawCodewords(this.addEccAndInterleave(dataCodewords));
    let mask = 0;
    let minPenalty = Infinity;
    for (let i = 0; i < 8; i++) {
      this.applyMask(i);
      this.drawFormatBits(i);
      const penalty = this.penaltyScore();
      if (penalty < minPenalty) {
        mask = i;
        minPenalty = penalty;
      }
      this.applyMask(i);
    }
    this.mask = mask;
    this.applyMask(mask);
    this.drawFormatBits(mask);
    this.isFunction = [];
  }

  setFunctionModule(x, y, dark) {
    this.modules[y][x] = dark;
    this.isFunction[y][x] = true;
  }

  drawFunctionPatterns() {
    for (let i = 0; i < this.size; i++) {
      this.setFunctionModule(6, i, i % 2 === 0);
      this.setFunctionModule(i, 6, i % 2 === 0);
    }
    this.drawFinder(3, 3);
    this.drawFinder(this.size - 4, 3);
    this.drawFinder(3, this.size - 4);
    const pos = this.alignmentPositions();
    pos.forEach((x, i) => {
      pos.forEach((y, j) => {
        const corner = (i === 0 && j === 0) || (i === 0 && j === pos.length - 1) || (i === pos.length - 1 && j === 0);
        if (!corner) this.drawAlignment(x, y);
      });
    });
    this.drawFormatBits(0);
    this.drawVersion();
  }

  drawFormatBits(mask) {
    const data = (this.ecl[1] << 3) | mask;
    let rem = data;
    for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    const bits = ((data << 10) | rem) ^ 0x5412;
    for (let i = 0; i <= 5; i++) this.setFunctionModule(8, i, getBit(bits, i));
    this.setFunctionModule(8, 7, getBit(bits, 6));
    this.setFunctionModule(8, 8, getBit(bits, 7));
    this.setFunctionModule(7, 8, getBit(bits, 8));
    for (let i = 9; i < 15; i++) this.setFunctionModule(14 - i, 8, getBit(bits, i));
    for (let i = 0; i < 8; i++) this.setFunctionModule(this.size - 1 - i, 8, getBit(bits, i));
    for (let i = 8; i < 15; i++) this.setFunctionModule(8, this.size - 15 + i, getBit(bits, i));
    this.setFunctionModule(8, this.size - 8, true);
  }

  drawVersion() {
    if (this.version < 7) return;
    let rem = this.version;
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    const bits = (this.version << 12) | rem;
    for (let i = 0; i < 18; i++) {
      const color = getBit(bits, i);
      const a = this.size - 11 + (i % 3);
      const b = Math.floor(i / 3);
      this.setFunctionModule(a, b, color);
      this.setFunctionModule(b, a, color);
    }
  }

  drawFinder(x, y) {
    for (let dy = -4; dy <= 4; dy++) {
      for (let dx = -4; dx <= 4; dx++) {
        const dist = Math.max(Math.abs(dx), Math.abs(dy));
        const xx = x + dx;
        const yy = y + dy;
        if (xx >= 0 && xx < this.size && yy >= 0 && yy < this.size) this.setFunctionModule(xx, yy, dist !== 2 && dist !== 4);
      }
    }
  }

  drawAlignment(x, y) {
    for (let dy = -2; dy <= 2; dy++) {
      for (let dx = -2; dx <= 2; dx++) this.setFunctionModule(x + dx, y + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
    }
  }

  alignmentPositions() {
    if (this.version === 1) return [];
    const numAlign = Math.floor(this.version / 7) + 2;
    const step = Math.floor((this.version * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4)) * 2;
    const result = [6];
    for (let pos = this.size - 7; result.length < numAlign; pos -= step) result.splice(1, 0, pos);
    return result;
  }

  addEccAndInterleave(data) {
    const ver = this.version;
    const ord = this.ecl[0];
    assert(data.length === numDataCodewords(ver, this.ecl));
    const numBlocks = NUM_ERROR_CORRECTION_BLOCKS[ord][ver];
    const blockEccLen = ECC_CODEWORDS_PER_BLOCK[ord][ver];
    const rawCodewords = Math.floor(numRawDataModules(ver) / 8);
    const numShortBlocks = numBlocks - (rawCodewords % numBlocks);
    const shortBlockLen = Math.floor(rawCodewords / numBlocks);
    const blocks = [];
    const divisor = rsDivisor(blockEccLen);
    for (let i = 0, k = 0; i < numBlocks; i++) {
      const dat = data.slice(k, k + shortBlockLen - blockEccLen + (i < numShortBlocks ? 0 : 1));
      k += dat.length;
      const ecc = rsRemainder(dat, divisor);
      if (i < numShortBlocks) dat.push(0);
      blocks.push(dat.concat(ecc));
    }
    const result = [];
    for (let i = 0; i < blocks[0].length; i++) {
      blocks.forEach((block, j) => {
        if (i !== shortBlockLen - blockEccLen || j >= numShortBlocks) result.push(block[i]);
      });
    }
    assert(result.length === rawCodewords);
    return result;
  }

  drawCodewords(data) {
    let i = 0;
    for (let right = this.size - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      for (let vert = 0; vert < this.size; vert++) {
        for (let j = 0; j < 2; j++) {
          const x = right - j;
          const upward = ((right + 1) & 2) === 0;
          const y = upward ? this.size - 1 - vert : vert;
          if (!this.isFunction[y][x] && i < data.length * 8) {
            this.modules[y][x] = getBit(data[i >>> 3], 7 - (i & 7));
            i++;
          }
        }
      }
    }
    assert(i === data.length * 8);
  }

  applyMask(mask) {
    for (let y = 0; y < this.size; y++) {
      for (let x = 0; x < this.size; x++) {
        let invert;
        switch (mask) {
          case 0: invert = (x + y) % 2 === 0; break;
          case 1: invert = y % 2 === 0; break;
          case 2: invert = x % 3 === 0; break;
          case 3: invert = (x + y) % 3 === 0; break;
          case 4: invert = (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0; break;
          case 5: invert = ((x * y) % 2) + ((x * y) % 3) === 0; break;
          case 6: invert = (((x * y) % 2) + ((x * y) % 3)) % 2 === 0; break;
          default: invert = (((x + y) % 2) + ((x * y) % 3)) % 2 === 0; break;
        }
        if (!this.isFunction[y][x] && invert) this.modules[y][x] = !this.modules[y][x];
      }
    }
  }

  penaltyScore() {
    let result = 0;
    const line = (get) => {
      let runColor = false;
      let run = 0;
      const history = [0, 0, 0, 0, 0, 0, 0];
      for (let i = 0; i < this.size; i++) {
        if (get(i) === runColor) {
          run++;
          if (run === 5) result += PENALTY_N1;
          else if (run > 5) result++;
        } else {
          this.addHistory(run, history);
          if (!runColor) result += this.countPatterns(history) * PENALTY_N3;
          runColor = get(i);
          run = 1;
        }
      }
      result += this.terminateAndCount(runColor, run, history) * PENALTY_N3;
    };
    for (let y = 0; y < this.size; y++) line((x) => this.modules[y][x]);
    for (let x = 0; x < this.size; x++) line((y) => this.modules[y][x]);
    for (let y = 0; y < this.size - 1; y++) {
      for (let x = 0; x < this.size - 1; x++) {
        const c = this.modules[y][x];
        if (c === this.modules[y][x + 1] && c === this.modules[y + 1][x] && c === this.modules[y + 1][x + 1]) result += PENALTY_N2;
      }
    }
    let dark = 0;
    for (const row of this.modules) for (const c of row) if (c) dark++;
    const total = this.size * this.size;
    const k = Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1;
    result += k * PENALTY_N4;
    return result;
  }

  countPatterns(h) {
    const n = h[1];
    const core = n > 0 && h[2] === n && h[3] === n * 3 && h[4] === n && h[5] === n;
    return (core && h[0] >= n * 4 && h[6] >= n ? 1 : 0) + (core && h[6] >= n * 4 && h[0] >= n ? 1 : 0);
  }

  terminateAndCount(color, run, history) {
    if (color) {
      this.addHistory(run, history);
      run = 0;
    }
    run += this.size;
    this.addHistory(run, history);
    return this.countPatterns(history);
  }

  addHistory(run, history) {
    if (history[0] === 0) run += this.size;
    history.pop();
    history.unshift(run);
  }
}

/**
 * Encode `text` (UTF-8, byte mode). Returns { size, version, get(x, y) }.
 * Error correction starts at medium and is raised when it fits the same version.
 */
export function encodeQr(text) {
  const bytes = utf8Bytes(String(text));
  let ecl = ECC.MEDIUM;
  let version;
  let usedBits;
  for (version = 1; ; version++) {
    const ccBits = version < 10 ? 8 : 16;
    usedBits = 4 + ccBits + bytes.length * 8;
    if (bytes.length < 1 << ccBits && usedBits <= numDataCodewords(version, ecl) * 8) break;
    if (version >= 40) throw new RangeError("Data too long");
  }
  for (const better of [ECC.QUARTILE, ECC.HIGH]) {
    if (usedBits <= numDataCodewords(version, better) * 8) ecl = better;
  }
  const bb = [];
  appendBits(0x4, 4, bb);
  appendBits(bytes.length, version < 10 ? 8 : 16, bb);
  for (const b of bytes) appendBits(b, 8, bb);
  const capacity = numDataCodewords(version, ecl) * 8;
  appendBits(0, Math.min(4, capacity - bb.length), bb);
  appendBits(0, (8 - (bb.length % 8)) % 8, bb);
  for (let pad = 0xec; bb.length < capacity; pad ^= 0xec ^ 0x11) appendBits(pad, 8, bb);
  const codewords = new Array(bb.length / 8).fill(0);
  bb.forEach((b, i) => (codewords[i >>> 3] |= b << (7 - (i & 7))));
  const m = new Matrix(version, ecl, codewords);
  return {
    size: m.size,
    version,
    get: (x, y) => x >= 0 && x < m.size && y >= 0 && y < m.size && m.modules[y][x],
  };
}

/**
 * A crisp SVG for `text`: dark modules on a light square with a 4-module quiet
 * zone, which phone cameras need. `label` becomes the accessible name.
 */
export function qrSvg(text, label = "QR code") {
  const qr = encodeQr(text);
  const border = 4;
  const dim = qr.size + border * 2;
  const parts = [];
  for (let y = 0; y < qr.size; y++) {
    for (let x = 0; x < qr.size; x++) {
      if (qr.get(x, y)) parts.push(`M${x + border},${y + border}h1v1h-1z`);
    }
  }
  const safe = String(label).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${dim} ${dim}" shape-rendering="crispEdges" role="img" aria-label="${safe}">` +
    `<rect width="100%" height="100%" fill="#ffffff"/>` +
    `<path d="${parts.join("")}" fill="#000000"/></svg>`
  );
}
