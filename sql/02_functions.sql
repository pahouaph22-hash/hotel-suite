-- =====================================================================
-- Saynam Hotel Suite — business logic. All writes to bookings, folios,
-- payments and the books happen inside these functions, so the same
-- posting rules apply whether the guest website or a staff member acts.
-- =====================================================================
alter table settings add column if not exists close_amounts jsonb not null
  default '{"depr": 47083333, "sal": 52000000, "int": 13333333}';

-- ---------- helpers ----------
create or replace function my_role() returns text language sql stable security definer set search_path = public as $$
  select role from staff where user_id = auth.uid() and active
$$;
create or replace function is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select my_role() is not null
$$;
create or replace function require_role(variadic roles text[]) returns void language plpgsql stable security definer set search_path = public as $$
declare r text := my_role();
begin
  if r is null or not (r = 'owner' or r = any(roles)) then
    raise exception 'permission_denied' using errcode = '42501', detail = coalesce(r, 'not staff');
  end if;
end $$;
create or replace function biz() returns date language sql stable security definer set search_path = public as $$
  select business_date from settings where id = 1
$$;
create or replace function log_action(p_action text, p_ref text, p_detail jsonb default null) returns void
language sql security definer set search_path = public as $$
  insert into audit_log(user_id, actor, action, ref, detail)
  values (auth.uid(), coalesce((select name from staff where user_id = auth.uid()), case when auth.uid() is null then 'website' end), p_action, p_ref, p_detail)
$$;
create or replace function jl(a text, dr bigint, cr bigint) returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object('a', a, 'dr', coalesce(dr,0), 'cr', coalesce(cr,0))
$$;
create or replace function assert_open(d date) returns void language plpgsql stable security definer set search_path = public as $$
begin
  if exists (select 1 from period_locks where month = to_char(d, 'YYYY-MM')) then
    raise exception 'period_locked' using errcode = 'P0001', detail = to_char(d, 'YYYY-MM');
  end if;
end $$;

