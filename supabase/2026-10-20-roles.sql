-- ============================================================
-- KOSTEN — Migración 20/10/2026: roles admin / comisión / guardia
-- ============================================================
-- Roles (en la base se siguen llamando como antes, para no romper nada):
--
--   'socio'   → Adherente: fichar, bitácora, anuncios, carnet.
--   'guardia' → (NUEVO) quien trabaja en la temporada: todo lo del
--               staff (fichajes en vivo, esporádicos, inventario,
--               credenciales, anuncios, aprobar/rechazar cuentas nuevas,
--               ver Adherentes y Registro), MENOS contribuciones y pagos.
--   'staff'   → Comisión: todo lo del guardia + contribuciones y pagos.
--   'admin'   → Leo: todo lo anterior + dar de baja / habilitar
--               adherentes + cambiar roles.
--
-- Funciones que usan las reglas:
--   is_staff_or_admin()   → guardia, comisión o admin (el "equipo")
--   es_comision_o_admin() → comisión o admin (plata)
--   es_admin()            → solo admin
-- Todas exigen que la cuenta esté activa.
--
-- Cómo se aplica: Supabase > SQL Editor > Run. Se puede correr más de una vez.
-- ============================================================


-- 1) Nuevo rol
alter table public.perfiles drop constraint if exists perfiles_rol_check;
alter table public.perfiles add constraint perfiles_rol_check
  check (rol in ('socio', 'guardia', 'staff', 'admin'));


-- 2) Funciones de permisos
create or replace function public.is_staff_or_admin()
returns boolean
language sql
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from public.perfiles
    where id = auth.uid() and rol in ('guardia', 'staff', 'admin') and estado = 'activo'
  );
$function$;

create or replace function public.es_comision_o_admin()
returns boolean
language sql
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from public.perfiles
    where id = auth.uid() and rol in ('staff', 'admin') and estado = 'activo'
  );
$function$;

create or replace function public.es_admin()
returns boolean
language sql
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from public.perfiles
    where id = auth.uid() and rol = 'admin' and estado = 'activo'
  );
$function$;


-- 3) Contribuciones y pagos: solo comisión y admin
drop policy if exists cuotas_select on public.cuotas;
create policy cuotas_select on public.cuotas for select
  using ((socio_id = auth.uid()) or es_comision_o_admin());
drop policy if exists cuotas_insert on public.cuotas;
create policy cuotas_insert on public.cuotas for insert with check (es_comision_o_admin());
drop policy if exists cuotas_update on public.cuotas;
create policy cuotas_update on public.cuotas for update using (es_comision_o_admin());

drop policy if exists pagos_sin_asociar_select on public.pagos_sin_asociar;
create policy pagos_sin_asociar_select on public.pagos_sin_asociar for select using (es_comision_o_admin());
drop policy if exists pagos_sin_asociar_insert on public.pagos_sin_asociar;
create policy pagos_sin_asociar_insert on public.pagos_sin_asociar for insert with check (es_comision_o_admin());
drop policy if exists pagos_sin_asociar_update on public.pagos_sin_asociar;
create policy pagos_sin_asociar_update on public.pagos_sin_asociar for update using (es_comision_o_admin());

-- En el Registro, los cambios de contribuciones y pagos solo los ve la comisión/admin.
drop policy if exists registro_cambios_select on public.registro_cambios;
create policy registro_cambios_select on public.registro_cambios for select
  using (is_staff_or_admin() and (tabla not in ('cuotas', 'pagos_sin_asociar') or es_comision_o_admin()));


-- 4) Qué puede cambiar cada uno en un perfil
create or replace function public.limitar_edicion_perfil()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  -- Operaciones internas de la base / panel de Supabase, o el admin: sin límites.
  if auth.uid() is null or public.es_admin() then
    return new;
  end if;

  if new.rol is distinct from old.rol then
    raise exception 'Solo el admin puede cambiar roles.';
  end if;

  -- El equipo puede aprobar o rechazar cuentas nuevas (pendiente → activo/inactivo).
  -- Dar de baja o volver a habilitar una cuenta ya resuelta es solo del admin.
  if new.estado is distinct from old.estado
     and not (public.is_staff_or_admin() and old.estado = 'pendiente' and new.estado in ('activo', 'inactivo')) then
    raise exception 'Solo el admin puede dar de baja o habilitar cuentas.';
  end if;

  if new.cuota_vencida is distinct from old.cuota_vencida and not public.es_comision_o_admin() then
    raise exception 'Solo la comisión puede cambiar el estado de la contribución.';
  end if;

  if public.is_staff_or_admin() then
    return new;
  end if;

  -- Adherente editando su propio perfil.
  if (old.nombre is not null and new.nombre is distinct from old.nombre)
     or (old.apellido is not null and new.apellido is distinct from old.apellido)
     or (old.dni is not null and new.dni is distinct from old.dni)
     or (old.email is not null and new.email is distinct from old.email)
     or new.numero_socio is distinct from old.numero_socio
     or new.fecha_alta is distinct from old.fecha_alta
  then
    raise exception 'No podés modificar ese dato de tu perfil.';
  end if;
  return new;
end;
$function$;
