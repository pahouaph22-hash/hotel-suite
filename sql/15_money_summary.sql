-- =====================================================================
-- Saynam Hotel Suite — money in / money out, as it really happened
--  * every cash or bank movement in the ledger is classified once (same rules as the screen):
--    income by source (website booking, counter walk-in, other bookings, OTA payouts),
--    expenses by category, owner/loan money kept apart from income and expenses
--  * a daily summary is frozen for each business day by 11:30 the next day (Vientiane time);
--    later back-dated entries show up as a difference against the frozen figures
--  * unpaid supplier bills (2110) can be paid, so they become real expenses on the day they are paid
-- =====================================================================
create table if not exists daily_closings (
  day date primary key,
  income bigint not null, expense bigint not null, fin_in bigint not null, fin_out bigint not null,
  by_cat jsonb not null, by_method jsonb not null,
  entries int not null, room_nights int not null, checkins int not null, walkins int not null,
  closed_at timestamptz not null default now(),
  closed_by text not null
);
alter table daily_closings enable row level security;
drop policy if exists staff_read on daily_closings;
create policy staff_read on daily_closings for select to authenticated using (is_staff());
revoke all on daily_closings from anon;

create or replace function money_rows(p_from date, p_to date)
returns table(entry bigint, day date, delta bigint, kind text, cat text, method text)
language sql stable security definer set search_path = public as $$
  with e as (
    select je.id, je.entry_date, je.source, je.reverses, je.ref, je.description,
           sum(case when l.account in ('1110', '1120') then l.debit - l.credit else 0 end)::bigint as delta,
           bool_or(a.type in ('eq', 'ncl')) as fin,
           bool_or(l.account = '1110' and l.debit <> l.credit) as cash_moved,
           (select x.account from journal_lines x where x.entry_id = je.id and x.account not in ('1110', '1120')
             order by x.debit + x.credit desc, x.account limit 1) as main
    from journal_entries je join journal_lines l on l.entry_id = je.id join accounts a on a.code = l.account
    where je.entry_date between p_from and p_to
    group by je.id)
  select e.id, e.entry_date, e.delta,
    case when e.fin then 'fin' when e.delta > 0 then 'in' else 'out' end,
    case when e.fin then case when e.delta > 0 then 'fin_in' else 'fin_out' end
         when e.delta > 0 then
           case when e.main in ('2150', '1130', '4100', '4200', '4300') then
                  coalesce((select case when b.source = 'website' then 'web' when b.channel = 'WALK' then 'walkin' else 'otherbk' end
                            from bookings b where b.id = e.ref), 'otherbk')
                when e.main = '1140' then 'ota' when e.main = '5950' then 'cashover' else 'other_in' end
         else
           case when e.main in ('1210', '1220') then 'capex' when e.main in ('2170', '1130', '2150') then 'refund'
                when e.main in ('2140', '1150') then 'vat' when e.main in ('2120', '5300') then 'comm'
                when e.main in ('2160', '5200') then 'staff' when e.main = '2110' then 'payables' else e.main end
    end,
    coalesce(e.description->>'m', case when e.cash_moved then 'cash' else 'bank' end)
  from e
  where e.delta <> 0 and e.source <> 'open'
    and not exists (select 1 from journal_entries o where o.id = e.reverses and o.source = 'open')
$$;

create or replace function day_money(p_day date) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'income', coalesce(sum(delta) filter (where kind = 'in'), 0),
    'expense', coalesce(-sum(delta) filter (where kind = 'out'), 0),
    'fin_in', coalesce(sum(delta) filter (where cat = 'fin_in'), 0),
    'fin_out', coalesce(-sum(delta) filter (where cat = 'fin_out'), 0),
    'by_cat', coalesce((select jsonb_object_agg(c, s) from (select cat c, sum(abs(delta)) s from money_rows(p_day, p_day) group by cat) q), '{}'),
    'by_method', coalesce((select jsonb_object_agg(m, s) from (select method m, sum(delta) s from money_rows(p_day, p_day) where kind = 'in' group by method) q), '{}'),
    'entries', count(*),
    'room_nights', (select count(*) from folio_items f where f.biz_date = p_day and f.kind = 'room' and f.voids is null and f.gross > 0),
    'checkins', (select count(*) from bookings b where b.check_in = p_day and b.checked_in_at is not null),
    'walkins', (select count(*) from bookings b where b.check_in = p_day and b.channel = 'WALK' and b.checked_in_at is not null))
  from money_rows(p_day, p_day)
$$;