create or replace function post_entry(p_date date, p_desc jsonb, p_ref text, p_source text, p_lines jsonb, p_reverses bigint default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare eid bigint; d bigint; c bigint;
begin
  perform assert_open(p_date);
  select coalesce(sum((x->>'dr')::bigint),0), coalesce(sum((x->>'cr')::bigint),0) into d, c from jsonb_array_elements(p_lines) x;
  if d <> c or d = 0 then raise exception 'unbalanced_entry' using errcode = 'P0001', detail = format('Dr %s Cr %s', d, c); end if;
  insert into journal_entries(entry_date, description, ref, source, reverses, created_by)
  values (p_date, p_desc, p_ref, p_source, p_reverses, auth.uid()) returning id into eid;
  insert into journal_lines(entry_id, account, debit, credit)
  select eid, x->>'a', (x->>'dr')::bigint, (x->>'cr')::bigint from jsonb_array_elements(p_lines) x
  where (x->>'dr')::bigint + (x->>'cr')::bigint > 0;
  return eid;
end $$;

create or replace function vat_split(p_amount bigint, out gross bigint, out net bigint, out vat bigint)
language plpgsql stable security definer set search_path = public as $$
declare r numeric; incl boolean;
begin
  select vat_rate / 100, prices_incl_vat into r, incl from settings where id = 1;
  if incl then vat := round(p_amount * r / (1 + r)); gross := p_amount; net := p_amount - vat;
  else vat := round(p_amount * r); net := p_amount; gross := p_amount + vat; end if;
end $$;

create or replace function direct_rate(p_base bigint) returns bigint language sql stable security definer set search_path = public as $$
  select (round(p_base * (1 - direct_discount / 100) / 1000) * 1000)::bigint from settings where id = 1
$$;

create or replace function pay_account(p_method text) returns text language sql immutable set search_path = public as $$
  select case when p_method = 'cash' then '1110' else '1120' end
$$;

create or replace function balance_of(p_booking text) returns bigint language sql stable security definer set search_path = public as $$
  select coalesce((select sum(gross) from folio_items where booking_id = p_booking), 0)
       - coalesce((select sum(case kind when 'refund' then -amount else amount end) from payments where booking_id = p_booking), 0)
       - coalesce((select sum(gross) from ota_receivables where booking_id = p_booking), 0)   -- room charges billed to a prepaid OTA
$$;

create or replace function add_charge(p_booking text, p_date date, p_kind text, p_desc jsonb, p_amount bigint, p_voids bigint default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v record; acc text; eid bigint; fid bigint;
begin
  if p_amount <= 0 then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  select * into v from vat_split(p_amount);
  acc := case p_kind when 'room' then '4100' when 'fnb' then '4200' else '4300' end;
  eid := post_entry(p_date, p_desc, p_booking, 'folio', jsonb_build_array(jl('1130', v.gross, 0), jl(acc, 0, v.net), jl('2140', 0, v.vat)));
  insert into folio_items(booking_id, biz_date, kind, description, gross, net, vat, journal_id, created_by)
  values (p_booking, p_date, p_kind, p_desc, v.gross, v.net, v.vat, eid, auth.uid()) returning id into fid;
  return fid;
end $$;

create or replace function add_payment(p_booking text, p_date date, p_method text, p_amount bigint, p_ref text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare b bookings; dep boolean; eid bigint; pid bigint; gname text;
begin
  if p_amount <= 0 then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  select * into b from bookings where id = p_booking for update;
  select name into gname from guests where id = b.guest_id;
  dep := b.status = 'confirmed';
  eid := post_entry(p_date, jsonb_build_object('k', case when dep then 'dep' else 'pay' end, 'm', p_method, 'g', gname), b.id,
                    case when dep then 'deposit' else 'payment' end,
                    jsonb_build_array(jl(pay_account(p_method), p_amount, 0), jl(case when dep then '2150' else '1130' end, 0, p_amount)));
  insert into payments(booking_id, biz_date, method, amount, kind, applied, reference, journal_id, created_by)
  values (b.id, p_date, p_method, p_amount, case when dep then 'deposit' else 'payment' end, not dep, p_ref, eid, auth.uid()) returning id into pid;
  return pid;
end $$;

create or replace function apply_deposits(p_booking text, p_date date, p_mode text) returns void
language plpgsql security definer set search_path = public as $$
-- p_mode: 'checkin' moves held deposits onto the folio; 'forfeit' recognises them as revenue; 'refund' pays them back
declare s bigint; gname text; b bookings; eid bigint;
begin
  select * into b from bookings where id = p_booking;
  select name into gname from guests where id = b.guest_id;
  select coalesce(sum(amount), 0) into s from payments where booking_id = p_booking and kind = 'deposit' and not applied;
  if s = 0 then return; end if;
  if p_mode = 'checkin' then
    perform post_entry(p_date, jsonb_build_object('k','depApply','g',gname), b.id, 'deposit', jsonb_build_array(jl('2150', s, 0), jl('1130', 0, s)));
  elsif p_mode = 'forfeit' then
    perform post_entry(p_date, jsonb_build_object('k','forfeit','g',gname), b.id, 'deposit', jsonb_build_array(jl('2150', s, 0), jl('4300', 0, s)));
  else
    eid := post_entry(p_date, jsonb_build_object('k','depRefund','g',gname), b.id, 'deposit', jsonb_build_array(jl('2150', s, 0), jl('1120', 0, s)));
    insert into payments(booking_id, biz_date, method, amount, kind, applied, journal_id, created_by)
    values (b.id, p_date, 'transfer', s, 'refund', true, eid, auth.uid());
  end if;
  update payments set applied = true where booking_id = p_booking and kind = 'deposit' and not applied;
end $$;

-- =====================================================================
-- PUBLIC (guest website) — callable without login
-- =====================================================================
create or replace function public_catalog() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'hotel', (select jsonb_build_object('name', hotel_name, 'tagline', tagline, 'about', about, 'address', address, 'phone', phone,
              'email', email, 'map_url', map_url, 'check_in_time', check_in_time, 'check_out_time', check_out_time,
              'deposit_pct', deposit_pct, 'direct_discount', direct_discount, 'free_cancel_days', free_cancel_days,
              'payment_note', payment_note, 'payment_qr_url', payment_qr_url, 'vat_rate', vat_rate, 'prices_incl_vat', prices_incl_vat, 'business_date', business_date)
              from settings where id = 1),
    'types', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'description', description, 'capacity', capacity,
              'base_rate', base_rate, 'direct_rate', direct_rate(base_rate), 'size_m2', size_m2, 'bed', bed, 'amenities', amenities) order by sort)
              from room_types where active), '[]'),
    'amenities', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'icon', icon, 'name', name) order by sort) from amenities), '[]'))
$$;

create or replace function free_rooms(p_type text, p_ci date, p_co date) returns setof text
language sql stable security definer set search_path = public as $$
  select r.no from rooms r
  where r.type_id = p_type and r.active and r.hk_status <> 'ooo'
    and not exists (select 1 from bookings b where b.room_no = r.no and b.status in ('confirmed','inhouse','out')
                    and daterange(b.check_in, b.check_out) && daterange(p_ci, p_co))
  order by r.no
