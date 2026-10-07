-- ============================================================
-- KOSTEN — Migración 8/10/2026 (b): códigos de alta + registro de cambios
-- ============================================================
--
-- 1. CÓDIGOS DE ALTA
--    Para crear una cuenta, además de mail y contraseña, hay que poner un
--    código sacado del listado de socios activos (tabla codigos_alta, una
--    fila por socio: código + DNI). Cada código sirve UNA sola vez, y el
--    DNI de esa fila queda cargado en el perfil de la cuenta nueva (y ya
--    no se puede cambiar), así cada cuenta queda atada a un socio real.
--    La base lo verifica al crear la cuenta: no se puede saltear desde
--    la pantalla.
--
--    IMPORTANTE: mientras la tabla codigos_alta esté VACÍA, el alta sigue
--    funcionando como hasta ahora (sin código). Se activa sola en cuanto
--    se cargue el listado.
--
-- 2. REGISTRO DE CAMBIOS
--    Cada alta, modificación o baja en las tablas principales queda
--    anotada en registro_cambios: quién, cuándo, qué tabla, y qué cambió
--    (antes → después). Lo hace la base sola, así queda registrado
--    cualquier cambio, venga de la app o de donde sea. Nadie puede
--    editar ni borrar ese registro desde la app; solo verlo (staff/admin).
--    No se registra lo que la base hace sola como consecuencia de otro
--    cambio (ej. el kayak que pasa a "en uso" al fichar).
--
-- Cómo se aplica: Supabase > SQL Editor > Run. Se puede correr más de una vez.
-- ============================================================


-- ------------------------------------------------------------
-- 1) Códigos de alta
-- ------------------------------------------------------------
create table if not exists public.codigos_alta (
  codigo text primary key,                 -- se guarda en MAYÚSCULAS, sin espacios
  dni text not null,
  nombre text,                             -- opcional, solo para identificarlo
  usado_por uuid references auth.users(id) on delete set null,
  usado_en timestamptz,
  created_at timestamptz not null default now()
);
alter table public.codigos_alta enable row level security;
drop policy if exists codigos_alta_select on public.codigos_alta;
create policy codigos_alta_select on public.codigos_alta for select using (is_staff_or_admin());
grant select on public.codigos_alta to authenticated;

-- ¿Hace falta código para registrarse? (sí, en cuanto haya códigos cargados)
create or replace function public.alta_requiere_codigo()
returns boolean
language sql
security definer
set search_path to 'public'
as $function$
  select exists (select 1 from public.codigos_alta);
$function$;

-- La pantalla de registro consulta si el código es válido antes de crear la
-- cuenta, para poder mostrar un mensaje claro. Solo responde sí/no: no
-- revela el DNI ni ningún otro dato.
create or replace function public.validar_codigo_alta(p_codigo text)
returns boolean
language sql
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from public.codigos_alta
    where codigo = upper(regexp_replace(coalesce(p_codigo, ''), '\s', '', 'g'))
      and usado_por is null
  );
$function$;

grant execute on function public.alta_requiere_codigo() to anon, authenticated;
grant execute on function public.validar_codigo_alta(text) to anon, authenticated;

-- Al registrarse: si hay códigos cargados, exige uno válido, lo marca como
-- usado y copia el DNI al perfil.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_codigo text := upper(regexp_replace(coalesce(new.raw_user_meta_data->>'codigo', ''), '\s', '', 'g'));
  v_dni text;
begin
  if public.alta_requiere_codigo() then
    update public.codigos_alta
    set usado_por = new.id, usado_en = now()
    where codigo = v_codigo and usado_por is null
    returning dni into v_dni;
    if not found then
      raise exception 'Código de alta inválido o ya usado';
    end if;
  end if;

  insert into public.perfiles (id, email, rol, estado, fecha_alta, dni)
  values (new.id, new.email, 'socio', 'activo', now(), v_dni);
  return new;
end;
$function$;


-- ------------------------------------------------------------
-- 2) Registro de cambios
-- ------------------------------------------------------------
create table if not exists public.registro_cambios (
  id bigint generated always as identity primary key,
  creado_en timestamptz not null default now(),
  usuario_id uuid,          -- quién lo hizo (vacío = la base sola, ej. tareas automáticas)
  usuario_nombre text,      -- su nombre en ese momento
  tabla text not null,
  accion text not null check (accion in ('alta', 'modificacion', 'baja')),
  registro_id text,
  fila jsonb,               -- cómo quedó el registro (o cómo era, si se borró)
  antes jsonb,              -- en modificaciones: solo los campos que cambiaron, antes...
  despues jsonb             -- ...y después
);
create index if not exists idx_registro_cambios_fecha on public.registro_cambios (creado_en desc);

alter table public.registro_cambios enable row level security;
drop policy if exists registro_cambios_select on public.registro_cambios;
create policy registro_cambios_select on public.registro_cambios for select using (is_staff_or_admin());
-- Solo lectura: nadie tiene permiso de insertar, editar ni borrar desde la app.
grant select on public.registro_cambios to authenticated;

create or replace function public.registrar_cambio()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_accion text;
  v_fila jsonb;
  v_antes jsonb;
  v_despues jsonb;
  v_nombre text;
  k text;
  -- Marcas internas de los avisos automáticos: no aportan al registro.
  ignorar text[] := array['recordatorio_enviado', 'alerta_enviada'];
begin
  -- Lo que la base hace sola como consecuencia de otro cambio no se anota
  -- aparte (ej. el equipo al fichar, o los likes al borrar un anuncio).
  if pg_trigger_depth() > 1 then
    return null;
  end if;

  if tg_op = 'INSERT' then
    v_accion := 'alta';
    v_fila := to_jsonb(new);
  elsif tg_op = 'DELETE' then
    v_accion := 'baja';
    v_fila := to_jsonb(old);
  else
    v_accion := 'modificacion';
    v_fila := to_jsonb(new);
    v_antes := '{}'::jsonb;
    v_despues := '{}'::jsonb;
    for k in select jsonb_object_keys(v_fila) loop
      if not (k = any(ignorar)) and (to_jsonb(old) -> k) is distinct from (v_fila -> k) then
        v_antes := v_antes || jsonb_build_object(k, to_jsonb(old) -> k);
        v_despues := v_despues || jsonb_build_object(k, v_fila -> k);
      end if;
    end loop;
    if v_despues = '{}'::jsonb then
      return null;  -- no cambió nada que valga la pena registrar
    end if;
  end if;

  select nullif(trim(coalesce(nombre, '') || ' ' || coalesce(apellido, '')), '')
  into v_nombre
  from public.perfiles where id = auth.uid();

  insert into public.registro_cambios (usuario_id, usuario_nombre, tabla, accion, registro_id, fila, antes, despues)
  values (auth.uid(), v_nombre, tg_table_name, v_accion, v_fila ->> 'id', v_fila, v_antes, v_despues);
  return null;
end;
$function$;

do $$
declare
  t text;
begin
  foreach t in array array['perfiles', 'equipo', 'fichajes', 'cuotas', 'pagos_sin_asociar',
                           'credenciales', 'anuncios', 'anuncio_comentarios', 'terminos_condiciones']
  loop
    execute format('drop trigger if exists zz_registro_cambios on public.%I', t);
    execute format('create trigger zz_registro_cambios after insert or update or delete on public.%I
                    for each row execute function public.registrar_cambio()', t);
  end loop;
end;
$$;
