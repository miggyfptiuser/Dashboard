-- ════════════════════════════════════════════════════════════════════
-- Store menu items without their release version
--
-- Menu item names carry a release suffix — BCAcknwldgmntRcptPrinting_9.0.0.36E.
-- The version is not part of the object's identity, so an exclusion keyed to it
-- would stop matching the moment the next release renamed the item, silently
-- putting the object back into the compare.
--
-- DATA ONLY. No DDL, no schema change. Safe to run before or after deploying
-- the matching index.html: the new bareName() strips a trailing version when
-- matching, so rows that still carry one keep working either way.
--
-- The SQL editor runs a pasted batch in ONE transaction. Section 3 reports
-- anything it could not do; nothing is silently skipped.
-- ════════════════════════════════════════════════════════════════════

-- ── 0. PREFLIGHT — highlight and run alone, read before continuing ───
-- `stripped` is what section 2 will store. Anything whose stripped name
-- already exists for the same client and status is a collision: the same
-- menu item recorded twice at different versions.
select id, client, status, object_name,
       regexp_replace(object_name, '_[0-9]+(\.[0-9]+)+[A-Za-z]*$', '') as stripped,
       item_label, created_at
from public.divergences
where upper(coalesce(kind, '')) = 'MENUITEM'
order by client, object_name;

-- ── 1. what the regex does ──────────────────────────────────────────
--   BCAcknwldgmntRcptPrinting_9.0.0.36E  -> BCAcknwldgmntRcptPrinting
--   BCCollectionReceiptPrinting_9.0.0.027E -> BCCollectionReceiptPrinting
--   BC010                                -> BC010          (no version)
--   RE.nsp_PaymentApplication            -> untouched      (not a MENUITEM)
-- It requires an underscore, then digits with at least one dot, so a name
-- merely ending in _2 is left alone.

-- ── 2. strip, newest row wins a collision ───────────────────────────
-- Two guards, both needed:
--   row_number() keeps one row per (client, stripped name, status), so two
--   rows in this same UPDATE cannot both become the same name;
--   NOT EXISTS keeps it off a name some other row already holds.
-- Either way the partial unique index on (client, lower(object_name))
-- where status = 'active' cannot be tripped.
with target as (
  select d.id, d.client, d.status,
         regexp_replace(d.object_name, '_[0-9]+(\.[0-9]+)+[A-Za-z]*$', '') as stripped,
         row_number() over (
           partition by d.client, d.status,
                        lower(regexp_replace(d.object_name, '_[0-9]+(\.[0-9]+)+[A-Za-z]*$', ''))
           order by d.created_at desc, d.id desc) as rn
  from public.divergences d
  where upper(coalesce(d.kind, '')) = 'MENUITEM'
)
update public.divergences d
   set object_name = t.stripped
  from target t
 where d.id = t.id
   and t.rn = 1
   and d.object_name <> t.stripped
   and not exists (
     select 1 from public.divergences x
      where x.id <> d.id
        and x.client = d.client
        and x.status = d.status
        and lower(x.object_name) = lower(t.stripped));

-- ── 3. anything left carrying a version ─────────────────────────────
-- Expect no rows. Any that appear are duplicates of a menu item recorded at
-- two versions — decide which to keep, converge or delete the other, and
-- re-run section 2.
select id, client, status, object_name, item_label, created_at
from public.divergences
where upper(coalesce(kind, '')) = 'MENUITEM'
  and object_name ~ '_[0-9]+(\.[0-9]+)+[A-Za-z]*$'
order by client, object_name;

-- ── 4. verify — one row, deliberately last ──────────────────────────
-- Expect: <n>, 0
select
  (select count(*) from public.divergences
    where upper(coalesce(kind, '')) = 'MENUITEM')                      as menu_item_rows,
  (select count(*) from public.divergences
    where upper(coalesce(kind, '')) = 'MENUITEM'
      and object_name ~ '_[0-9]+(\.[0-9]+)+[A-Za-z]*$')                as still_versioned;
