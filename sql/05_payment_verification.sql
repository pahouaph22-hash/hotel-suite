-- =====================================================================
-- Saynam Hotel Suite — website bookings wait for staff to verify payment
--
-- A website booking starts as 'pending': the room is held, but the booking
-- is not confirmed. It becomes 'confirmed' only when a staff member checks
-- the transfer slip against the bank and confirms the deposit was received.
-- Pending bookings without a slip are released after the hold period.
-- =====================================================================
alter table settings add column if not exists pending_hold_hours int not null default 24 check (pending_hold_hours between 1 and 168);
alter table bookings add column if not exists confirmed_at timestamptz;
alter table bookings add column if not exists confirmed_by uuid;
alter table bookings add column if not exists cancel_reason text;

alter table bookings drop constraint if exists bookings_status_check;
alter table bookings add constraint bookings_status_check check (status in ('pending','confirmed','inhouse','out','cancelled','noshow'));
alter table bookings drop constraint if exists no_double_booking;
alter table bookings add constraint no_double_booking exclude using gist (room_no with =, daterange(check_in, check_out) with &&)
  where (status in ('pending','confirmed','inhouse','out'));

-- release pending website bookings that never sent a slip within the hold period
create or replace function expire_unpaid() returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; b record;
begin
  for b in select bk.id from bookings bk, settings s
           where s.id = 1 and bk.status = 'pending'
             and bk.created_at < now() - make_interval(hours => s.pending_hold_hours)
             and not exists (select 1 from payment_claims c where c.booking_id = bk.id and c.status = 'pending')
             and not exists (select 1 from payments p where p.booking_id = bk.id) loop
    update bookings set status = 'cancelled', cancelled_at = now(), cancel_reason = 'unpaid_expired' where id = b.id;
    update payment_claims set status = 'rejected', decided_at = now() where booking_id = b.id and status = 'pending';
    perform log_action('booking.expired', b.id, jsonb_build_object('reason', 'no payment within hold period'));
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function free_rooms(p_type text, p_ci date, p_co date) returns setof text
language sql stable security definer set search_path = public as $$
  select r.no from rooms r
  where r.type_id = p_type and r.active and r.hk_status <> 'ooo'
    and not exists (select 1 from bookings b where b.room_no = r.no and b.status in ('pending','confirmed','inhouse','out')
                    and daterange(b.check_in, b.check_out) && daterange(p_ci, p_co))
  order by r.no
$$;

create or replace function public_availability(p_ci date, p_co date) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform check_stay(p_ci, p_co);
  perform expire_unpaid();
  return coalesce((select jsonb_agg(jsonb_build_object('type_id', t.id, 'free', (select count(*) from free_rooms(t.id, p_ci, p_co)),
                    'nightly', direct_rate(t.base_rate)) order by t.sort) from room_types t where t.active), '[]');
end $$;

