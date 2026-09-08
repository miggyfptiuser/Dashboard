# Deliverables Board — project context

Internal tracker replacing a pinned Viber message. Static frontend on GitHub
Pages, Postgres on Supabase, no build step and no server.

## Layout

- `index.html` — the entire app. HTML, CSS, and an ES module script block in one
  file. Edit it directly; there is nothing to compile.


## Architecture

Browser talks straight to PostgREST over HTTPS (`sb.from('items').update(...)`
compiles to one `PATCH /rest/v1/items?id=eq.N`). There is no backend tier.

Consequences that matter when adding features:

- **Client-side validation is UX only.** Any signed-in user can open DevTools
  and issue arbitrary PostgREST calls. Real rules belong in CHECK constraints,
  RLS policies, or triggers — never in `save()`.
- **RLS is the entire authorization model.** Every policy gates on
  `is_member()`, which matches `members.user_id = auth.uid()`.
- **The anon key is public and that's fine.** Never add the `service_role` key
  to this file; it bypasses RLS.

## Data model

`members` are decoupled from `auth.users`. A member row is a name you can assign
work to; `user_id` is null until that person is invited and signs in, at which
point `claim_membership()` links them by matching email. **`members.id` is not an
auth uid** — anything resolving an actor from `auth.uid()` must go through
`members.user_id`. This exact confusion caused a bug where new teammates'
status changes were silently rejected by a foreign key inside a trigger.

`items` carry both `status` (what's happening) and `stage` (nullable
`sit|uat|live`, position on the deploy track). These were one field originally.
`item_status` still contains unused `sit`/`uat`/`live` values because Postgres
can't drop enum values — ignore them; they are not offered in the UI.

`activity` is written by the `log_item_change` trigger on insert and update.
Deletes are not logged; rows cascade away with the item.

`items.client` is the client the work belongs to — `text NOT NULL DEFAULT
'htland'` with a CHECK constraint, mirrored by the `CLIENTS` const in
`index.html`. The client vocabulary now lives in **three** places that must
agree: `CLIENTS`, `items_client_check`, and `divergences_client_check`. **Add a
key to one without the others and every save for that client is rejected.** It is a CHECK rather than an enum precisely because
`item_status` taught us enum values can't be dropped. The `DEFAULT` is load-
bearing beyond the backfill: a teammate on a Pages-cached page inserts without
a `client`, and the default files it under HTLand instead of failing.

A sub-item's client is inherited from its parent and enforced by the
`items_client_from_parent` trigger; re-filing a parent cascades to its children
via `items_cascade_client`. The editor renders a sub-item's client select
disabled to match. Migration: `migrations/2026-09-02-add-client.sql`.

## Frontend conventions

- One global `state` object, and `render()` repaints everything from it. There
  is no diffing and no framework.
- `wire()` re-attaches every handler after each render. New interactive markup
  needs its handler registered there or it will be inert.
- Editors are uncontrolled: typed values live only in the DOM until save, and
  `save()` scrapes them by element id. Field ids are suffixed with the item id
  (`f-title-42`) because two editors on screen once caused saves to read the
  wrong record.
- Realtime subscriptions in `start()` reload and repaint on changes to `items`,
  `sections`, `members`, and `activity`.

## Gotchas that have already cost time

- **Always check the `error` returned by Supabase calls.** A rejected write
  returns success-shaped output and looks identical to a successful one. Several
  handlers used to discard it.
- **`sb.rpc()` returns a thenable builder, not a Promise.** No `.catch()` on it.
- **PL/pgSQL doesn't type-check function bodies at `create` time.** Errors like
  `malformed array literal` surface on first execution, not on definition. Test
  a trigger by actually performing the edit that fires it.
- **Array append in PL/pgSQL needs `arr || array['x']`**, not `arr || 'x'`.
- **`const` in the module has a temporal dead zone.** Helpers referenced from
  `render()` must be defined above first use or declared as hoisted functions.
- **GitHub Pages caches `index.html`.** After a deploy, hard-refresh. If a
  teammate reports a bug you already fixed, rule out stale cache first.
- **The live Supabase project is the source of truth for schema.** There is
  no `schema.sql` in the repo; if you need to rebuild the DB, export from
  Supabase first.

## Conventions from the Viber board

Status vocabulary mirrors what the team already writes: NYS, SIT, UAT, LIVE,
TBS, plus For Checking / Addressing / Validation / Enhancement. `copyForViber()`
regenerates the pinned message in the group's existing format — strikethrough
for done, `c/o <first name>` for ownership, `*Heading:*` per section. The first
`deliverables`-typed section prints unheaded as the main numbered list;
subsequent ones get their own heading.

