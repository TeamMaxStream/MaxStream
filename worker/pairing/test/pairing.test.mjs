import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';

import {
  b64url,
  customTokenPayload,
  importPrivateKey,
  isRedeemable,
  isValidCode,
  oauthAssertionPayload,
  redeemPairingCode,
  signJwt,
} from '../src/firebase.js';
import { handlePairing } from '../src/handler.js';

const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

async function makeAccount() {
  const keyPair = await crypto.subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  );
  const pkcs8 = await crypto.subtle.exportKey('pkcs8', keyPair.privateKey);
  const base64 = Buffer.from(pkcs8).toString('base64');
  const pem = `-----BEGIN PRIVATE KEY-----\n${base64.match(/.{1,64}/g).join('\n')}\n-----END PRIVATE KEY-----\n`;
  return {
    publicKey: keyPair.publicKey,
    account: {
      type: 'service_account',
      project_id: 'test-project',
      client_email: `svc-${crypto.randomUUID()}@test-project.iam.gserviceaccount.com`,
      private_key_id: 'kid-1',
      private_key: pem,
    },
  };
}

function decode(token, part) {
  const data = token.split('.')[part].replace(/-/g, '+').replace(/_/g, '/');
  return JSON.parse(Buffer.from(data, 'base64').toString('utf8'));
}

async function verifySignature(token, publicKey) {
  const [header, payload, signature] = token.split('.');
  const bytes = Uint8Array.from(
    Buffer.from(signature.replace(/-/g, '+').replace(/_/g, '/'), 'base64'),
  );
  return crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    publicKey,
    bytes,
    new TextEncoder().encode(`${header}.${payload}`),
  );
}

test('pairing codes are exactly six digits', () => {
  assert.equal(isValidCode('123456'), true);
  assert.equal(isValidCode('000000'), true);
  assert.equal(isValidCode('12345'), false);
  assert.equal(isValidCode('1234567'), false);
  assert.equal(isValidCode('abcdef'), false);
  assert.equal(isValidCode(' 123456 '), false);
  assert.equal(isValidCode(123456), false);
});

test('only unused, unexpired records with a uid are redeemable', () => {
  const nowMs = 1_700_000_000_000;
  assert.equal(isRedeemable({ userId: 'u1', expiresAt: nowMs + 60_000, isUsed: false }, nowMs), true);
  assert.equal(isRedeemable({ userId: 'u1', expiresAt: nowMs - 1, isUsed: false }, nowMs), false);
  assert.equal(isRedeemable({ userId: 'u1', expiresAt: nowMs + 60_000, isUsed: true }, nowMs), false);
  assert.equal(isRedeemable({ userId: '', expiresAt: nowMs + 60_000, isUsed: false }, nowMs), false);
  assert.equal(isRedeemable({ expiresAt: nowMs + 60_000, isUsed: false }, nowMs), false);
  assert.equal(isRedeemable(null, nowMs), false);
});

test('custom token and oauth assertion payloads have the required claims', async () => {
  const { account } = await makeAccount();
  const now = 1_700_000_000;
  const custom = customTokenPayload(account, 'user-1', now);
  assert.equal(custom.uid, 'user-1');
  assert.equal(custom.iss, account.client_email);
  assert.equal(custom.sub, account.client_email);
  assert.match(custom.aud, /IdentityToolkit$/);
  assert.equal(custom.iat, now);
  assert.equal(custom.exp, now + 3600);

  const oauth = oauthAssertionPayload(account, now);
  assert.equal(oauth.iss, account.client_email);
  assert.equal(oauth.aud, 'https://oauth2.googleapis.com/token');
  assert.equal(
    oauth.scope,
    'https://www.googleapis.com/auth/userinfo.email ' +
      'https://www.googleapis.com/auth/firebase.database',
  );
});

test('JWTs are RS256-signed and verifiable', async () => {
  const { account, publicKey } = await makeAccount();
  const key = await importPrivateKey(account.private_key);
  const token = await signJwt(
    customTokenPayload(account, 'user-2', 1_700_000_000),
    key,
    account.private_key_id,
  );

  assert.deepEqual(decode(token, 0), { alg: 'RS256', typ: 'JWT', kid: 'kid-1' });
  assert.equal(decode(token, 1).uid, 'user-2');
  assert.equal(await verifySignature(token, publicKey), true);

  const tampered = `${token.split('.').slice(0, 2).join('.')}.${b64url(new Uint8Array([1, 2, 3]))}`;
  assert.equal(await verifySignature(tampered, publicKey), false);
});

