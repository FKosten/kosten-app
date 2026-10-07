// ============================================================
// KOSTEN — Edge Function: check-fichajes
// ============================================================
// Qué hace: cada vez que se la llama (la va a llamar sola el cron
// que programamos con SQL, cada 1 minuto), revisa todos los
// fichajes que siguen "en_agua" y:
//   - si ya se pasó la hora estimada de salida y todavía no se
//     avisó, le manda un push de recordatorio al socio.
//   - si pasaron 15 minutos o más de la hora estimada y todavía
//     no se avisó, le manda un push a todo el staff/admin.
//
// El envío de la notificación push está escrito a mano con las
// herramientas nativas de criptografía del servidor (Web Crypto),
// en vez de usar la librería "web-push" de Node — esa librería no
// es del todo compatible con el motor donde corren las funciones
// de Supabase y fallaba silenciosamente al intentar mandar un push
// real. Esta versión no depende de ninguna librería externa para
// esa parte.
//
// Cómo se publica: se pega este código en el panel de Supabase,
// en Edge Functions > check-fichajes > Code, reemplazando todo lo
// que había, y se le da "Deploy". No hace falta terminal.
// ============================================================

import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const vapidPublicKeyB64 = Deno.env.get("VAPID_PUBLIC_KEY")!;
const vapidPrivateKeyB64 = Deno.env.get("VAPID_PRIVATE_KEY")!;
const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:info@fundacionkosten.org";

Deno.serve(async (_req: Request) => {
  console.log("check-fichajes: inicio");
  try {
    const supabase = createClient(supabaseUrl, serviceKey);
    const ahora = new Date();

    const { data: activos, error } = await supabase
      .from("fichajes")
      .select("*")
      .eq("estado", "en_agua");

    if (error) {
      console.error("check-fichajes: error leyendo fichajes:", error.message);
      return jsonResponse({ error: error.message }, 500);
    }

    console.log(`check-fichajes: ${activos?.length ?? 0} fichaje(s) en_agua`);

    let recordatoriosEnviados = 0;
    let alertasEnviadas = 0;
    const detalles: string[] = [];

    for (const f of activos ?? []) {
      const estimada = new Date(f.hora_estimada_salida);
      const minutosVencido = (ahora.getTime() - estimada.getTime()) / 60000;
      console.log(`check-fichajes: fichaje ${f.id} vencido hace ${minutosVencido.toFixed(1)} min (recordatorio_enviado=${f.recordatorio_enviado}, alerta_enviada=${f.alerta_enviada})`);

      if (minutosVencido >= 0 && !f.recordatorio_enviado && !f.es_esporadico && f.socio_id) {
        try {
          console.log(`check-fichajes: enviando recordatorio a socio ${f.socio_id} (fichaje ${f.id})`);
          await enviarPushAUsuario(
            supabase,
            f.socio_id,
            "Kosten Fichaje",
            "Ya pasó tu hora estimada de salida del agua. Fichá tu salida cuando llegues a la costa."
          );
          await supabase.from("fichajes").update({ recordatorio_enviado: true }).eq("id", f.id);
          recordatoriosEnviados++;
          console.log(`check-fichajes: recordatorio OK (fichaje ${f.id})`);
        } catch (e) {
          console.error(`check-fichajes: FALLO recordatorio (fichaje ${f.id}):`, e instanceof Error ? (e.stack || e.message) : String(e));
          detalles.push("recordatorio " + f.id + ": " + String(e));
        }
      }

      if (minutosVencido >= 15 && !f.alerta_enviada) {
        try {
          const nombre = f.es_esporadico ? (f.nombre_esporadico || "Un esporádico") : "Un socio";
          console.log(`check-fichajes: enviando alerta a staff (fichaje ${f.id})`);
          await enviarPushAStaff(
            supabase,
            "Kosten — Alerta de fichaje",
            `${nombre} no fichó su salida (vencida hace más de 15 minutos). Revisá el panel de Staff/Comisión.`
          );
          await supabase.from("fichajes").update({ alerta_enviada: true }).eq("id", f.id);
          alertasEnviadas++;
          console.log(`check-fichajes: alerta OK (fichaje ${f.id})`);
        } catch (e) {
          console.error(`check-fichajes: FALLO alerta (fichaje ${f.id}):`, e instanceof Error ? (e.stack || e.message) : String(e));
          detalles.push("alerta " + f.id + ": " + String(e));
        }
      }
    }

    console.log(`check-fichajes: fin — recordatorios=${recordatoriosEnviados} alertas=${alertasEnviadas}`);

    return jsonResponse({
      ok: true,
      revisados: activos?.length ?? 0,
      recordatoriosEnviados,
      alertasEnviadas,
      detalles,
    });
  } catch (e) {
    console.error("check-fichajes: CRASH general:", e instanceof Error ? (e.stack || e.message) : String(e));
    return jsonResponse({ error: String(e) }, 500);
  }
});

