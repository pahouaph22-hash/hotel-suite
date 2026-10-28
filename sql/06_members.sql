-- =====================================================================
-- Saynam Hotel Suite — member accounts, full prepayment, cancellation policy
--
--  * Guests must sign up (Supabase Auth) and have a member profile before booking.
--  * Members see their own bookings, payments and status after logging in.
--  * Website bookings are paid in full by bank transfer; staff must open the
--    slip and record the bank reference before approving it.
--  * Members may cancel until N hours (default 3) before check-in time:
--    a confirmed booking gets 80% back, 20% is kept as a cancellation fee.
--    Refunds are recorded as owed (account 2170) until staff pay them out.
-- =====================================================================

alter table settings add column if not exists cancel_cutoff_hours int not null default 3 check (cancel_cutoff_hours between 0 and 72);
alter table settings add column if not exists cancel_refund_pct numeric(5,2) not null default 80 check (cancel_refund_pct between 0 and 100);
update settings set deposit_pct = 100 where id = 1;

insert into accounts(code, type, name) values
  ('2170', 'cl', '{"lo":"ເງິນຄືນລູກຄ້າຄ້າງຈ່າຍ","th":"เงินคืนลูกค้าค้างจ่าย","en":"Guest refunds payable"}'::jsonb)
on conflict (code) do nothing;

create table if not exists customers (
  user_id uuid primary key references auth.users(id),
  guest_id uuid not null unique references guests(id),
  name text not null check (length(trim(name)) between 2 and 120),
  phone text not null check (length(regexp_replace(phone, '\D', '', 'g')) >= 8),
  email text,
  country text not null default 'LA',
  created_at timestamptz not null default now()
);
alter table bookings add column if not exists customer_id uuid references customers(user_id);
create index if not exists bookings_customer_idx on bookings (customer_id);

alter table payment_claims add column if not exists viewed_by uuid;
alter table payment_claims add column if not exists viewed_at timestamptz;
alter table payment_claims add column if not exists bank_ref text;
alter table payment_claims add column if not exists note text;

create table if not exists refunds (
  id bigserial primary key,
  booking_id text not null references bookings(id),
  paid_total bigint not null check (paid_total >= 0),
  fee bigint not null check (fee >= 0),
  amount bigint not null check (amount >= 0),
  pct numeric(5,2) not null,
  reason text not null,
  status text not null default 'owed' check (status in ('owed','paid')),
  journal_id bigint references journal_entries(id),
  created_by uuid,
  created_at timestamptz not null default now(),
  paid_method text, paid_ref text, paid_by uuid, paid_at timestamptz,
  payment_id bigint references payments(id),
  check (paid_total = fee + amount)
);
create index if not exists refunds_booking_idx on refunds (booking_id);

drop trigger if exists audit_customers on customers;
create trigger audit_customers after insert or update or delete on customers for each row execute function trg_audit_row();

-- ---------- RLS: staff can read, nobody writes directly ----------
alter table customers enable row level security;
alter table refunds enable row level security;
drop policy if exists staff_read on customers;
create policy staff_read on customers for select to authenticated using (is_staff());
drop policy if exists staff_read on refunds;
create policy staff_read on refunds for select to authenticated using (is_staff());
revoke all on customers, refunds from anon, authenticated;
grant select on customers, refunds to authenticated;
revoke all on sequence refunds_id_seq from anon, authenticated;

-- audit trail names members too
create or replace function log_action(p_action text, p_ref text, p_detail jsonb default null) returns void
language sql security definer set search_path = public as $$
  insert into audit_log(user_id, actor, action, ref, detail)
  values (auth.uid(), coalesce((select name from staff where user_id = auth.uid() and active),
                               (select 'member: ' || name from customers where user_id = auth.uid()),
                               case when auth.uid() is null then 'website' end), p_action, p_ref, p_detail)
$$;

-- ---------- helpers ----------
create or replace function require_member() returns customers language plpgsql stable security definer set search_path = public as $$
declare c customers;
begin
  if auth.uid() is null then raise exception 'login_required' using errcode = 'P0001'; end if;
  select * into c from customers where user_id = auth.uid();
  if c.user_id is null then raise exception 'profile_required' using errcode = 'P0001'; end if;
  return c;
end $$;

