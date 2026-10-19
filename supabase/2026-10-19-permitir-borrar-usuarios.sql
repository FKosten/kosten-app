-- ============================================================
-- KOSTEN — Migración 19/10/2026: poder borrar usuarios desde Supabase
-- ============================================================
-- Problema: al borrar un usuario en Authentication > Users daba error.
-- Al borrarlo, la base desvincula sus fichajes (socio_id pasa a vacío,
-- para conservar el historial sin nombre). Pero el trigger que protege
-- la bitácora (limitar_edicion_bitacora) frenaba ese cambio, porque no
-- distinguía entre un adherente editando y una operación de la base.
--
-- Arreglo: las protecciones de bitácora y de perfil se aplican solo a
-- los usuarios de la app (con sesión iniciada). Las operaciones que
-- hace Supabase por dentro (borrados en cascada, panel de administración,
-- Edge Functions) no tienen sesión de usuario y quedan afuera. Los
-- adherentes siguen igual de limitados que antes.
--
-- Cómo se aplica: Supabase > SQL Editor > Run. Se puede correr más de una vez.
-- ============================================================

create or replace function public.limitar_edicion_bitacora()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  -- Sin usuario de la app (borrado en cascada, panel de Supabase,
  -- Edge Functions) o staff/admin: sin restricciones.
  if auth.uid() is null or public.is_staff_or_admin() then
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

create or replace function public.limitar_edicion_perfil()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is null or public.is_staff_or_admin() then
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
