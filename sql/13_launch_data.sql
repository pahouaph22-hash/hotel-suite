-- =====================================================================
-- Saynam Hotel Suite — launch: real contact details and payment QR, wording that promises only what the
-- hotel has decided, month-end amounts cleared, and all test bookings / money / logs removed.
-- Keeps: settings, room types, rooms, amenities, channels, promo codes, chart of accounts, staff, member accounts.
-- =====================================================================
select set_config('hotel.night_audit', 'on', true);

update settings set
  phone = '+856 96886740',
  email = 'larmouamua@gmail.com',
  payment_qr_url = 'img/payment-qr.png',
  close_amounts = '{"sal": 0, "depr": 0, "int": 0}',
  pending_hold_hours = 6,
  business_date = (now() at time zone 'Asia/Vientiane')::date,
  payment_note = jsonb_build_object(
    'lo', 'ສະແກນ QR ດ້ວຍແອັບທະນາຄານທີ່ຮອງຮັບ LAO QR (ເຊັ່ນ BCEL One), ໃສ່ຈຳນວນເງິນໃຫ້ກົງກັບຍອດທີ່ສະແດງ, ແລ້ວອັບໂຫຼດຮູບສະລິບ. ເມື່ອພະນັກງານກວດສອບແລ້ວ ທ່ານຈະໄດ້ຮັບແຈ້ງເຕືອນໃນບັນຊີ.',
    'th', 'สแกน QR ด้วยแอปธนาคารที่รองรับ LAO QR (เช่น BCEL One) ใส่จำนวนเงินให้ตรงกับยอดที่แสดง แล้วอัปโหลดรูปสลิป เมื่อพนักงานตรวจสอบแล้ว คุณจะได้รับการแจ้งเตือนในบัญชี',
    'en', 'Scan the QR with a banking app that supports LAO QR (such as BCEL One), enter exactly the amount shown, then upload a picture of the slip. You will get a notification in your account once our team has checked it.'),
  about = jsonb_build_object(
    'lo', 'ໂຮງແຮມລຽບແມ່ນ້ຳຂອງ ໃນນະຄອນຫຼວງວຽງຈັນ. ຈອງກັບໂຮງແຮມໂດຍກົງ, ຊຳລະຜ່ານ LAO QR ແລະ ຕິດຕາມການຈອງຂອງທ່ານໄດ້ທຸກເວລາໃນບັນຊີສະມາຊິກ.',
    'th', 'โรงแรมริมแม่น้ำโขงในนครหลวงเวียงจันทน์ จองตรงกับโรงแรม ชำระผ่าน LAO QR และติดตามการจองของคุณได้ทุกเวลาในบัญชีสมาชิก',
    'en', 'A riverside hotel on the Mekong in Vientiane. Book direct with the hotel, pay by LAO QR and follow your booking any time in your member account.')
where id = 1;

-- test data: the ledger, folio, payments and audit log are append-only by design, so their guards are paused for this one clean-up
alter table journal_lines disable trigger user;
alter table journal_entries disable trigger user;
alter table folio_items disable trigger user;
alter table payments disable trigger user;
alter table audit_log disable trigger user;
alter table bookings disable trigger user;
alter table payment_claims disable trigger user;
alter table refunds disable trigger user;
alter table support_messages disable trigger user;
alter table ota_receivables disable trigger user;
alter table period_locks disable trigger user;

delete from notifications;
delete from support_messages;
delete from support_threads;
delete from reviews;
delete from refunds;
delete from payment_claims;
delete from ota_receivables;
delete from folio_items;
delete from payments;
delete from bookings;
delete from guests g where not exists (select 1 from customers c where c.guest_id = g.id);
delete from journal_lines;
delete from journal_entries;
delete from period_locks;
delete from audit_log;

alter table journal_lines enable trigger user;
alter table journal_entries enable trigger user;
alter table folio_items enable trigger user;
alter table payments enable trigger user;
alter table audit_log enable trigger user;
alter table bookings enable trigger user;
alter table payment_claims enable trigger user;
alter table refunds enable trigger user;
alter table support_messages enable trigger user;
alter table ota_receivables enable trigger user;
alter table period_locks enable trigger user;

update rooms set hk_status = 'clean' where hk_status <> 'ooo';
select log_action('system.launch_reset', null, jsonb_build_object('note', 'test bookings, payments, ledger and logs cleared before opening'));
