# MaxStream pairing Worker

Passwordless TV pairing. The phone writes a one-time code to RTDB; the TV sends
the code here; this Worker validates and burns it with an ETag-conditional
write, then returns a Firebase custom token that the TV exchanges with
`accounts:signInWithCustomToken`.

No password ever leaves the phone.

## Endpoint

`POST /pairing/redeem`

```json
{ "code": "123456" }
```

| Status | Meaning |
| --- | --- |
| 200 | `{ "customToken": "...", "uid": "..." }` |
| 400 | malformed request/code |
| 404 | code missing, expired, used, or invalid (deliberately indistinguishable) |
| 409 | another request consumed the code first |
| 429 | rate limited |
| 500 | server/configuration error |

## Setup

1. Create a Firebase service-account key for project `maxstream-8effc`
   (Firebase console → Project settings → Service accounts → Generate new
   private key). The account needs Realtime Database access.
2. Store the JSON key as a Worker secret:

   ```bash
   cd worker/pairing
   npx wrangler secret put FIREBASE_SERVICE_ACCOUNT < service-account.json
   npx wrangler secret put FIREBASE_DATABASE_URL
   # e.g. https://maxstream-8effc-default-rtdb.firebaseio.com
   ```

3. Enable the abuse brake (recommended):

   ```bash
   npx wrangler kv namespace create PAIRING_KV
   # paste the returned id into wrangler.toml and uncomment the binding
   ```

   Also consider a Cloudflare rate-limiting rule for `/pairing/redeem`.

4. Deploy the standalone Worker:

   ```bash
   npx wrangler deploy
   ```

   Or mount it in the existing MaxStream Worker:

   ```js
   import { handlePairing } from './pairing/handler.js';

   export default {
     async fetch(request, env) {
       const pairing = await handlePairing(request, env);
       if (pairing) return pairing;
       // ... existing routing
     },
   };
   ```

   If you mount it, clients should keep using the mounted URL. This repository
   deploys it standalone at
   `https://maxstream-pairing.maxstream123.workers.dev/pairing/redeem`, which is
   what `PAIRING_REDEEM_URL` in `android/tvapp/.../AuthRepository.kt` uses. If
   you rename or re-mount the Worker, update that constant.

5. Purge legacy password-bearing codes **once** (they predate this fix):

   ```bash
   FIREBASE_SERVICE_ACCOUNT="$(cat service-account.json)" \
   FIREBASE_DATABASE_URL=https://maxstream-8effc-default-rtdb.firebaseio.com \
   node scripts/purge-device-codes.mjs
   ```

6. Deploy the tightened rules: `firebase deploy --only database`.

Old app builds (≤ 1.8.0) can no longer read pairing codes after the rules
deploy. They must update to pair again.

## Tests

```bash
node --test test
```

The tests use Node's built-in WebCrypto/fetch and mock Google/RTDB responses;
no network access or credentials are required.
