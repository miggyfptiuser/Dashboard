-- ════════════════════════════════════════════════════════════════════
-- "Both" as a third value for items.client
--
-- Most work here is a standard fix that goes to both clients, but
-- items.client forced a choice, so shared work had to be entered twice
-- and kept in step by hand. 'both' means one item that applies to each
-- client: it shows under either client filter, lands in both clients'
-- deploy push lists, and prints in both halves of the Viber export.
--
-- It is NOT a third client. There are still two client databases, and
-- divergences_client_check deliberately does NOT gain 'both' — see
-- section 2.
--
-- RUN THIS BEFORE DEPLOYING the matching index.html. The frontend sends
-- `client` on every item save; until the constraint allows it, saving a
-- Both item fails with a check violation.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. widen the items constraint ───────────────────────────────────
-- Still a CHECK rather than an enum, for the reason in CLAUDE.md:
-- unused enum values can never be dropped. Keep in step with the
-- CLIENTS const in index.html.
alter table public.items
  drop constraint if exists items_client_check;
alter table public.items
  add constraint items_client_check
  check (client in ('htland','rcd_land','both'));

-- ── 2. divergences stays two-valued ─────────────────────────────────
-- Nothing to run here — this section is the note.
--
-- CLAUDE.md used to say the client vocabulary lives in three places that
-- must agree: the CLIENTS const, items_client_check, and
-- divergences_client_check. That stops being true with this migration,
-- and the asymmetry is deliberate.
--
-- A divergence records that ONE client's copy of an object was enhanced,
-- so the other client's copy is the thing you must not overwrite. A
-- divergence "for both clients" is a contradiction: if both copies
-- changed the same way, they still match and there is nothing to exclude
-- from the compare. index.html reflects this — the item editor reads
-- ITEM_CLIENT_KEYS (three options) while the Compare tab's "Enhanced
-- for" select reads CLIENT_KEYS (two).
--
-- Do not "fix" the mismatch by adding 'both' below.
--   alter table public.divergences ... check (client in (...))   -- NO

-- ── 3. verify ───────────────────────────────────────────────────────
-- The Supabase SQL editor renders only the LAST statement's result, so
-- the one-row summary is deliberately last. Highlight a query and run it
-- alone if you want the detail.

-- Expect: items_client_check listing all three values.
select conname, pg_get_constraintdef(oid) from pg_constraint
where conrelid = 'public.items'::regclass and contype = 'c';

-- Expect: existing rows untouched, no 'both' yet.
select client, count(*) from public.items group by client order by client;

-- ── the summary — one row, and the last thing the editor will show ──
-- Expect: t, f, t
--   items_allows_both     false -> section 1 did not apply
--   divergences_allows_both true -> someone widened the wrong constraint
select
  pg_get_constraintdef(c.oid) like '%both%'                        as items_allows_both,
  coalesce((select pg_get_constraintdef(d.oid) like '%both%'
            from pg_constraint d
            where d.conrelid = to_regclass('public.divergences')
              and d.conname = 'divergences_client_check'), false)  as divergences_allows_both,
  to_regclass('public.items') is not null                          as sanity_right_db
from pg_constraint c
where c.conrelid = 'public.items'::regclass and c.conname = 'items_client_check';