test('redeem mints a token and burns the code with a matching ETag', async () => {
  const { account, publicKey } = await makeAccount();
  const env = { FIREBASE_SERVICE_ACCOUNT: JSON.stringify(account) };
  const now = Date.now();
  const burnCalls = [];

  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    if (url === 'https://oauth2.googleapis.com/token') {
      return new Response(JSON.stringify({ access_token: 'access', expires_in: 3600 }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (url.endsWith('/device_codes/123456.json') && init.method === 'PUT') {
      burnCalls.push(init);
      return new Response(JSON.stringify({ isUsed: true }), { status: 200 });
    }
    if (url.endsWith('/device_codes/123456.json')) {
      return new Response(
        JSON.stringify({ code: '123456', userId: 'user-3', expiresAt: now + 60_000, isUsed: false }),
        { status: 200, headers: { ETag: '"etag-1"' } },
      );
    }
    throw new Error(`unexpected fetch ${init.method || 'GET'} ${url}`);
  };

  const result = await redeemPairingCode(env, '123456', now);
  assert.equal(result.status, 'ok');
  assert.equal(result.uid, 'user-3');
  assert.equal(decode(result.customToken, 1).uid, 'user-3');
  assert.equal(await verifySignature(result.customToken, publicKey), true);

  assert.equal(burnCalls.length, 1);
  assert.equal(burnCalls[0].headers['if-match'], '"etag-1"');
  assert.deepEqual(JSON.parse(burnCalls[0].body), {
    code: '123456',
    userId: 'user-3',
    expiresAt: now + 60_000,
    isUsed: true,
    redeemedAt: { '.sv': 'timestamp' },
  });
});

test('redeem refuses used/expired codes without writing', async () => {
  const { account } = await makeAccount();
  const env = { FIREBASE_SERVICE_ACCOUNT: JSON.stringify(account) };
  const now = Date.now();
  let wrote = false;

  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    if (url === 'https://oauth2.googleapis.com/token') {
      return new Response(JSON.stringify({ access_token: 'access', expires_in: 3600 }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (init.method === 'PUT') {
      wrote = true;
      return new Response('{}', { status: 200 });
    }
    if (url.endsWith('/device_codes/654321.json')) {
      return new Response(
        JSON.stringify({ userId: 'user-4', expiresAt: now - 1, isUsed: false }),
        { status: 200, headers: { ETag: '"etag-2"' } },
      );
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const result = await redeemPairingCode(env, '654321', now);
  assert.equal(result.status, 'invalid');
  assert.equal(wrote, false);
});

test('redeem reports a conflict when another request wins the ETag race', async () => {
  const { account } = await makeAccount();
  const env = { FIREBASE_SERVICE_ACCOUNT: JSON.stringify(account) };
  const now = Date.now();

  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    if (url === 'https://oauth2.googleapis.com/token') {
      return new Response(JSON.stringify({ access_token: 'access', expires_in: 3600 }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (url.endsWith('/device_codes/111111.json') && init.method === 'PUT') {
      return new Response('{}', { status: 412 });
    }
    if (url.endsWith('/device_codes/111111.json')) {
      return new Response(
        JSON.stringify({ userId: 'user-5', expiresAt: now + 60_000, isUsed: false }),
        { status: 200, headers: { ETag: '"etag-3"' } },
      );
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const result = await redeemPairingCode(env, '111111', now);
  assert.equal(result.status, 'conflict');
});

test('handler owns only POST /pairing/redeem and validates input', async () => {
  assert.equal(await handlePairing(new Request('https://example.com/other'), {}), null);

  const options = await handlePairing(
    new Request('https://example.com/pairing/redeem', { method: 'OPTIONS' }),
    {},
  );
  assert.equal(options.status, 204);

  const get = await handlePairing(
    new Request('https://example.com/pairing/redeem'),
    {},
  );
  assert.equal(get.status, 405);

  const bad = await handlePairing(
    new Request('https://example.com/pairing/redeem', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: 'abc' }),
    }),
    {},
  );
  assert.equal(bad.status, 400);
});

test('a KV outage fails open instead of breaking pairing', async () => {
  const env = {
    PAIRING_KV: {
      async get() {
        throw new Error('KV quota exceeded');
      },
      async put() {
        throw new Error('KV quota exceeded');
      },
    },
  };
  const response = await handlePairing(
    new Request('https://example.com/pairing/redeem', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'cf-connecting-ip': '203.0.113.5',
      },
      body: JSON.stringify({ code: 'abc' }),
    }),
    env,
  );
  // Reaching validation (400) proves the KV exception was contained.
  assert.equal(response.status, 400);
});
