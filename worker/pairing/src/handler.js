import { isValidCode, redeemPairingCode } from './firebase.js';

const REDEEM_PATH = '/pairing/redeem';
const RATE_LIMIT_PER_MINUTE = 10;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
      ...CORS_HEADERS,
    },
  });
}

async function isRateLimited(env, ip) {
  if (!env.PAIRING_KV || !ip) return false;
  const minute = Math.floor(Date.now() / 60000);
  const key = `pair-rl:${ip}:${minute}`;
  try {
    const current = Number(await env.PAIRING_KV.get(key)) || 0;
    if (current >= RATE_LIMIT_PER_MINUTE) return true;
    // KV is eventually consistent; this is a coarse abuse brake, not a precise
    // quota. Cloudflare rate-limiting rules should also be enabled in production.
    await env.PAIRING_KV.put(key, String(current + 1), { expirationTtl: 120 });
    return false;
  } catch (error) {
    // A KV outage must not take pairing down with it. Log and fail open; the
    // Cloudflare rate-limiting rule is the second line of defence.
    console.error('pairing rate-limit KV failed:', error?.message || 'unknown error');
    return false;
  }
}

/**
 * Handles `POST /pairing/redeem`.
 *
 * Returns `null` for paths this module does not own so an existing Worker can
 * delegate here without changing its routing.
 */
export async function handlePairing(request, env) {
  const url = new URL(request.url);
  if (url.pathname !== REDEEM_PATH) return null;

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (request.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405);
  }

  const ip = request.headers.get('cf-connecting-ip') || '';
  if (await isRateLimited(env, ip)) {
    return json({ error: 'rate_limited' }, 429);
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'invalid_request' }, 400);
  }

  const code = typeof body?.code === 'string' ? body.code.trim() : '';
  if (!isValidCode(code)) {
    return json({ error: 'invalid_request' }, 400);
  }

  try {
    const result = await redeemPairingCode(env, code);
    if (result.status === 'ok') {
      return json({ customToken: result.customToken, uid: result.uid });
    }
    if (result.status === 'conflict') {
      return json({ error: 'code_already_used' }, 409);
    }
    // Deliberately identical for missing/expired/used/malformed records so the
    // endpoint cannot be used to probe which codes exist.
    return json({ error: 'invalid_code' }, 404);
  } catch (error) {
    // Never log the code, token, or service-account material.
    console.error('pairing redeem failed:', error?.message || 'unknown error');
    return json({ error: 'server_error' }, 500);
  }
}
