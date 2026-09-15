-- ════════════════════════════════════════════════════════════════════
-- "Both" becomes a flag alongside a real home client
--
-- 2026-09-10 made 'both' a third value of items.client. That overwrote
-- the home client: once an item was Both, nothing recorded which client
-- it belonged to, which is exactly why Split had to stop and ask. This
-- keeps both facts — client says whose item it is, applies_to_both says
-- it also applies to the other — so Split has nothing to ask.
--
-- RUN THIS BEFORE DEPLOYING the matching index.html. The new page sends
-- applies_to_both on every item save; until the column exists, every
-- save fails.
--
-- The Supabase SQL editor runs a pasted batch in ONE transaction. If the
-- assertion in section 4 fires, everything above it rolls back too, and
-- the database is left exactly as it was.
-- ════════════════════════════════════════════════════════════════════

-- ── 0. PREFLIGHT — highlight and run on its own, read before running ─
-- These rows have no recorded home client and will be defaulted to
-- HTLand. Note any that belong to RCD Land; afterwards, re-file them
-- from the item editor's dropdown. That edit is safe now — changing the
-- client no longer touches the Both flag.
select id, ref_code, title, parent_id
from public.items where client = 'both'
order by parent_id nulls first, id;

-- Section 2 REPLACES the two trigger functions below. The repo copy in
-- migrations/2026-09-02-add-client.sql is what they extend; if the live
-- definitions were changed since, compare before running:
--   select pg_get_functiondef('public.items_client_from_parent'::regproc);
--   select pg_get_functiondef('public.items_cascade_client'::regproc);

-- ── 1. the column ───────────────────────────────────────────────────
-- NOT NULL DEFAULT false for the same reason items.client has a default:
-- a teammate on a Pages-cached page inserts without it, and the default
-- files the row as single-client instead of failing the save.
alter table public.items
  add column if not exists applies_to_both boolean not null default false;

-- ── 2. sub-items inherit the flag, in the database ──────────────────
-- Under the old model a sub-item inherited 'both' for free, because it
-- lived in client. A new column is not covered by those triggers, and
-- copyForViber() builds each client block's sub-items from the same
-- filtered list as the parents — so without this, a Both item's
-- sub-items would silently drop out of the other client's half.
--
-- Names kept deliberately: CLAUDE.md cites both triggers by name.

create or replace function public.items_client_from_parent()
returns trigger language plpgsql as $$
declare
  parent_client text;
  parent_both   boolean;
begin
  if new.parent_id is not null then
    select i.client, i.applies_to_both
      into parent_client, parent_both
      from public.items i where i.id = new.parent_id;
    -- guard the null case: a vanished parent must not null out the child
    if parent_client is not null then
      new.client          := parent_client;
      new.applies_to_both := coalesce(parent_both, false);
    end if;
  end if;
  return new;
end $$;

drop trigger if exists items_client_from_parent on public.items;
create trigger items_client_from_parent
  before insert or update of parent_id, client, applies_to_both on public.items
  for each row execute function public.items_client_from_parent();

-- Re-filing a parent, or toggling its Both flag, takes the children along.
create or replace function public.items_cascade_client()
returns trigger language plpgsql as $$
begin
  if new.parent_id is null
     and (new.client          is distinct from old.client
       or new.applies_to_both is distinct from old.applies_to_both) then
    update public.items
       set client = new.client, applies_to_both = new.applies_to_both
     where parent_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists items_cascade_client on public.items;
create trigger items_cascade_client
  after update of client, applies_to_both on public.items
  for each row execute function public.items_cascade_client();

-- Still no recursion: the cascade's UPDATE touches only rows with a
-- non-null parent_id, and items_cascade_client is a no-op for those.

-- ── 3. convert existing Both rows — parents first ───────────────────
-- Parents only. The extended cascade from section 2 carries client AND
-- the flag down to each parent's children.
--
-- Do not collapse this into one UPDATE over every 'both' row. Row order
-- within a statement is unspecified: a child processed before its parent
-- would have its BEFORE trigger read the parent's still-'both' client
-- straight back onto it.
update public.items
   set client = 'htland', applies_to_both = true
 where client = 'both' and parent_id is null;

-- ── 4. sweep and assert ─────────────────────────────────────────────
-- Nothing should be left — the inheritance triggers made a 'both' child
-- of a non-'both' parent impossible — but the CHECK in section 5 fails
-- outright if anything is, so sweep and then prove it.
update public.items
   set client = 'htland', applies_to_both = true
 where client = 'both';

do $$
declare n int;
begin
  select count(*) into n from public.items where client = 'both';
  if n > 0 then
    raise exception '% item(s) still have client = both; nothing was changed', n;
  end if;
end $$;

-- ── 5. narrow the constraint back to the two real clients ───────────
-- Last on purpose: it cannot be added while any 'both' row exists.
-- Keep in step with the CLIENTS const in index.html, which is back to
-- exactly these two keys.
alter table public.items
  drop constraint if exists items_client_check;
alter table public.items
  add constraint items_client_check check (client in ('htland','rcd_land'));

-- ── MANUAL CHECK: is a Both toggle logged? ───────────────────────────
-- Same question the client migration left open. If log_item_change
-- enumerates tracked columns, decide whether applies_to_both belongs in
-- it; if it diffs generically there is nothing to do. Test by toggling
-- the box on a real item and reading the activity feed.
--   select pg_get_functiondef('public.log_item_change'::regproc);

-- ── 6. verify — one row, deliberately the last statement ────────────
-- Expect: t, 0, t, <n>
--   both_rows_left       > 0   -> section 4 should have rolled everything back
--   check_two_valued     false -> section 5 did not apply
--   flagged_items               -> the count you converted, sub-items included
select
  exists (select 1 from information_schema.columns
          where table_schema = 'public' and table_name = 'items'
            and column_name = 'applies_to_both')                   as column_exists,
  (select count(*) from public.items where client = 'both')         as both_rows_left,
  (select pg_get_constraintdef(oid) not like '%both%'
     from pg_constraint
    where conrelid = 'public.items'::regclass
      and conname = 'items_client_check')                           as check_two_valued,
  (select count(*) from public.items where applies_to_both)         as flagged_items;
