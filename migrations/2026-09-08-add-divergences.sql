-- ════════════════════════════════════════════════════════════════════
-- Divergence registry: client-program DB objects excluded from the
-- HTLand <-> RCD Land SQL compare.
--
-- SCOPE. Every object_name stored here names an object in a *client
-- program database* (SQL Server). Nothing in this table describes the
-- Supabase schema behind this tracker — the table itself is the only
-- Supabase change.
--
-- WHY A TABLE. Items are work records: they get completed, reworked and
-- deleted, and their activity rows cascade away with them. A divergence
-- outlives all of that — it stands until someone deliberately ports the
-- enhancement to the other client. If the exclusion list were derived
-- from a flag on items, deleting an item would silently shrink the list
-- and the next compare would quietly revert the enhancement. That is
-- precisely the failure this table exists to prevent.
--
-- RUN THIS BEFORE DEPLOYING the matching index.html. Section 0 is a
-- preflight you must read; 1-4 are required; 5 verifies.
-- ════════════════════════════════════════════════════════════════════

-- ── 0. PREFLIGHT — read the output before running anything below ────
-- The two foreign keys below depend on these types. items.id is an
-- integer/bigint identity; members.id is a uuid (the frontend compares
-- member ids as strings and item ids with a + coercion). A bigint column
-- may reference an integer PK — int4 and int8 share an operator family —
-- but created_by must match members.id exactly or the FK is rejected.
--
-- Also confirm is_member() exists: it is the whole authorization model.
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name in ('items','members')
  and column_name = 'id';

select proname, prosecdef, pg_get_function_identity_arguments(oid) as args
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and proname = 'is_member';

