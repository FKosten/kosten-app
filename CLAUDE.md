Fundación Kosten — App de gestión (kosten-app)

## Qué es esto
Sistema de gestión para Fundación Kosten, una organización sin fines de lucro de actividades náuticas (SUP y kayak) en Caleta Olivia, Santa Cruz, Argentina. Funciona como club con rol social. Quien lo desarrolla y decide es Leo (integra la comisión directiva de forma simbólica y es instructor de SUP). Leo no es programador: habla en español rioplatense informal, prefiere pasos claros y que se le explique el porqué de las decisiones.

## Terminología (importante)
- Todo el texto visible de la app usa "adherente/s" (no "socio/s") y "contribución/es" (no "cuota/s").
- Los nombres internos de la base y del código siguen usando "socio"/"cuota" (tabla `cuotas`, columna `cuota_vencida`, rol `'socio'`, `pagarCuota()`, Edge Functions `mp-webhook`/`crear-pago-cuota`). No renombrar: implicaría una migración riesgosa de piezas ya desplegadas sin beneficio visible.

## Stack
- Backend: Supabase (Postgres + Auth + Realtime + Edge Functions), región São Paulo. Project URL: `https://cmwdkrgshsfrhtduszdq.supabase.co`. La publishable key está en `index.html` (es pública por diseño).
- Frontend: una sola app web responsive, sin frameworks: `index.html` + `manifest.json` + `sw.js` + logo + íconos. Cliente JS oficial de Supabase desde CDN. PWA instalable (celu) y back office (compu), mismo código con vistas según rol.
- Hosting: Vercel conectado a este repo (`FKosten/kosten-app`, público). URL: `https://kosten-app-murex.vercel.app`. Cada push redeploya solo en 1-2 min.
- Push: Web Push hecho a mano con Web Crypto (RFC 8291 + RFC 8292 VAPID), sin la librería `web-push`.
- Pagos: Mercado Pago (débito automático existente + Checkout Pro para pagos puntuales), vía webhook a una Edge Function.
- Clima: Open-Meteo (gratis, sin key) para datos en vivo; links de salida a Windguru y Wisuki.
- Camino a app nativa (futuro): empaquetar esta misma web con Capacitor.

## Seguridad y secretos (leer antes de tocar nada)
- Este repo es PÚBLICO. Nunca commitear: service role key, `MP_ACCESS_TOKEN`, claves VAPID privadas ni ningún secreto. Esos viven como Secrets de las Edge Functions en Supabase (la service role la inyecta Supabase sola como `SUPABASE_SERVICE_ROLE_KEY`).
- Proyecto Supabase con "Automatically expose new tables" desactivado y "Enable automatic RLS" activado: cada tabla nace cerrada y los permisos se otorgan a propósito.
- Toda tabla nueva que vaya a ser leída/escrita desde una Edge Function necesita `grant ... to service_role;` explícito, si no falla con "permission denied for table ...".
- Las políticas RLS filtran filas, no columnas. Para restringir columnas editables hay que usar un trigger `BEFORE UPDATE` que compare `OLD` vs `NEW`. Ya se usó en `limitar_edicion_perfil()` (el adherente solo edita teléfono y contacto de emergencia) y `limitar_edicion_bitacora()` (solo nota/horarios de sus fichajes cerrados).
- Si una tabla tiene dos columnas que apuntan a la misma tabla (ej. `credenciales.socio_id` y `credenciales.registrado_por` → `perfiles`), los embeds de PostgREST son ambiguos: nombrar la relación, ej. `perfiles!credenciales_socio_id_fkey(nombre,apellido)`.
- Recuperación de contraseña: `resetPasswordForEmail` + listener del evento `PASSWORD_RECOVERY`. Supabase no avisa si el email no existe; si alguien dice que no le llegó, revisar spam y los logs de Authentication.
- Un ícono de PWA ya instalado en un celu no se actualiza solo: hay que borrarlo y reinstalar.
- En iPhone las notificaciones push solo llegan si la PWA está instalada en la pantalla de inicio (limitación de Apple).

