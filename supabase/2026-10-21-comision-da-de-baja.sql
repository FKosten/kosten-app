-- ============================================================
-- KOSTEN — Migración 21/10/2026: la comisión puede dar de baja
-- ============================================================
-- Qué cambia: además del admin, los miembros de la comisión (rol 'staff')
-- pueden dar de baja una cuenta activa, siempre que sea de un adherente
-- o de un guardia. No pueden dar de baja a otro miembro de la comisión,
-- al admin, ni a sí mismos.
--
-- Volver a habilitar una cuenta dada de baja y cambiar roles sigue siendo
-- solo del admin. Aprobar o rechazar cuentas nuevas sigue siendo de todo
-- el equipo (guardia, comisión y admin).
--
-- Cómo se aplica: Supabase > SQL Editor > Run. Se puede correr más de una vez.
-- ============================================================

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

  if new.estado is distinct from old.estado then
    if public.is_staff_or_admin() and old.estado = 'pendiente' and new.estado in ('activo', 'inactivo') then
      null;  -- todo el equipo puede aprobar o rechazar cuentas nuevas
    elsif public.es_comision_o_admin() and old.estado = 'activo' and new.estado = 'inactivo'
          and old.rol in ('socio', 'guardia') and old.id <> auth.uid() then
      null;  -- la comisión puede dar de baja a adherentes y guardias
    else
      raise exception 'No tenés permiso para cambiar el estado de esta cuenta.';
    end if;
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