-- last moment a member may cancel: check-in time on the arrival day (hotel time) minus the cutoff
create or replace function cancel_deadline(p_ci date) returns timestamptz language sql stable security definer set search_path = public as $$
  select ((p_ci + coalesce(nullif(s.check_in_time, ''), '14:00')::time) at time zone 'Asia/Vientiane') - make_interval(hours => s.cancel_cutoff_hours)
  from settings s where s.id = 1
$$;

create or replace function paid_net(p_booking text) returns bigint language sql stable security definer set search_path = public as $$
  select coalesce(sum(case kind when 'refund' then -amount else amount end), 0)::bigint from payments where booking_id = p_booking
$$;

-- Money held for a booking that is being cancelled: keep the fee as revenue, owe the rest back to the guest.
-- Dr 2150 customer deposits / Cr 2170 refunds payable / Cr 4300 other revenue (cancellation fee)
create or replace function settle_cancellation(p_booking text, p_refund_pct numeric, p_reason text) returns bigint
language plpgsql security definer set search_path = public as $$
declare b bookings; s bigint; back bigint; fee bigint; eid bigint; gname text; rid bigint; lines jsonb;
begin
  select * into b from bookings where id = p_booking;
  select name into gname from guests where id = b.guest_id;
  select coalesce(sum(amount), 0) into s from payments where booking_id = b.id and kind = 'deposit' and not applied;
  if s = 0 then return null; end if;
  back := least(s, (round(s * p_refund_pct / 100 / 1000) * 1000)::bigint);
  fee := s - back;
  lines := jsonb_build_array(jl('2150', s, 0));
  if back > 0 then lines := lines || jsonb_build_array(jl('2170', 0, back)); end if;
  if fee > 0 then lines := lines || jsonb_build_array(jl('4300', 0, fee)); end if;
  eid := post_entry(biz(), jsonb_build_object('k', 'cxlPolicy', 'g', gname, 'pct', p_refund_pct), b.id, 'deposit', lines);
  update payments set applied = true where booking_id = b.id and kind = 'deposit' and not applied;
  insert into refunds(booking_id, paid_total, fee, amount, pct, reason, journal_id, created_by)
  values (b.id, s, fee, back, p_refund_pct, p_reason, eid, auth.uid()) returning id into rid;
  return rid;
end $$;

-- ---------- member profile ----------
create or replace function member_me() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c customers;
begin
  if auth.uid() is null then return null; end if;
  select * into c from customers where user_id = auth.uid();
  if c.user_id is null then
    return jsonb_build_object('profile', false, 'email', (select email from auth.users where id = auth.uid()));
  end if;
  return jsonb_build_object('profile', true, 'name', c.name, 'phone', c.phone, 'email', c.email, 'country', c.country, 'since', c.created_at);
end $$;

create or replace function member_register(p_name text, p_phone text, p_country text default 'LA') returns jsonb
language plpgsql security definer set search_path = public as $$
declare c customers; gid uuid; em text;
begin
  if auth.uid() is null then raise exception 'login_required' using errcode = 'P0001'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'name_required' using errcode = 'P0001'; end if;
  if length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) < 8 then raise exception 'phone_required' using errcode = 'P0001'; end if;
  select email into em from auth.users where id = auth.uid();
  select * into c from customers where user_id = auth.uid();
  if c.user_id is null then
    insert into guests(name, phone, email, country) values (trim(p_name), trim(p_phone), em, coalesce(nullif(p_country, ''), 'LA')) returning id into gid;
    insert into customers(user_id, guest_id, name, phone, email, country) values (auth.uid(), gid, trim(p_name), trim(p_phone), em, coalesce(nullif(p_country, ''), 'LA'));
    perform log_action('member.register', em, jsonb_build_object('name', trim(p_name), 'phone', trim(p_phone)));
  else
    update customers set name = trim(p_name), phone = trim(p_phone), country = coalesce(nullif(p_country, ''), country), email = em where user_id = auth.uid();
    update guests set name = trim(p_name), phone = trim(p_phone), email = em, country = coalesce(nullif(p_country, ''), country) where id = c.guest_id;
  end if;
  return member_me();
end $$;