create or replace function public_book(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ci date := (p->>'ci')::date; co date := (p->>'co')::date; t room_types; pct numeric := 0;
  room text; gid uuid; bid text; bcode text; rate bigint; n int; dep bigint; s settings;
begin
  perform check_stay(ci, co);
  perform expire_unpaid();
  select * into s from settings where id = 1;
  select * into t from room_types where id = p->>'type' and active;
  if t.id is null then raise exception 'invalid_room_type' using errcode = 'P0001'; end if;
  if coalesce((p->>'adults')::int, 1) > t.capacity then raise exception 'too_many_guests' using errcode = 'P0001'; end if;
  if length(trim(coalesce(p->>'name',''))) < 2 then raise exception 'name_required' using errcode = 'P0001'; end if;
  if length(regexp_replace(coalesce(p->>'phone',''), '\D', '', 'g')) < 8 then raise exception 'phone_required' using errcode = 'P0001'; end if;
  if nullif(trim(p->>'promo'), '') is not null then
    pct := promo_pct(p->>'promo');
    if pct is null then raise exception 'promo_invalid' using errcode = 'P0001'; end if;
  end if;
  perform pg_advisory_xact_lock(hashtext('hotel-booking'));
  select f into room from free_rooms(t.id, ci, co) f limit 1;
  if room is null then raise exception 'sold_out' using errcode = 'P0001'; end if;
  n := co - ci;
  rate := (round(direct_rate(t.base_rate) * (1 - pct / 100) / 1000) * 1000)::bigint;
  dep := (round(rate * n * s.deposit_pct / 100 / 10000) * 10000)::bigint;
  insert into guests(name, phone, email, country) values (trim(p->>'name'), trim(p->>'phone'), nullif(trim(p->>'email'),''), coalesce(nullif(p->>'country',''),'OT'))
    returning id into gid;
  insert into bookings(guest_id, room_no, type_id, check_in, check_out, adults, channel, rate, deposit_due, promo, special_request, source, status)
  values (gid, room, t.id, ci, co, coalesce((p->>'adults')::int, 1), 'DIR', rate, dep, nullif(upper(trim(p->>'promo')),''), left(p->>'request', 500), 'website',
          case when dep > 0 then 'pending' else 'confirmed' end)
  returning id, code into bid, bcode;
  perform log_action('booking.create', bid, jsonb_build_object('source','website','ci',ci,'co',co,'type',t.id,'status', case when dep > 0 then 'pending' else 'confirmed' end));
  return jsonb_build_object('id', bid, 'code', bcode, 'nights', n, 'rate', rate, 'total', rate * n, 'deposit_due', dep,
                            'status', case when dep > 0 then 'pending' else 'confirmed' end, 'hold_hours', s.pending_hold_hours);
end $$;

-- money received before the stay starts is a customer deposit (liability 2150) for pending and confirmed bookings alike
create or replace function add_payment(p_booking text, p_date date, p_method text, p_amount bigint, p_ref text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare b bookings; dep boolean; eid bigint; pid bigint; gname text;
begin
  if p_amount <= 0 then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  select * into b from bookings where id = p_booking for update;
  select name into gname from guests where id = b.guest_id;
  dep := b.status in ('pending','confirmed');
  eid := post_entry(p_date, jsonb_build_object('k', case when dep then 'dep' else 'pay' end, 'm', p_method, 'g', gname), b.id,
                    case when dep then 'deposit' else 'payment' end,
                    jsonb_build_array(jl(pay_account(p_method), p_amount, 0), jl(case when dep then '2150' else '1130' end, 0, p_amount)));
  insert into payments(booking_id, biz_date, method, amount, kind, applied, reference, journal_id, created_by)
  values (b.id, p_date, p_method, p_amount, case when dep then 'deposit' else 'payment' end, not dep, p_ref, eid, auth.uid()) returning id into pid;
  return pid;
end $$;

create or replace function slip_path_ok(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_name ~ '^[0-9A-F]{6}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
     and exists (select 1 from bookings b where b.code = split_part(p_name, '/', 1) and b.status in ('pending','confirmed')
                 and (select count(*) from payment_claims c where c.booking_id = b.id and c.status = 'pending') < 3)
$$;

create or replace function public_claim(p_code text, p_phone text, p_amount bigint, p_ref text, p_slip text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  b := find_guest_booking(p_code, p_phone);
  if b.id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if b.status not in ('pending','confirmed') then raise exception 'not_payable' using errcode = 'P0001'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > b.rate * (b.check_out - b.check_in) then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  if (select count(*) from payment_claims where booking_id = b.id and status = 'pending') >= 3 then raise exception 'too_many_claims' using errcode = 'P0001'; end if;
  if p_slip is null or split_part(p_slip, '/', 1) <> b.code
     or not exists (select 1 from storage.objects o where o.bucket_id = 'slips' and o.name = p_slip) then
    raise exception 'slip_required' using errcode = 'P0001';
  end if;
  insert into payment_claims(booking_id, amount, reference, slip_path) values (b.id, p_amount, left(p_ref, 80), p_slip);
  perform log_action('claim.create', b.id, jsonb_build_object('amount', p_amount, 'slip', p_slip));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public_lookup(p_code text, p_phone text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare b bookings; last_claim text; hold int;
begin
  perform expire_unpaid();
  b := find_guest_booking(p_code, p_phone);
  if b.id is null then return null; end if;
  select status into last_claim from payment_claims where booking_id = b.id order by id desc limit 1;
  select pending_hold_hours into hold from settings where id = 1;
  return jsonb_build_object('code', b.code, 'status', b.status, 'ci', b.check_in, 'co', b.check_out, 'nights', b.check_out - b.check_in,
    'type', (select name from room_types where id = b.type_id), 'adults', b.adults, 'rate', b.rate, 'total', b.rate * (b.check_out - b.check_in),
    'guest', (select name from guests where id = b.guest_id), 'deposit_due', b.deposit_due,
    'paid', (select coalesce(sum(case kind when 'refund' then -amount else amount end),0) from payments where booking_id = b.id),
    'pending_claims', (select coalesce(sum(amount),0) from payment_claims where booking_id = b.id and status = 'pending'),
    'last_claim', last_claim, 'cancel_reason', b.cancel_reason,
    'hold_until', case when b.status = 'pending' then b.created_at + make_interval(hours => hold) end);
end $$;

-- staff accept a pending booking: only once the deposit has actually been received
create or replace function confirm_if_paid(p_booking text) returns boolean language plpgsql security definer set search_path = public as $$
declare b bookings; paid bigint;
begin
  select * into b from bookings where id = p_booking for update;
  if b.status <> 'pending' then return false; end if;
  select coalesce(sum(case kind when 'refund' then -amount else amount end), 0) into paid from payments where booking_id = b.id;
  if paid < b.deposit_due then return false; end if;
  update bookings set status = 'confirmed', confirmed_at = now(), confirmed_by = auth.uid() where id = b.id;
  perform log_action('booking.confirmed', b.id, jsonb_build_object('paid', paid, 'deposit_due', b.deposit_due));
  return true;
end $$;

create or replace function staff_accept_booking(p_id text) returns void language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  perform require_role('manager','frontdesk','accountant');
  select * into b from bookings where id = p_id;
  if b.status <> 'pending' then raise exception 'not_pending' using errcode = 'P0001'; end if;
  if not confirm_if_paid(p_id) then raise exception 'deposit_not_received' using errcode = 'P0001'; end if;
end $$;

create or replace function staff_verify_claim(p_claim bigint, p_approve boolean, p_method text default 'qr') returns void
language plpgsql security definer set search_path = public as $$
declare c payment_claims; pid bigint;
begin
  perform require_role('manager','frontdesk','accountant');
  select * into c from payment_claims where id = p_claim for update;
  if c.status <> 'pending' then raise exception 'already_decided' using errcode = 'P0001'; end if;
  if p_approve then
    if (select status from bookings where id = c.booking_id) not in ('pending','confirmed','inhouse') then raise exception 'not_payable' using errcode = 'P0001'; end if;
    pid := add_payment(c.booking_id, biz(), p_method, c.amount, coalesce(c.reference, 'slip #' || c.id));
  end if;
  update payment_claims set status = case when p_approve then 'verified' else 'rejected' end, payment_id = pid,
         decided_by = auth.uid(), decided_at = now() where id = p_claim;
  perform log_action(case when p_approve then 'claim.verify' else 'claim.reject' end, c.booking_id, jsonb_build_object('claim', p_claim, 'amount', c.amount));
  if p_approve then perform confirm_if_paid(c.booking_id); end if;
end $$;

create or replace function staff_payment(p_id text, p_method text, p_amount bigint, p_ref text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_role('manager','frontdesk','accountant');
  if (select status from bookings where id = p_id) not in ('pending','confirmed','inhouse') then raise exception 'not_payable' using errcode = 'P0001'; end if;
  perform add_payment(p_id, biz(), p_method, p_amount, p_ref);
  perform log_action('payment.take', p_id, jsonb_build_object('method', p_method, 'amount', p_amount, 'ref', p_ref));
end $$;

create or replace function staff_cancel(p_id text, p_status text, p_refund boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  perform require_role('manager','frontdesk');
  select * into b from bookings where id = p_id for update;
  if b.status not in ('pending','confirmed') or p_status not in ('cancelled','noshow') then raise exception 'cannot_cancel' using errcode = 'P0001'; end if;
  if p_status = 'noshow' and (b.check_in > biz() or b.status = 'pending') then raise exception 'cannot_cancel' using errcode = 'P0001'; end if;
  perform apply_deposits(p_id, biz(), case when p_refund and p_status = 'cancelled' then 'refund' else 'forfeit' end);
  update bookings set status = p_status, cancelled_at = now(), cancel_reason = case when b.status = 'pending' then 'declined_by_staff' end where id = p_id;
  update payment_claims set status = 'rejected', decided_by = auth.uid(), decided_at = now() where booking_id = p_id and status = 'pending';
  perform log_action('booking.' || p_status, p_id, jsonb_build_object('refund', p_refund, 'was', b.status));
end $$;

create or replace function staff_night_audit() returns jsonb language plpgsql security definer set search_path = public as $$
declare d date := biz(); b record; n int := 0; ns int := 0; ex int := 0; amt bigint := 0;
begin
  perform require_role('manager','frontdesk');
  if exists (select 1 from bookings where status = 'inhouse' and check_out <= d) then
    raise exception 'departures_pending' using errcode = 'P0001';
  end if;
  -- website bookings whose payment was never confirmed by the arrival date are released, not charged
  for b in select id from bookings where status = 'pending' and check_in <= d loop
    perform apply_deposits(b.id, d, 'refund');
    update bookings set status = 'cancelled', cancelled_at = now(), cancel_reason = 'unpaid_at_arrival' where id = b.id;
    update payment_claims set status = 'rejected', decided_at = now() where booking_id = b.id and status = 'pending';
    perform log_action('booking.expired', b.id, jsonb_build_object('reason', 'payment not confirmed by arrival date'));
    ex := ex + 1;
  end loop;
  for b in select id from bookings where status = 'confirmed' and check_in <= d loop
    perform apply_deposits(b.id, d, 'forfeit');
    update bookings set status = 'noshow', cancelled_at = now() where id = b.id;
    ns := ns + 1;
  end loop;
  for b in select id, room_no, rate from bookings where status = 'inhouse' order by room_no loop
    perform add_charge(b.id, d, 'room', jsonb_build_object('k','night','room',b.room_no,'d',d), b.rate);
    n := n + 1; amt := amt + b.rate;
  end loop;
  update rooms set hk_status = 'dirty' where hk_status <> 'ooo' and no in (select room_no from bookings where status = 'inhouse');
  perform set_config('hotel.night_audit', 'on', true);
  update settings set business_date = d + 1 where id = 1;
  perform log_action('night_audit', to_char(d, 'YYYY-MM-DD'), jsonb_build_object('room_nights', n, 'amount', amt, 'noshows', ns, 'unpaid_released', ex));
  perform expire_unpaid();
  return jsonb_build_object('room_nights', n, 'amount', amt, 'noshows', ns, 'unpaid_released', ex, 'business_date', d + 1);
end $$;

-- staff screens also need why a booking was released and when it was accepted
create or replace function admin_snapshot() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'permission_denied' using errcode = '42501'; end if;
  return jsonb_build_object(
    'me', me(),
    'settings', (select to_jsonb(s) from settings s where id = 1),
    'accounts', (select jsonb_agg(to_jsonb(a) order by code) from accounts a),
    'types', (select jsonb_agg(to_jsonb(t) order by sort) from room_types t),
    'rooms', (select jsonb_agg(to_jsonb(r) order by no) from rooms r),
    'channels', (select jsonb_agg(to_jsonb(c)) from channels c),
    'promos', coalesce((select jsonb_agg(to_jsonb(p)) from promo_codes p), '[]'),
    'amenities', coalesce((select jsonb_agg(to_jsonb(m) order by sort) from amenities m), '[]'),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object(
        'id', b.id, 'code', b.code, 'guest', jsonb_build_object('id', g.id, 'name', g.name, 'phone', g.phone, 'email', g.email, 'country', g.country),
        'room', b.room_no, 'type', b.type_id, 'ci', b.check_in, 'co', b.check_out, 'adults', b.adults, 'ch', b.channel, 'rate', b.rate,
        'status', b.status, 'created', (b.created_at at time zone 'Asia/Vientiane')::date, 'source', b.source, 'deposit_due', b.deposit_due,
        'promo', b.promo, 'request', b.special_request, 'cancel_reason', b.cancel_reason, 'confirmed_at', b.confirmed_at,
        'folio', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'date', f.biz_date, 'kind', f.kind, 'desc', f.description,
                  'gross', f.gross, 'net', f.net, 'vat', f.vat, 'voids', f.voids) order by f.id) from folio_items f where f.booking_id = b.id), '[]'),
        'pays', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'date', p.biz_date, 'm', p.method, 'amt', p.amount,
                  'dep', p.kind = 'deposit', 'applied', p.applied, 'refund', p.kind = 'refund', 'ref', p.reference) order by p.id) from payments p where p.booking_id = b.id), '[]')
      ) order by b.check_in) from bookings b join guests g on g.id = b.guest_id), '[]'),
    'journal', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'date', e.entry_date, 'desc', e.description, 'ref', e.ref, 'src', e.source,
        'rev', e.reverses, 'revBy', e.reversed_by, 'at', e.created_at,
        'lines', (select jsonb_agg(jsonb_build_object('a', l.account, 'dr', l.debit, 'cr', l.credit) order by l.id) from journal_lines l where l.entry_id = e.id))
      order by e.id) from journal_entries e), '[]'),
    'arOTA', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'bk', o.booking_id, 'ch', o.channel, 'date', o.entry_date, 'gross', o.gross,
        'amt', o.amount, 'settled', o.settled_on is not null)) from ota_receivables o), '[]'),
    'claims', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'bk', c.booking_id, 'amt', c.amount, 'ref', c.reference, 'status', c.status,
        'slip', c.slip_path, 'at', c.created_at) order by c.id desc) from payment_claims c), '[]'),
    'locks', coalesce((select jsonb_agg(month order by month) from period_locks), '[]'),
    'audit', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'at', a.at, 'actor', a.actor, 'action', a.action, 'ref', a.ref, 'detail', a.detail) order by a.id desc)
      from (select * from audit_log order by id desc limit 500) a), '[]')
  );
end $$;

revoke execute on function expire_unpaid(), confirm_if_paid(text), staff_accept_booking(text) from public, anon;
grant execute on function staff_accept_booking(text) to authenticated;

-- website bookings that were marked confirmed before this rule existed, with no money received yet, go back to pending
update bookings b set status = 'pending'
where b.source = 'website' and b.status = 'confirmed' and b.deposit_due > 0
  and not exists (select 1 from payments p where p.booking_id = b.id);
