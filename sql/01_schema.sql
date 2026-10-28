-- =====================================================================
-- Saynam Hotel Suite — database for Supabase (PostgreSQL 15+)
-- Run files in order: 01_schema.sql, 02_functions.sql, 03_seed.sql
-- Money is stored as whole LAK in bigint. Every amount that reaches the
-- books goes through post_entry(), which refuses unbalanced entries and
-- entries dated in a locked month. Journal rows can never be edited or
-- deleted: a mistake is corrected by a reversing entry.
-- =====================================================================
create schema if not exists extensions;
create extension if not exists btree_gist with schema extensions;
create extension if not exists pgcrypto with schema extensions;
set search_path = public, extensions;

-- ---------- settings & master data ----------
create table settings (
  id int primary key default 1 check (id = 1),
  hotel_name text not null default 'Saynam Riverside Hotel',
  tagline jsonb not null default '{}',
  about jsonb not null default '{}',
  address text, phone text, email text, map_url text,
  check_in_time text not null default '14:00',
  check_out_time text not null default '12:00',
  currency text not null default 'LAK',
  vat_rate numeric(5,2) not null default 10 check (vat_rate between 0 and 30),
  prices_incl_vat boolean not null default true,
  deposit_pct numeric(5,2) not null default 30 check (deposit_pct between 0 and 100),
  direct_discount numeric(5,2) not null default 5 check (direct_discount between 0 and 50),
  free_cancel_days int not null default 3,
  payment_note jsonb not null default '{}',
  business_date date not null default current_date
);

create table accounts (
  code text primary key,
  type text not null check (type in ('ca','nca','cl','ncl','eq','rev','cos','opx','fin')),
  name jsonb not null,
  active boolean not null default true
);