function jsonResponse(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function enviarPushAUsuario(supabase: any, userId: string, title: string, body: string) {
  const { data: subs } = await supabase.from("push_subscriptions").select("*").eq("user_id", userId);
  await enviarATodas(supabase, subs ?? [], title, body);
}

async function enviarPushAStaff(supabase: any, title: string, body: string) {
  const { data: staff } = await supabase.from("perfiles").select("id").in("rol", ["staff", "admin"]);
  const ids = (staff ?? []).map((s: any) => s.id);
  if (ids.length === 0) return;
  const { data: subs } = await supabase.from("push_subscriptions").select("*").in("user_id", ids);
  await enviarATodas(supabase, subs ?? [], title, body);
}

async function enviarATodas(supabase: any, subs: any[], title: string, body: string) {
  for (const s of subs) {
    try {
      await enviarPush(
        { endpoint: s.endpoint, p256dh: s.p256dh, auth: s.auth },
        JSON.stringify({ title, body })
      );
    } catch (err: any) {
      const status = err?.statusCode;
      if (status === 404 || status === 410) {
        await supabase.from("push_subscriptions").delete().eq("id", s.id);
      } else {
        throw err;
      }
    }
  }
}

// =====================================================================
// ENVÍO DE WEB PUSH — implementado a mano con Web Crypto (sin librerías
// externas), siguiendo los estándares RFC 8291 (cifrado del mensaje) y
// RFC 8292 (VAPID).
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

  // PRK = HKDF-Extract(salt = auth_secret, ikm = ecdh_secret)
  const prk = await hmacSha256(uaAuthBytes, sharedSecret);

  // IKM = HKDF-Expand(PRK, "WebPush: info" || 0x00 || ua_public || as_public, 32)
  const keyInfo = concatBytes(
    new TextEncoder().encode("WebPush: info\0"),
    uaPublicBytes,
    asPublicBytes
  );
  const ikm = (await hmacSha256(prk, concatBytes(keyInfo, new Uint8Array([1])))).slice(0, 32);

  const salt = crypto.getRandomValues(new Uint8Array(16));

  // PRK2 = HKDF-Extract(salt, ikm)
  const prk2 = await hmacSha256(salt, ikm);

  const cekInfo = new TextEncoder().encode("Content-Encoding: aes128gcm\0");
  const cek = (await hmacSha256(prk2, concatBytes(cekInfo, new Uint8Array([1])))).slice(0, 16);

  const nonceInfo = new TextEncoder().encode("Content-Encoding: nonce\0");
  const nonce = (await hmacSha256(prk2, concatBytes(nonceInfo, new Uint8Array([1])))).slice(0, 12);

  const plaintext = concatBytes(new TextEncoder().encode(payload), new Uint8Array([2])); // delimitador

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

// Convierte un punto público EC crudo (0x04 || x || y, 65 bytes) a un
// JWK que Web Crypto pueda importar como clave pública ECDH.
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
