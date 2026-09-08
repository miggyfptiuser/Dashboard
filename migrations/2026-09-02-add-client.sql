-- ════════════════════════════════════════════════════════════════════
-- Two-client support: HTLand + RCD Land
--
-- RUN THIS BEFORE DEPLOYING the matching index.html. The frontend sends
-- `client` on every item save; without the column those writes fail.
--
-- Paste into the Supabase SQL editor. Sections 1 and 2 are required;
-- section 3 is a manual check, section 4 verifies.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. the column ───────────────────────────────────────────────────
-- NOT NULL DEFAULT backfills every existing row to htland in one
-- statement (no table rewrite on PG 11+).
--
-- The DEFAULT is kept deliberately, not just for the backfill: GitHub
-- Pages caches index.html, so a teammate on a stale page inserts without
-- a client. The default lands them in HTLand — correct in the
-- overwhelming majority of cases. Without it their save dies on a
-- not-null violation they can do nothing about.
alter table public.items
  add column if not exists client text not null default 'htland';

-- A CHECK, not an enum: unused enum values can never be dropped (see the
-- item_status note in CLAUDE.md), whereas this constraint can be dropped
-- and recreated when the client roster changes. Keep it in step with the
-- CLIENTS const in index.html — they are two halves of one vocabulary.
alter table public.items
  drop constraint if exists items_client_check;
alter table public.items
  add constraint items_client_check check (client in ('htland','rcd_land'));

-- ── 2. sub-items follow their parent ────────────────────────────────
-- A child whose client differs from its parent renders under that parent
-- regardless of the active filter, so the mismatch would be invisible.
-- Enforced here rather than in save(): client-side validation is UX only.

create or replace function public.items_client_from_parent()
returns trigger language plpgsql as $$
declare parent_client text;
begin
  if new.parent_id is not null then
    select i.client into parent_client from public.items i where i.id = new.parent_id;
    -- guard the null case: a vanished parent must not null out the child
    if parent_client is not null then
      new.client := parent_client;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists items_client_from_parent on public.items;
create trigger items_client_from_parent
  before insert or update of parent_id, client on public.items
  for each row execute function public.items_client_from_parent();

-- Re-filing a parent takes its children along.
create or replace function public.items_cascade_client()
returns trigger language plpgsql as $$
begin
  if new.parent_id is null and new.client is distinct from old.client then
    update public.items set client = new.client where parent_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists items_cascade_client on public.items;
create trigger items_cascade_client
  after update of client on public.items
  for each row execute function public.items_cascade_client();

-- No recursion: the cascade's UPDATE only touches rows with a non-null
-- parent_id, and items_cascade_client is a no-op for those.

-- ── 3. MANUAL CHECK: should a client change be logged? ───────────────
-- Read the existing trigger and decide. If it enumerates tracked columns,
-- add `client` so re-filing an item shows up in the activity feed; if it
-- diffs generically there is nothing to do. Either way, test it by
-- actually performing the edit — PL/pgSQL bodies are not type-checked at
-- CREATE time, so a bad reference only surfaces on first execution.
--
--   select pg_get_functiondef('log_item_change'::regproc);

-- ── 4. verify ───────────────────────────────────────────────────────
-- Expect: every pre-existing row 'htland'.
select client, count(*) from public.items group by client order by client;

-- Expect: items_client_check present.
select conname, pg_get_constraintdef(oid) from pg_constraint
where conrelid = 'public.items'::regclass and conname = 'items_client_check';

-- Expect: both new triggers alongside the existing log_item_change.
select tgname from pg_trigger
where tgrelid = 'public.items'::regclass and not tgisinternal order by tgname;

-- RLS is untouched: client is a categorization, not a permission boundary,
-- and every policy still gates on is_member(). Confirm nothing drifted:
select tablename, policyname, cmd from pg_policies
where schemaname = 'public' and tablename = 'items';
