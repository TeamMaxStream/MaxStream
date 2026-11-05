// One-off cleanup for pairing codes written before the password relay was
// removed. Deletes every record that still contains a `password` field (and
// expired records). Safe to run more than once.
//
//   FIREBASE_SERVICE_ACCOUNT="$(cat service-account.json)" \
//   FIREBASE_DATABASE_URL=https://maxstream-8effc-default-rtdb.firebaseio.com \
//   node scripts/purge-device-codes.mjs

import { databaseUrl, getAccessToken, parseServiceAccount } from '../src/firebase.js';

const env = {
  FIREBASE_SERVICE_ACCOUNT: process.env.FIREBASE_SERVICE_ACCOUNT,
  FIREBASE_DATABASE_URL: process.env.FIREBASE_DATABASE_URL,
};

if (!env.FIREBASE_SERVICE_ACCOUNT) {
  console.error('FIREBASE_SERVICE_ACCOUNT is required');
  process.exit(1);
}

const account = parseServiceAccount(env);
const base = databaseUrl(env, account);
const token = await getAccessToken(env, account);
const auth = { Authorization: `Bearer ${token}` };

const response = await fetch(`${base}/device_codes.json`, { headers: auth });
if (!response.ok) {
  console.error(`Failed to read device_codes (HTTP ${response.status})`);
  process.exit(1);
}

const records = (await response.json()) ?? {};
const now = Date.now();
let purged = 0;

for (const [code, record] of Object.entries(records)) {
  if (!record || typeof record !== 'object') continue;
  const hasLegacyPassword = Object.prototype.hasOwnProperty.call(record, 'password');
  const expired = Number(record.expiresAt) < now;
  if (!hasLegacyPassword && !expired) continue;

  const del = await fetch(`${base}/device_codes/${encodeURIComponent(code)}.json`, {
    method: 'DELETE',
    headers: auth,
  });
  if (del.ok) {
    purged += 1;
    console.log(`deleted device_codes/${code} (${hasLegacyPassword ? 'legacy password' : 'expired'})`);
  } else {
    console.error(`failed to delete device_codes/${code} (HTTP ${del.status})`);
  }
}

console.log(`done: ${purged} record(s) removed`);
