-- =====================================================================
-- Saynam Hotel Suite — tidy-up and speed
--  * the back office asks for a tiny change signature every 15 s and downloads the full picture only when something changed
--  * daily summaries start at the first day with money movements (no empty summaries for days before the hotel used the system)
--  * indexes on the foreign keys the database advisor listed
-- =====================================================================
create or replace function admin_sig() returns text language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'permission_denied' using errcode = '42501'; end if;
  return concat_ws('|', (select max(id) from audit_log), (select max(id) from journal_entries), (select business_date from settings where id = 1),
    (select count(*) from payment_claims where status = 'pending'), (select count(*) from support_messages), (select count(*) from reviews),
    (select count(*) from notifications), (select max(day) from daily_closings), (select count(*) from cash_counts), (select count(*) from fixed_assets));
end $$;
revoke execute on function admin_sig() from public, anon;
grant execute on function admin_sig() to authenticated;

create or replace function auto_daily_close() returns int language plpgsql security definer set search_path = public as $$
declare d date; n int := 0; last date := biz() - 1; first date := (select min(entry_date) from journal_entries);
begin
  if first is null then return 0; end if;
  d := greatest(coalesce((select max(day) + 1 from daily_closings), first), first);
  while d <= last and n < 400 loop
    if close_day_summary(d, 'auto') then n := n + 1; end if;
    d := d + 1;
  end loop;
  return n;
end $$;

create or replace function staff_close_day(p_day date) returns boolean language plpgsql security definer set search_path = public as $$
begin
  perform require_role('manager', 'accountant', 'frontdesk');
  if p_day is null or p_day >= biz() then raise exception 'day_not_finished' using errcode = 'P0001'; end if;
  if p_day < coalesce((select min(entry_date) from journal_entries), biz()) then raise exception 'nothing_due' using errcode = 'P0001'; end if;
  if exists (select 1 from daily_closings where day = p_day) then raise exception 'already_posted' using errcode = 'P0001'; end if;
  return close_day_summary(p_day, coalesce((select name from staff where user_id = auth.uid()), 'staff'));
end $$;

-- empty summaries made for days before the first money movement
delete from daily_closings where entries = 0 and day < coalesce((select min(entry_date) from journal_entries), current_date);

create index if not exists bookings_channel_idx on bookings(channel);
create index if not exists bookings_guest_idx on bookings(guest_id);
create index if not exists bookings_type_idx on bookings(type_id);
create index if not exists folio_items_journal_idx on folio_items(journal_id);
create index if not exists folio_items_voids_idx on folio_items(voids);
create index if not exists journal_entries_reversed_by_idx on journal_entries(reversed_by);
create index if not exists journal_entries_reverses_idx on journal_entries(reverses);
create index if not exists notifications_booking_idx on notifications(booking_id);
create index if not exists ota_receivables_booking_idx on ota_receivables(booking_id);
create index if not exists ota_receivables_channel_idx on ota_receivables(channel);
create index if not exists ota_receivables_payout_idx on ota_receivables(payout_entry);
create index if not exists payment_claims_booking_idx on payment_claims(booking_id);
create index if not exists payment_claims_payment_idx on payment_claims(payment_id);
create index if not exists payments_journal_idx on payments(journal_id);
create index if not exists refunds_journal_idx on refunds(journal_id);
create index if not exists refunds_payment_idx on refunds(payment_id);
create index if not exists rooms_type_idx on rooms(type_id);
create index if not exists support_threads_booking_idx on support_threads(booking_id);
create index if not exists cash_counts_entry_idx on cash_counts(entry_id);
create index if not exists fixed_assets_entry_idx on fixed_assets(purchase_entry);