The export emits one block per client in `CLIENT_KEYS` order — **HTLand first,
then RCD Land** — each with its own sections and its own `*DEADLINES:*` / TBS
trailer, so either half can be posted alone. Two things that look like bugs but
aren't: `mainListUsed` is scoped *inside* the client loop (hoist it and RCD
Land's main list prints headed while HTLand's doesn't), and the whole function
ignores `state.filterClient` — it regenerates the pinned message, which has to
be complete regardless of how the board is scoped. Clients with no items print
no heading.

`items.scope_tags` (text[]) still exists on the table but is no longer surfaced
in the UI — dropped because the sole dev didn't slice work by transaction type.
Don't re-add editor/row/search wiring for it without a reason; if a use for
per-item domain tagging comes back, prefer repurposing the column over adding a
new one.

The client filter (`state.filterClient`) scopes all three tabs, not just the
board — the chips render outside the board-only block in the toolbar. Everything
reads through the `inClient()` helper. On the Board, a section holding none of
the selected client's items is hidden entirely; `state.showAllSections` is the
escape hatch, without which you could never add the first item for a new client.

Per-item SQL deployment inventory lives in `items.sql_objects` (text[]) — one
identifier per line in the editor, optional `PROC:` / `TABLE:` / `VIEW:` /
`FUNC:` / `TRIG:` prefix is parsed for a badge but not enforced. The Deploy tab
buckets `for_deployment` items by **client and then `stage`** (sit / uat / null)
and offers a dedup'd Copy-list per bucket, keyed `stage:client`. The client
split is not cosmetic: `copySql()` dedups across a whole bucket, so one combined
bucket would hand you a push list blending both clients' objects. Design decision: item-level staging only — all of
an item's `sql_objects` move together. If mixed-stage pushes become real,
migrate the array to a child table with per-object timestamps rather than
overloading the column.

## Divergence registry (Compare tab)

The two clients run **separate SQL Server databases for the client program**,
and they are meant to stay schema-identical: a standard fix goes to both. A
client-requested enhancement goes to one, and from then on that object is
deliberately different. Regular schema compares between the two databases flag
it every run, and "fixing" the difference silently reverts the enhancement.

`divergences` records those objects so they can be excluded from the compare.
Migration: `migrations/2026-09-08-add-divergences.sql`. **Nothing in this table
describes this tracker's own Supabase schema** — every `object_name` names an
object in a client program database.

- **It is a table, not a flag on `items`, on purpose.** Items get completed,
  reworked and deleted. A divergence outlives all of that; it stands until
  someone ports the enhancement to the other client. `item_id` is therefore
  `ON DELETE SET NULL`, never cascade, and `item_label` keeps a text snapshot
  of the origin item so the row still reads sensibly once the item is gone.
- **`copyExclusions()` ignores `state.filterClient` and emits both clients.**
  This looks like the per-client bug `copySql()` avoids, but it is the opposite
  case: a push list belongs to one client, an ignore list does not. The compare
  runs *between* the two databases and takes one list, so a filtered copy would
  hand back half of it. Same reasoning as `copyForViber()`. The browsing list
  below the button *does* respect the chips, and says so when filtered.
- **Rows are retired, not deleted.** `status` goes `active` → `converged` with a
  `converged_at`; converged rows stay as the record of why the databases once
  differed. The unique index is *partial* (`where status = 'active'`) precisely
  so history can coexist with the same object diverging again later.
- **Matching between an item's `sql_objects` and the registry is on the bare
  name** — `bareName()` strips the `PROC:` prefix and any `schema.` qualifier
  and lowercases, so `PROC:sp_foo` on an item matches `dbo.sp_foo` in the
  registry. Deliberately loose: a false positive costs a glance, a miss costs an
  overwritten enhancement. `objKey()` is the stricter key and keeps the schema,
  because dedup in the exclusion list must not merge `dbo.x` with `arc.x`.
- The `⚠ n enhanced` badge on an item row and in the Deploy card is the
  cross-client warning: it fires for divergences under **either** client, and
  the one that matters is the other client's — that is the push that quietly
  reverts an enhancement.

## Verifying against the live database

```sql
-- functions and whether they're SECURITY DEFINER
select proname, prosecdef from pg_proc p
join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public';

-- read a function body exactly as defined
select pg_get_functiondef('log_item_change'::regproc);

-- policies: qual is USING, with_check is CHECK
select tablename, policyname, cmd, qual, with_check from pg_policies
where schemaname = 'public';
```
