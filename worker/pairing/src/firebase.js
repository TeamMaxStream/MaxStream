// Firebase helpers for the pairing Worker.
//
// Cloudflare Workers cannot use firebase-admin (gRPC/Node APIs), so custom
// tokens and Realtime Database admin access are implemented with WebCrypto:
//   * RS256 JWTs are signed with the service-account private key.
//   * The OAuth assertion is exchanged for a database-scoped access token.
//   * Codes are burned with an ETag-conditional PATCH so two TVs cannot redeem
//     the same code.

const OAUTH_TOKEN_URL = 'https://oauth2.googleapis.com/token';
// Both scopes are required by the RTDB REST API. With only
// `firebase.database`, Google mints a token that the database rejects with
// HTTP 401 "Unauthorized request".
const OAUTH_SCOPE =
  'https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/firebase.database';
const CUSTOM_TOKEN_AUD =
  'https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit';

const accessTokenCache = new Map();

export function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

export function b64url(input) {
  const bytes =
    typeof input === 'string' ? new TextEncoder().encode(input) : input;
  let binary = '';
  for (let i = 0; i < bytes.length; i += 1) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

function pemToDer(pem) {
  const body = String(pem)
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');
  if (!body) throw new Error('Service account private_key is empty');
  const binary = atob(body);
  const der = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    der[i] = binary.charCodeAt(i);
  }
  return der;
}

export function parseServiceAccount(env) {
  const raw = env.FIREBASE_SERVICE_ACCOUNT;
  if (!raw) throw new Error('FIREBASE_SERVICE_ACCOUNT is not configured');
  let account;
  try {
    account = JSON.parse(raw);
  } catch {
    throw new Error('FIREBASE_SERVICE_ACCOUNT is not valid JSON');
  }
  if (!account.client_email || !account.private_key) {
    throw new Error('FIREBASE_SERVICE_ACCOUNT is missing client_email/private_key');
  }
  return account;
}

export async function importPrivateKey(pem) {
  return crypto.subtle.importKey(
    'pkcs8',
    pemToDer(pem),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
}

export async function signJwt(payload, privateKey, kid) {
  const header = { alg: 'RS256', typ: 'JWT' };
  if (kid) header.kid = kid;
  const unsigned = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    privateKey,
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${b64url(new Uint8Array(signature))}`;
}

export function oauthAssertionPayload(account, now = nowSeconds()) {
  return {
    iss: account.client_email,
    scope: OAUTH_SCOPE,
    aud: OAUTH_TOKEN_URL,
    iat: now,
    exp: now + 3600,
  };
}

export async function getAccessToken(env, account, now = nowSeconds()) {
  const cached = accessTokenCache.get(account.client_email);
  if (cached && cached.expiresAt - 60 > now) return cached.token;

  const key = await importPrivateKey(account.private_key);
  const assertion = await signJwt(
    oauthAssertionPayload(account, now),
    key,
    account.private_key_id,
  );
  const response = await fetch(OAUTH_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  if (!response.ok) {
    throw new Error(`OAuth token exchange failed (HTTP ${response.status})`);
  }
  const data = await response.json();
  if (!data.access_token) throw new Error('OAuth token exchange returned no token');
  accessTokenCache.set(account.client_email, {
    token: data.access_token,
    expiresAt: now + Number(data.expires_in || 3600),
  });
  return data.access_token;
}

export function databaseUrl(env, account) {
  const configured = env.FIREBASE_DATABASE_URL;
  if (configured) return String(configured).replace(/\/+$/, '');
  if (!account.project_id) {
    throw new Error('FIREBASE_DATABASE_URL is not configured');
  }
  return `https://${account.project_id}-default-rtdb.firebaseio.com`;
}

export function isValidCode(code) {
  return typeof code === 'string' && /^\d{6}$/.test(code);
}

export function isRedeemable(record, nowMs = Date.now()) {
  if (!record || typeof record !== 'object') return false;
  if (typeof record.userId !== 'string' || record.userId.length === 0) return false;
  if (record.isUsed === true) return false;
  // Client-written codes store expiry as epoch milliseconds (ServerValue is
  // not required), so compare against milliseconds, not seconds.
  const expiresAt = Number(record.expiresAt);
  return Number.isFinite(expiresAt) && expiresAt > nowMs;
}

export function customTokenPayload(account, uid, now = nowSeconds()) {
  return {
    iss: account.client_email,
    sub: account.client_email,
    aud: CUSTOM_TOKEN_AUD,
    iat: now,
    exp: now + 3600,
    uid,
  };
}

export async function mintCustomToken(account, uid, now = nowSeconds()) {
  const key = await importPrivateKey(account.private_key);
  return signJwt(
    customTokenPayload(account, uid, now),
    key,
    account.private_key_id,
  );
}

async function adminRequest(env, account, path, init = {}) {
  const token = await getAccessToken(env, account);
  const base = databaseUrl(env, account);
  return fetch(`${base}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(init.headers || {}),
    },
  });
}

/**
 * Redeems a pairing code exactly once.
 *
 * Returns { status: 'ok', customToken, uid } or { status: 'invalid' } or
 * { status: 'conflict' } when another request consumed the code first.
 * Throws on server/configuration errors.
 */
export async function redeemPairingCode(env, code, nowMs = Date.now()) {
  if (!isValidCode(code)) return { status: 'invalid' };

  const account = parseServiceAccount(env);
  const path = `/device_codes/${encodeURIComponent(code)}.json`;

  const read = await adminRequest(env, account, path, {
    headers: { 'X-Firebase-ETag': 'true' },
  });
  if (!read.ok) throw new Error(`RTDB read failed (HTTP ${read.status})`);

  const record = await read.json();
  if (!isRedeemable(record, nowMs)) return { status: 'invalid' };

  // Mint first, then burn: a signing failure must not consume the code.
  const customToken = await mintCustomToken(
    account,
    record.userId,
    Math.floor(nowMs / 1000),
  );

  const etag = read.headers.get('ETag');
  // RTDB only supports conditional (`if-match`) writes on PUT — PATCH returns
  // HTTP 400. PUT replaces the node, so send the full record back with the
  // burn fields added; the stale ETag from a concurrent redeem yields 412.
  const burnBody = {
    ...record,
    isUsed: true,
    redeemedAt: { '.sv': 'timestamp' },
  };
  const burn = await adminRequest(env, account, path, {
    method: 'PUT',
    headers: {
      'Content-Type': 'application/json',
      ...(etag ? { 'if-match': etag } : {}),
    },
    body: JSON.stringify(burnBody),
  });
  if (burn.status === 412) return { status: 'conflict' };
  if (!burn.ok) throw new Error(`RTDB burn failed (HTTP ${burn.status})`);

  return { status: 'ok', customToken, uid: record.userId };
}
