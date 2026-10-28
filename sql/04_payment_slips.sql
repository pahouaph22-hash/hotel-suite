-- =====================================================================
-- Saynam Hotel Suite — hotel payment QR + transfer-slip uploads
-- Run after 01–03. Needs Supabase Storage (present on every project).
-- =====================================================================
alter table settings add column if not exists payment_qr_url text;
alter table payment_claims add column if not exists slip_path text;

-- Storage: slips are private (staff only); the hotel's QR is public.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('slips', 'slips', false, 5242880, array['image/jpeg','image/png','image/webp']),
       ('hotel-public', 'hotel-public', true, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- A guest may upload a slip only into the folder of a booking that is still awaiting payment,
-- with a random file name, and only while fewer than 3 slips are waiting for review.
create or replace function slip_path_ok(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_name ~ '^[0-9A-F]{6}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
     and exists (select 1 from bookings b where b.code = split_part(p_name, '/', 1) and b.status = 'confirmed'
                 and (select count(*) from payment_claims c where c.booking_id = b.id and c.status = 'pending') < 3)
$$;
revoke execute on function slip_path_ok(text) from public;
grant execute on function slip_path_ok(text) to anon, authenticated;

drop policy if exists "slips: guests upload" on storage.objects;
create policy "slips: guests upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'slips' and public.slip_path_ok(name));
drop policy if exists "slips: staff read" on storage.objects;
create policy "slips: staff read" on storage.objects for select to authenticated
  using (bucket_id = 'slips' and public.is_staff());
drop policy if exists "hotel-public: managers write" on storage.objects;
create policy "hotel-public: managers write" on storage.objects for insert to authenticated
  with check (bucket_id = 'hotel-public' and public.my_role() in ('owner','manager'));

-- Guest reports a payment: a slip is now required, and it must be an uploaded file in this booking's folder.
drop function if exists public_claim(text, text, bigint, text);
create or replace function public_claim(p_code text, p_phone text, p_amount bigint, p_ref text, p_slip text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  b := find_guest_booking(p_code, p_phone);
  if b.id is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if b.status <> 'confirmed' then raise exception 'not_payable' using errcode = 'P0001'; end if;
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
revoke execute on function public_claim(text, text, bigint, text, text) from public;
grant execute on function public_claim(text, text, bigint, text, text) to anon, authenticated;
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