// XSalsa20-Poly1305 secretbox (libsodium crypto_secretbox).
// Pure JS: Workers have no WebCrypto Salsa20 primitive. Ported from the
// MaxStream API extractor so the legacy worker can sign VidLink API tokens.

const SIGMA0 = 0x61707865;
const SIGMA1 = 0x3320646e;
const SIGMA2 = 0x79622d32;
const SIGMA3 = 0x6b206574;

const P1305 = (1n << 130n) - 5n;
const MASK128 = (1n << 128n) - 1n;

function rotl32(v, c) {
  return ((v << c) | (v >>> (32 - c))) | 0;
}

function salsaRounds(x) {
  let x0 = x[0], x1 = x[1], x2 = x[2], x3 = x[3];
  let x4 = x[4], x5 = x[5], x6 = x[6], x7 = x[7];
  let x8 = x[8], x9 = x[9], x10 = x[10], x11 = x[11];
  let x12 = x[12], x13 = x[13], x14 = x[14], x15 = x[15];

  for (let i = 0; i < 10; i++) {
    x4 = (x4 ^ rotl32((x0 + x12) | 0, 7)) | 0;
    x8 = (x8 ^ rotl32((x4 + x0) | 0, 9)) | 0;
    x12 = (x12 ^ rotl32((x8 + x4) | 0, 13)) | 0;
    x0 = (x0 ^ rotl32((x12 + x8) | 0, 18)) | 0;

    x9 = (x9 ^ rotl32((x5 + x1) | 0, 7)) | 0;
    x13 = (x13 ^ rotl32((x9 + x5) | 0, 9)) | 0;
    x1 = (x1 ^ rotl32((x13 + x9) | 0, 13)) | 0;
    x5 = (x5 ^ rotl32((x1 + x13) | 0, 18)) | 0;

    x14 = (x14 ^ rotl32((x10 + x6) | 0, 7)) | 0;
    x2 = (x2 ^ rotl32((x14 + x10) | 0, 9)) | 0;
    x6 = (x6 ^ rotl32((x2 + x14) | 0, 13)) | 0;
    x10 = (x10 ^ rotl32((x6 + x2) | 0, 18)) | 0;

    x3 = (x3 ^ rotl32((x15 + x11) | 0, 7)) | 0;
    x7 = (x7 ^ rotl32((x3 + x15) | 0, 9)) | 0;
    x11 = (x11 ^ rotl32((x7 + x3) | 0, 13)) | 0;
    x15 = (x15 ^ rotl32((x11 + x7) | 0, 18)) | 0;

    x1 = (x1 ^ rotl32((x0 + x3) | 0, 7)) | 0;
    x2 = (x2 ^ rotl32((x1 + x0) | 0, 9)) | 0;
    x3 = (x3 ^ rotl32((x2 + x1) | 0, 13)) | 0;
    x0 = (x0 ^ rotl32((x3 + x2) | 0, 18)) | 0;

    x6 = (x6 ^ rotl32((x5 + x4) | 0, 7)) | 0;
    x7 = (x7 ^ rotl32((x6 + x5) | 0, 9)) | 0;
    x4 = (x4 ^ rotl32((x7 + x6) | 0, 13)) | 0;
    x5 = (x5 ^ rotl32((x4 + x7) | 0, 18)) | 0;

    x11 = (x11 ^ rotl32((x10 + x9) | 0, 7)) | 0;
    x8 = (x8 ^ rotl32((x11 + x10) | 0, 9)) | 0;
    x9 = (x9 ^ rotl32((x8 + x11) | 0, 13)) | 0;
    x10 = (x10 ^ rotl32((x9 + x8) | 0, 18)) | 0;

    x12 = (x12 ^ rotl32((x15 + x14) | 0, 7)) | 0;
    x13 = (x13 ^ rotl32((x12 + x15) | 0, 9)) | 0;
    x14 = (x14 ^ rotl32((x13 + x12) | 0, 13)) | 0;
    x15 = (x15 ^ rotl32((x14 + x13) | 0, 18)) | 0;
  }

  x[0] = x0; x[1] = x1; x[2] = x2; x[3] = x3;
  x[4] = x4; x[5] = x5; x[6] = x6; x[7] = x7;
  x[8] = x8; x[9] = x9; x[10] = x10; x[11] = x11;
  x[12] = x12; x[13] = x13; x[14] = x14; x[15] = x15;
}

function leWords(bytes) {
  const out = new Int32Array(bytes.length >> 2);
  for (let i = 0; i < out.length; i++) {
    const b = i * 4;
    out[i] =
      (bytes[b] |
        (bytes[b + 1] << 8) |
        (bytes[b + 2] << 16) |
        (bytes[b + 3] << 24)) | 0;
  }
  return out;
}