-- ---------- booking (members only, full prepayment) ----------
create or replace function member_book(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c customers; ci date := (p->>'ci')::date; co date := (p->>'co')::date; t room_types; pct numeric := 0;
  room text; bid text; bcode text; rate bigint; n int; total bigint; s settings;
begin
  c := require_member();
  perform check_stay(ci, co);
  perform expire_unpaid();
  select * into s from settings where id = 1;
  select * into t from room_types where id = p->>'type' and active;
  if t.id is null then raise exception 'invalid_room_type' using errcode = 'P0001'; end if;
  if coalesce((p->>'adults')::int, 1) > t.capacity then raise exception 'too_many_guests' using errcode = 'P0001'; end if;
  if nullif(trim(p->>'promo'), '') is not null then
    pct := promo_pct(p->>'promo');
    if pct is null then raise exception 'promo_invalid' using errcode = 'P0001'; end if;
  end if;
  perform pg_advisory_xact_lock(hashtext('hotel-booking'));
  -- the same request sent twice (double tap, back button) must not hold a second room
  if exists (select 1 from bookings where customer_id = c.user_id and status = 'pending' and type_id = t.id and check_in = ci and check_out = co) then
    raise exception 'duplicate_booking' using errcode = 'P0001';
  end if;
  if (select count(*) from bookings where customer_id = c.user_id and status = 'pending') >= 3 then
    raise exception 'too_many_pending' using errcode = 'P0001';
  end if;
  select f into room from free_rooms(t.id, ci, co) f limit 1;
  if room is null then raise exception 'sold_out' using errcode = 'P0001'; end if;
  n := co - ci;
  rate := (round(direct_rate(t.base_rate) * (1 - pct / 100) / 1000) * 1000)::bigint;
  total := rate * n;
  insert into bookings(guest_id, customer_id, room_no, type_id, check_in, check_out, adults, channel, rate, deposit_due, promo, special_request, source, status)
  values (c.guest_id, c.user_id, room, t.id, ci, co, coalesce((p->>'adults')::int, 1), 'DIR', rate, total, nullif(upper(trim(p->>'promo')), ''),
          left(p->>'request', 500), 'website', case when total > 0 then 'pending' else 'confirmed' end)
  returning id, code into bid, bcode;
  perform log_action('booking.create', bid, jsonb_build_object('source', 'website', 'member', c.email, 'ci', ci, 'co', co, 'type', t.id, 'total', total));
  return jsonb_build_object('id', bid, 'code', bcode, 'nights', n, 'rate', rate, 'total', total, 'due', total,
                            'status', case when total > 0 then 'pending' else 'confirmed' end, 'hold_hours', s.pending_hold_hours,
                            'cancel_until', cancel_deadline(ci));
end $$;

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
      'hold_until', case when b.status = 'pending' then b.created_at + make_interval(hours => s.pending_hold_hours) end,
      'cancel_until', cancel_deadline(b.check_in),
      'can_cancel', b.status in ('pending', 'confirmed') and now() < cancel_deadline(b.check_in)
                    and not exists (select 1 from payment_claims where booking_id = b.id and status = 'pending'),
      'refund_pct', case when b.status = 'confirmed' then s.cancel_refund_pct else 100 end,
      'held', (select coalesce(sum(amount), 0) from payments where booking_id = b.id and kind = 'deposit' and not applied)
    ) x from bookings b where b.customer_id = c.user_id) q), '[]');
end $$;

create or replace function member_booking(p_code text) returns bookings language plpgsql stable security definer set search_path = public as $$
declare c customers; b bookings;
begin
  c := require_member();
  select * into b from bookings where code = upper(trim(p_code)) and customer_id = c.user_id;
  if b.id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  return b;
end $$;