## Roles
- Adherente (`socio` en la base): Mi carnet (QR + n.° de adherente), fichaje de ingreso/salida, clima y mareas, bitácora propia, anuncios, estado de su contribución (y pago si está vencida), sus certificados.
- Staff (guardia/instructor): todo lo anterior + fichajes en vivo, cerrar salidas, alta de esporádicos, inventario, marcar contribuciones, cargar anuncios y credenciales.
- Admin (comisión): todo lo anterior + alta/baja/edición de adherentes y configuración.

## Modelo de datos
- perfiles: id (= id de Supabase Auth, se crea por trigger al registrarse), nombre, apellido, dni, fecha_nacimiento, telefono, email, contacto_emergencia, fecha_alta, rol (socio/staff/admin), estado (activo/inactivo), acepta_tyc, fecha_tyc, version_tyc, cuota_vencida, numero_socio (integer unique, secuencia `numero_socio_seq`).
- equipo: id, tipo (embarcacion/remo/chaleco), subtipo (kayak/sup, solo embarcaciones), numero, estado (disponible/en_uso/mantenimiento/de_baja).
- fichajes: id, socio_id (nulo si esporádico), es_esporadico, nombre_esporadico, dni_esporadico, embarcacion_id / remo_id / chaleco_id (nulos si el equipo es propio), hora_ingreso, hora_estimada_salida, hora_salida_real, marcado_por (socio/staff), estado (en_agua/cerrado), recordatorio_enviado, alerta_enviada, nota, cargado_manual.
- push_subscriptions: id, user_id, endpoint, p256dh, auth, created_at (una fila por dispositivo).
- terminos_condiciones: version, texto, fecha_publicacion.
- cuotas: id, socio_id, periodo (YYYY-MM-01), monto, monto_neto, fecha_pago, medio (mercado_pago/manual), mp_payment_id, registrado_por, notas. `unique(socio_id, periodo)` para upsert.
- pagos_sin_asociar: cobros de MP que no se pudieron emparejar (id, mp_payment_id unique, dni_recibido, email_pagador, nombre_pagador, monto, periodo, fecha_pago, estado pendiente/asociado).
- credenciales: id, socio_id, nombre, fecha, vencimiento (opcional), registrado_por, certificado_por, created_at.
- anuncio_likes (unique anuncio_id+socio_id) y anuncio_comentarios: likes y comentarios de adherentes en los anuncios.
- anuncios: titulo, cuerpo, fecha_vigencia_hasta, creado_por, imagen_url. Trigger AFTER INSERT → `pg_net.http_post` → Edge Function `notificar-anuncio`. Se borran solos al vencer (`pg_cron`, job `kosten-limpiar-anuncios`).
- Reglas de negocio: un adherente con la contribución vencida puede fichar, pero solo con equipo propio. Cada ítem (embarcación/remo/chaleco) puede ser del club o propio, de forma independiente.

## Edge Functions
- check-fichajes: la dispara `pg_cron` cada 1 minuto. Si pasó la hora estimada de salida y no se avisó, push de recordatorio al adherente. Si pasaron 15 min o más, push de alerta a staff/admin.
- notificar-anuncio: push a todos los adherentes al publicarse un anuncio (reusa el mismo motor de Web Push).
- mp-webhook (Verify JWT DESACTIVADO): recibe cobros de Mercado Pago. Empareja por `external_reference`, luego DNI, luego email. Si no encuentra, va a `pagos_sin_asociar`.
- crear-pago-cuota (Verify JWT ACTIVADO): genera la preferencia de Checkout Pro del adherente y devuelve el `init_point`.

## Pantallas del frontend
- Login/registro/olvidé contraseña → completar perfil con T&C obligatorios.
- Adherente: pestañas Fichaje (principal, con tarjeta de clima y alerta si el viento supera 40 km/h, `UMBRAL_VIENTO_ALERTA_KMH`), Bitácora, Anuncios, Mi contribución (hoy placeholder "¡Próximamente!"), Mis certificados. Mi carnet es un modal desde el header.
- Staff/Comisión, 5 pestañas: Fichaje (resumen de equipo en uso, fichajes en vivo, esporádicos, historial por fecha), Contribuciones, Inventario, Credenciales, Anuncios.
- Sin Realtime todavía: la pantalla se refresca sola cada 20 segundos.

