-- ============================================================
-- KOSTEN — Esquema completo de la base (foto al 7/10/2026)
-- ============================================================
-- Reconstruido a partir de lo que hay hoy en Supabase (consulta
-- supabase/extraer-esquema.sql), porque los .sql originales de cada
-- fase quedaron en el chat y no en el repo.
--
-- Para qué sirve: respaldo y referencia. Con esto se puede volver a
-- armar la base desde cero en un proyecto nuevo de Supabase.
-- NO hace falta correrlo en el proyecto actual: ahí ya está todo.
--
-- La única clave que aparece es la publishable (sb_publishable_...),
-- que es pública por diseño (es la misma que usa index.html).
-- ============================================================


-- ------------------------------------------------------------
-- Secuencia del número de adherente
-- ------------------------------------------------------------
create sequence if not exists public.numero_socio_seq start 1;


-- ------------------------------------------------------------
-- Tablas
-- ------------------------------------------------------------
create table public.perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text,
  apellido text,
  dni text,
  fecha_nacimiento date,
  telefono text,
  email text,
  contacto_emergencia text,
  fecha_alta timestamptz default now(),
  rol text not null default 'socio' check (rol in ('socio', 'staff', 'admin')),
  estado text not null default 'activo' check (estado in ('activo', 'inactivo')),
  acepta_tyc boolean not null default false,
  fecha_tyc timestamptz,
  version_tyc text,
  cuota_vencida boolean not null default false,
  numero_socio integer default nextval('public.numero_socio_seq'),
  constraint perfiles_numero_socio_unique unique (numero_socio)
);

create table public.terminos_condiciones (
  id uuid primary key default gen_random_uuid(),
  version text not null,
  texto text not null,
  fecha_publicacion timestamptz not null default now()
);

create table public.equipo (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('embarcacion', 'remo', 'chaleco')),
  subtipo text check (subtipo in ('kayak', 'sup')),
  numero integer not null,
  estado text not null default 'disponible'
    check (estado in ('disponible', 'en_uso', 'mantenimiento', 'de_baja'))
);
create index idx_equipo_tipo_estado on public.equipo (tipo, estado);

create table public.fichajes (
  id uuid primary key default gen_random_uuid(),
  socio_id uuid references public.perfiles(id) on delete set null,
  es_esporadico boolean not null default false,
  nombre_esporadico text,
  dni_esporadico text,
  embarcacion_id uuid references public.equipo(id) on delete set null,
  remo_id uuid references public.equipo(id) on delete set null,
  chaleco_id uuid references public.equipo(id) on delete set null,
  hora_ingreso timestamptz not null default now(),
  hora_estimada_salida timestamptz not null,
  hora_salida_real timestamptz,
  marcado_por text not null check (marcado_por in ('socio', 'staff')),
  estado text not null default 'en_agua' check (estado in ('en_agua', 'cerrado')),
  recordatorio_enviado boolean not null default false,
  alerta_enviada boolean not null default false,
  nota text,
  cargado_manual boolean not null default false
);
create index idx_fichajes_estado on public.fichajes (estado);
create index idx_fichajes_socio on public.fichajes (socio_id);

create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.perfiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);

create table public.cuotas (
  id uuid primary key default gen_random_uuid(),
  socio_id uuid not null references public.perfiles(id) on delete cascade,
  periodo date not null,
  monto numeric,
  monto_neto numeric,
  fecha_pago timestamptz not null default now(),
  medio text not null default 'mercado_pago' check (medio in ('mercado_pago', 'manual')),
  mp_payment_id text,
  registrado_por uuid references public.perfiles(id) on delete set null,
  notas text,
  created_at timestamptz not null default now(),
  unique (socio_id, periodo)
);
create index idx_cuotas_mp_payment_id on public.cuotas (mp_payment_id);

create table public.pagos_sin_asociar (
  id uuid primary key default gen_random_uuid(),
  mp_payment_id text unique,
  dni_recibido text,
  email_pagador text,
  nombre_pagador text,
  monto numeric,
  periodo date,
  fecha_pago timestamptz,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'asociado', 'descartado')),
  asociado_a uuid references public.perfiles(id) on delete set null,
  resuelto_por uuid references public.perfiles(id) on delete set null,
  resuelto_en timestamptz,
  created_at timestamptz not null default now()
);

