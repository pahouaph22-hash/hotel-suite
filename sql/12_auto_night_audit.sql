-- =====================================================================
-- Saynam Hotel Suite — the day closes itself at midnight (Vientiane time) if the desk forgot,
-- the desk cannot close the same day twice, and month-end entries refuse to post an amount that was never set.
-- =====================================================================
create or replace function night_audit_core() returns jsonb language plpgsql security definer set search_path = public as $$
declare d date := biz(); b record; n int := 0; ns int := 0; ex int := 0; amt bigint := 0;
begin
  if exists (select 1 from bookings where status = 'inhouse' and check_out <= d) then
    raise exception 'departures_pending' using errcode = 'P0001';
  end if;
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

create or replace function staff_night_audit() returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform require_role('manager', 'frontdesk');
  -- closing early in the evening is normal (the business date moves to tomorrow); closing tomorrow as well is not
  if biz() > (now() at time zone 'Asia/Vientiane')::date then raise exception 'day_already_closed' using errcode = 'P0001'; end if;
  return night_audit_core();
end $$;

-- run by the scheduler a few minutes after midnight: catches up every day the desk did not close
create or replace function auto_night_audit() returns jsonb language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone 'Asia/Vientiane')::date; done int := 0; r jsonb;
begin
  while biz() < today and done < 31 loop
    begin
      r := night_audit_core();
      done := done + 1;
    exception when others then
      perform log_action('night_audit.auto_failed', to_char(biz(), 'YYYY-MM-DD'), jsonb_build_object('error', sqlerrm));
      exit;
    end;
  end loop;
  return jsonb_build_object('closed_days', done, 'business_date', biz());
end $$;

create or replace function acct_close(p_kind text, p_month text) returns bigint language plpgsql security definer set search_path = public as $$
declare a jsonb; d date; eid bigint; k text; v bigint;
begin
  perform require_role('manager','accountant');
  select close_amounts into a from settings where id = 1;
  d := least((p_month || '-01')::date + interval '1 month' - interval '1 day', biz())::date;
  if to_char(d, 'YYYY-MM') <> p_month then raise exception 'month_not_started' using errcode = 'P0001'; end if;
  k := case p_kind when 'depr' then 'depr' when 'int' then 'int' when 'sal_pay' then 'sal' when 'sal_accrue' then 'salAcc' end;
  if k is null then raise exception 'invalid_kind' using errcode = 'P0001'; end if;
  v := coalesce((a->>(case p_kind when 'depr' then 'depr' when 'int' then 'int' else 'sal' end))::bigint, 0);
  if v <= 0 then raise exception 'close_amount_missing' using errcode = 'P0001'; end if;
  if entry_posted(k, p_month) or (k in ('sal','salAcc') and (entry_posted('sal', p_month) or entry_posted('salAcc', p_month))) then
    raise exception 'already_posted' using errcode = 'P0001';
  end if;
  eid := post_entry(d, jsonb_build_object('k', k, 'mo', p_month), upper(k) || '-' || p_month, 'close',
    case p_kind
      when 'depr' then jsonb_build_array(jl('5800', v, 0), jl('1290', 0, v))
      when 'int' then jsonb_build_array(jl('5900', v, 0), jl('1120', 0, v))
      when 'sal_pay' then jsonb_build_array(jl('5200', v, 0), jl('1120', 0, v))
      else jsonb_build_array(jl('5200', v, 0), jl('2160', 0, v)) end);
  perform log_action('close.' || p_kind, p_month, null);
  return eid;
end $$;

revoke execute on function night_audit_core(), auto_night_audit() from public, anon, authenticated;
revoke execute on function staff_night_audit(), acct_close(text, text) from public, anon;
grant execute on function staff_night_audit(), acct_close(text, text) to authenticated;

-- schedule (only where pg_cron exists: the live project, not the local test database)
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      create extension if not exists pg_cron with schema pg_catalog;
      perform cron.unschedule(jobid) from cron.job where jobname = 'saynam-night-audit';
      perform cron.schedule('saynam-night-audit', '5 17 * * *', 'select public.auto_night_audit()');   -- 00:05 Vientiane (UTC+7)
    exception when others then
      raise notice 'automatic night audit not scheduled: %', sqlerrm;
    end;
  end if;
end $$;
