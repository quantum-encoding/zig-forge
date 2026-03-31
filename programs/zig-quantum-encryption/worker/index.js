// Cloudflare Worker: Post-Quantum Cryptography API
// Static WASM import (required by Workers — no WebAssembly.compile at runtime)
import wasm from "./quantum_vault.wasm";
import { QuantumVault } from "./quantum-vault.js";

const qv = new QuantumVault(wasm);

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function b64(bytes) {
  return btoa(String.fromCharCode(...bytes));
}

function unb64(str) {
  return new Uint8Array([...atob(str)].map((c) => c.charCodeAt(0)));
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;

    try {
      // ─── ML-KEM-768 Key Exchange ──────────────────────────────

      if (path === "/mlkem/keygen" && request.method === "POST") {
        const { ek, dk } = qv.mlKemKeygen();
        return json({ ek: b64(ek), dk: b64(dk) });
      }

      if (path === "/mlkem/encaps" && request.method === "POST") {
        const { ek } = await request.json();
        const { sharedSecret, ciphertext } = qv.mlKemEncaps(unb64(ek));
        return json({ shared_secret: b64(sharedSecret), ciphertext: b64(ciphertext) });
      }

      if (path === "/mlkem/decaps" && request.method === "POST") {
        const { dk, ciphertext } = await request.json();
        const ss = qv.mlKemDecaps(unb64(dk), unb64(ciphertext));
        return json({ shared_secret: b64(ss) });
      }

      // ─── ML-DSA-65 Signatures ─────────────────────────────────

      if (path === "/mldsa/keygen" && request.method === "POST") {
        const { pk, sk } = qv.mlDsaKeygen();
        return json({ pk: b64(pk), sk: b64(sk) });
      }

      if (path === "/mldsa/sign" && request.method === "POST") {
        const { sk, message } = await request.json();
        const sig = qv.mlDsaSign(unb64(sk), message);
        return json({ signature: b64(sig) });
      }

      if (path === "/mldsa/verify" && request.method === "POST") {
        const { pk, message, signature } = await request.json();
        const valid = qv.mlDsaVerify(unb64(pk), message, unb64(signature));
        return json({ valid });
      }

      // ─── Hybrid ML-KEM+X25519 ─────────────────────────────────

      if (path === "/hybrid/keygen" && request.method === "POST") {
        const { ek, dk } = qv.hybridKeygen();
        return json({ ek: b64(ek), dk: b64(dk) });
      }

      if (path === "/hybrid/encaps" && request.method === "POST") {
        const { ek } = await request.json();
        const { sharedSecret, ciphertext } = qv.hybridEncaps(unb64(ek));
        return json({ shared_secret: b64(sharedSecret), ciphertext: b64(ciphertext) });
      }

      if (path === "/hybrid/decaps" && request.method === "POST") {
        const { dk, ciphertext } = await request.json();
        const ss = qv.hybridDecaps(unb64(dk), unb64(ciphertext));
        return json({ shared_secret: b64(ss) });
      }

      // ─── Info ──────────────────────────────────────────────────

      if (path === "/" || path === "/version") {
        return json({
          name: "quantum-vault-worker",
          version: qv.version(),
          algorithms: ["ML-KEM-768", "ML-DSA-65", "Hybrid-ML-KEM-X25519"],
          endpoints: [
            "POST /mlkem/keygen",
            "POST /mlkem/encaps",
            "POST /mlkem/decaps",
            "POST /mldsa/keygen",
            "POST /mldsa/sign",
            "POST /mldsa/verify",
            "POST /hybrid/keygen",
            "POST /hybrid/encaps",
            "POST /hybrid/decaps",
          ],
        });
      }

      return json({ error: "not_found" }, 404);
    } catch (e) {
      return json({ error: e.message }, 500);
    }
  },
};
