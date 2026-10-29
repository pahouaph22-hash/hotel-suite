-- =====================================================================
-- Saynam Hotel Suite — who checked each guest in and out, and when.
-- A trigger stamps the time and the staff member on every status change,
-- whichever function made it; history is backfilled from the audit log.
-- =====================================================================
alter table bookings add column if not exists checked_in_by uuid;
alter table bookings add column if not exists checked_out_by uuid;

create or replace function trg_stay_stamp() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'inhouse' then new.checked_in_at := coalesce(new.checked_in_at, now()); new.checked_in_by := coalesce(new.checked_in_by, auth.uid()); end if;
    if new.status = 'out' then new.checked_out_at := coalesce(new.checked_out_at, now()); new.checked_out_by := coalesce(new.checked_out_by, auth.uid()); end if;
  end if;
  return new;
end $$;
drop trigger if exists stay_stamp on bookings;
create trigger stay_stamp before update of status on bookings for each row execute function trg_stay_stamp();

-- history: take the staff member and time from the audit log where the booking row has none
update bookings b set checked_in_by = a.user_id, checked_in_at = coalesce(b.checked_in_at, a.at)
from (select distinct on (ref) ref, user_id, at from audit_log where action = 'booking.checkin' order by ref, id desc) a
where a.ref = b.id and b.checked_in_by is null and b.status in ('inhouse', 'out');
update bookings b set checked_out_by = a.user_id, checked_out_at = coalesce(b.checked_out_at, a.at)
from (select distinct on (ref) ref, user_id, at from audit_log where action = 'booking.checkout' order by ref, id desc) a
where a.ref = b.id and b.checked_out_by is null and b.status = 'out';

-- staff screen: check-in / check-out times and names for every booking
create or replace function admin_stays() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'permission_denied' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'ci_at', b.checked_in_at, 'co_at', b.checked_out_at,
      'ci_by', (select name from staff where user_id = b.checked_in_by), 'co_by', (select name from staff where user_id = b.checked_out_by)))
    from bookings b where b.checked_in_at is not null or b.checked_out_at is not null), '[]');
end $$;

revoke execute on function trg_stay_stamp() from public, anon, authenticated;
revoke execute on function admin_stays() from public, anon;
grant execute on function admin_stays() to authenticated;
