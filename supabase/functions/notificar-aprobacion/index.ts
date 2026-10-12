// ============================================================
// KOSTEN — Edge Function: notificar-aprobacion
// ============================================================
// Qué hace: cuando el staff aprueba una cuenta (el perfil pasa a
// "activo"), la base llama sola a esta función (trigger
// on_perfil_aprobado) y esta le manda una notificación push a esa
// persona avisándole que ya puede entrar.
//
// Solo le llega si activó las notificaciones en su teléfono mientras
// esperaba (la pantalla de "cuenta pendiente" se lo ofrece).
//
// Antes de mandar nada verifica en la base que la cuenta esté realmente
// activa: así, aunque alguien llame a esta función por su cuenta, no
// puede hacer llegar un "te aprobaron" falso a una cuenta pendiente.
//
// Cómo se publica: Supabase > Edge Functions > Deploy a new function >
// Via Editor, nombre "notificar-aprobacion", pegar este código y Deploy.
// En Settings, "Verify JWT" DESACTIVADO (la llama la base, no un usuario).
// Usa los mismos Secrets VAPID que las otras funciones.
// ============================================================

import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const vapidPublicKeyB64 = Deno.env.get("VAPID_PUBLIC_KEY")!;
const vapidPrivateKeyB64 = Deno.env.get("VAPID_PRIVATE_KEY")!;
const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:info@fundacionkosten.org";

Deno.serve(async (req: Request) => {
  try {
    const body = await req.json().catch(() => ({}));
    const userId = body?.user_id;
    if (!userId) {
      return jsonResponse({ error: "Falta user_id" }, 400);
    }

    const supabase = createClient(supabaseUrl, serviceKey);

    const { data: perfil, error: errPerfil } = await supabase
      .from("perfiles")
      .select("id, estado")
      .eq("id", userId)
      .maybeSingle();
    if (errPerfil || !perfil) {
      return jsonResponse({ error: "Perfil no encontrado" }, 404);
    }
    if (perfil.estado !== "activo") {
      return jsonResponse({ ok: true, enviados: 0, motivo: "la cuenta no está activa" });
    }

    const { data: subs, error: errSubs } = await supabase
      .from("push_subscriptions")
      .select("*")
      .eq("user_id", userId);
    if (errSubs) {
      console.error("notificar-aprobacion: error leyendo suscripciones:", errSubs.message);
      return jsonResponse({ error: errSubs.message }, 500);
    }

    let enviados = 0;
    for (const s of subs ?? []) {
      try {
        await enviarPush(
          { endpoint: s.endpoint, p256dh: s.p256dh, auth: s.auth },
          JSON.stringify({ title: "Kosten", body: "¡Tu cuenta fue aprobada! Ya podés entrar a la app." })
        );
        enviados++;
      } catch (err: any) {
        const status = err?.statusCode;
        if (status === 404 || status === 410) {
          await supabase.from("push_subscriptions").delete().eq("id", s.id);
        } else {
          console.error("notificar-aprobacion: fallo enviando a una suscripción:", err instanceof Error ? err.message : String(err));
        }
      }
    }

    console.log(`notificar-aprobacion: enviados ${enviados} de ${subs?.length ?? 0}`);
    return jsonResponse({ ok: true, enviados });
  } catch (e) {
    console.error("notificar-aprobacion: CRASH:", e instanceof Error ? (e.stack || e.message) : String(e));
    return jsonResponse({ error: String(e) }, 500);
  }
});

function jsonResponse(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// =====================================================================
// ENVÍO DE WEB PUSH — idéntico al de check-fichajes y notificar-anuncio (Web Crypto, RFC
// 8291 + RFC 8292), copiado tal cual para que esta función sea
// autocontenida y no dependa de otro archivo.
// =====================================================================

async function enviarPush(
  sub: { endpoint: string; p256dh: string; auth: string },
  payload: string
) {
  const endpointUrl = new URL(sub.endpoint);
  const aud = endpointUrl.origin;

  const authHeader = await construirAuthorizationVapid(aud);
  const { body, headers: cryptoHeaders } = await cifrarPayload(sub, payload);

  const res = await fetch(sub.endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Encoding": "aes128gcm",
      TTL: "60",
      Authorization: authHeader,
      ...cryptoHeaders,
    },
    body,
  });

  if (!res.ok) {
    const texto = await res.text().catch(() => "");
    const e: any = new Error(`push falló (${res.status}): ${texto}`);
    e.statusCode = res.status;
    throw e;
  }
}

