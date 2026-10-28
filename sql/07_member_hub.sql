-- =====================================================================
-- Saynam Hotel Suite — member hub: payment history, messages to the hotel,
-- reviews after the stay, notifications, profile & security events.
-- Every member function works only on rows of auth.uid(); tables are closed
-- to direct access (RLS + no grants) and readable by staff only.
-- =====================================================================

create table if not exists support_threads (
  id bigserial primary key,
  customer_id uuid not null references customers(user_id),
  booking_id text references bookings(id),
  category text not null check (category in ('question','problem','booking','payment','other')),
  subject text not null check (length(trim(subject)) between 3 and 120),
  status text not null default 'open' check (status in ('open','answered','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  member_seen_at timestamptz,
  staff_seen_at timestamptz
);
create index if not exists support_threads_customer_idx on support_threads (customer_id);

create table if not exists support_messages (
  id bigserial primary key,
  thread_id bigint not null references support_threads(id),
  sender text not null check (sender in ('member','staff')),
  staff_id uuid,
  body text not null check (length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists support_messages_thread_idx on support_messages (thread_id);

create table if not exists reviews (
  id bigserial primary key,
  booking_id text not null unique references bookings(id),
  customer_id uuid not null references customers(user_id),
  rating int not null check (rating between 1 and 5),
  r_clean int check (r_clean between 1 and 5),
  r_service int check (r_service between 1 and 5),
  r_location int check (r_location between 1 and 5),
  r_value int check (r_value between 1 and 5),
  title text check (length(title) <= 120),
  body text check (length(body) <= 2000),
  status text not null default 'published' check (status in ('published','hidden')),
  staff_reply text check (length(staff_reply) <= 2000),
  replied_by uuid, replied_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists reviews_customer_idx on reviews (customer_id);

create table if not exists notifications (
  id bigserial primary key,
  customer_id uuid not null references customers(user_id),
  kind text not null,
  booking_id text references bookings(id),
  data jsonb not null default '{}',
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_customer_idx on notifications (customer_id, created_at desc);

do $$
declare t text;
begin
  foreach t in array array['support_threads','support_messages','reviews','notifications'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists staff_read on %I', t);
    execute format('create policy staff_read on %I for select to authenticated using (is_staff())', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant select on %I to authenticated', t);
  end loop;
end $$;
revoke all on sequence support_threads_id_seq, support_messages_id_seq, reviews_id_seq, notifications_id_seq from anon, authenticated;

-- ---------- notifications: written by triggers, so every path (guest, staff, night audit) is covered ----------
create or replace function notify(p_customer uuid, p_kind text, p_booking text, p_data jsonb default '{}') returns void
language sql security definer set search_path = public as $$
  insert into notifications(customer_id, kind, booking_id, data) select p_customer, p_kind, p_booking, coalesce(p_data, '{}') where p_customer is not null
$$;

create or replace function trg_notify_booking() returns trigger language plpgsql security definer set search_path = public as $$
declare k text; d jsonb;
begin
  if new.customer_id is null then return new; end if;
  d := jsonb_build_object('code', new.code, 'ci', new.check_in, 'co', new.check_out, 'total', new.rate * (new.check_out - new.check_in));
  if tg_op = 'INSERT' then
    perform notify(new.customer_id, 'booking_received', new.id, d);
  elsif new.status is distinct from old.status then
    k := case new.status
           when 'confirmed' then 'booking_confirmed'
           when 'inhouse' then 'checked_in'
           when 'out' then 'checked_out'
           when 'noshow' then 'booking_noshow'
           when 'cancelled' then case new.cancel_reason when 'guest_cancelled' then 'booking_cancelled' when 'declined_by_staff' then 'booking_declined'
                                                       when 'unpaid_expired' then 'booking_expired' when 'unpaid_at_arrival' then 'booking_expired' else 'booking_cancelled_hotel' end
         end;
    if k is not null then perform notify(new.customer_id, k, new.id, d); end if;
  end if;
  return new;
end $$;
drop trigger if exists notify_booking on bookings;
create trigger notify_booking after insert or update of status on bookings for each row execute function trg_notify_booking();

create or replace function trg_notify_claim() returns trigger language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = new.booking_id;
  if b.customer_id is null then return new; end if;
  if tg_op = 'INSERT' then
    perform notify(b.customer_id, 'slip_received', b.id, jsonb_build_object('code', b.code, 'amount', new.amount));
  elsif new.status is distinct from old.status and new.status in ('verified', 'rejected') then
    perform notify(b.customer_id, case new.status when 'verified' then 'payment_verified' else 'payment_rejected' end, b.id,
                   jsonb_build_object('code', b.code, 'amount', new.amount, 'ref', new.bank_ref));
  end if;
  return new;
end $$;
drop trigger if exists notify_claim on payment_claims;
create trigger notify_claim after insert or update of status on payment_claims for each row execute function trg_notify_claim();

create or replace function trg_notify_refund() returns trigger language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = new.booking_id;
  if b.customer_id is null or new.amount <= 0 then return new; end if;
  if tg_op = 'INSERT' then
    perform notify(b.customer_id, 'refund_owed', b.id, jsonb_build_object('code', b.code, 'amount', new.amount, 'fee', new.fee));
  elsif new.status = 'paid' and old.status <> 'paid' then
    perform notify(b.customer_id, 'refund_paid', b.id, jsonb_build_object('code', b.code, 'amount', new.amount, 'ref', new.paid_ref));
  end if;
  return new;
end $$;
drop trigger if exists notify_refund on refunds;
create trigger notify_refund after insert or update of status on refunds for each row execute function trg_notify_refund();

create or replace function trg_notify_support() returns trigger language plpgsql security definer set search_path = public as $$
declare th support_threads;
begin
  if new.sender <> 'staff' then return new; end if;
  select * into th from support_threads where id = new.thread_id;
  perform notify(th.customer_id, 'support_reply', th.booking_id, jsonb_build_object('thread', th.id, 'subject', th.subject));
  return new;
end $$;
drop trigger if exists notify_support on support_messages;
create trigger notify_support after insert on support_messages for each row execute function trg_notify_support();

-- ---------- member: profile & security ----------
create or replace function member_me() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c customers; u record;
begin
  if auth.uid() is null then return null; end if;
  select id, email, last_sign_in_at, created_at into u from auth.users where id = auth.uid();
  select * into c from customers where user_id = auth.uid();
  if c.user_id is null then return jsonb_build_object('profile', false, 'email', u.email); end if;
  return jsonb_build_object('profile', true, 'name', c.name, 'phone', c.phone, 'email', c.email, 'country', c.country, 'since', c.created_at,
    'member_no', 'M-' || upper(left(replace(c.user_id::text, '-', ''), 8)), 'last_sign_in', u.last_sign_in_at,
    'bookings', (select count(*) from bookings where customer_id = c.user_id),
    'reviews', (select count(*) from reviews where customer_id = c.user_id));
end $$;

create or replace function member_security_event(p_kind text) returns void language plpgsql security definer set search_path = public as $$
declare c customers;
begin
  c := require_member();
  if p_kind not in ('password_changed') then raise exception 'invalid_kind' using errcode = 'P0001'; end if;
  perform log_action('member.' || p_kind, c.email, null);
  perform notify(c.user_id, p_kind, null, '{}');
end $$;

-- ---------- member: payment history (incoming, slips under review or rejected, refunds owed and paid) ----------
create or replace function member_payments() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c customers;
begin
  c := require_member();
  return coalesce((select jsonb_agg(row_to_json(x) order by x.at desc, x.no desc) from (
    select 'PAY-' || lpad(p.id::text, 6, '0') as no, p.created_at as at, b.code, case when p.kind = 'refund' then 'refund' else 'payment' end as kind,
           p.method, p.amount, p.reference as ref, 'done' as status, b.type_id
    from payments p join bookings b on b.id = p.booking_id where b.customer_id = c.user_id
    union all
    select 'SLP-' || lpad(pc.id::text, 6, '0'), pc.created_at, b.code, 'slip', 'qr', pc.amount, null, pc.status, b.type_id
    from payment_claims pc join bookings b on b.id = pc.booking_id where b.customer_id = c.user_id and pc.status in ('pending', 'rejected')
    union all
    select 'RF-' || lpad(r.id::text, 6, '0'), r.created_at, b.code, 'refund_owed', null, r.amount, null, 'owed', b.type_id
    from refunds r join bookings b on b.id = r.booking_id where b.customer_id = c.user_id and r.status = 'owed' and r.amount > 0
  ) x), '[]');
end $$;

-- ---------- member: messages ----------
create or replace function member_threads() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c customers;
begin
  c := require_member();
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'category', t.category, 'subject', t.subject, 'status', t.status,
      'code', (select code from bookings where id = t.booking_id), 'created', t.created_at, 'updated', t.updated_at,
      'unread', exists (select 1 from support_messages m where m.thread_id = t.id and m.sender = 'staff' and m.created_at > coalesce(t.member_seen_at, '-infinity')),
      'messages', coalesce((select jsonb_agg(jsonb_build_object('sender', m.sender, 'body', m.body, 'at', m.created_at,
                    'staff', case when m.sender = 'staff' then (select split_part(name, ' ', 1) from staff where user_id = m.staff_id) end) order by m.id)
                  from support_messages m where m.thread_id = t.id), '[]')) order by t.updated_at desc)
    from support_threads t where t.customer_id = c.user_id), '[]');
end $$;

create or replace function member_thread_new(p_category text, p_subject text, p_body text, p_code text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare c customers; bid text; tid bigint;
begin
  c := require_member();
  if p_category not in ('question','problem','booking','payment','other') then raise exception 'invalid_kind' using errcode = 'P0001'; end if;
  if length(trim(coalesce(p_subject, ''))) < 3 then raise exception 'subject_required' using errcode = 'P0001'; end if;
  if length(trim(coalesce(p_body, ''))) < 5 or length(p_body) > 2000 then raise exception 'message_required' using errcode = 'P0001'; end if;
  if (select count(*) from support_threads where customer_id = c.user_id and status <> 'closed') >= 5 then raise exception 'too_many_threads' using errcode = 'P0001'; end if;
  if (select count(*) from support_messages m join support_threads t on t.id = m.thread_id
      where t.customer_id = c.user_id and m.sender = 'member' and m.created_at > now() - interval '1 day') >= 30 then
    raise exception 'too_many_messages' using errcode = 'P0001';
  end if;
  if nullif(trim(p_code), '') is not null then
    select id into bid from bookings where code = upper(trim(p_code)) and customer_id = c.user_id;
    if bid is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  end if;
  insert into support_threads(customer_id, booking_id, category, subject, member_seen_at) values (c.user_id, bid, p_category, left(trim(p_subject), 120), now()) returning id into tid;
  insert into support_messages(thread_id, sender, body) values (tid, 'member', trim(p_body));
  perform log_action('support.new', 'T-' || tid, jsonb_build_object('category', p_category, 'subject', left(trim(p_subject), 120), 'booking', bid));
  return tid;
end $$;

create or replace function member_thread_reply(p_thread bigint, p_body text) returns void language plpgsql security definer set search_path = public as $$
declare c customers; th support_threads;
begin
  c := require_member();
  select * into th from support_threads where id = p_thread and customer_id = c.user_id for update;
  if th.id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if length(trim(coalesce(p_body, ''))) < 1 or length(p_body) > 2000 then raise exception 'message_required' using errcode = 'P0001'; end if;
  if (select count(*) from support_messages m join support_threads t on t.id = m.thread_id
      where t.customer_id = c.user_id and m.sender = 'member' and m.created_at > now() - interval '1 day') >= 30 then
    raise exception 'too_many_messages' using errcode = 'P0001';
  end if;
  insert into support_messages(thread_id, sender, body) values (th.id, 'member', trim(p_body));
  update support_threads set status = 'open', updated_at = now(), member_seen_at = now() where id = th.id;
  perform log_action('support.reply', 'T-' || th.id, null);
end $$;

create or replace function member_thread_close(p_thread bigint) returns void language plpgsql security definer set search_path = public as $$
declare c customers;
begin
  c := require_member();
  update support_threads set status = 'closed', updated_at = now() where id = p_thread and customer_id = c.user_id;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform log_action('support.close', 'T-' || p_thread, jsonb_build_object('by', 'member'));
end $$;

create or replace function member_thread_seen(p_thread bigint) returns void language plpgsql security definer set search_path = public as $$
declare c customers;
begin
  c := require_member();
  update support_threads set member_seen_at = now() where id = p_thread and customer_id = c.user_id;
  update notifications set read_at = now() where customer_id = c.user_id and kind = 'support_reply' and read_at is null and (data->>'thread')::bigint = p_thread;
end $$;

-- ---------- member: reviews (only after checking out) ----------
create or replace function member_review(p_code text, p_rating int, p_clean int, p_service int, p_location int, p_value int, p_title text, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare c customers; b bookings; r reviews;
begin
  c := require_member();
  select * into b from bookings where code = upper(trim(p_code)) and customer_id = c.user_id;
  if b.id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if b.status <> 'out' then raise exception 'review_after_stay' using errcode = 'P0001'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'rating_required' using errcode = 'P0001'; end if;
  if length(coalesce(p_body, '')) > 2000 or length(coalesce(p_title, '')) > 120 then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  select * into r from reviews where booking_id = b.id for update;
  if r.id is null then
    insert into reviews(booking_id, customer_id, rating, r_clean, r_service, r_location, r_value, title, body)
    values (b.id, c.user_id, p_rating, p_clean, p_service, p_location, p_value, nullif(trim(p_title), ''), nullif(trim(p_body), ''));
    perform log_action('review.create', b.id, jsonb_build_object('rating', p_rating));
  else
    -- a review can be edited until the hotel has answered it
    if r.staff_reply is not null then raise exception 'review_locked' using errcode = 'P0001'; end if;
    update reviews set rating = p_rating, r_clean = p_clean, r_service = p_service, r_location = p_location, r_value = p_value,
           title = nullif(trim(p_title), ''), body = nullif(trim(p_body), ''), updated_at = now() where id = r.id;
    perform log_action('review.update', b.id, jsonb_build_object('rating', p_rating, 'was', r.rating));
  end if;
end $$;

create or replace function member_reviews() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c customers;
begin
  c := require_member();
  return coalesce((select jsonb_agg(jsonb_build_object('code', b.code, 'rating', r.rating, 'r_clean', r.r_clean, 'r_service', r.r_service, 'r_location', r.r_location,
      'r_value', r.r_value, 'title', r.title, 'body', r.body, 'status', r.status, 'reply', r.staff_reply, 'replied_at', r.replied_at,
      'created', r.created_at, 'updated', r.updated_at) order by r.created_at desc)
    from reviews r join bookings b on b.id = r.booking_id where r.customer_id = c.user_id), '[]');
end $$;

-- ---------- member: notifications ----------
create or replace function member_notifications() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c customers;
begin
  c := require_member();
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'code', (select code from bookings where id = n.booking_id),
      'data', n.data, 'read', n.read_at is not null, 'at', n.created_at) order by n.id desc)
    from (select * from notifications where customer_id = c.user_id order by id desc limit 80) n), '[]');
end $$;

create or replace function member_notifications_read(p_ids bigint[] default null) returns void language plpgsql security definer set search_path = public as $$
declare c customers;
begin
  c := require_member();
  update notifications set read_at = now() where customer_id = c.user_id and read_at is null and (p_ids is null or id = any(p_ids));
end $$;

-- one round trip for the account page
create or replace function member_hub() returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform require_member();
  return jsonb_build_object('me', member_me(), 'bookings', member_bookings(), 'payments', member_payments(), 'threads', member_threads(),
    'reviews', member_reviews(), 'notifications', member_notifications(),
    'unread', (select count(*) from notifications where customer_id = auth.uid() and read_at is null));
end $$;

-- ---------- public: published reviews for the website ----------
create or replace function public_reviews() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'count', (select count(*) from reviews where status = 'published'),
    'avg', (select round(avg(rating)::numeric, 1) from reviews where status = 'published'),
    'items', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
      select jsonb_build_object('name', split_part(c.name, ' ', 1), 'country', c.country, 'rating', r.rating, 'title', r.title, 'body', r.body,
        'month', to_char(b.check_in, 'YYYY-MM'), 'type', b.type_id, 'reply', r.staff_reply, 'at', r.created_at) x
      from reviews r join customers c on c.user_id = r.customer_id join bookings b on b.id = r.booking_id
      where r.status = 'published' order by r.created_at desc limit 12) q), '[]'))
