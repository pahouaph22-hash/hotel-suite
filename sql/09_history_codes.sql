-- =====================================================================
-- Saynam Hotel Suite — booking codes SN0000–SN9999, linking older bookings to
-- member accounts, and a full activity history per customer.
-- =====================================================================

-- ---------- booking codes: "SN" (ສາຍນ້ຳ) + 4 digits, random, never reused ----------
alter table bookings add column if not exists old_code text;
create or replace function new_booking_code() returns text language plpgsql volatile security definer set search_path = public as $$
declare c text; i int := 0;
begin
  loop
    c := 'SN' || lpad((floor(random() * 10000))::int::text, 4, '0');
    exit when not exists (select 1 from bookings where code = c or old_code = c);
    i := i + 1;
    if i > 200 then
      -- fall back to a sequential scan for the first free number when the space is crowded
      select 'SN' || lpad(n::text, 4, '0') into c from generate_series(0, 9999) n
       where not exists (select 1 from bookings where code = 'SN' || lpad(n::text, 4, '0')) limit 1;
      if c is null then raise exception 'booking_codes_exhausted' using errcode = 'P0001'; end if;
      exit;
    end if;
  end loop;
  return c;
end $$;
alter table bookings alter column code set default new_booking_code();
-- the unique constraint on bookings.code stays: two bookings can never share a code
alter table bookings drop constraint if exists booking_code_format;
alter table bookings add constraint booking_code_format check (code ~ '^SN[0-9]{4}$') not valid;

-- give existing bookings an SN code; keep the old one so it can still be searched
do $$
declare b record;
begin
  for b in select id, code from bookings where code !~ '^SN[0-9]{4}$' order by created_at loop
    update bookings set old_code = b.code, code = new_booking_code() where id = b.id;
  end loop;
end $$;
alter table bookings validate constraint booking_code_format;

-- slips are stored under the booking code folder; accept the new code format
create or replace function slip_path_ok(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and p_name ~ '^SN[0-9]{4}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
     and exists (select 1 from bookings b where b.code = split_part(p_name, '/', 1) and b.status = 'pending' and b.customer_id = auth.uid()
                 and (select count(*) from payment_claims c where c.booking_id = b.id and c.status = 'pending') < 3)
$$;

-- ---------- link a booking made before accounts existed (or at the desk) to a member ----------
create or replace function staff_link_member(p_id text, p_member uuid) returns void language plpgsql security definer set search_path = public as $$
declare b bookings; c customers;
begin
  perform require_role('manager', 'frontdesk');
  select * into b from bookings where id = p_id for update;
  if b.id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if b.customer_id is not null then raise exception 'already_linked' using errcode = 'P0001'; end if;
  select * into c from customers where user_id = p_member;
  if c.user_id is null then raise exception 'user_not_found' using errcode = 'P0001'; end if;
  update bookings set customer_id = c.user_id where id = p_id;
  perform log_action('booking.link_member', p_id, jsonb_build_object('member', c.email, 'name', c.name));
  perform notify(c.user_id, 'booking_linked', p_id, jsonb_build_object('code', b.code));
end $$;

create or replace function staff_unlink_member(p_id text) returns void language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  perform require_role('manager');
  select * into b from bookings where id = p_id for update;
  if b.customer_id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  update bookings set customer_id = null where id = p_id;
  perform log_action('booking.unlink_member', p_id, jsonb_build_object('member', (select email from customers where user_id = b.customer_id)));
end $$;

-- the owner's own test bookings from before member accounts: same name and phone as the member who made them
update bookings b set customer_id = c.user_id
from customers c join guests g0 on true
where b.customer_id is null and b.source = 'website' and g0.id = b.guest_id
  and right(regexp_replace(g0.phone, '\D', '', 'g'), 8) = right(regexp_replace(c.phone, '\D', '', 'g'), 8)
  and lower(trim(g0.name)) = lower(trim(c.name))
  and c.email = 'pahouaph22@gmail.com';

-- ---------- activity history ----------
-- what a customer may see about their own bookings: everything that changed them, without staff names or internal notes
create or replace function activity_rows(p_member uuid, p_staff_view boolean) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'at', a.at, 'action', a.action, 'code', b.code, 'bk', b.id,
      'who', case when a.user_id = p_member then 'member' when exists (select 1 from staff s where s.user_id = a.user_id) then 'hotel' else 'system' end,
      'actor', case when p_staff_view then a.actor end,
      'detail', case when p_staff_view then a.detail else
        (select coalesce(jsonb_object_agg(k, v), '{}') from jsonb_each(coalesce(a.detail, '{}')) e(k, v)
          where k in ('amount', 'method', 'refund', 'fee', 'pct', 'room', 'total', 'ci', 'co', 'kind', 'text', 'rating', 'subject', 'from', 'to', 'reason', 'was')) end)
      order by a.id desc), '[]')
  from audit_log a
  left join bookings b on b.id = a.ref
  where (b.customer_id = p_member and a.action in ('booking.create','booking.confirmed','booking.checkin','booking.checkout','booking.cancelled','booking.noshow',
          'booking.guest_cancel','booking.expired','booking.extend','booking.link_member','claim.create','claim.verify','claim.reject','payment.take',
          'folio.charge','folio.void','refund.paid','review.create','review.update','review.reply'))
     or (a.user_id = p_member and a.action in ('member.register','member.password_changed','support.new','support.reply','support.close'))
$$;

create or replace function member_activity() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c customers;
begin
  c := require_member();
  return activity_rows(c.user_id, false);
end $$;

create or replace function admin_member_history(p_member uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform require_role('manager', 'frontdesk', 'accountant');
  return jsonb_build_object('activity', activity_rows(p_member, true));
end $$;

create or replace function member_hub() returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform require_member();
  return jsonb_build_object('me', member_me(), 'bookings', member_bookings(), 'payments', member_payments(), 'threads', member_threads(),
    'reviews', member_reviews(), 'notifications', member_notifications(), 'activity', member_activity(),
    'unread', (select count(*) from notifications where customer_id = auth.uid() and read_at is null));
end $$;

-- staff screens: check-in/out stamps plus the previous booking code
create or replace function admin_stays() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'permission_denied' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'ci_at', b.checked_in_at, 'co_at', b.checked_out_at, 'old_code', b.old_code,
      'ci_by', (select name from staff where user_id = b.checked_in_by), 'co_by', (select name from staff where user_id = b.checked_out_by)))
    from bookings b where b.checked_in_at is not null or b.checked_out_at is not null or b.old_code is not null), '[]');
end $$;

revoke execute on function new_booking_code(), activity_rows(uuid, boolean) from public, anon, authenticated;
revoke execute on function staff_link_member(text, uuid), staff_unlink_member(text), member_activity(), admin_member_history(uuid) from public, anon;
grant execute on function staff_link_member(text, uuid), staff_unlink_member(text), member_activity(), admin_member_history(uuid) to authenticated;