create table staff (
  user_id uuid primary key,              -- = auth.users.id
  name text not null,
  role text not null check (role in ('owner','manager','frontdesk','accountant','housekeeping')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table amenities (
  id text primary key,
  icon text not null default 'dot',
  name jsonb not null,
  sort int not null default 0
);

create table room_types (
  id text primary key,
  name jsonb not null,
  description jsonb not null default '{}',
  capacity int not null check (capacity between 1 and 12),
  base_rate bigint not null check (base_rate > 0),
  size_m2 int,
  bed jsonb not null default '{}',
  amenities text[] not null default '{}',
  sort int not null default 0,
  active boolean not null default true
);

create table rooms (
  no text primary key,
  type_id text not null references room_types(id),
  floor int not null default 1,
  hk_status text not null default 'inspected' check (hk_status in ('clean','inspected','dirty','ooo')),
  note text,
  active boolean not null default true
);

create table channels (
  id text primary key,
  name jsonb not null,
  commission numeric(5,4) not null default 0 check (commission between 0 and 0.5),
  mode text not null default 'hotel' check (mode in ('hotel','ota'))  -- ota = the OTA collects from the guest
);

create table promo_codes (
  code text primary key check (code = upper(code)),
  pct numeric(5,2) not null check (pct > 0 and pct <= 50),
  active boolean not null default true,
  valid_to date
);

-- ---------- guests & bookings ----------
create table guests (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 120),
  phone text, email text, country text default 'OT', notes text,
  created_at timestamptz not null default now()
);
create index on guests (phone);

create sequence booking_seq start 3001;
create table bookings (
  id text primary key default 'BK' || nextval('booking_seq'),
  code text not null unique default upper(substr(encode(extensions.gen_random_bytes(6),'hex'),1,6)),
  guest_id uuid not null references guests(id),
  room_no text not null references rooms(no),
  type_id text not null references room_types(id),
  check_in date not null,
  check_out date not null,
  adults int not null default 1 check (adults between 1 and 12),
  channel text not null references channels(id),
  rate bigint not null check (rate >= 0),
  status text not null default 'confirmed' check (status in ('confirmed','inhouse','out','cancelled','noshow')),
  deposit_due bigint not null default 0,
  promo text,
  special_request text,
  source text not null default 'staff' check (source in ('staff','website','import')),
  created_at timestamptz not null default now(),
  created_by uuid,
  checked_in_at timestamptz, checked_out_at timestamptz, cancelled_at timestamptz,
  check (check_out > check_in),
  -- a room can never hold two live stays on the same night
  constraint no_double_booking exclude using gist (room_no with =, daterange(check_in, check_out) with &&)
    where (status in ('confirmed','inhouse','out'))
);
create index on bookings (check_in);
create index on bookings (status);

-- ---------- the books ----------
create table journal_entries (
  id bigserial primary key,
  entry_date date not null,
  description jsonb not null,
  ref text,
  source text not null,
  reverses bigint references journal_entries(id),
  reversed_by bigint references journal_entries(id),
  created_by uuid,
  created_at timestamptz not null default now()
);
create index on journal_entries (entry_date);
create index on journal_entries (ref);

create table journal_lines (
  id bigserial primary key,
  entry_id bigint not null references journal_entries(id),
  account text not null references accounts(code),
  debit bigint not null default 0 check (debit >= 0),
  credit bigint not null default 0 check (credit >= 0),
  check ((debit > 0) <> (credit > 0))
);
create index on journal_lines (entry_id);
create index on journal_lines (account);

create table folio_items (
  id bigserial primary key,
  booking_id text not null references bookings(id),
  biz_date date not null,
  kind text not null check (kind in ('room','fnb','minibar','laundry','tour','other')),
  description jsonb not null,
  gross bigint not null, net bigint not null, vat bigint not null,
  voids bigint references folio_items(id),
  journal_id bigint not null references journal_entries(id),
  created_by uuid,
  created_at timestamptz not null default now()
);
create index on folio_items (booking_id);

create table payments (
  id bigserial primary key,
  booking_id text not null references bookings(id),
  biz_date date not null,
  method text not null check (method in ('cash','qr','card','transfer')),
  amount bigint not null check (amount > 0),
  kind text not null check (kind in ('deposit','payment','refund')),
  applied boolean not null default true,     -- deposits flip to true at check-in / forfeiture
  reference text,
  journal_id bigint not null references journal_entries(id),
  created_by uuid,
  created_at timestamptz not null default now()
);
create index on payments (booking_id);

create table payment_claims (                 -- guest says "I paid by QR"; staff verifies against the bank
  id bigserial primary key,
  booking_id text not null references bookings(id),
  amount bigint not null check (amount > 0),
  reference text,
  status text not null default 'pending' check (status in ('pending','verified','rejected')),
  payment_id bigint references payments(id),
  decided_by uuid, decided_at timestamptz,
  created_at timestamptz not null default now()
);

create table ota_receivables (
  id bigserial primary key,
  booking_id text not null references bookings(id),
  channel text not null references channels(id),
  entry_date date not null,
  gross bigint not null,
  amount bigint not null,                    -- net of commission: what the OTA will pay out
  settled_on date,
  payout_entry bigint references journal_entries(id)
);

create table period_locks (
  month text primary key check (month ~ '^\d{4}-\d{2}$'),
  locked_by uuid,
  locked_at timestamptz not null default now()
);

create table audit_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  user_id uuid,
  actor text,
  action text not null,
  ref text,
  detail jsonb
);
create index on audit_log (at desc);

-- ---------- integrity triggers ----------
create or replace function trg_entry_balanced() returns trigger language plpgsql set search_path = public as $$
declare d bigint; c bigint; eid bigint := coalesce(new.entry_id, old.entry_id);
begin
  select coalesce(sum(debit),0), coalesce(sum(credit),0) into d, c from journal_lines where entry_id = eid;
  if d <> c or d = 0 then
    raise exception 'Journal entry % is not balanced (Dr % / Cr %)', eid, d, c using errcode = '23514';
  end if;
  return null;
end $$;
create constraint trigger journal_balanced after insert on journal_lines
  deferrable initially deferred for each row execute function trg_entry_balanced();