$$;

-- ---------- staff: inbox & reviews ----------
create or replace function admin_support() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'permission_denied' using errcode = '42501'; end if;
  return jsonb_build_object(
    'threads', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'member', t.customer_id, 'name', c.name, 'email', c.email, 'phone', c.phone,
        'bk', t.booking_id, 'category', t.category, 'subject', t.subject, 'status', t.status, 'created', t.created_at, 'updated', t.updated_at,
        'unread', exists (select 1 from support_messages m where m.thread_id = t.id and m.sender = 'member' and m.created_at > coalesce(t.staff_seen_at, '-infinity')),
        'messages', coalesce((select jsonb_agg(jsonb_build_object('sender', m.sender, 'body', m.body, 'at', m.created_at,
                      'staff', (select name from staff where user_id = m.staff_id)) order by m.id) from support_messages m where m.thread_id = t.id), '[]'))
        order by t.updated_at desc) from support_threads t join customers c on c.user_id = t.customer_id), '[]'),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'bk', r.booking_id, 'name', c.name, 'email', c.email, 'rating', r.rating,
        'r_clean', r.r_clean, 'r_service', r.r_service, 'r_location', r.r_location, 'r_value', r.r_value, 'title', r.title, 'body', r.body,
        'status', r.status, 'reply', r.staff_reply, 'replied_at', r.replied_at, 'replier', (select name from staff where user_id = r.replied_by),
        'created', r.created_at) order by r.created_at desc) from reviews r join customers c on c.user_id = r.customer_id), '[]'));
