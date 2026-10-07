-- ============================================================
-- KOSTEN — Foto del estado actual de la base
-- ============================================================
-- No modifica nada: solo LEE cómo está armada la base hoy (tablas,
-- permisos, políticas RLS, funciones, triggers y tareas del cron)
-- para poder guardar una copia en el repo.
--
-- Cómo se usa: pegarlo en Supabase > SQL Editor > Run, y en los
-- resultados usar Export > Download CSV.
-- ============================================================

-- Tipos enumerados
select 0 as orden, 'TIPO ' || t.typname as seccion,
  string_agg(e.enumlabel, ', ' order by e.enumsortorder) as definicion
from pg_type t
join pg_enum e on e.enumtypid = t.oid
where t.typnamespace = 'public'::regnamespace
group by t.typname

union all
-- Tablas y columnas
select 1, 'TABLA ' || c.relname,
  string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod) ||
    case when a.attnotnull then ' not null' else '' end ||
    coalesce(' default ' || pg_get_expr(d.adbin, d.adrelid), ''),
    E'\n' order by a.attnum)
from pg_class c
join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
group by c.relname

union all
-- Claves, únicos, checks y referencias entre tablas
select 2, 'RESTRICCIONES ' || conrelid::regclass::text,
  string_agg(conname || ': ' || pg_get_constraintdef(oid), E'\n' order by conname)
from pg_constraint
where connamespace = 'public'::regnamespace and conrelid <> 0
group by conrelid

union all
-- Índices
select 3, 'INDICES ' || tablename, string_agg(indexdef, E';\n' order by indexname)
from pg_indexes
where schemaname = 'public'
group by tablename

union all
-- RLS prendido/apagado por tabla
select 4, 'RLS ' || relname, case when relrowsecurity then 'activado' else 'DESACTIVADO' end
from pg_class
where relnamespace = 'public'::regnamespace and relkind = 'r'

union all
-- Políticas RLS
select 5, 'POLITICA ' || tablename || ' / ' || policyname,
  'para ' || cmd || ' a ' || array_to_string(roles, ',') ||
  coalesce(E'\nusing: ' || qual, '') ||
  coalesce(E'\nwith check: ' || with_check, '')
from pg_policies
where schemaname = 'public'

union all
-- Permisos (grants) por tabla
select 6, 'PERMISOS ' || table_name,
  string_agg(grantee || ': ' || privilege_type, E'\n' order by grantee, privilege_type)
from information_schema.role_table_grants
where table_schema = 'public' and grantee in ('anon', 'authenticated', 'service_role')
group by table_name

union all
-- Funciones propias (no las de extensiones)
select 7, 'FUNCION ' || p.proname, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  and not exists (select 1 from pg_depend dep where dep.objid = p.oid and dep.deptype = 'e')

union all
-- Triggers (incluye el de auth.users que crea el perfil)
select 8, 'TRIGGER ' || tgrelid::regclass::text || ' / ' || tgname, pg_get_triggerdef(oid)
from pg_trigger
where not tgisinternal
  and tgrelid in (select oid from pg_class
                  where relnamespace in ('public'::regnamespace, 'auth'::regnamespace))

union all
-- Secuencias
select 9, 'SECUENCIA ' || sequencename,
  'empieza en ' || start_value || ', último ' || coalesce(last_value::text, '-')
from pg_sequences
where schemaname = 'public'

union all
-- Tareas programadas (pg_cron)
select 10, 'CRON ' || jobname, schedule || E'\n' || command
from cron.job

order by 1, 2;