async function construirAuthorizationVapid(aud: string): Promise<string> {
  const header = { typ: "JWT", alg: "ES256" };
  const payload = {
    aud,
    exp: Math.floor(Date.now() / 1000) + 12 * 60 * 60,
    sub: vapidSubject,
  };
  const signingInput =
    bytesToB64url(new TextEncoder().encode(JSON.stringify(header))) +
    "." +
    bytesToB64url(new TextEncoder().encode(JSON.stringify(payload)));

  const privateKey = await importVapidPrivateKey();
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    new TextEncoder().encode(signingInput)
  );

  const jwt = signingInput + "." + bytesToB64url(new Uint8Array(signature));
  return `vapid t=${jwt}, k=${vapidPublicKeyB64}`;
}

async function importVapidPrivateKey(): Promise<CryptoKey> {
  const pub = b64urlToBytes(vapidPublicKeyB64); // 65 bytes: 0x04 || x(32) || y(32)
  const x = pub.slice(1, 33);
  const y = pub.slice(33, 65);
  const d = b64urlToBytes(vapidPrivateKeyB64);

  const jwk: JsonWebKey = {
    kty: "EC",
    crv: "P-256",
    x: bytesToB64url(x),
    y: bytesToB64url(y),
    d: bytesToB64url(d),
    ext: true,
  };

  return crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}

async function cifrarPayload(
  sub: { p256dh: string; auth: string },
  payload: string
): Promise<{ body: Uint8Array; headers: Record<string, string> }> {
  const uaPublicBytes = b64urlToBytes(sub.p256dh); // 65 bytes
  const uaAuthBytes = b64urlToBytes(sub.auth); // 16 bytes

  const uaPublicKey = await crypto.subtle.importKey(
    "jwk",
    puntoARawJwk(uaPublicBytes),
    { name: "ECDH", namedCurve: "P-256" },
    true,
    []
  );

  const asKeyPair = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"]
  );
  const asPublicBytes = new Uint8Array(
    await crypto.subtle.exportKey("raw", asKeyPair.publicKey)
  );

  const sharedSecretBits = await crypto.subtle.deriveBits(
    { name: "ECDH", public: uaPublicKey },
    asKeyPair.privateKey,
    256
  );
  const sharedSecret = new Uint8Array(sharedSecretBits);

  const prk = await hmacSha256(uaAuthBytes, sharedSecret);

  const keyInfo = concatBytes(
    new TextEncoder().encode("WebPush: info\0"),
    uaPublicBytes,
    asPublicBytes
  );
  const ikm = (await hmacSha256(prk, concatBytes(keyInfo, new Uint8Array([1])))).slice(0, 32);

  const salt = crypto.getRandomValues(new Uint8Array(16));

  const prk2 = await hmacSha256(salt, ikm);

  const cekInfo = new TextEncoder().encode("Content-Encoding: aes128gcm\0");
  const cek = (await hmacSha256(prk2, concatBytes(cekInfo, new Uint8Array([1])))).slice(0, 16);

  const nonceInfo = new TextEncoder().encode("Content-Encoding: nonce\0");
  const nonce = (await hmacSha256(prk2, concatBytes(nonceInfo, new Uint8Array([1])))).slice(0, 12);

  const plaintext = concatBytes(new TextEncoder().encode(payload), new Uint8Array([2]));

  const aesKey = await crypto.subtle.importKey("raw", cek, { name: "AES-GCM" }, false, ["encrypt"]);
  const ciphertextBuf = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce },
    aesKey,
    plaintext
  );
  const ciphertext = new Uint8Array(ciphertextBuf);

  const recordSize = 4096;
  const header = new Uint8Array(16 + 4 + 1 + asPublicBytes.length);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, recordSize, false);
  header[20] = asPublicBytes.length;
  header.set(asPublicBytes, 21);

  const body = concatBytes(header, ciphertext);

  return { body, headers: {} };
}

function puntoARawJwk(pub: Uint8Array): JsonWebKey {
  const x = pub.slice(1, 33);
  const y = pub.slice(33, 65);
  return { kty: "EC", crv: "P-256", x: bytesToB64url(x), y: bytesToB64url(y), ext: true };
}

async function hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", cryptoKey, data);
  return new Uint8Array(sig);
}

function concatBytes(...arrs: Uint8Array[]): Uint8Array {
  const total = arrs.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const a of arrs) {
    out.set(a, offset);
    offset += a.length;
  }
  return out;
}

function b64urlToBytes(b64url: string): Uint8Array {
  const padding = "=".repeat((4 - (b64url.length % 4)) % 4);
  const base64 = (b64url + padding).replace(/-/g, "+").replace(/_/g, "/");
  const binStr = atob(base64);
  const bytes = new Uint8Array(binStr.length);
  for (let i = 0; i < binStr.length; i++) bytes[i] = binStr.charCodeAt(i);
  return bytes;
}

function bytesToB64url(bytes: Uint8Array): string {
  let binStr = "";
  for (const b of bytes) binStr += String.fromCharCode(b);
  return btoa(binStr).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