-- a slip may go only into the folder of the member's own booking that is still awaiting payment
create or replace function slip_path_ok(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and p_name ~ '^[0-9A-F]{6}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
     and exists (select 1 from bookings b where b.code = split_part(p_name, '/', 1) and b.status = 'pending' and b.customer_id = auth.uid()
                 and (select count(*) from payment_claims c where c.booking_id = b.id and c.status = 'pending') < 3)
$$;

create or replace function member_claim(p_code text, p_amount bigint, p_slip text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bookings; remaining bigint;
begin
  b := member_booking(p_code);
  select * into b from bookings where id = b.id for update;
  if b.status <> 'pending' then raise exception 'not_payable' using errcode = 'P0001'; end if;
  remaining := b.rate * (b.check_out - b.check_in) - paid_net(b.id)
               - (select coalesce(sum(amount), 0) from payment_claims where booking_id = b.id and status = 'pending');
  if p_amount is null or p_amount <= 0 or p_amount > remaining then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  if (select count(*) from payment_claims where booking_id = b.id and status = 'pending') >= 3 then raise exception 'too_many_claims' using errcode = 'P0001'; end if;
  if p_slip is null or split_part(p_slip, '/', 1) <> b.code
     or not exists (select 1 from storage.objects o where o.bucket_id = 'slips' and o.name = p_slip) then
    raise exception 'slip_required' using errcode = 'P0001';
  end if;
  if exists (select 1 from payment_claims where slip_path = p_slip) then raise exception 'slip_required' using errcode = 'P0001'; end if;
  insert into payment_claims(booking_id, amount, slip_path) values (b.id, p_amount, p_slip);
  perform log_action('claim.create', b.id, jsonb_build_object('amount', p_amount, 'slip', p_slip));
  return jsonb_build_object('ok', true);
end $$;

create or replace function member_cancel(p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings; s settings; pct numeric; rid bigint; r refunds;
begin
  b := member_booking(p_code);
  select * into b from bookings where id = b.id for update;
  select * into s from settings where id = 1;
  if b.status not in ('pending', 'confirmed') then raise exception 'cannot_cancel' using errcode = 'P0001'; end if;
  if now() >= cancel_deadline(b.check_in) then raise exception 'cancel_window_closed' using errcode = 'P0001'; end if;
  -- money may already be on its way: staff must decide the slip first
  if exists (select 1 from payment_claims where booking_id = b.id and status = 'pending') then
    raise exception 'slip_under_review' using errcode = 'P0001';
  end if;
  -- a confirmed (fully paid) booking keeps the cancellation fee; a request the hotel never approved gets everything back
  pct := case when b.status = 'confirmed' then s.cancel_refund_pct else 100 end;
  rid := settle_cancellation(b.id, pct, 'guest_cancel');
  update bookings set status = 'cancelled', cancelled_at = now(), cancel_reason = 'guest_cancelled' where id = b.id;
  select * into r from refunds where id = rid;
  perform log_action('booking.guest_cancel', b.id, jsonb_build_object('was', b.status, 'pct', pct, 'refund', coalesce(r.amount, 0), 'fee', coalesce(r.fee, 0)));
  return jsonb_build_object('ok', true, 'refund', coalesce(r.amount, 0), 'fee', coalesce(r.fee, 0), 'pct', pct);
end $$;

-- ---------- staff: proof of payment must be looked at before it can be approved ----------
create or replace function staff_open_slip(p_claim bigint) returns text language plpgsql security definer set search_path = public as $$
declare c payment_claims;
begin
  perform require_role('manager', 'frontdesk', 'accountant');
  select * into c from payment_claims where id = p_claim;
  if c.id is null or c.slip_path is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if c.status = 'pending' then
    update payment_claims set viewed_by = auth.uid(), viewed_at = now() where id = p_claim;
    perform log_action('claim.viewed', c.booking_id, jsonb_build_object('claim', p_claim));
  end if;
  return c.slip_path;
end $$;

drop function if exists staff_verify_claim(bigint, boolean, text);
create or replace function staff_verify_claim(p_claim bigint, p_approve boolean, p_method text default 'qr', p_bank_ref text default null)
returns void language plpgsql security definer set search_path = public as $$
declare c payment_claims; pid bigint; b bookings;
begin
  perform require_role('manager', 'frontdesk', 'accountant');
  select * into c from payment_claims where id = p_claim for update;
  if c.id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if c.status <> 'pending' then raise exception 'already_decided' using errcode = 'P0001'; end if;
  select * into b from bookings where id = c.booking_id for update;
  if p_approve then
    -- the approving staff member must have opened this slip in the last 30 minutes and typed the bank transaction reference
    if c.slip_path is not null and (c.viewed_by is distinct from auth.uid() or c.viewed_at < now() - interval '30 minutes') then
      raise exception 'slip_not_viewed' using errcode = 'P0001';
    end if;
    if length(trim(coalesce(p_bank_ref, ''))) < 3 then raise exception 'bank_ref_required' using errcode = 'P0001'; end if;
    if exists (select 1 from payment_claims where bank_ref = trim(p_bank_ref) and status = 'verified') then
      raise exception 'bank_ref_used' using errcode = 'P0001';
    end if;
    if b.status not in ('pending', 'confirmed', 'inhouse') then raise exception 'not_payable' using errcode = 'P0001'; end if;
    pid := add_payment(c.booking_id, biz(), p_method, c.amount, trim(p_bank_ref));
  end if;
  update payment_claims set status = case when p_approve then 'verified' else 'rejected' end, payment_id = pid,
         bank_ref = case when p_approve then trim(p_bank_ref) end, note = case when not p_approve then nullif(trim(p_bank_ref), '') end,
         decided_by = auth.uid(), decided_at = now() where id = p_claim;
  perform log_action(case when p_approve then 'claim.verify' else 'claim.reject' end, c.booking_id,
                     jsonb_build_object('claim', p_claim, 'amount', c.amount, 'bank_ref', trim(p_bank_ref)));
  if p_approve then perform confirm_if_paid(c.booking_id); end if;
end $$;

-- transfers for website bookings go through the slip check; only money handed over at the desk is entered directly
create or replace function staff_payment(p_id text, p_method text, p_amount bigint, p_ref text default null) returns void
language plpgsql security definer set search_path = public as $$
declare st text;
begin
  perform require_role('manager', 'frontdesk', 'accountant');
  select status into st from bookings where id = p_id;
  if st not in ('pending', 'confirmed', 'inhouse') then raise exception 'not_payable' using errcode = 'P0001'; end if;
  if st = 'pending' and p_method not in ('cash', 'card') then raise exception 'use_slip_check' using errcode = 'P0001'; end if;
  perform add_payment(p_id, biz(), p_method, p_amount, p_ref);
  perform log_action('payment.take', p_id, jsonb_build_object('method', p_method, 'amount', p_amount, 'ref', p_ref));
end $$;

create or replace function staff_refund_paid(p_refund bigint, p_method text, p_ref text) returns void
language plpgsql security definer set search_path = public as $$
declare r refunds; eid bigint; pid bigint; gname text;
begin
  perform require_role('manager', 'accountant');
  select * into r from refunds where id = p_refund for update;
  if r.id is null or r.status <> 'owed' or r.amount <= 0 then raise exception 'nothing_due' using errcode = 'P0001'; end if;
  if p_method not in ('cash', 'transfer', 'qr') then raise exception 'invalid_kind' using errcode = 'P0001'; end if;
  if p_method <> 'cash' and length(trim(coalesce(p_ref, ''))) < 3 then raise exception 'bank_ref_required' using errcode = 'P0001'; end if;
  select g.name into gname from bookings b join guests g on g.id = b.guest_id where b.id = r.booking_id;
  eid := post_entry(biz(), jsonb_build_object('k', 'refundPaid', 'g', gname, 'm', p_method), r.booking_id, 'cash',
                    jsonb_build_array(jl('2170', r.amount, 0), jl(pay_account(p_method), 0, r.amount)));
  insert into payments(booking_id, biz_date, method, amount, kind, applied, reference, journal_id, created_by)
  values (r.booking_id, biz(), p_method, r.amount, 'refund', true, nullif(trim(p_ref), ''), eid, auth.uid()) returning id into pid;
  update refunds set status = 'paid', paid_method = p_method, paid_ref = nullif(trim(p_ref), ''), paid_by = auth.uid(), paid_at = now(), payment_id = pid where id = p_refund;
  perform log_action('refund.paid', r.booking_id, jsonb_build_object('refund', p_refund, 'amount', r.amount, 'method', p_method, 'ref', p_ref));
end $$;

-- staff cancellations with a refund now create a refund owed instead of assuming the money already left the bank
create or replace function staff_cancel(p_id text, p_status text, p_refund boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  perform require_role('manager', 'frontdesk');
  select * into b from bookings where id = p_id for update;
  if b.status not in ('pending', 'confirmed') or p_status not in ('cancelled', 'noshow') then raise exception 'cannot_cancel' using errcode = 'P0001'; end if;
  if p_status = 'noshow' and (b.check_in > biz() or b.status = 'pending') then raise exception 'cannot_cancel' using errcode = 'P0001'; end if;
  if p_refund and p_status = 'cancelled' then perform settle_cancellation(p_id, 100, 'staff_refund');
  else perform apply_deposits(p_id, biz(), 'forfeit'); end if;
  update bookings set status = p_status, cancelled_at = now(), cancel_reason = case when b.status = 'pending' then 'declined_by_staff' end where id = p_id;
  update payment_claims set status = 'rejected', decided_by = auth.uid(), decided_at = now() where booking_id = p_id and status = 'pending';
  perform log_action('booking.' || p_status, p_id, jsonb_build_object('refund', p_refund, 'was', b.status));
end $$;

create or replace function staff_night_audit() returns jsonb language plpgsql security definer set search_path = public as $$
declare d date := biz(); b record; n int := 0; ns int := 0; ex int := 0; amt bigint := 0;
begin
  perform require_role('manager', 'frontdesk');
  if exists (select 1 from bookings where status = 'inhouse' and check_out <= d) then
    raise exception 'departures_pending' using errcode = 'P0001';
  end if;
  -- website bookings whose payment was never approved by the arrival date are released; any money received is owed back in full
  for b in select id from bookings where status = 'pending' and check_in <= d loop
    perform settle_cancellation(b.id, 100, 'unpaid_at_arrival');
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
    perform add_charge(b.id, d, 'room', jsonb_build_object('k', 'night', 'room', b.room_no, 'd', d), b.rate);
    n := n + 1; amt := amt + b.rate;
  end loop;
  update rooms set hk_status = 'dirty' where hk_status <> 'ooo' and no in (select room_no from bookings where status = 'inhouse');
  perform set_config('hotel.night_audit', 'on', true);
  update settings set business_date = d + 1 where id = 1;
  perform log_action('night_audit', to_char(d, 'YYYY-MM-DD'), jsonb_build_object('room_nights', n, 'amount', amt, 'noshows', ns, 'unpaid_released', ex));
  perform expire_unpaid();
  return jsonb_build_object('room_nights', n, 'amount', amt, 'noshows', ns, 'unpaid_released', ex, 'business_date', d + 1);
end $$;

-- 2170 moves only through cancellations and refund payouts
create or replace function acct_manual(p_date date, p_text text, p_lines jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare eid bigint;
begin
  perform require_role('manager', 'accountant');
  if p_date > biz() then raise exception 'future_date' using errcode = 'P0001'; end if;
  if exists (select 1 from jsonb_array_elements(p_lines) x where x->>'a' in ('1130', '1140', '2150', '2170')) then
    raise exception 'control_account' using errcode = 'P0001', detail = '1130, 1140, 2150 and 2170 move only through bookings';
  end if;
  if length(trim(coalesce(p_text, ''))) < 3 then raise exception 'reason_required' using errcode = 'P0001'; end if;
  eid := post_entry(p_date, jsonb_build_object('k', 'manual', 'text', left(p_text, 160)), 'MJ', 'manual', p_lines);
  perform log_action('journal.manual', 'JV-' || eid, jsonb_build_object('lines', p_lines));
  return eid;
end $$;

create or replace function public_catalog() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'hotel', (select jsonb_build_object('name', hotel_name, 'tagline', tagline, 'about', about, 'address', address, 'phone', phone,
              'email', email, 'map_url', map_url, 'check_in_time', check_in_time, 'check_out_time', check_out_time,
              'deposit_pct', deposit_pct, 'direct_discount', direct_discount, 'free_cancel_days', free_cancel_days,
              'cancel_cutoff_hours', cancel_cutoff_hours, 'cancel_refund_pct', cancel_refund_pct, 'pending_hold_hours', pending_hold_hours,
              'payment_note', payment_note, 'payment_qr_url', payment_qr_url, 'vat_rate', vat_rate, 'prices_incl_vat', prices_incl_vat, 'business_date', business_date)
              from settings where id = 1),
    'types', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'description', description, 'capacity', capacity,
              'base_rate', base_rate, 'direct_rate', direct_rate(base_rate), 'size_m2', size_m2, 'bed', bed, 'amenities', amenities) order by sort)
              from room_types where active), '[]'),
    'amenities', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'icon', icon, 'name', name) order by sort) from amenities), '[]'))