-- ── 1. the table ────────────────────────────────────────────────────
create table if not exists public.divergences (
  id           bigint generated always as identity primary key,

  -- Which client's copy is the enhanced one. This is *metadata about the
  -- pair*, not a scoping key: a compare between the two databases takes
  -- one combined ignore list, so the frontend's Copy button deliberately
  -- emits both clients' rows regardless of the active client filter.
  client       text not null default 'htland',

  -- Spelled the way the compare tool names it — prefer schema-qualified
  -- (dbo.sp_compute_charges) so the line can be pasted straight in.
  object_name  text not null,

  -- PROC / TABLE / VIEW / FUNC / TRIG / MENUITEM. Cosmetic: it drives a
  -- badge and
  -- nothing else, and is parsed from the PREFIX: convention already used
  -- by items.sql_objects. Never required.
  kind         text,

  -- The point of the row. Without it, a future reader cannot tell an
  -- intended enhancement from drift someone gave up on.
  reason       text not null,

  -- Optional originating board item. ON DELETE SET NULL, never cascade:
  -- the divergence has to survive the item, or the list silently shrinks.
  item_id      bigint references public.items(id) on delete set null,

  -- Text snapshot of that item, so the origin is still readable after the
  -- item is gone and item_id has been nulled out.
  item_label   text,

  -- active    -> excluded from the compare.
  -- converged -> the enhancement was ported to the other client and the
  --              object is back under comparison. Converged rows are kept
  --              rather than deleted: the record of why the two databases
  --              once differed is the useful part.
  status       text not null default 'active',
  converged_at date,

  -- members.id, NOT an auth uid — see the members note in CLAUDE.md.
  created_by   uuid references public.members(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- A CHECK rather than an enum, for the reason recorded in CLAUDE.md:
-- unused enum values can never be dropped. Keep this in step with the
-- CLIENTS const in index.html and with items_client_check — there are now
-- THREE places the client vocabulary has to agree.
alter table public.divergences
  drop constraint if exists divergences_client_check;
alter table public.divergences
  add constraint divergences_client_check check (client in ('htland','rcd_land'));

alter table public.divergences
  drop constraint if exists divergences_status_check;
alter table public.divergences
  add constraint divergences_status_check check (status in ('active','converged'));

-- Case-insensitive because SQL Server object names are. PARTIAL on
-- status='active' on purpose: converged rows stay as history, and the
-- same object is free to diverge again later without colliding with them.
drop index if exists public.divergences_active_key;
create unique index divergences_active_key
  on public.divergences (client, lower(object_name))
  where status = 'active';

create index if not exists divergences_item_id_idx
  on public.divergences (item_id);

-- ── 2. updated_at ───────────────────────────────────────────────────
-- Deliberately NOT a generically named helper: a set_updated_at() may
-- already exist for items with different behaviour, and create or replace
-- would silently redefine it under that table's feet.
create or replace function public.divergences_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists divergences_touch_updated_at on public.divergences;
create trigger divergences_touch_updated_at
  before update on public.divergences
  for each row execute function public.divergences_touch_updated_at();

-- ── 3. row level security ───────────────────────────────────────────
-- Same shape as items. RLS is the entire authorization model: client is a
-- categorization, not a permission boundary, so every policy gates only
-- on is_member().
alter table public.divergences enable row level security;

drop policy if exists divergences_select on public.divergences;
create policy divergences_select on public.divergences
  for select using (public.is_member());

drop policy if exists divergences_insert on public.divergences;
create policy divergences_insert on public.divergences
  for insert with check (public.is_member());

drop policy if exists divergences_update on public.divergences;
create policy divergences_update on public.divergences
  for update using (public.is_member()) with check (public.is_member());

drop policy if exists divergences_delete on public.divergences;
create policy divergences_delete on public.divergences
  for delete using (public.is_member());

-- ── 4. realtime ─────────────────────────────────────────────────────
-- index.html subscribes to this table on the 'board' channel alongside
-- items/sections/members/activity. Without membership in the publication
-- nobody else's tab ever refreshes — no error, just a stale list.
-- Every failure here is swallowed on purpose. The Supabase SQL editor runs a
-- pasted batch inside ONE transaction, so an unhandled error in this block
-- rolls back the table, the policies and the index along with it -- and the
-- symptom is a migration that reports nothing and created nothing. Realtime is
-- a convenience; the table is not. Never let this abort the run.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table public.divergences;
      raise notice 'divergences added to supabase_realtime';
    exception
      when duplicate_object then
        raise notice 'divergences already in supabase_realtime';
      when insufficient_privilege then
        raise notice 'not the owner of supabase_realtime -- add the table from '
                     'Database > Replication in the dashboard';
    end;
  else
    raise notice 'no supabase_realtime publication -- skipping';
  end if;
end $$;

-- ── 5. verify ───────────────────────────────────────────────────────
-- READ THIS FIRST. The Supabase SQL editor renders only the result of the
-- LAST statement in whatever you run. Run the whole file and the four
-- detail queries below execute and are thrown away -- they look like they
-- "returned nothing" when they returned plenty. Either highlight one query
-- and run just that, or rely on the one-row summary at the bottom, which is
-- deliberately the last statement in the file so a full run displays it.

-- Expect: 12 columns, client defaulting to 'htland', status to 'active'.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'divergences'
order by ordinal_position;

-- Expect: both CHECK constraints.
-- NOTE: ::regclass ERRORS if the table is missing, rather than returning no
-- rows. An empty result here means the table exists and has no CHECKs; an
-- error means the table itself never got created.
select conname, pg_get_constraintdef(oid) from pg_constraint
where conrelid = 'public.divergences'::regclass and contype = 'c';

-- Expect: 3 rows - divergences_pkey, divergences_active_key
-- (UNIQUE ... WHERE (status = 'active')), divergences_item_id_idx.
select indexname, indexdef from pg_indexes
where schemaname = 'public' and tablename = 'divergences';

-- Expect: four policies, every qual / with_check reading is_member().
select tablename, policyname, cmd, qual, with_check from pg_policies
where schemaname = 'public' and tablename = 'divergences';

-- ── the summary — one row, and the last thing the editor will show ──
-- Expect: t, t, 12, 2, 3, 4, t
--   (12 columns; 2 CHECKs; 3 indexes - pkey, active_key, item_id_idx;
--    4 policies; realtime on)
-- to_regclass returns null instead of erroring, so this is safe to run even
-- when nothing was created at all.
--
-- sanity_right_db false  -> wrong project or wrong schema, nothing else matters
-- table_exists   false   -> the batch rolled back; scroll up for the real error
-- realtime       false   -> harmless, but other people's tabs will not refresh
--                          until you add it under Database > Replication
select
  to_regclass('public.divergences') is not null as table_exists,
  to_regclass('public.items')       is not null as sanity_right_db,
  (select count(*) from information_schema.columns
     where table_schema = 'public' and table_name = 'divergences')  as columns,
  (select count(*) from pg_constraint
     where conrelid = to_regclass('public.divergences')
       and contype = 'c')                                           as checks,
  (select count(*) from pg_indexes
     where schemaname = 'public' and tablename = 'divergences')     as indexes,
  (select count(*) from pg_policies
     where schemaname = 'public' and tablename = 'divergences')     as policies,
  exists (select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public' and tablename = 'divergences')     as realtime;