create table public.credenciales (
  id uuid primary key default gen_random_uuid(),
  socio_id uuid not null references public.perfiles(id) on delete cascade,
  nombre text not null,
  fecha date not null,
  vencimiento date,
  registrado_por uuid references public.perfiles(id) on delete set null,
  created_at timestamptz not null default now(),
  certificado_por text
);
create index idx_credenciales_socio on public.credenciales (socio_id);

create table public.anuncios (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  cuerpo text not null,
  fecha_vigencia_hasta date not null,
  creado_por uuid references public.perfiles(id) on delete set null,
  created_at timestamptz not null default now(),
  imagen_url text
);
create index idx_anuncios_vigencia on public.anuncios (fecha_vigencia_hasta);

create table public.anuncio_likes (
  id uuid primary key default gen_random_uuid(),
  anuncio_id uuid not null references public.anuncios(id) on delete cascade,
  socio_id uuid not null references public.perfiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (anuncio_id, socio_id)
);
create index idx_anuncio_likes_anuncio on public.anuncio_likes (anuncio_id);

create table public.anuncio_comentarios (
  id uuid primary key default gen_random_uuid(),
  anuncio_id uuid not null references public.anuncios(id) on delete cascade,
  socio_id uuid not null references public.perfiles(id) on delete cascade,
  texto text not null,
  created_at timestamptz not null default now()
);
create index idx_anuncio_comentarios_anuncio on public.anuncio_comentarios (anuncio_id);


-- ------------------------------------------------------------
-- Funciones
-- ------------------------------------------------------------

-- ¿El usuario logueado es staff o admin? (la usan casi todas las políticas)
create or replace function public.is_staff_or_admin()
returns boolean
language sql
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from public.perfiles
    where id = auth.uid() and rol in ('staff','admin')
  );
$function$;

-- Crea el perfil automáticamente cuando alguien se registra
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.perfiles (id, email, rol, estado, fecha_alta)
  values (new.id, new.email, 'socio', 'activo', now());
  return new;
end;
$function$;

-- El adherente solo puede editar algunos datos de su perfil
-- (nombre/apellido/dni/email solo la primera vez, cuando están vacíos)
create or replace function public.limitar_edicion_perfil()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if public.is_staff_or_admin() then
    return new;
  end if;
  if (old.nombre is not null and new.nombre is distinct from old.nombre)
     or (old.apellido is not null and new.apellido is distinct from old.apellido)
     or (old.dni is not null and new.dni is distinct from old.dni)
     or (old.email is not null and new.email is distinct from old.email)
     or new.rol is distinct from old.rol
     or new.estado is distinct from old.estado
     or new.numero_socio is distinct from old.numero_socio
     or new.cuota_vencida is distinct from old.cuota_vencida
     or new.fecha_alta is distinct from old.fecha_alta
  then
    raise exception 'No podés modificar ese dato de tu perfil.';
  end if;
  return new;
end;
$function$;

-- El adherente solo puede editar nota/horarios de su bitácora (y cerrar su fichaje)
create or replace function public.limitar_edicion_bitacora()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if public.is_staff_or_admin() then
    return new;
  end if;
  if new.socio_id is distinct from old.socio_id
     or new.embarcacion_id is distinct from old.embarcacion_id
     or new.remo_id is distinct from old.remo_id
     or new.chaleco_id is distinct from old.chaleco_id
     or new.es_esporadico is distinct from old.es_esporadico
     or new.marcado_por is distinct from old.marcado_por
     or new.cargado_manual is distinct from old.cargado_manual
     or (new.estado is distinct from old.estado and not (old.estado = 'en_agua' and new.estado = 'cerrado'))
     or (old.estado = 'en_agua' and (new.nota is distinct from old.nota or new.hora_ingreso is distinct from old.hora_ingreso))
  then
    raise exception 'No podés modificar ese dato de tu bitácora.';
  end if;
  return new;
end;
$function$;

-- Al crear un anuncio, llama a la Edge Function que manda el push
create or replace function public.notificar_nuevo_anuncio()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform net.http_post(
    url := 'https://cmwdkrgshsfrhtduszdq.supabase.co/functions/v1/notificar-anuncio',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer sb_publishable_ACCXhsFXKdFArbwTxoZl3A_3wxgvf4O'
    ),
    body := jsonb_build_object('anuncio_id', new.id)
  );
  return new;