create or replace function close_day_summary(p_day date, p_by text) returns boolean language plpgsql security definer set search_path = public as $$
declare m jsonb := day_money(p_day);
begin
  insert into daily_closings(day, income, expense, fin_in, fin_out, by_cat, by_method, entries, room_nights, checkins, walkins, closed_by)
  values (p_day, (m->>'income')::bigint, (m->>'expense')::bigint, (m->>'fin_in')::bigint, (m->>'fin_out')::bigint, m->'by_cat', m->'by_method',
          (m->>'entries')::int, (m->>'room_nights')::int, (m->>'checkins')::int, (m->>'walkins')::int, p_by)
  on conflict (day) do nothing;
  if found then perform log_action('day.summary', to_char(p_day, 'YYYY-MM-DD'), m || jsonb_build_object('by', p_by)); end if;
  return found;
end $$;

-- scheduler, 11:30 Vientiane: every finished business day that has no summary yet
create or replace function auto_daily_close() returns int language plpgsql security definer set search_path = public as $$
declare d date; n int := 0; last date := biz() - 1;
begin
  d := coalesce((select max(day) + 1 from daily_closings), (select min(entry_date) from journal_entries), last);
  while d <= last and n < 400 loop
    if close_day_summary(d, 'auto') then n := n + 1; end if;
    d := d + 1;
  end loop;
  return n;
end $$;

-- the desk or the office can freeze a finished day earlier than the scheduler
create or replace function staff_close_day(p_day date) returns boolean language plpgsql security definer set search_path = public as $$
begin
  perform require_role('manager', 'accountant', 'frontdesk');
  if p_day is null or p_day >= biz() then raise exception 'day_not_finished' using errcode = 'P0001'; end if;
  if exists (select 1 from daily_closings where day = p_day) then raise exception 'already_posted' using errcode = 'P0001'; end if;
  return close_day_summary(p_day, coalesce((select name from staff where user_id = auth.uid()), 'staff'));
end $$;

-- pay supplier bills that were recorded as unpaid
create or replace function acct_pay_payable(p_amount bigint, p_pay text, p_note text) returns bigint
language plpgsql security definer set search_path = public as $$
declare owed bigint; eid bigint;
begin
  perform require_role('manager', 'accountant');
  if p_pay not in ('1110', '1120') then raise exception 'invalid_account' using errcode = 'P0001'; end if;
  select coalesce(sum(l.credit - l.debit), 0) into owed from journal_lines l where l.account = '2110';
  if p_amount is null or p_amount <= 0 or p_amount > owed then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  eid := post_entry(biz(), jsonb_build_object('k', 'payBill', 'text', left(coalesce(p_note, ''), 160)), 'AP', 'cash',
                    jsonb_build_array(jl('2110', p_amount, 0), jl(p_pay, 0, p_amount)));
  perform log_action('payable.pay', 'JV-' || eid, jsonb_build_object('amount', p_amount, 'from', p_pay, 'note', p_note));
  return eid;
end $$;

-- staff screens: who posted each entry, and the frozen daily summaries
create or replace function admin_finance() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'permission_denied' using errcode = '42501'; end if;
  return jsonb_build_object(
    'assets', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'account', f.account, 'cost', f.cost, 'salvage', f.salvage,
        'life', f.life_months, 'in_use', f.in_use, 'entry', f.purchase_entry, 'at', f.created_at) order by f.id) from fixed_assets f), '[]'),
    'counts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'date', c.count_date, 'account', c.account, 'counted', c.counted, 'book', c.book,
        'diff', c.diff, 'note', c.note, 'entry', c.entry_id, 'at', c.created_at, 'by', (select name from staff where user_id = c.created_by)) order by c.id desc)
        from (select * from cash_counts order by id desc limit 200) c), '[]'),
    'closings', coalesce((select jsonb_agg(to_jsonb(x) order by x.day desc) from (select * from daily_closings order by day desc limit 800) x), '[]'),
    'jby', coalesce((select jsonb_object_agg(e.id::text,
        coalesce((select name from staff where user_id = e.created_by), (select 'web: ' || name from customers where user_id = e.created_by), 'system'))
        from journal_entries e where e.entry_date >= biz() - 800), '{}'));
end $$;

revoke execute on function money_rows(date, date), day_money(date), close_day_summary(date, text), auto_daily_close() from public, anon, authenticated;
revoke execute on function staff_close_day(date), acct_pay_payable(bigint, text, text), admin_finance() from public, anon;
grant execute on function staff_close_day(date), acct_pay_payable(bigint, text, text), admin_finance() to authenticated;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      create extension if not exists pg_cron with schema pg_catalog;
      perform cron.unschedule(jobid) from cron.job where jobname = 'saynam-daily-summary';
      perform cron.schedule('saynam-daily-summary', '30 4 * * *', 'select public.auto_daily_close()');   -- 11:30 Vientiane (UTC+7)
    exception when others then
      raise notice 'daily summary not scheduled: %', sqlerrm;
    end;
  end if;
end $$;