create or replace function trg_no_change() returns trigger language plpgsql set search_path = public as $$
begin
  raise exception '% rows are permanent: post a reversing entry instead', tg_table_name using errcode = '42501';
end $$;
create trigger journal_lines_frozen before update or delete on journal_lines for each row execute function trg_no_change();
create trigger folio_frozen before update or delete on folio_items for each row execute function trg_no_change();
create trigger ota_no_delete before delete on ota_receivables for each row execute function trg_no_change();
create trigger audit_frozen before update or delete on audit_log for each row execute function trg_no_change();

create or replace function trg_entry_guard() returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then raise exception 'journal entries are permanent' using errcode = '42501'; end if;
  if old.reversed_by is null and new.reversed_by is not null
     and (new.entry_date, new.description, new.ref, new.source, new.reverses) is not distinct from
         (old.entry_date, old.description, old.ref, old.source, old.reverses) then
    return new;                                    -- the only allowed change: mark as reversed, once
  end if;
  raise exception 'journal entries are permanent: post a reversing entry instead' using errcode = '42501';
end $$;
create trigger journal_entries_guard before update or delete on journal_entries for each row execute function trg_entry_guard();

create or replace function trg_payment_guard() returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and old.applied = false and new.applied = true
     and (to_jsonb(new) - 'applied') = (to_jsonb(old) - 'applied') then return new; end if;
  raise exception 'payments are permanent' using errcode = '42501';
end $$;
create trigger payments_guard before update or delete on payments for each row execute function trg_payment_guard();

-- business_date only moves through the night audit
create or replace function trg_settings_guard() returns trigger language plpgsql set search_path = public as $$
begin
  if new.business_date is distinct from old.business_date and coalesce(current_setting('hotel.night_audit', true),'') <> 'on' then
    raise exception 'business date changes only through the night audit' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger settings_guard before update on settings for each row execute function trg_settings_guard();

-- master-data change history
create or replace function trg_audit_row() returns trigger language plpgsql security definer set search_path = public as $$
declare pk text;
begin
  if tg_table_name = 'rooms' and tg_op = 'UPDATE' and (to_jsonb(new) - 'hk_status') = (to_jsonb(old) - 'hk_status') then
    return new;                                   -- housekeeping status changes are logged by staff_set_hk
  end if;
  pk := coalesce(to_jsonb(new)->>'id', to_jsonb(new)->>'no', to_jsonb(new)->>'code', to_jsonb(new)->>'month', to_jsonb(new)->>'user_id',
                 to_jsonb(old)->>'id', to_jsonb(old)->>'no', to_jsonb(old)->>'code', to_jsonb(old)->>'month', to_jsonb(old)->>'user_id');
  insert into audit_log(user_id, actor, action, ref, detail)
  values (auth.uid(), (select name from staff where user_id = auth.uid()), tg_table_name || '.' || lower(tg_op), pk,
          jsonb_build_object('old', case when tg_op <> 'INSERT' then to_jsonb(old) end, 'new', case when tg_op <> 'DELETE' then to_jsonb(new) end));
  return coalesce(new, old);
end $$;
create trigger audit_settings after update on settings for each row execute function trg_audit_row();
create trigger audit_room_types after insert or update or delete on room_types for each row execute function trg_audit_row();
create trigger audit_rooms after insert or update or delete on rooms for each row execute function trg_audit_row();
create trigger audit_channels after insert or update or delete on channels for each row execute function trg_audit_row();
create trigger audit_promos after insert or update or delete on promo_codes for each row execute function trg_audit_row();
create trigger audit_staff after insert or update or delete on staff for each row execute function trg_audit_row();
create trigger audit_amenities after insert or update or delete on amenities for each row execute function trg_audit_row();
create trigger audit_accounts after insert or update or delete on accounts for each row execute function trg_audit_row();
create trigger audit_locks after insert or delete on period_locks for each row execute function trg_audit_row();