end;
$function$;

-- Recalcula quién tiene la contribución vencida (vencida recién desde el día 11).
-- Su cron todavía NO está activo a propósito: se activa después de Mercado Pago.
create or replace function public.actualizar_estado_cuotas()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  periodo_actual date := date_trunc('month', current_date)::date;
begin
  if extract(day from current_date) < 11 then
    -- Todavía en el margen del mes: nadie queda marcado como vencido.
    update public.perfiles set cuota_vencida = false where rol = 'socio' and cuota_vencida = true;
    return;
  end if;

  update public.perfiles p
  set cuota_vencida = not exists (
    select 1 from public.cuotas c where c.socio_id = p.id and c.periodo = periodo_actual
  )
  where p.rol = 'socio';
end;
$function$;

-- (rls_auto_enable() la crea Supabase sola con la opción "Enable automatic RLS";
-- no hace falta recrearla a mano.)


-- ------------------------------------------------------------
-- Triggers
-- ------------------------------------------------------------
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create trigger on_perfil_update_propio
  before update on public.perfiles
  for each row execute function public.limitar_edicion_perfil();

create trigger on_fichaje_update_bitacora
  before update on public.fichajes
  for each row execute function public.limitar_edicion_bitacora();

create trigger on_anuncio_creado
  after insert on public.anuncios
  for each row execute function public.notificar_nuevo_anuncio();


-- ------------------------------------------------------------
-- RLS (filas que puede ver/tocar cada uno)
-- ------------------------------------------------------------
alter table public.perfiles             enable row level security;
alter table public.terminos_condiciones enable row level security;
alter table public.equipo               enable row level security;
alter table public.fichajes             enable row level security;
alter table public.push_subscriptions   enable row level security;
alter table public.cuotas               enable row level security;
alter table public.pagos_sin_asociar    enable row level security;
alter table public.credenciales         enable row level security;
alter table public.anuncios             enable row level security;
alter table public.anuncio_likes        enable row level security;
alter table public.anuncio_comentarios  enable row level security;

-- perfiles
create policy perfiles_select on public.perfiles for select
  using ((id = auth.uid()) or is_staff_or_admin());
create policy perfiles_update on public.perfiles for update
  using ((id = auth.uid()) or is_staff_or_admin());

-- terminos_condiciones
create policy tyc_select on public.terminos_condiciones for select using (true);
create policy tyc_insert on public.terminos_condiciones for insert
  with check (is_staff_or_admin());

-- equipo
create policy equipo_select on public.equipo for select
  using (auth.role() = 'authenticated');
create policy equipo_insert on public.equipo for insert with check (is_staff_or_admin());
create policy equipo_update on public.equipo for update
  using (auth.role() = 'authenticated');
create policy equipo_delete on public.equipo for delete using (is_staff_or_admin());

-- fichajes
create policy fichajes_select on public.fichajes for select
  using ((socio_id = auth.uid()) or is_staff_or_admin());
create policy fichajes_insert on public.fichajes for insert
  with check ((socio_id = auth.uid()) or is_staff_or_admin());
create policy fichajes_update_bitacora_propia on public.fichajes for update
  using (socio_id = auth.uid()) with check (socio_id = auth.uid());
create policy fichajes_update_staff on public.fichajes for update
  using (is_staff_or_admin());

-- push_subscriptions
create policy push_subscriptions_select on public.push_subscriptions for select
  using ((user_id = auth.uid()) or is_staff_or_admin());
create policy push_subscriptions_insert on public.push_subscriptions for insert
  with check (user_id = auth.uid());
create policy push_subscriptions_update on public.push_subscriptions for update
  using (user_id = auth.uid());
create policy push_subscriptions_delete on public.push_subscriptions for delete
  using (user_id = auth.uid());

-- cuotas
create policy cuotas_select on public.cuotas for select
  using ((socio_id = auth.uid()) or is_staff_or_admin());
create policy cuotas_insert on public.cuotas for insert with check (is_staff_or_admin());
create policy cuotas_update on public.cuotas for update using (is_staff_or_admin());

