-- ============================================================
-- KOSTEN — Migración 12/10/2026: aprobación de cuentas
-- ============================================================
-- Qué cambia:
--
-- 1. Las cuentas nuevas nacen "pendientes". La persona puede completar
--    su perfil y activar las notificaciones, pero NO puede ver ni hacer
--    nada más hasta que alguien del staff la apruebe (pestaña Staff >
--    "Cuentas pendientes"). Las cuentas que ya existen quedan activas.
--
-- 2. "Inactivo" ahora bloquea de verdad: una cuenta rechazada o dada de
--    baja no puede leer ni escribir nada (antes era solo una etiqueta).
--    Lo controla la base, tabla por tabla, no solo la pantalla. También
--    un staff/admin dado de baja pierde sus permisos.
--
-- 3. Cuando una cuenta pasa a "activo", la base avisa a la Edge Function
--    notificar-aprobacion, que le manda una notificación push a esa
--    persona (si las tiene activadas).
--
-- Los códigos de alta (codigos_alta) siguen existiendo y apagados
-- mientras esa tabla esté vacía.
--
-- Cómo se aplica: Supabase > SQL Editor > Run. Se puede correr más de una vez.
-- ============================================================


-- ------------------------------------------------------------
-- 1) Nuevo estado "pendiente"
-- ------------------------------------------------------------
alter table public.perfiles drop constraint if exists perfiles_estado_check;
alter table public.perfiles add constraint perfiles_estado_check
  check (estado in ('pendiente', 'activo', 'inactivo'));
alter table public.perfiles alter column estado set default 'pendiente';

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

  -- Nace pendiente: la comisión/staff la aprueba desde la app.
  insert into public.perfiles (id, email, rol, estado, fecha_alta, dni)
  values (new.id, new.email, 'socio', 'pendiente', now(), v_dni);
  return new;
end;
$function$;

-- Si algún día se cargan códigos, que el DNI pueda faltar (lo escribe el socio).
alter table public.codigos_alta alter column dni drop not null;


-- ------------------------------------------------------------
-- 2) Solo las cuentas activas pueden usar la app
-- ------------------------------------------------------------
create or replace function public.cuenta_activa()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from public.perfiles
    where id = auth.uid() and estado = 'activo'
  );
$function$;

-- Staff/admin solo cuentan como tales si su cuenta está activa.
create or replace function public.is_staff_or_admin()
returns boolean
language sql
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from public.perfiles
    where id = auth.uid() and rol in ('staff','admin') and estado = 'activo'
  );
$function$;

-- Candado extra en cada tabla: además de las reglas que ya tenía, la cuenta
-- tiene que estar activa. (perfiles, terminos_condiciones y
-- push_subscriptions quedan afuera a propósito: una cuenta pendiente
-- necesita completar su perfil, leer los T&C y activar las notificaciones
-- para enterarse cuando la aprueben.)
do $$
declare
  t text;
begin
  foreach t in array array['equipo', 'fichajes', 'cuotas', 'pagos_sin_asociar', 'credenciales',
                           'anuncios', 'anuncio_likes', 'anuncio_comentarios',
                           'registro_cambios', 'codigos_alta']
  loop
    execute format('drop policy if exists solo_cuentas_activas on public.%I', t);
    execute format('create policy solo_cuentas_activas on public.%I as restrictive for all
                    using (public.cuenta_activa()) with check (public.cuenta_activa())', t);
  end loop;
end;
$$;


-- ------------------------------------------------------------
-- 3) Aviso al aprobar una cuenta
-- ------------------------------------------------------------
create or replace function public.notificar_cuenta_aprobada()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if old.estado is distinct from 'activo' and new.estado = 'activo' then
    perform net.http_post(
      url := 'https://cmwdkrgshsfrhtduszdq.supabase.co/functions/v1/notificar-aprobacion',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer sb_publishable_ACCXhsFXKdFArbwTxoZl3A_3wxgvf4O'
      ),
      body := jsonb_build_object('user_id', new.id)
    );
  end if;
  return new;
end;
$function$;

drop trigger if exists on_perfil_aprobado on public.perfiles;
create trigger on_perfil_aprobado
  after update of estado on public.perfiles
  for each row execute function public.notificar_cuenta_aprobada();