end $$;

create or replace function staff_thread_reply(p_thread bigint, p_body text, p_close boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare th support_threads;
begin
  perform require_role('manager', 'frontdesk', 'accountant');
  select * into th from support_threads where id = p_thread for update;
  if th.id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if length(trim(coalesce(p_body, ''))) < 1 or length(p_body) > 2000 then raise exception 'message_required' using errcode = 'P0001'; end if;
  insert into support_messages(thread_id, sender, staff_id, body) values (th.id, 'staff', auth.uid(), trim(p_body));
  update support_threads set status = case when p_close then 'closed' else 'answered' end, updated_at = now(), staff_seen_at = now() where id = th.id;
  perform log_action('support.answer', 'T-' || th.id, jsonb_build_object('close', p_close));
end $$;

create or replace function staff_thread_status(p_thread bigint, p_status text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_role('manager', 'frontdesk', 'accountant');
  if p_status not in ('open', 'closed', 'seen') then raise exception 'invalid_kind' using errcode = 'P0001'; end if;
  if p_status = 'seen' then update support_threads set staff_seen_at = now() where id = p_thread; return; end if;
  update support_threads set status = p_status, updated_at = now() where id = p_thread;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform log_action('support.' || p_status, 'T-' || p_thread, jsonb_build_object('by', 'staff'));
end $$;

create or replace function staff_review_reply(p_id bigint, p_reply text) returns void language plpgsql security definer set search_path = public as $$
declare r reviews;
begin
  perform require_role('manager', 'frontdesk');
  select * into r from reviews where id = p_id for update;
  if r.id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if length(trim(coalesce(p_reply, ''))) < 2 or length(p_reply) > 2000 then raise exception 'message_required' using errcode = 'P0001'; end if;
  update reviews set staff_reply = trim(p_reply), replied_by = auth.uid(), replied_at = now() where id = p_id;
  perform log_action('review.reply', r.booking_id, null);
  perform notify(r.customer_id, 'review_reply', r.booking_id, jsonb_build_object('code', (select code from bookings where id = r.booking_id)));
end $$;

create or replace function staff_review_status(p_id bigint, p_status text) returns void language plpgsql security definer set search_path = public as $$
declare r reviews;
begin
  perform require_role('manager');
  if p_status not in ('published', 'hidden') then raise exception 'invalid_kind' using errcode = 'P0001'; end if;
  update reviews set status = p_status where id = p_id returning * into r;
  if r.id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform log_action('review.' || p_status, r.booking_id, null);
end $$;

-- ---------- privileges ----------
revoke execute on function notify(uuid, text, text, jsonb), trg_notify_booking(), trg_notify_claim(), trg_notify_refund(), trg_notify_support() from public, anon, authenticated;
revoke execute on function member_me(), member_security_event(text), member_payments(), member_threads(), member_thread_new(text, text, text, text),
  member_thread_reply(bigint, text), member_thread_close(bigint), member_thread_seen(bigint),
  member_review(text, int, int, int, int, int, text, text), member_reviews(), member_notifications(), member_notifications_read(bigint[]), member_hub(),
  admin_support(), staff_thread_reply(bigint, text, boolean), staff_thread_status(bigint, text), staff_review_reply(bigint, text), staff_review_status(bigint, text)
  from public, anon;
grant execute on function member_me(), member_security_event(text), member_payments(), member_threads(), member_thread_new(text, text, text, text),
  member_thread_reply(bigint, text), member_thread_close(bigint), member_thread_seen(bigint),
  member_review(text, int, int, int, int, int, text, text), member_reviews(), member_notifications(), member_notifications_read(bigint[]), member_hub(),
  admin_support(), staff_thread_reply(bigint, text, boolean), staff_thread_status(bigint, text), staff_review_reply(bigint, text), staff_review_status(bigint, text)
  to authenticated;
revoke execute on function public_reviews() from public;
grant execute on function public_reviews() to anon, authenticated;
