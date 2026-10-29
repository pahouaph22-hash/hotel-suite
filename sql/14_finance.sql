-- =====================================================================
-- Saynam Hotel Suite — finance controls (IFRS for SMEs)
--  * opening balances: one entry that starts the books, equity is the balancing figure (Section 3/4)
--  * fixed-asset register with straight-line depreciation (Section 17 / IAS 16)
--  * cash counts (over/short posted to 5950) and bank reconciliations (recorded, never auto-posted)
--  * profit tax rate kept in settings (Lao standard rate 20%) instead of a fixed number in the screen
-- =====================================================================
alter table settings add column if not exists profit_tax_rate numeric not null default 20 check (profit_tax_rate between 0 and 100);

insert into accounts(code, type, name) values
  ('5950', 'opx', '{"lo":"ເງິນສົດຂາດ / ເກີນ","th":"เงินสดขาด / เกิน","en":"Cash over / short"}')
on conflict (code) do nothing;

create table if not exists fixed_assets (
  id bigserial primary key,
  name text not null check (length(trim(name)) between 2 and 120),
  account text not null check (account in ('1210', '1220')),
  cost bigint not null check (cost > 0),
  salvage bigint not null default 0 check (salvage >= 0),
  life_months int not null check (life_months between 1 and 600),
  in_use date not null,
  purchase_entry bigint references journal_entries(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (salvage < cost)
);
create table if not exists cash_counts (
  id bigserial primary key,
  count_date date not null,
  account text not null check (account in ('1110', '1120')),
  counted bigint not null check (counted >= 0),
  book bigint not null,
  diff bigint not null,
  note text,
  entry_id bigint references journal_entries(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists cash_counts_date_idx on cash_counts(count_date);
alter table fixed_assets enable row level security;
alter table cash_counts enable row level security;
drop policy if exists staff_read on fixed_assets;
create policy staff_read on fixed_assets for select to authenticated using (is_staff());
drop policy if exists staff_read on cash_counts;
create policy staff_read on cash_counts for select to authenticated using (is_staff());
revoke all on fixed_assets, cash_counts from anon;

-- ---------- opening balances ----------
create or replace function acct_opening(p_date date, p_lines jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare d bigint; c bigint; eid bigint; lines jsonb;
begin
  perform require_role('manager', 'accountant');
  if exists (select 1 from journal_entries where source = 'open' and reversed_by is null and reverses is null) then
    raise exception 'already_posted' using errcode = 'P0001';
  end if;
  if p_date is null or p_date > biz() then raise exception 'future_date' using errcode = 'P0001'; end if;
  if exists (select 1 from jsonb_array_elements(p_lines) x left join accounts a on a.code = x->>'a'
             where a.code is null or a.type not in ('ca', 'nca', 'cl', 'ncl', 'eq') or a.code in ('1130', '1140', '2150', '2170')
                or coalesce((x->>'dr')::bigint, 0) < 0 or coalesce((x->>'cr')::bigint, 0) < 0) then
    raise exception 'invalid_account' using errcode = 'P0001', detail = 'opening balances take balance-sheet accounts only; guest ledgers, deposits and refunds start at zero';
  end if;
  select coalesce(sum(coalesce((x->>'dr')::bigint, 0)), 0), coalesce(sum(coalesce((x->>'cr')::bigint, 0)), 0) into d, c
  from jsonb_array_elements(p_lines) x where x->>'a' <> '3100';
  -- owner's capital is the balancing figure: assets − liabilities − other equity
  lines := coalesce((select jsonb_agg(jsonb_build_object('a', x->>'a', 'dr', coalesce((x->>'dr')::bigint, 0), 'cr', coalesce((x->>'cr')::bigint, 0)))
                     from jsonb_array_elements(p_lines) x where x->>'a' <> '3100'), '[]'::jsonb)
           || jsonb_build_array(jsonb_build_object('a', '3100', 'dr', greatest(c - d, 0), 'cr', greatest(d - c, 0)));
  if d = 0 and c = 0 then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  eid := post_entry(p_date, jsonb_build_object('k', 'open'), 'OB', 'open', lines);
  perform log_action('journal.opening', 'JV-' || eid, jsonb_build_object('lines', lines));
  return eid;
end $$;

-- opening entries can be reversed (to correct them) like any other non-booking entry
create or replace function acct_reverse(p_id bigint, p_reason text) returns bigint
language plpgsql security definer set search_path = public as $$
declare e journal_entries; eid bigint; lines jsonb;
begin
  perform require_role('manager','accountant');
  select * into e from journal_entries where id = p_id for update;
  if e.id is null or e.reversed_by is not null or e.reverses is not null
     or e.source not in ('manual','expense','close','tax','finance','cash','open') then
    raise exception 'cannot_reverse' using errcode = 'P0001';
  end if;
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'reason_required' using errcode = 'P0001'; end if;
  select jsonb_agg(jl(account, credit, debit)) into lines from journal_lines where entry_id = p_id;
  eid := post_entry(biz(), jsonb_build_object('k','rev','id',p_id,'text',left(p_reason,160)), 'REV-' || p_id, 'reversal', lines, p_id);
  update journal_entries set reversed_by = eid where id = p_id;
  perform log_action('journal.reverse', 'JV-' || p_id, jsonb_build_object('reversal', eid, 'reason', p_reason));
  return eid;
end $$;

-- ---------- fixed assets ----------
-- straight line, full month from the month after the asset is ready for use; the last month takes the rounding remainder
create or replace function asset_depr(p_cost bigint, p_salvage bigint, p_life int, p_in_use date, p_month text) returns bigint
language sql immutable set search_path = public as $$
  with k as (select ((extract(year from (p_month || '-01')::date) * 12 + extract(month from (p_month || '-01')::date))
                   - (extract(year from p_in_use) * 12 + extract(month from p_in_use)))::int as n,
                    (p_cost - p_salvage) / p_life as m)
  select case when n < 1 or n > p_life then 0
              when n = p_life then (p_cost - p_salvage) - m * (p_life - 1)
              else m end::bigint from k
$$;
create or replace function depr_for_month(p_month text) returns bigint language sql stable security definer set search_path = public as $$
  select coalesce(sum(asset_depr(cost, salvage, life_months, in_use, p_month)), 0)::bigint from fixed_assets
$$;

create or replace function acct_asset_add(p jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare aid bigint; eid bigint; pay text := coalesce(p->>'pay', 'none'); cost bigint := (p->>'cost')::bigint; d date := (p->>'in_use')::date;
begin
  perform require_role('manager', 'accountant');
  if d is null or d > biz() then raise exception 'future_date' using errcode = 'P0001'; end if;
  if pay not in ('none', '1110', '1120', '2110') then raise exception 'invalid_account' using errcode = 'P0001'; end if;
  if pay <> 'none' then
    eid := post_entry(d, jsonb_build_object('k', 'asset', 'text', left(p->>'name', 120)), 'FA', 'finance',
                      jsonb_build_array(jl(p->>'account', cost, 0), jl(pay, 0, cost)));
  end if;
  insert into fixed_assets(name, account, cost, salvage, life_months, in_use, purchase_entry)
  values (trim(p->>'name'), p->>'account', cost, coalesce((p->>'salvage')::bigint, 0), (p->>'life_months')::int, d, eid)
  returning id into aid;
  perform log_action('asset.add', 'FA-' || aid, p || jsonb_build_object('entry', eid));
  return aid;
end $$;

-- month-end depreciation comes from the register when it has assets; the flat monthly amount in settings is the fallback
create or replace function acct_close(p_kind text, p_month text) returns bigint language plpgsql security definer set search_path = public as $$
declare a jsonb; d date; eid bigint; k text; v bigint; det jsonb := null;
begin
  perform require_role('manager','accountant');
  select close_amounts into a from settings where id = 1;
  d := least((p_month || '-01')::date + interval '1 month' - interval '1 day', biz())::date;
  if to_char(d, 'YYYY-MM') <> p_month then raise exception 'month_not_started' using errcode = 'P0001'; end if;
  k := case p_kind when 'depr' then 'depr' when 'int' then 'int' when 'sal_pay' then 'sal' when 'sal_accrue' then 'salAcc' end;
  if k is null then raise exception 'invalid_kind' using errcode = 'P0001'; end if;
  if p_kind = 'depr' and exists (select 1 from fixed_assets) then
    v := depr_for_month(p_month);
    det := (select jsonb_agg(jsonb_build_object('id', id, 'amt', asset_depr(cost, salvage, life_months, in_use, p_month)))
            from fixed_assets where asset_depr(cost, salvage, life_months, in_use, p_month) > 0);
  else
    v := coalesce((a->>(case p_kind when 'depr' then 'depr' when 'int' then 'int' else 'sal' end))::bigint, 0);
  end if;
  if v <= 0 then raise exception 'close_amount_missing' using errcode = 'P0001'; end if;
  if entry_posted(k, p_month) or (k in ('sal','salAcc') and (entry_posted('sal', p_month) or entry_posted('salAcc', p_month))) then
    raise exception 'already_posted' using errcode = 'P0001';
  end if;
  eid := post_entry(d, jsonb_build_object('k', k, 'mo', p_month) || case when det is not null then jsonb_build_object('assets', det) else '{}'::jsonb end,
    upper(k) || '-' || p_month, 'close',
    case p_kind
      when 'depr' then jsonb_build_array(jl('5800', v, 0), jl('1290', 0, v))
      when 'int' then jsonb_build_array(jl('5900', v, 0), jl('1120', 0, v))
      when 'sal_pay' then jsonb_build_array(jl('5200', v, 0), jl('1120', 0, v))
      else jsonb_build_array(jl('5200', v, 0), jl('2160', 0, v)) end);
  perform log_action('close.' || p_kind, p_month, jsonb_build_object('amount', v));
  return eid;
end $$;

-- ---------- cash count / bank reconciliation ----------
create or replace function acct_cash_count(p_account text, p_counted bigint, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d date := biz(); book bigint; diff bigint; eid bigint; cid bigint;
begin
  if p_account = '1110' then perform require_role('manager', 'accountant', 'frontdesk');
  else perform require_role('manager', 'accountant'); end if;
  if p_account not in ('1110', '1120') or p_counted is null or p_counted < 0 then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into book from journal_lines l join journal_entries e on e.id = l.entry_id
   where l.account = p_account and e.entry_date <= d;
  diff := p_counted - book;
  if diff <> 0 and length(trim(coalesce(p_note, ''))) < 3 then raise exception 'reason_required' using errcode = 'P0001'; end if;
  -- cash in the drawer is the truth: post the difference. A bank difference is usually timing, so it is only recorded.
  if p_account = '1110' and diff <> 0 then
    eid := post_entry(d, jsonb_build_object('k', 'cashCount', 'text', left(p_note, 160)), 'CNT', 'cash',
             case when diff > 0 then jsonb_build_array(jl('1110', diff, 0), jl('5950', 0, diff))
                  else jsonb_build_array(jl('5950', -diff, 0), jl('1110', 0, -diff)) end);
  end if;
  insert into cash_counts(count_date, account, counted, book, diff, note, entry_id) values (d, p_account, p_counted, book, diff, nullif(trim(p_note), ''), eid)
  returning id into cid;
  perform log_action(case when p_account = '1110' then 'cash.count' else 'bank.reconcile' end, 'CC-' || cid,
                     jsonb_build_object('counted', p_counted, 'book', book, 'diff', diff, 'note', p_note));
  return jsonb_build_object('id', cid, 'book', book, 'diff', diff, 'entry', eid);
end $$;

create or replace function admin_finance() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'permission_denied' using errcode = '42501'; end if;
  return jsonb_build_object(
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'account', f.account, 'cost', f.cost, 'salvage', f.salvage,
        'life', f.life_months, 'in_use', f.in_use, 'entry', f.purchase_entry, 'at', f.created_at) order by f.id) from fixed_assets f), '[]'),
    'counts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'date', c.count_date, 'account', c.account, 'counted', c.counted, 'book', c.book,
        'diff', c.diff, 'note', c.note, 'entry', c.entry_id, 'at', c.created_at, 'by', (select name from staff where user_id = c.created_by)) order by c.id desc)
        from (select * from cash_counts order by id desc limit 200) c), '[]'));
end $$;

revoke execute on function asset_depr(bigint, bigint, int, date, text), depr_for_month(text) from public, anon, authenticated;
revoke execute on function acct_opening(date, jsonb), acct_reverse(bigint, text), acct_asset_add(jsonb), acct_close(text, text), acct_cash_count(text, bigint, text), admin_finance() from public, anon;
grant execute on function acct_opening(date, jsonb), acct_reverse(bigint, text), acct_asset_add(jsonb), acct_close(text, text), acct_cash_count(text, bigint, text), admin_finance() to authenticated;