$$;

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
        'status', b.status, 'created', (b.created_at at time zone 'Asia/Vientiane')::date, 'createdAt', b.created_at, 'source', b.source, 'deposit_due', b.deposit_due,
        'promo', b.promo, 'request', b.special_request, 'cancel_reason', b.cancel_reason, 'confirmed_at', b.confirmed_at, 'member', b.customer_id,
        'cancel_until', case when b.customer_id is not null then cancel_deadline(b.check_in) end,
        'folio', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'date', f.biz_date, 'kind', f.kind, 'desc', f.description,
                  'gross', f.gross, 'net', f.net, 'vat', f.vat, 'voids', f.voids) order by f.id) from folio_items f where f.booking_id = b.id), '[]'),
        'pays', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'date', p.biz_date, 'm', p.method, 'amt', p.amount,
                  'dep', p.kind = 'deposit', 'applied', p.applied, 'refund', p.kind = 'refund', 'ref', p.reference) order by p.id) from payments p where p.booking_id = b.id), '[]')
      ) order by b.check_in) from bookings b join guests g on g.id = b.guest_id), '[]'),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', c.user_id, 'name', c.name, 'phone', c.phone, 'email', c.email, 'country', c.country,
        'since', c.created_at, 'guest', c.guest_id) order by c.created_at desc) from customers c), '[]'),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'bk', r.booking_id, 'paid_total', r.paid_total, 'fee', r.fee, 'amount', r.amount,
        'pct', r.pct, 'reason', r.reason, 'status', r.status, 'at', r.created_at, 'paid_at', r.paid_at, 'paid_method', r.paid_method, 'paid_ref', r.paid_ref)
        order by r.id desc) from refunds r), '[]'),
    'journal', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'date', e.entry_date, 'desc', e.description, 'ref', e.ref, 'src', e.source,
        'rev', e.reverses, 'revBy', e.reversed_by, 'at', e.created_at,
        'lines', (select jsonb_agg(jsonb_build_object('a', l.account, 'dr', l.debit, 'cr', l.credit) order by l.id) from journal_lines l where l.entry_id = e.id))
      order by e.id) from journal_entries e), '[]'),
    'arOTA', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'bk', o.booking_id, 'ch', o.channel, 'date', o.entry_date, 'gross', o.gross,
        'amt', o.amount, 'settled', o.settled_on is not null)) from ota_receivables o), '[]'),
    'claims', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'bk', c.booking_id, 'amt', c.amount, 'ref', c.reference, 'status', c.status,
        'slip', c.slip_path, 'at', c.created_at, 'viewed_by', c.viewed_by, 'viewed_at', c.viewed_at, 'bank_ref', c.bank_ref, 'note', c.note,
        'viewer', (select name from staff where user_id = c.viewed_by), 'decider', (select name from staff where user_id = c.decided_by), 'decided_at', c.decided_at)
        order by c.id desc) from payment_claims c), '[]'),
    'locks', coalesce((select jsonb_agg(month order by month) from period_locks), '[]'),
    'audit', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'at', a.at, 'actor', a.actor, 'action', a.action, 'ref', a.ref, 'detail', a.detail) order by a.id desc)
      from (select * from audit_log order by id desc limit 500) a), '[]')
  );