$$;

create or replace function check_stay(p_ci date, p_co date) returns void language plpgsql stable security definer set search_path = public as $$
begin
  if p_ci is null or p_co is null or p_co <= p_ci then raise exception 'invalid_dates' using errcode = 'P0001'; end if;
  if p_ci < biz() then raise exception 'date_in_past' using errcode = 'P0001'; end if;
  if p_co - p_ci > 30 or p_ci > biz() + 400 then raise exception 'stay_too_long' using errcode = 'P0001'; end if;
end $$;

create or replace function public_availability(p_ci date, p_co date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform check_stay(p_ci, p_co);
  return coalesce((select jsonb_agg(jsonb_build_object('type_id', t.id, 'free', (select count(*) from free_rooms(t.id, p_ci, p_co)),
                    'nightly', direct_rate(t.base_rate)) order by t.sort) from room_types t where t.active), '[]');
end $$;

create or replace function promo_pct(p_code text) returns numeric language sql stable security definer set search_path = public as $$
  select pct from promo_codes where code = upper(trim(p_code)) and active and (valid_to is null or valid_to >= biz())
$$;

create or replace function public_book(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ci date := (p->>'ci')::date; co date := (p->>'co')::date; t room_types; pct numeric := 0;
  room text; gid uuid; bid text; bcode text; rate bigint; n int; dep bigint; s settings;
begin
  perform check_stay(ci, co);
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
  insert into bookings(guest_id, room_no, type_id, check_in, check_out, adults, channel, rate, deposit_due, promo, special_request, source)
  values (gid, room, t.id, ci, co, coalesce((p->>'adults')::int, 1), 'DIR', rate, dep, nullif(upper(trim(p->>'promo')),''), left(p->>'request', 500), 'website')
  returning id, code into bid, bcode;
  perform log_action('booking.create', bid, jsonb_build_object('source','website','ci',ci,'co',co,'type',t.id));
  return jsonb_build_object('id', bid, 'code', bcode, 'nights', n, 'rate', rate, 'total', rate * n, 'deposit_due', dep);
end $$;

create or replace function find_guest_booking(p_code text, p_phone text) returns bookings
language sql stable security definer set search_path = public as $$
  select b.* from bookings b join guests g on g.id = b.guest_id
  where b.code = upper(trim(p_code))
    and length(regexp_replace(coalesce(p_phone,''), '\D', '', 'g')) >= 8
    and right(regexp_replace(g.phone, '\D', '', 'g'), 8) = right(regexp_replace(p_phone, '\D', '', 'g'), 8)
$$;

create or replace function public_lookup(p_code text, p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b bookings;
begin
  b := find_guest_booking(p_code, p_phone);
  if b.id is null then return null; end if;
  return jsonb_build_object('code', b.code, 'status', b.status, 'ci', b.check_in, 'co', b.check_out, 'nights', b.check_out - b.check_in,
    'type', (select name from room_types where id = b.type_id), 'adults', b.adults, 'rate', b.rate, 'total', b.rate * (b.check_out - b.check_in),
    'guest', (select name from guests where id = b.guest_id), 'deposit_due', b.deposit_due,
    'paid', (select coalesce(sum(case kind when 'refund' then -amount else amount end),0) from payments where booking_id = b.id),
    'pending_claims', (select coalesce(sum(amount),0) from payment_claims where booking_id = b.id and status = 'pending'));
end $$;

-- public_claim (guest payment report with slip) is defined in 04_payment_slips.sql

-- =====================================================================
-- STAFF — front office
-- =====================================================================
create or replace function me() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', user_id, 'name', name, 'role', role) from staff where user_id = auth.uid() and active
$$;

create or replace function do_check_in(p_booking text) returns void language plpgsql security definer set search_path = public as $$
begin
  update bookings set status = 'inhouse', checked_in_at = now() where id = p_booking;
  perform apply_deposits(p_booking, biz(), 'checkin');
end $$;

create or replace function staff_create_booking(p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare ci date := (p->>'ci')::date; co date := (p->>'co')::date; gid uuid; bid text; r rooms;
begin
  perform require_role('manager','frontdesk');
  perform check_stay(ci, co);
  select * into r from rooms where no = p->>'room' and active;
  if r.no is null or r.hk_status = 'ooo' then raise exception 'room_unavailable' using errcode = 'P0001'; end if;
  if length(trim(coalesce(p->>'name',''))) < 2 then raise exception 'name_required' using errcode = 'P0001'; end if;
  if nullif(p->>'guest_id','') is not null then gid := (p->>'guest_id')::uuid;
  else insert into guests(name, phone, email, country) values (trim(p->>'name'), nullif(trim(p->>'phone'),''), nullif(trim(p->>'email'),''), coalesce(nullif(p->>'country',''),'OT')) returning id into gid; end if;
  insert into bookings(guest_id, room_no, type_id, check_in, check_out, adults, channel, rate, special_request, source, created_by)
  values (gid, r.no, r.type_id, ci, co, coalesce((p->>'adults')::int,1), p->>'ch', (p->>'rate')::bigint, left(p->>'request',500), 'staff', auth.uid())
  returning id into bid;
  if coalesce((p->>'deposit')::bigint, 0) > 0 then perform add_payment(bid, biz(), coalesce(p->>'method','qr'), (p->>'deposit')::bigint, p->>'ref'); end if;
  if coalesce((p->>'checkin')::boolean, false) and ci = biz() then perform do_check_in(bid); end if;
  perform log_action('booking.create', bid, jsonb_build_object('source','staff','ci',ci,'co',co,'room',r.no,'ch',p->>'ch','rate',p->>'rate'));
  return bid;
end $$;

create or replace function staff_check_in(p_id text) returns void language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  perform require_role('manager','frontdesk');
  select * into b from bookings where id = p_id for update;
  if b.status <> 'confirmed' or b.check_in > biz() then raise exception 'cannot_check_in' using errcode = 'P0001'; end if;
  perform do_check_in(p_id);
  perform log_action('booking.checkin', p_id, jsonb_build_object('room', b.room_no));
end $$;

create or replace function staff_check_out(p_id text, p_method text) returns void language plpgsql security definer set search_path = public as $$
declare b bookings; ch channels; room_gross bigint; bal bigint; ota bigint := 0; comm bigint; eid bigint; d date := biz();
begin
  perform require_role('manager','frontdesk');
  select * into b from bookings where id = p_id for update;
  if b.status <> 'inhouse' then raise exception 'not_in_house' using errcode = 'P0001'; end if;
  select * into ch from channels where id = b.channel;
  select coalesce(sum(gross),0) into room_gross from folio_items where booking_id = p_id and kind = 'room';
  bal := balance_of(p_id);
  comm := round(room_gross * ch.commission);
  if ch.mode = 'ota' then
    ota := greatest(0, least(room_gross, bal));
    if ota > 0 then perform post_entry(d, jsonb_build_object('k','otaBill','ch',ch.id), p_id, 'ota', jsonb_build_array(jl('1140', ota, 0), jl('1130', 0, ota))); end if;
    if comm > 0 then perform post_entry(d, jsonb_build_object('k','comm','ch',ch.id,'pct',ch.commission), p_id, 'ota', jsonb_build_array(jl('5300', comm, 0), jl('1140', 0, comm))); end if;
    if ota > 0 or comm > 0 then insert into ota_receivables(booking_id, channel, entry_date, gross, amount) values (p_id, ch.id, d, ota, ota - comm); end if;
    bal := bal - ota;
  elsif comm > 0 then
    perform post_entry(d, jsonb_build_object('k','comm','ch',ch.id,'pct',ch.commission), p_id, 'ota', jsonb_build_array(jl('5300', comm, 0), jl('2120', 0, comm)));
  end if;
  if bal > 0 then perform add_payment(p_id, d, p_method, bal);
  elsif bal < 0 then
    eid := post_entry(d, jsonb_build_object('k','refund','g',(select name from guests where id = b.guest_id)), p_id, 'payment',
                      jsonb_build_array(jl('1130', -bal, 0), jl(pay_account(p_method), 0, -bal)));
    insert into payments(booking_id, biz_date, method, amount, kind, journal_id, created_by) values (p_id, d, p_method, -bal, 'refund', eid, auth.uid());
  end if;
  update bookings set status = 'out', checked_out_at = now(),
         check_out = greatest(least(check_out, d), check_in + 1) where id = p_id;
  update rooms set hk_status = 'dirty' where no = b.room_no and hk_status <> 'ooo';
  perform log_action('booking.checkout', p_id, jsonb_build_object('room', b.room_no, 'method', p_method, 'ota', ota, 'commission', comm));
end $$;

create or replace function staff_cancel(p_id text, p_status text, p_refund boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  perform require_role('manager','frontdesk');
  select * into b from bookings where id = p_id for update;
  if b.status <> 'confirmed' or p_status not in ('cancelled','noshow') then raise exception 'cannot_cancel' using errcode = 'P0001'; end if;
  if p_status = 'noshow' and b.check_in > biz() then raise exception 'cannot_cancel' using errcode = 'P0001'; end if;
  perform apply_deposits(p_id, biz(), case when p_refund and p_status = 'cancelled' then 'refund' else 'forfeit' end);
  update bookings set status = p_status, cancelled_at = now() where id = p_id;
  update payment_claims set status = 'rejected', decided_by = auth.uid(), decided_at = now() where booking_id = p_id and status = 'pending';
  perform log_action('booking.' || p_status, p_id, jsonb_build_object('refund', p_refund));
end $$;

create or replace function staff_extend(p_id text, p_nights int default 1) returns void language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  perform require_role('manager','frontdesk');
  select * into b from bookings where id = p_id for update;
  if b.status not in ('confirmed','inhouse') or p_nights not between 1 and 30 then raise exception 'cannot_extend' using errcode = 'P0001'; end if;
  update bookings set check_out = check_out + p_nights where id = p_id;   -- the exclusion constraint refuses a clash
  perform log_action('booking.extend', p_id, jsonb_build_object('from', b.check_out, 'to', b.check_out + p_nights));
end $$;

create or replace function staff_charge(p_id text, p_kind text, p_text text, p_amount bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_role('manager','frontdesk');
  if p_kind not in ('fnb','minibar','laundry','tour','other') then raise exception 'invalid_kind' using errcode = 'P0001'; end if;
  if (select status from bookings where id = p_id) <> 'inhouse' then raise exception 'not_in_house' using errcode = 'P0001'; end if;
  perform add_charge(p_id, biz(), p_kind, jsonb_build_object('k','extra','text', left(p_text, 120)), p_amount);
  perform log_action('folio.charge', p_id, jsonb_build_object('kind', p_kind, 'amount', p_amount, 'text', p_text));
end $$;

create or replace function staff_void_charge(p_folio bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare f folio_items; eid bigint; lines jsonb;
begin
  perform require_role('manager');
  select * into f from folio_items where id = p_folio;
  if f.id is null or f.voids is not null or exists (select 1 from folio_items where voids = p_folio) then raise exception 'cannot_void' using errcode = 'P0001'; end if;
  if (select status from bookings where id = f.booking_id) <> 'inhouse' then raise exception 'not_in_house' using errcode = 'P0001'; end if;
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'reason_required' using errcode = 'P0001'; end if;
  select jsonb_agg(jl(account, credit, debit)) into lines from journal_lines where entry_id = f.journal_id;
  eid := post_entry(biz(), jsonb_build_object('k','void','text',p_reason,'of',f.description), f.booking_id, 'folio', lines, f.journal_id);
  update journal_entries set reversed_by = eid where id = f.journal_id;
  insert into folio_items(booking_id, biz_date, kind, description, gross, net, vat, voids, journal_id, created_by)
  values (f.booking_id, biz(), f.kind, jsonb_build_object('k','void','text',p_reason,'of',f.description), -f.gross, -f.net, -f.vat, f.id, eid, auth.uid());
  perform log_action('folio.void', f.booking_id, jsonb_build_object('folio', p_folio, 'amount', f.gross, 'reason', p_reason));
end $$;

create or replace function staff_payment(p_id text, p_method text, p_amount bigint, p_ref text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_role('manager','frontdesk','accountant');
  if (select status from bookings where id = p_id) not in ('confirmed','inhouse') then raise exception 'not_payable' using errcode = 'P0001'; end if;
  perform add_payment(p_id, biz(), p_method, p_amount, p_ref);
  perform log_action('payment.take', p_id, jsonb_build_object('method', p_method, 'amount', p_amount, 'ref', p_ref));
end $$;

create or replace function staff_verify_claim(p_claim bigint, p_approve boolean, p_method text default 'qr') returns void
language plpgsql security definer set search_path = public as $$
declare c payment_claims; pid bigint;
begin
  perform require_role('manager','frontdesk','accountant');
  select * into c from payment_claims where id = p_claim for update;
  if c.status <> 'pending' then raise exception 'already_decided' using errcode = 'P0001'; end if;
  if p_approve then
    if (select status from bookings where id = c.booking_id) not in ('confirmed','inhouse') then raise exception 'not_payable' using errcode = 'P0001'; end if;
    pid := add_payment(c.booking_id, biz(), p_method, c.amount, c.reference);
  end if;
  update payment_claims set status = case when p_approve then 'verified' else 'rejected' end, payment_id = pid,
         decided_by = auth.uid(), decided_at = now() where id = p_claim;
  perform log_action(case when p_approve then 'claim.verify' else 'claim.reject' end, c.booking_id, jsonb_build_object('claim', p_claim, 'amount', c.amount));
end $$;

create or replace function staff_set_hk(p_room text, p_status text) returns void language plpgsql security definer set search_path = public as $$
declare old text;
begin
  perform require_role('manager','frontdesk','housekeeping');
  select hk_status into old from rooms where no = p_room;
  update rooms set hk_status = p_status where no = p_room;
  perform log_action('room.hk', p_room, jsonb_build_object('from', old, 'to', p_status));
end $$;

create or replace function staff_night_audit() returns jsonb language plpgsql security definer set search_path = public as $$
declare d date := biz(); b record; n int := 0; ns int := 0; amt bigint := 0;
begin
  perform require_role('manager','frontdesk');
  if exists (select 1 from bookings where status = 'inhouse' and check_out <= d) then
    raise exception 'departures_pending' using errcode = 'P0001';
  end if;
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
  perform log_action('night_audit', to_char(d, 'YYYY-MM-DD'), jsonb_build_object('room_nights', n, 'amount', amt, 'noshows', ns));
  return jsonb_build_object('room_nights', n, 'amount', amt, 'noshows', ns, 'business_date', d + 1);
end $$;

-- =====================================================================
-- STAFF — accounting
-- =====================================================================
create or replace function entry_posted(p_k text, p_mo text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from journal_entries where description->>'k' = p_k and description->>'mo' = p_mo and reversed_by is null)
$$;

create or replace function acct_expense(p_date date, p_account text, p_text text, p_gross bigint, p_has_vat boolean, p_pay text)
returns bigint language plpgsql security definer set search_path = public as $$
declare r numeric; vat bigint := 0; eid bigint;
begin
  perform require_role('manager','accountant');
  if p_date > biz() then raise exception 'future_date' using errcode = 'P0001'; end if;
  if p_account not in (select code from accounts where type in ('cos','opx') or code = '1220') then raise exception 'invalid_account' using errcode = 'P0001'; end if;
  if p_pay not in ('1110','1120','2110') or p_gross <= 0 then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  if p_has_vat then select vat_rate / 100 into r from settings where id = 1; vat := round(p_gross * r / (1 + r)); end if;
  eid := post_entry(p_date, jsonb_build_object('k','exp','text', left(p_text,160)), 'EXP', 'expense',
                    jsonb_build_array(jl(p_account, p_gross - vat, 0), jl('1150', vat, 0), jl(p_pay, 0, p_gross)));
  perform log_action('journal.expense', 'JV-' || eid, jsonb_build_object('account', p_account, 'amount', p_gross));
  return eid;
end $$;

create or replace function acct_manual(p_date date, p_text text, p_lines jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare eid bigint;
begin
  perform require_role('manager','accountant');
  if p_date > biz() then raise exception 'future_date' using errcode = 'P0001'; end if;
  if exists (select 1 from jsonb_array_elements(p_lines) x where x->>'a' in ('1130','1140','2150')) then
    raise exception 'control_account' using errcode = 'P0001', detail = '1130, 1140 and 2150 move only through bookings';
  end if;
  if length(trim(coalesce(p_text,''))) < 3 then raise exception 'reason_required' using errcode = 'P0001'; end if;
  eid := post_entry(p_date, jsonb_build_object('k','manual','text', left(p_text,160)), 'MJ', 'manual', p_lines);
  perform log_action('journal.manual', 'JV-' || eid, jsonb_build_object('lines', p_lines));
  return eid;
end $$;

create or replace function acct_reverse(p_id bigint, p_reason text) returns bigint
language plpgsql security definer set search_path = public as $$
declare e journal_entries; eid bigint; lines jsonb;
begin
  perform require_role('manager','accountant');
  select * into e from journal_entries where id = p_id for update;
  if e.id is null or e.reversed_by is not null or e.reverses is not null
     or e.source not in ('manual','expense','close','tax','finance','cash') then
    raise exception 'cannot_reverse' using errcode = 'P0001';
  end if;
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'reason_required' using errcode = 'P0001'; end if;
  select jsonb_agg(jl(account, credit, debit)) into lines from journal_lines where entry_id = p_id;
  eid := post_entry(biz(), jsonb_build_object('k','rev','id',p_id,'text',left(p_reason,160)), 'REV-' || p_id, 'reversal', lines, p_id);
  update journal_entries set reversed_by = eid where id = p_id;
  perform log_action('journal.reverse', 'JV-' || p_id, jsonb_build_object('reversal', eid, 'reason', p_reason));
  return eid;
end $$;

create or replace function acct_ota_payout(p_channel text) returns bigint language plpgsql security definer set search_path = public as $$
declare s bigint; eid bigint;
begin
  perform require_role('manager','accountant');
  select coalesce(sum(amount),0) into s from ota_receivables where channel = p_channel and settled_on is null;
  if s <= 0 then raise exception 'nothing_due' using errcode = 'P0001'; end if;
  eid := post_entry(biz(), jsonb_build_object('k','otaPayout','ch',p_channel), 'OTA-' || p_channel, 'ota', jsonb_build_array(jl('1120', s, 0), jl('1140', 0, s)));
  update ota_receivables set settled_on = biz(), payout_entry = eid where channel = p_channel and settled_on is null;
  perform log_action('ota.payout', p_channel, jsonb_build_object('amount', s));
  return s;
end $$;

create or replace function acct_pay_commissions() returns bigint language plpgsql security definer set search_path = public as $$
declare s bigint;
begin
  perform require_role('manager','accountant');
  select coalesce(sum(credit - debit),0) into s from journal_lines where account = '2120';
  if s <= 0 then raise exception 'nothing_due' using errcode = 'P0001'; end if;
  perform post_entry(biz(), jsonb_build_object('k','commPay'), 'COMM', 'cash', jsonb_build_array(jl('2120', s, 0), jl('1120', 0, s)));
  perform log_action('commission.pay', 'COMM', jsonb_build_object('amount', s));
  return s;
end $$;

create or replace function vat_for(p_month text, out output bigint, out input bigint) language sql stable security definer set search_path = public as $$
  select coalesce(sum(case when l.account = '2140' then l.credit - l.debit end),0)::bigint,
         coalesce(sum(case when l.account = '1150' then l.debit - l.credit end),0)::bigint
  from journal_lines l join journal_entries e on e.id = l.entry_id
  where to_char(e.entry_date, 'YYYY-MM') = p_month and coalesce(e.description->>'k','') <> 'vatPay'
$$;

create or replace function acct_pay_vat(p_month text) returns bigint language plpgsql security definer set search_path = public as $$
declare v record; net bigint; lines jsonb;
begin
  perform require_role('manager','accountant');
  if p_month >= to_char(biz(), 'YYYY-MM') then raise exception 'month_open' using errcode = 'P0001'; end if;
  if entry_posted('vatPay', p_month) then raise exception 'already_posted' using errcode = 'P0001'; end if;
  select * into v from vat_for(p_month);
  net := v.output - v.input;
  lines := jsonb_build_array(jl('2140', v.output, 0), jl('1150', 0, v.input),
           case when net >= 0 then jl('1120', 0, net) else jl('1120', -net, 0) end);
  perform post_entry(biz(), jsonb_build_object('k','vatPay','mo',p_month), 'VAT-' || p_month, 'tax', lines);
  perform log_action('vat.pay', p_month, jsonb_build_object('output', v.output, 'input', v.input, 'net', net));
  return net;
end $$;

create or replace function acct_close(p_kind text, p_month text) returns bigint language plpgsql security definer set search_path = public as $$
declare a jsonb; d date; eid bigint; k text;
begin
  perform require_role('manager','accountant');
  select close_amounts into a from settings where id = 1;
  d := least((p_month || '-01')::date + interval '1 month' - interval '1 day', biz())::date;
  if to_char(d, 'YYYY-MM') <> p_month then raise exception 'month_not_started' using errcode = 'P0001'; end if;
  k := case p_kind when 'depr' then 'depr' when 'int' then 'int' when 'sal_pay' then 'sal' when 'sal_accrue' then 'salAcc' end;
  if k is null then raise exception 'invalid_kind' using errcode = 'P0001'; end if;
  if entry_posted(k, p_month) or (k in ('sal','salAcc') and (entry_posted('sal', p_month) or entry_posted('salAcc', p_month))) then
    raise exception 'already_posted' using errcode = 'P0001';
  end if;
  eid := post_entry(d, jsonb_build_object('k', k, 'mo', p_month), upper(k) || '-' || p_month, 'close',
    case p_kind
      when 'depr' then jsonb_build_array(jl('5800', (a->>'depr')::bigint, 0), jl('1290', 0, (a->>'depr')::bigint))
      when 'int' then jsonb_build_array(jl('5900', (a->>'int')::bigint, 0), jl('1120', 0, (a->>'int')::bigint))
      when 'sal_pay' then jsonb_build_array(jl('5200', (a->>'sal')::bigint, 0), jl('1120', 0, (a->>'sal')::bigint))
      else jsonb_build_array(jl('5200', (a->>'sal')::bigint, 0), jl('2160', 0, (a->>'sal')::bigint)) end);
  perform log_action('close.' || p_kind, p_month, null);
  return eid;
end $$;

create or replace function acct_lock_month(p_month text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_role('manager','accountant');
  if p_month >= to_char(biz(), 'YYYY-MM') then raise exception 'month_open' using errcode = 'P0001'; end if;
  insert into period_locks(month, locked_by) values (p_month, auth.uid());
end $$;
create or replace function acct_unlock_month(p_month text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_role('owner');
  delete from period_locks where month = p_month;
end $$;

-- one round trip for the back office; RLS also lets staff read tables directly
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
        'promo', b.promo, 'request', b.special_request,
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

-- =====================================================================
-- Row level security & grants
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['settings','accounts','staff','amenities','room_types','rooms','channels','promo_codes','guests','bookings',
                           'journal_entries','journal_lines','folio_items','payments','payment_claims','ota_receivables','period_locks','audit_log'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists staff_read on %I', t);
    execute format('create policy staff_read on %I for select to authenticated using (is_staff())', t);
  end loop;
  foreach t in array array['amenities','room_types','rooms','channels','promo_codes'] loop
    execute format('drop policy if exists manager_write on %I', t);
    execute format('create policy manager_write on %I for all to authenticated using (my_role() in (''owner'',''manager'')) with check (my_role() in (''owner'',''manager''))', t);
  end loop;
end $$;
drop policy if exists manager_update on settings;
create policy manager_update on settings for update to authenticated using (my_role() in ('owner','manager')) with check (my_role() in ('owner','manager'));
drop policy if exists owner_manage on staff;
create policy owner_manage on staff for all to authenticated using (my_role() = 'owner') with check (my_role() = 'owner');

revoke all on all tables in schema public from anon, authenticated;
grant select on all tables in schema public to authenticated;
grant insert, update, delete on amenities, room_types, rooms, channels, promo_codes, staff to authenticated;
grant update on settings to authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public_catalog(), public_availability(date, date), public_book(jsonb), public_lookup(text, text)
  to anon, authenticated;
grant execute on function me(), admin_snapshot(), staff_create_booking(jsonb), staff_check_in(text), staff_check_out(text, text),
  staff_cancel(text, text, boolean), staff_extend(text, int), staff_charge(text, text, text, bigint), staff_void_charge(bigint, text),
  staff_payment(text, text, bigint, text), staff_verify_claim(bigint, boolean, text), staff_set_hk(text, text), staff_night_audit(),
  acct_expense(date, text, text, bigint, boolean, text), acct_manual(date, text, jsonb), acct_reverse(bigint, text),
  acct_ota_payout(text), acct_pay_commissions(), acct_pay_vat(text), acct_close(text, text), acct_lock_month(text), acct_unlock_month(text),
  my_role(), is_staff() to authenticated;

-- ---------- staff accounts (owner only) ----------
create or replace function admin_add_staff(p_email text, p_name text, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  perform require_role('owner');
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'user_not_found' using errcode = 'P0001', detail = 'Create the login in Supabase Auth first'; end if;
  insert into staff(user_id, name, role) values (uid, trim(p_name), p_role)
  on conflict (user_id) do update set name = excluded.name, role = excluded.role, active = true;
end $$;
create or replace function admin_set_staff(p_user uuid, p_role text, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_role('owner');
  if p_user = auth.uid() and (p_role <> 'owner' or not p_active) then raise exception 'cannot_demote_self' using errcode = 'P0001'; end if;
  update staff set role = p_role, active = p_active where user_id = p_user;
end $$;
create or replace function admin_staff() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform require_role('owner');
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.user_id, 'name', s.name, 'role', s.role, 'active', s.active,
          'email', (select email from auth.users u where u.id = s.user_id)) order by s.created_at) from staff s), '[]');
end $$;
revoke execute on function admin_add_staff(text, text, text), admin_set_staff(uuid, text, boolean), admin_staff() from public, anon;
grant execute on function admin_add_staff(text, text, text), admin_set_staff(uuid, text, boolean), admin_staff() to authenticated;

-- promo preview for the booking form (the price is still recomputed inside public_book)
create or replace function public_promo(p_code text) returns numeric language sql stable security definer set search_path = public as $$
  select promo_pct(p_code)
$$;
revoke execute on function public_promo(text) from public;
grant execute on function public_promo(text) to anon, authenticated;
