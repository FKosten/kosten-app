-- ============================================================
-- KOSTEN — Copia de seguridad de los DATOS
-- ============================================================
-- No modifica nada: solo lee. Devuelve una fila por tabla con todos sus
-- datos (en formato JSON), para guardar una copia en la compu.
--
-- Cómo se usa:
--   1. Supabase > SQL Editor > pegar esto > Run.
--   2. En los resultados: Export > Download CSV.
--   3. Guardar el archivo en la carpeta de backups (NO en este repo:
--      el repo es público y esto tiene datos personales de adherentes).
--
-- La estructura de la base (tablas, reglas, funciones) ya está guardada
-- en supabase/esquema-2026-10-07.sql y las migraciones siguientes.
-- Lo que NO incluye: las contraseñas de las cuentas (Supabase no las
-- deja exportar). Si hubiera que reconstruir todo desde cero, cada uno
-- tendría que volver a crear su contraseña con "¿Olvidaste tu contraseña?".
-- ============================================================

select 'perfiles' as tabla, count(*) as filas, coalesce(jsonb_agg(t), '[]') as datos from public.perfiles t
union all select 'equipo', count(*), coalesce(jsonb_agg(t), '[]') from public.equipo t
union all select 'fichajes', count(*), coalesce(jsonb_agg(t), '[]') from public.fichajes t
union all select 'cuotas', count(*), coalesce(jsonb_agg(t), '[]') from public.cuotas t
union all select 'pagos_sin_asociar', count(*), coalesce(jsonb_agg(t), '[]') from public.pagos_sin_asociar t
union all select 'credenciales', count(*), coalesce(jsonb_agg(t), '[]') from public.credenciales t
union all select 'anuncios', count(*), coalesce(jsonb_agg(t), '[]') from public.anuncios t
union all select 'anuncio_likes', count(*), coalesce(jsonb_agg(t), '[]') from public.anuncio_likes t
union all select 'anuncio_comentarios', count(*), coalesce(jsonb_agg(t), '[]') from public.anuncio_comentarios t
union all select 'terminos_condiciones', count(*), coalesce(jsonb_agg(t), '[]') from public.terminos_condiciones t
union all select 'push_subscriptions', count(*), coalesce(jsonb_agg(t), '[]') from public.push_subscriptions t;
