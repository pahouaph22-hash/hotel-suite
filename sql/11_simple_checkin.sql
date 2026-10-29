-- =====================================================================
-- Saynam Hotel Suite — one-tap check-in, including guests who arrive early.
-- An early arrival moves the booking's check-in date to today (the room must be
-- free for those nights — the no-double-booking rule still applies) and the extra
-- night is charged at the booked rate by the night audit, like any other night.
-- =====================================================================
drop function if exists staff_check_in(text);
create or replace function staff_check_in(p_id text, p_early boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bookings; d date := biz(); today date := (now() at time zone 'Asia/Vientiane')::date; extra int := 0;
begin
  perform require_role('manager', 'frontdesk');
  select * into b from bookings where id = p_id for update;
  if b.id is null or b.status <> 'confirmed' then raise exception 'cannot_check_in' using errcode = 'P0001'; end if;
  if b.check_in > d then
    -- the business day is behind the calendar: close the missing days first, otherwise the guest would be charged for a day that is already over
    if d < today then raise exception 'close_day_first' using errcode = 'P0001'; end if;
    extra := b.check_in - d;
    if not p_early then raise exception 'early_arrival' using errcode = 'P0001', detail = extra::text; end if;
    update bookings set check_in = d where id = p_id;
    perform log_action('booking.early_arrival', p_id, jsonb_build_object('from', b.check_in, 'to', d, 'nights', extra, 'rate', b.rate));
  end if;
  perform do_check_in(p_id);
  perform log_action('booking.checkin', p_id, jsonb_build_object('room', b.room_no, 'early_nights', extra));
  return jsonb_build_object('room', b.room_no, 'early_nights', extra,
    'room_status', (select hk_status from rooms where no = b.room_no));
end $$;
revoke execute on function staff_check_in(text, boolean) from public, anon;
grant execute on function staff_check_in(text, boolean) to authenticated;

-- members see the early-arrival change in their booking history
create or replace function activity_rows(p_member uuid, p_staff_view boolean) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'at', a.at, 'action', a.action, 'code', b.code, 'bk', b.id,
      'who', case when a.user_id = p_member then 'member' when exists (select 1 from staff s where s.user_id = a.user_id) then 'hotel' else 'system' end,
      'actor', case when p_staff_view then a.actor end,
      'detail', case when p_staff_view then a.detail else
        (select coalesce(jsonb_object_agg(k, v), '{}') from jsonb_each(coalesce(a.detail, '{}')) e(k, v)
          where k in ('amount', 'method', 'refund', 'fee', 'pct', 'room', 'total', 'ci', 'co', 'kind', 'text', 'rating', 'subject', 'from', 'to', 'reason', 'was', 'nights')) end)
      order by a.id desc), '[]')
  from audit_log a
  left join bookings b on b.id = a.ref
  where (b.customer_id = p_member and a.action in ('booking.create','booking.confirmed','booking.checkin','booking.checkout','booking.cancelled','booking.noshow',
          'booking.guest_cancel','booking.expired','booking.extend','booking.early_arrival','booking.link_member','claim.create','claim.verify','claim.reject','payment.take',
          'folio.charge','folio.void','refund.paid','review.create','review.update','review.reply'))
     or (a.user_id = p_member and a.action in ('member.register','member.password_changed','support.new','support.reply','support.close'))
$$;
revoke execute on function activity_rows(uuid, boolean) from public, anon, authenticated;
