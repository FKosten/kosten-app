// ============================================================
// KOSTEN — Edge Function: limpiar-anuncios
// ============================================================
// Qué hace: la llama el cron una vez por día (job kosten-limpiar-anuncios,
// 6:00 UTC = 3:00 de Argentina) y:
//   - borra los anuncios vencidos (junto con sus likes y comentarios)
//     Y TAMBIÉN sus fotos. Antes el cron borraba solo la fila con SQL y la
//     foto quedaba guardada para siempre, ocupando espacio.
//   - borra fotos "huérfanas": las que quedaron en el bucket sin ningún
//     anuncio que las use (ej. de anuncios borrados antes de este cambio).
//
// Las fotos no se pueden borrar desde SQL (Supabase no lo permite), por eso
// esto vive en una Edge Function que usa la API de Storage.
//
// Cómo se publica: Supabase > Edge Functions > Deploy a new function >
// Via Editor, nombre "limpiar-anuncios", pegar este código y Deploy.
// En Settings, "Verify JWT" DESACTIVADO (la llama la base, no un usuario).
// Es inofensiva si alguien la llama de más: solo borra lo que ya venció.
// ============================================================

import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "anuncios";

Deno.serve(async (_req: Request) => {
  try {
    const supabase = createClient(supabaseUrl, serviceKey);
    // Fecha de hoy en Argentina (YYYY-MM-DD).
    const hoy = new Date().toLocaleDateString("en-CA", { timeZone: "America/Argentina/Buenos_Aires" });

    // 1) Anuncios vencidos: primero sus fotos, después las filas.
    const { data: vencidos, error: errVencidos } = await supabase
      .from("anuncios")
      .select("id, imagen_url")
      .lt("fecha_vigencia_hasta", hoy);
    if (errVencidos) throw new Error("leyendo anuncios vencidos: " + errVencidos.message);

    const fotosVencidas = (vencidos ?? []).map((a) => rutaDeFoto(a.imagen_url)).filter(Boolean) as string[];
    if (fotosVencidas.length > 0) {
      const { error } = await supabase.storage.from(BUCKET).remove(fotosVencidas);
      if (error) console.error("limpiar-anuncios: error borrando fotos vencidas:", error.message);
    }
    if ((vencidos ?? []).length > 0) {
      const { error } = await supabase.from("anuncios").delete().in("id", vencidos!.map((a) => a.id));
      if (error) throw new Error("borrando anuncios vencidos: " + error.message);
    }

    // 2) Fotos huérfanas (más de 1 día de antigüedad, para no tocar una foto
    //    que se está subiendo justo en este momento).
    const { data: vigentes } = await supabase.from("anuncios").select("imagen_url");
    const enUso = new Set((vigentes ?? []).map((a) => rutaDeFoto(a.imagen_url)).filter(Boolean));
    const { data: archivos, error: errLista } = await supabase.storage.from(BUCKET).list("", { limit: 1000 });
    if (errLista) throw new Error("listando fotos: " + errLista.message);
    const haceUnDia = Date.now() - 24 * 60 * 60 * 1000;
    const huerfanas = (archivos ?? [])
      .filter((f) => f.id && !enUso.has(f.name) && new Date(f.created_at).getTime() < haceUnDia)
      .map((f) => f.name);
    if (huerfanas.length > 0) {
      const { error } = await supabase.storage.from(BUCKET).remove(huerfanas);
      if (error) console.error("limpiar-anuncios: error borrando fotos huérfanas:", error.message);
    }

    const resultado = { ok: true, anunciosBorrados: vencidos?.length ?? 0, fotosVencidas: fotosVencidas.length, fotosHuerfanas: huerfanas.length };
    console.log("limpiar-anuncios:", JSON.stringify(resultado));
    return jsonResponse(resultado);
  } catch (e) {
    console.error("limpiar-anuncios: CRASH:", e instanceof Error ? (e.stack || e.message) : String(e));
    return jsonResponse({ error: String(e) }, 500);
  }
});

// De la URL pública de la foto saca la ruta dentro del bucket.
function rutaDeFoto(url: string | null): string | null {
  const marca = `/${BUCKET}/`;
  const i = url ? url.indexOf(marca) : -1;
  return i < 0 ? null : decodeURIComponent(url!.slice(i + marca.length));
}

function jsonResponse(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
