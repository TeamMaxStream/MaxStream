import { handlePairing } from './handler.js';

// Standalone entry point. To use this inside the existing MaxStream Worker,
// import { handlePairing } from './pairing/handler.js' and call it first:
//
//   const pairing = await handlePairing(request, env);
//   if (pairing) return pairing;
//
export default {
  async fetch(request, env) {
    const response = await handlePairing(request, env);
    if (response) return response;
    return new Response('Not found', { status: 404 });
  },
};