-- pagos_sin_asociar
create policy pagos_sin_asociar_select on public.pagos_sin_asociar for select
  using (is_staff_or_admin());
create policy pagos_sin_asociar_insert on public.pagos_sin_asociar for insert
  with check (is_staff_or_admin());
create policy pagos_sin_asociar_update on public.pagos_sin_asociar for update
  using (is_staff_or_admin());

-- credenciales
create policy credenciales_select on public.credenciales for select
  using ((socio_id = auth.uid()) or is_staff_or_admin());
create policy credenciales_insert on public.credenciales for insert
  with check (is_staff_or_admin());
create policy credenciales_delete on public.credenciales for delete
  using (is_staff_or_admin());

-- anuncios
create policy anuncios_select on public.anuncios for select
  using (auth.role() = 'authenticated');
create policy anuncios_insert on public.anuncios for insert with check (is_staff_or_admin());
create policy anuncios_delete on public.anuncios for delete using (is_staff_or_admin());

-- anuncio_likes
create policy anuncio_likes_select on public.anuncio_likes for select
  using (auth.role() = 'authenticated');
create policy anuncio_likes_insert_propio on public.anuncio_likes for insert
  with check (socio_id = auth.uid());
create policy anuncio_likes_delete_propio on public.anuncio_likes for delete
  using (socio_id = auth.uid());

-- anuncio_comentarios
create policy anuncio_comentarios_select on public.anuncio_comentarios for select
  using (auth.role() = 'authenticated');
create policy anuncio_comentarios_insert_propio on public.anuncio_comentarios for insert
  with check (socio_id = auth.uid());
create policy anuncio_comentarios_delete on public.anuncio_comentarios for delete
  using ((socio_id = auth.uid()) or is_staff_or_admin());


-- ------------------------------------------------------------
-- Permisos (grants). Como "Automatically expose new tables" está
-- desactivado, cada tabla necesita su grant explícito.
-- ------------------------------------------------------------
grant select                         on public.terminos_condiciones to anon;

grant select, update                 on public.perfiles             to authenticated;
grant select                         on public.terminos_condiciones to authenticated;
grant select, insert, update, delete on public.equipo               to authenticated;
grant select, insert, update         on public.fichajes             to authenticated;
grant select, insert, update, delete on public.push_subscriptions   to authenticated;
grant select, insert, update         on public.cuotas               to authenticated;
grant select, update                 on public.pagos_sin_asociar    to authenticated;
grant select, insert, delete         on public.credenciales         to authenticated;
grant select, insert, delete         on public.anuncios             to authenticated;
grant select, insert, delete         on public.anuncio_likes        to authenticated;
grant select, insert, delete         on public.anuncio_comentarios  to authenticated;

-- Para las Edge Functions
grant select, insert, update, delete on public.perfiles             to service_role;
grant select, insert, update, delete on public.equipo               to service_role;
grant select, insert, update, delete on public.fichajes             to service_role;
grant select, insert, update, delete on public.push_subscriptions   to service_role;
grant select, insert, update, delete on public.cuotas               to service_role;
grant select, insert, update, delete on public.pagos_sin_asociar    to service_role;
grant select, insert, update, delete on public.credenciales         to service_role;
grant select                         on public.anuncios             to service_role;
grant select                         on public.anuncio_likes        to service_role;
grant select                         on public.anuncio_comentarios  to service_role;


-- ------------------------------------------------------------
-- Tareas programadas (pg_cron + pg_net)
-- ------------------------------------------------------------
select cron.schedule('kosten-check-fichajes', '* * * * *', $$
  select net.http_post(
    url := 'https://cmwdkrgshsfrhtduszdq.supabase.co/functions/v1/check-fichajes',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer sb_publishable_ACCXhsFXKdFArbwTxoZl3A_3wxgvf4O'
    ),
    body := '{}'::jsonb
  );
$$);

select cron.schedule('kosten-limpiar-anuncios', '0 6 * * *', $$
  delete from public.anuncios where fecha_vigencia_hasta < current_date;
$$);

-- Pendiente (activar recién después de Mercado Pago):
-- select cron.schedule('kosten-actualizar-cuotas', '0 4 * * *', $$ select public.actualizar_estado_cuotas(); $$);
