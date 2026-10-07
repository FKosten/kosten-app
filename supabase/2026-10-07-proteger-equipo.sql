-- ============================================================
-- KOSTEN — Migración 7/10/2026: proteger el inventario y la regla
-- de "contribución vencida → solo equipo propio"
-- ============================================================
-- Qué cambia:
--
-- 1. Hasta ahora, cuando un adherente fichaba, era la PANTALLA la que
--    marcaba el kayak/remo/chaleco como "en uso" (y como "disponible"
--    al salir). Para eso, la base tenía que dejar que cualquier
--    adherente edite el inventario, y alguien con conocimientos
--    técnicos podía cambiar cualquier equipo (darlo de baja, cambiarle
--    el número, etc.).
--    Ahora eso lo hace la BASE sola, con un trigger sobre fichajes, y
--    editar el inventario queda solo para staff/admin.
--
-- 2. La regla "con la contribución vencida solo se ficha con equipo
--    propio" la controlaba solo la pantalla. Ahora también la controla
--    la base, así no se puede saltear. De paso, la base verifica que el
--    equipo elegido siga disponible (evita que dos personas fichen con
--    el mismo kayak al mismo tiempo).
--
-- Staff/admin no tienen ninguna de estas restricciones.
--
-- Cómo se aplica: pegar todo en Supabase > SQL Editor > Run.
-- Se puede correr más de una vez sin problema.
-- ============================================================


-- ------------------------------------------------------------
-- 1) Antes de crear un fichaje: validar vencida y disponibilidad
-- ------------------------------------------------------------
create or replace function public.validar_fichaje_nuevo()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  vencida boolean;
  ocupados integer;
begin
  if public.is_staff_or_admin() then
    return new;
  end if;
  -- Todo el equipo es propio: no hay nada que validar.
  if new.embarcacion_id is null and new.remo_id is null and new.chaleco_id is null then
    return new;
  end if;

  select cuota_vencida into vencida from public.perfiles where id = auth.uid();
  if coalesce(vencida, false) then
    raise exception 'Tu contribución está vencida — solo podés fichar con equipo propio.';
  end if;

  if new.estado = 'en_agua' then
    select count(*) into ocupados
    from public.equipo
    where id in (new.embarcacion_id, new.remo_id, new.chaleco_id)
      and estado <> 'disponible';
    if ocupados > 0 then
      raise exception 'Parte del equipo que elegiste ya no está disponible. Actualizá la pantalla y elegí otro.';
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists on_fichaje_validar on public.fichajes;
create trigger on_fichaje_validar
  before insert on public.fichajes
  for each row execute function public.validar_fichaje_nuevo();


-- ------------------------------------------------------------
-- 2) Al entrar/salir del agua: la base marca el equipo sola
-- ------------------------------------------------------------
-- Solo cambia equipo que esté "disponible" ↔ "en uso": si staff puso
-- algo en mantenimiento o de baja mientras estaba en el agua, se respeta.
create or replace function public.sincronizar_estado_equipo()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if tg_op = 'INSERT' and new.estado = 'en_agua' then
    update public.equipo set estado = 'en_uso'
    where id in (new.embarcacion_id, new.remo_id, new.chaleco_id)
      and estado = 'disponible';
  elsif tg_op = 'UPDATE' and old.estado = 'en_agua' and new.estado = 'cerrado' then
    update public.equipo set estado = 'disponible'
    where id in (new.embarcacion_id, new.remo_id, new.chaleco_id)
      and estado = 'en_uso';
  end if;
  return null;
end;
$function$;

drop trigger if exists on_fichaje_equipo on public.fichajes;
create trigger on_fichaje_equipo
  after insert or update of estado on public.fichajes
  for each row execute function public.sincronizar_estado_equipo();


-- ------------------------------------------------------------
-- 3) Editar el inventario: solo staff/admin
-- ------------------------------------------------------------
drop policy if exists equipo_update on public.equipo;
create policy equipo_update on public.equipo for update
  using (is_staff_or_admin())
  with check (is_staff_or_admin());