## Estado
Fases 1, 2 y 3 funcionalmente completas y probadas en producción por Leo (Mac/Safari, iPhone PWA, Android/Chrome): registro, login, perfil + T&C, fichaje, panel de staff, historial, recuperación de contraseña, clima y mareas, carnet con QR, bitácora, push de recordatorio y alerta, inventario y credenciales.

## Pendiente
1. Activar Mercado Pago (próximo paso confirmado). El código de `mp-webhook` y `crear-pago-cuota` TODAVÍA NO EXISTE (confirmado por Leo, oct 2026): hay que escribirlo cuando Leo tenga acceso a la cuenta de MP. `index.html` ya tiene una llamada a `/functions/v1/crear-pago-cuota`. Pasos: (a) Leo consigue el `MP_ACCESS_TOKEN` de la cuenta de la fundación (lo administra el tesorero); (b) deploy de ambas funciones; (c) cargar `MP_ACCESS_TOKEN` como Secret; (d) dar de alta la URL de `mp-webhook` en Mercado Pago Developers, evento "Pagos"; (e) confirmar Verify JWT; (f) probar con un pago y revisar `pagos_sin_asociar`; (g) recién ahí activar el cron de recálculo diario de vencidas (`actualizar_estado_cuotas()`, hoy comentado en `kosten-cuotas.sql` a propósito, para no marcar a todos como vencidos de entrada); (h) reemplazar el placeholder por la pantalla real. Política: débito automático el día 7, reintento de MP unos días después, vencida recién el día 11. Contribución: $15.000/mes.
2. Probar de punta a punta Anuncios: publicar → aparece en staff → aparece en el adherente → llega el push.
3. Verificar: el campo de hora estimada de salida puede mostrarse en formato 12hs AM/PM en algunos navegadores (Safari/Mac) en vez de 24hs (solo visual). También probar en producción el alta de esporádico, si no se hizo.
4. Kiosco (cobro de baño y agua caliente para mate): no arrancado.

## Ideas a futuro (sin fecha)
- "Quién está en el club" (fin social: "veo quién está y decido si voy"): botón manual "Estoy en el club" que se apaga solo a las pocas horas, con una pestaña visible para los adherentes. Se descartó el GPS automático porque la ubicación en segundo plano no anda bien en PWA, sobre todo en iPhone. Con Capacitor se podría automatizar.
- Cámara EZVIZ en vivo para que los adherentes vean el mar. EZVIZ usa su propio Open Platform/SDK con tokens temporales (pedirlos desde una Edge Function, nunca exponer claves en el frontend); hay que revisar los límites del plan. Alternativa: RTSP local + relay a HLS, que suma infraestructura 24/7.
- Avisos de vencimiento de credenciales con push.
- Migrar a app nativa con Capacitor.
- Los T&C hay que redactarlos y que los revise un abogado antes de publicarlos, por tratarse de actividades náuticas con riesgo.

## Cómo trabajar acá
- Cambios al frontend: editar `index.html`/`manifest.json`/`sw.js`, commit y push; Vercel redeploya solo.
- Cambios a la base: dejar el SQL versionado en `supabase/` (idealmente un archivo nuevo por migración) y avisarle a Leo que lo corra en el SQL Editor, salvo que se configure el Supabase CLI.
- Edge Functions: viven en `supabase/functions/<nombre>/`. Hoy se despliegan pegando el código en el dashboard de Supabase.
- Antes de cualquier cambio de seguridad (RLS, grants, triggers) explicarle a Leo qué hace y por qué.
- Esquema completo de la base (tablas, RLS, grants, funciones, triggers, cron) en `supabase/esquema-2026-10-07.sql`, reconstruido desde producción porque los .sql originales por fase quedaron en el chat. Para volver a sacar la foto: `supabase/extraer-esquema.sql`.
