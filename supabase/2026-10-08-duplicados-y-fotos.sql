-- ============================================================
-- KOSTEN — Migración 8/10/2026: evitar duplicados y limpiar fotos
-- ============================================================
-- Qué cambia:
--
-- 1. La base ya no acepta:
--    - dos cuentas con el mismo DNI (se compara solo los números, así
--      "12.345.678" y "12345678" cuentan como el mismo). Importa para
--      que Mercado Pago pueda identificar sin dudas quién pagó.
--    - dos equipos del mismo tipo con el mismo número (ej. dos "Kayak 3").
--    - que un adherente tenga dos ingresos abiertos a la vez.
--    (Antes se chequeaba solo en la pantalla, o en ningún lado.)
--
-- 2. Fotos de anuncios: tope de 5 MB por foto y solo imágenes. (La app
--    ahora las achica antes de subirlas, así que normalmente pesan mucho
--    menos.)
--
-- 3. El cron diario que borra anuncios vencidos ahora llama a la Edge
--    Function limpiar-anuncios, que además borra sus fotos (desde SQL no
--    se pueden borrar archivos). Por eso la función necesita permiso para
--    borrar anuncios.
--
-- Se verificó antes que hoy no hay datos repetidos que choquen con esto.
-- Cómo se aplica: Supabase > SQL Editor > Run. Se puede correr más de una vez.
-- ============================================================


-- 1) Sin duplicados
create unique index if not exists perfiles_dni_unico
  on public.perfiles (regexp_replace(dni, '\D', '', 'g'))
  where coalesce(dni, '') <> '';

create unique index if not exists equipo_numero_unico
  on public.equipo (tipo, coalesce(subtipo, ''), numero);

create unique index if not exists fichajes_un_ingreso_abierto
  on public.fichajes (socio_id)
  where estado = 'en_agua' and socio_id is not null;


-- 2) Fotos de anuncios: máximo 5 MB y solo imágenes
update storage.buckets
set file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic', 'image/heif']
where id = 'anuncios';


-- 3) Limpieza diaria de anuncios vencidos + sus fotos, vía Edge Function
grant delete on public.anuncios to service_role;

select cron.schedule('kosten-limpiar-anuncios', '0 6 * * *', $$
  select net.http_post(
    url := 'https://cmwdkrgshsfrhtduszdq.supabase.co/functions/v1/limpiar-anuncios',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer sb_publishable_ACCXhsFXKdFArbwTxoZl3A_3wxgvf4O'
    ),
    body := '{}'::jsonb
  );
$$);
