-- =====================================================================
-- Saynam Hotel Suite — members see when they were checked in and out (and their room once in house)
-- =====================================================================
create or replace function member_bookings() returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare c customers; s settings;
begin
  c := require_member();
  perform expire_unpaid();
  select * into s from settings where id = 1;
  return coalesce((select jsonb_agg(x order by x->>'created' desc) from (
    select jsonb_build_object(
      'code', b.code, 'status', b.status, 'ci', b.check_in, 'co', b.check_out, 'nights', b.check_out - b.check_in,
      'type', (select name from room_types where id = b.type_id), 'type_id', b.type_id, 'adults', b.adults, 'rate', b.rate,
      'total', b.rate * (b.check_out - b.check_in), 'paid', paid_net(b.id),
      'pending_claims', (select coalesce(sum(amount), 0) from payment_claims where booking_id = b.id and status = 'pending'),
      'claims', coalesce((select jsonb_agg(jsonb_build_object('amount', pc.amount, 'status', pc.status, 'at', pc.created_at, 'decided_at', pc.decided_at) order by pc.id)
                          from payment_claims pc where pc.booking_id = b.id), '[]'),
      'refund', (select jsonb_build_object('amount', r.amount, 'fee', r.fee, 'pct', r.pct, 'status', r.status, 'paid_at', r.paid_at)
                 from refunds r where r.booking_id = b.id order by r.id desc limit 1),
      'cancel_reason', b.cancel_reason, 'created', b.created_at, 'confirmed_at', b.confirmed_at,
      'checked_in_at', b.checked_in_at, 'checked_out_at', b.checked_out_at, 'room', case when b.status in ('inhouse', 'out') then b.room_no end, 'old_code', b.old_code,
      'hold_until', case when b.status = 'pending' then b.created_at + make_interval(hours => s.pending_hold_hours) end,
      'cancel_until', cancel_deadline(b.check_in),
      'can_cancel', b.status in ('pending', 'confirmed') and now() < cancel_deadline(b.check_in)
                    and not exists (select 1 from payment_claims where booking_id = b.id and status = 'pending'),
      'refund_pct', case when b.status = 'confirmed' then s.cancel_refund_pct else 100 end,
      'held', (select coalesce(sum(amount), 0) from payments where booking_id = b.id and kind = 'deposit' and not applied)
    ) x from bookings b where b.customer_id = c.user_id) q), '[]');
end $$;
