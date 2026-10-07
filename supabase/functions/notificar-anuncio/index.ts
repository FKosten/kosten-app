// ============================================================
// KOSTEN — Edge Function: notificar-anuncio
// ============================================================
// Qué hace: cuando staff/comisión carga un anuncio nuevo, la base de
// datos llama sola a esta función (ver el trigger en kosten-fase3.sql)
// y esta le manda una notificación push a todos los que tengan las
// notificaciones activadas, avisando que hay una novedad.
// El texto de la notificación es siempre el mismo (no el del anuncio):
// así no se corta ni falla con anuncios largos, y el detalle se lee en la app.
//
// Usa exactamente el mismo motor de envío de Web Push (Web Crypto,
// sin librerías externas) que ya está funcionando en check-fichajes.
//
// Cómo se publica: se pega este código en el panel de Supabase, en
// Edge Functions > notificar-anuncio > Code, y se le da "Deploy".
// Usa los mismos Secrets que check-fichajes (VAPID_PUBLIC_KEY,
// VAPID_PRIVATE_KEY, VAPID_SUBJECT) — como son del proyecto entero,
// no hace falta cargarlos de nuevo.
// "Verify JWT" en Settings tiene que quedar DESACTIVADO acá, igual
// que en check-fichajes y en mp-webhook, porque quien llama a esta
// función es la propia base de datos, no un socio con sesión iniciada.
// ============================================================

import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const vapidPublicKeyB64 = Deno.env.get("VAPID_PUBLIC_KEY")!;
const vapidPrivateKeyB64 = Deno.env.get("VAPID_PRIVATE_KEY")!;
const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:info@fundacionkosten.org";

Deno.serve(async (req: Request) => {
  console.log("notificar-anuncio: inicio");
  try {
    const body = await req.json().catch(() => ({}));
    const anuncioId = body?.anuncio_id;
    if (!anuncioId) {
      return jsonResponse({ error: "Falta anuncio_id" }, 400);
    }

    const supabase = createClient(supabaseUrl, serviceKey);

    const { data: anuncio, error: errAnuncio } = await supabase
      .from("anuncios")
      .select("id")
      .eq("id", anuncioId)
      .maybeSingle();

    if (errAnuncio || !anuncio) {
      console.error("notificar-anuncio: no se encontró el anuncio", anuncioId, errAnuncio?.message);
      return jsonResponse({ error: "Anuncio no encontrado" }, 404);
    }

    const { data: subs, error: errSubs } = await supabase.from("push_subscriptions").select("*");
    if (errSubs) {
      console.error("notificar-anuncio: error leyendo suscripciones:", errSubs.message);
      return jsonResponse({ error: errSubs.message }, 500);
    }

    let enviados = 0;
    for (const s of subs ?? []) {
      try {
        await enviarPush(
          { endpoint: s.endpoint, p256dh: s.p256dh, auth: s.auth },
          JSON.stringify({ title: "Kosten", body: "¡Hay un anuncio nuevo de Kosten!" })
        );
        enviados++;
      } catch (err: any) {
        const status = err?.statusCode;
        if (status === 404 || status === 410) {
          await supabase.from("push_subscriptions").delete().eq("id", s.id);
        } else {
          console.error("notificar-anuncio: fallo enviando a una suscripción:", err);
        }
      }
    }

    console.log(`notificar-anuncio: enviados ${enviados} de ${subs?.length ?? 0}`);
    return jsonResponse({ ok: true, enviados });
  } catch (e) {
    console.error("notificar-anuncio: CRASH:", e instanceof Error ? (e.stack || e.message) : String(e));
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
// ENVÍO DE WEB PUSH — idéntico al de check-fichajes (Web Crypto, RFC
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