function packLe(words) {
  const out = new Uint8Array(words.length * 4);
  for (let i = 0; i < words.length; i++) {
    const v = words[i];
    const b = i * 4;
    out[b] = v & 0xff;
    out[b + 1] = (v >>> 8) & 0xff;
    out[b + 2] = (v >>> 16) & 0xff;
    out[b + 3] = (v >>> 24) & 0xff;
  }
  return out;
}

// Salsa20 block with feed-forward (crypto_core_salsa20).
function salsa20Block(key, nonce, counter) {
  const k = leWords(key);
  const n = leWords(nonce);
  const counterLo = counter >>> 0;
  const counterHi = Math.floor(counter / 0x100000000) >>> 0;

  const x = new Int32Array([
    SIGMA0, k[0], k[1], k[2], k[3],
    SIGMA1, n[0], n[1], counterLo, counterHi,
    SIGMA2, k[4], k[5], k[6], k[7],
    SIGMA3,
  ]);
  const orig = Int32Array.from(x);
  salsaRounds(x);

  const out = new Uint8Array(64);
  for (let i = 0; i < 16; i++) {
    const v = (x[i] + orig[i]) | 0;
    const b = i * 4;
    out[b] = v & 0xff;
    out[b + 1] = (v >>> 8) & 0xff;
    out[b + 2] = (v >>> 16) & 0xff;
    out[b + 3] = (v >>> 24) & 0xff;
  }
  return out;
}

// Salsa20 stream XOR with the block counter starting at zero.
function salsa20Xor(data, key, nonce) {
  const out = Uint8Array.from(data);
  let offset = 0;
  let counter = 0;
  while (offset < data.length) {
    const block = salsa20Block(key, nonce, counter++);
    const length = Math.min(64, data.length - offset);
    for (let i = 0; i < length; i++) {
      out[offset + i] = (out[offset + i] ^ block[i]) & 0xff;
    }
    offset += length;
  }
  return out;
}

// HSalsa20: key(32) + nonce(16) -> 32-byte subkey (no feed-forward).
function hsalsa20(key, nonce) {
  const k = leWords(key);
  const n = leWords(nonce);
  const x = new Int32Array([
    SIGMA0, k[0], k[1], k[2], k[3],
    SIGMA1, n[0], n[1], n[2], n[3],
    SIGMA2, k[4], k[5], k[6], k[7],
    SIGMA3,
  ]);
  salsaRounds(x);
  return packLe([x[0], x[5], x[10], x[15], x[6], x[7], x[8], x[9]]);
}

// Poly1305 one-time authenticator (RFC 8439), bigint arithmetic.
export function poly1305(msg, key32) {
  const rBytes = key32.slice(0, 16);
  rBytes[3] &= 0x0f;
  rBytes[7] &= 0x0f;
  rBytes[11] &= 0x0f;
  rBytes[15] &= 0x0f;
  rBytes[4] &= 0xfc;
  rBytes[8] &= 0xfc;
  rBytes[12] &= 0xfc;

  const r = bytesToLe(rBytes);
  const s = bytesToLe(key32.slice(16, 32));
  let h = 0n;

  for (let offset = 0; offset < msg.length; offset += 16) {
    const block = msg.subarray(offset, Math.min(offset + 16, msg.length));
    let n = 0n;
    for (let i = block.length - 1; i >= 0; i--) {
      n = (n << 8n) | BigInt(block[i]);
    }
    n |= 1n << BigInt(8 * block.length);
    h = ((h + n) * r) % P1305;
  }

  h = (h + s) & MASK128;
  const out = new Uint8Array(16);
  for (let i = 0; i < 16; i++) {
    out[i] = Number((h >> BigInt(8 * i)) & 0xffn);
  }
  return out;
}

function bytesToLe(bytes) {
  let out = 0n;
  for (let i = bytes.length - 1; i >= 0; i--) {
    out = (out << 8n) | BigInt(bytes[i]);
  }
  return out;
}

/**
 * Detached secretbox: returns mac(16) || ciphertext.
 * key = 32 bytes, nonce = 24 bytes.
 */
export function secretbox(message, key, nonce) {
  if (key.length !== 32) throw new Error("secretbox key must be 32 bytes");
  if (nonce.length !== 24) throw new Error("secretbox nonce must be 24 bytes");

  const subkey = hsalsa20(key, nonce.subarray(0, 16));
  const streamNonce = nonce.subarray(16, 24);
  const keystream = salsa20Xor(new Uint8Array(32 + message.length), subkey, streamNonce);
  const polyKey = keystream.subarray(0, 32);

  const ciphertext = new Uint8Array(message.length);
  for (let i = 0; i < message.length; i++) {
    ciphertext[i] = message[i] ^ keystream[32 + i];
  }

  const mac = poly1305(ciphertext, polyKey);
  const out = new Uint8Array(16 + ciphertext.length);
  out.set(mac, 0);
  out.set(ciphertext, 16);
  return out;
}