end $$;

-- ---------- privileges ----------
-- anonymous visitors can only browse; booking, paying and checking a booking need a member login
revoke execute on function public_book(jsonb), public_lookup(text, text), public_claim(text, text, bigint, text, text) from public, anon, authenticated;
revoke execute on function require_member(), cancel_deadline(date), paid_net(text), settle_cancellation(text, numeric, text), member_booking(text),
  expire_unpaid(), confirm_if_paid(text) from public, anon, authenticated;
revoke execute on function member_me(), member_register(text, text, text), member_book(jsonb), member_bookings(), member_claim(text, bigint, text),
  member_cancel(text), staff_open_slip(bigint), staff_verify_claim(bigint, boolean, text, text), staff_refund_paid(bigint, text, text) from public, anon;
grant execute on function member_me(), member_register(text, text, text), member_book(jsonb), member_bookings(), member_claim(text, bigint, text),
  member_cancel(text), staff_open_slip(bigint), staff_verify_claim(bigint, boolean, text, text), staff_refund_paid(bigint, text, text) to authenticated;
revoke execute on function slip_path_ok(text) from public, anon;
grant execute on function slip_path_ok(text) to authenticated;

drop policy if exists "slips: guests upload" on storage.objects;
drop policy if exists "slips: members upload" on storage.objects;
create policy "slips: members upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'slips' and public.slip_path_ok(name));
