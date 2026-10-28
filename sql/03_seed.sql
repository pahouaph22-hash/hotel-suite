-- Saynam Hotel Suite — starting data (generated from src/catalog.js). Safe to edit after loading.

insert into settings (id, hotel_name, tagline, about, address, phone, email, map_url, check_in_time, check_out_time, vat_rate, prices_incl_vat, deposit_pct, direct_discount, free_cancel_days, payment_note, close_amounts, business_date)
values (1, 'Saynam Riverside Hotel', '{"lo":"ພັກຜ່ອນລຽບແມ່ນ້ຳຂອງ ໃຈກາງນະຄອນຫຼວງວຽງຈັນ","th":"พักผ่อนริมแม่น้ำโขง ใจกลางนครหลวงเวียงจันทน์","en":"A quiet stay on the Mekong, in the heart of Vientiane"}'::jsonb, '{"lo":"ໂຮງແຮມ 24 ຫ້ອງ ຫ່າງຈາກຖະໜົນລຽບແມ່ນ້ຳ ແລະ ຕະຫຼາດກາງຄືນພຽງ 5 ນາທີຍ່າງ. ທຸກຫ້ອງມີແອ, Wi-Fi ໄວ ແລະ ນ້ຳອຸ່ນ. ອາຫານເຊົ້າລາວ-ສາກົນ ທຸກເຊົ້າທີ່ຮ້ານອາຫານລຽບນ້ຳ.","th":"โรงแรม 24 ห้อง เดินเพียง 5 นาทีถึงถนนเลียบแม่น้ำและตลาดกลางคืน ทุกห้องมีแอร์ Wi-Fi ความเร็วสูง และน้ำอุ่น อาหารเช้าลาว-นานาชาติทุกเช้าที่ร้านอาหารริมน้ำ","en":"Twenty-four rooms, a five-minute walk from the riverside promenade and night market. Every room has air-conditioning, fast Wi-Fi and hot water. Lao and international breakfast is served each morning at our riverside restaurant."}'::jsonb, 'Ban Xieng Yeun, Chanthabouly District, Vientiane Capital, Lao PDR', '+856 21 000 000', 'stay@saynam-hotel.example', 'https://maps.google.com/?q=Chanthabouly+Vientiane', '14:00', '12:00', 10, true, 30, 5, 3, '{"lo":"ສະແກນ QR ດ້ວຍແອັບທະນາຄານ (BCEL OnePay ຫຼື LAO QR) ແລ້ວແຈ້ງເລກອ້າງອີງການໂອນ. ພະນັກງານຈະກວດ ແລະ ຢືນຢັນພາຍໃນ 2 ຊົ່ວໂມງ (08:00–22:00).","th":"สแกน QR ด้วยแอปธนาคาร (BCEL OnePay หรือ LAO QR) แล้วแจ้งเลขอ้างอิงการโอน พนักงานจะตรวจสอบและยืนยันภายใน 2 ชั่วโมง (08:00–22:00)","en":"Scan the QR with your banking app (BCEL OnePay or LAO QR), then send us the transfer reference. Our team checks it and confirms within 2 hours (08:00–22:00)."}'::jsonb, '{"depr":47083333,"sal":52000000,"int":13333333}'::jsonb, current_date)
on conflict (id) do nothing;

insert into accounts (code, type, name) values
('1110', 'ca', '{"lo":"ເງິນສົດໃນມື","th":"เงินสดในมือ","en":"Cash on hand"}'::jsonb),
('1120', 'ca', '{"lo":"ເງິນຝາກທະນາຄານ","th":"เงินฝากธนาคาร","en":"Cash at bank"}'::jsonb),
('1130', 'ca', '{"lo":"ລູກໜີ້ແຂກພັກ (Guest ledger)","th":"ลูกหนี้แขกพัก (Guest ledger)","en":"Guest ledger receivable"}'::jsonb),
('1140', 'ca', '{"lo":"ລູກໜີ້ OTA","th":"ลูกหนี้ OTA","en":"OTA receivables"}'::jsonb),
('1150', 'ca', '{"lo":"ອາກອນມູນຄ່າເພີ່ມ ຂາເຂົ້າ","th":"ภาษีซื้อ","en":"Input VAT"}'::jsonb),
('1210', 'nca', '{"lo":"ອາຄານ","th":"อาคาร","en":"Building"}'::jsonb),
('1220', 'nca', '{"lo":"ເຟີນິເຈີ ແລະ ອຸປະກອນ","th":"เฟอร์นิเจอร์และอุปกรณ์","en":"Furniture & equipment"}'::jsonb),
('1290', 'nca', '{"lo":"ຄ່າຫຼຸ້ຍຫ້ຽນສະສົມ","th":"ค่าเสื่อมราคาสะสม","en":"Accumulated depreciation"}'::jsonb),
('2110', 'cl', '{"lo":"ເຈົ້າໜີ້ການຄ້າ","th":"เจ้าหนี้การค้า","en":"Trade payables"}'::jsonb),
('2120', 'cl', '{"lo":"ຄ່ານາຍໜ້າ OTA ຄ້າງຈ່າຍ","th":"ค่าคอมมิชชั่น OTA ค้างจ่าย","en":"OTA commission payable"}'::jsonb),
('2140', 'cl', '{"lo":"ອາກອນມູນຄ່າເພີ່ມ ຂາອອກ","th":"ภาษีขาย","en":"Output VAT payable"}'::jsonb),
('2150', 'cl', '{"lo":"ເງິນມັດຈຳລູກຄ້າ (ໜີ້ສິນຕາມສັນຍາ)","th":"เงินมัดจำลูกค้า (หนี้สินตามสัญญา)","en":"Customer deposits (contract liability)"}'::jsonb),
('2160', 'cl', '{"lo":"ຄ່າໃຊ້ຈ່າຍຄ້າງຈ່າຍ","th":"ค่าใช้จ่ายค้างจ่าย","en":"Accrued expenses"}'::jsonb),
('2310', 'ncl', '{"lo":"ເງິນກູ້ທະນາຄານ","th":"เงินกู้ธนาคาร","en":"Bank loan"}'::jsonb),
('3100', 'eq', '{"lo":"ທຶນຂອງເຈົ້າຂອງ","th":"ทุนของเจ้าของ","en":"Owner''s capital"}'::jsonb),
('3200', 'eq', '{"lo":"ກຳໄລສະສົມ","th":"กำไรสะสม","en":"Retained earnings"}'::jsonb),
('4100', 'rev', '{"lo":"ລາຍຮັບຄ່າຫ້ອງພັກ","th":"รายได้ค่าห้องพัก","en":"Room revenue"}'::jsonb),
('4200', 'rev', '{"lo":"ລາຍຮັບອາຫານ ແລະ ເຄື່ອງດື່ມ","th":"รายได้อาหารและเครื่องดื่ม","en":"F&B revenue"}'::jsonb),
('4300', 'rev', '{"lo":"ລາຍຮັບອື່ນ","th":"รายได้อื่น","en":"Other operating revenue"}'::jsonb),
('5100', 'cos', '{"lo":"ຕົ້ນທຶນອາຫານ ແລະ ເຄື່ອງດື່ມ","th":"ต้นทุนอาหารและเครื่องดื่ม","en":"Cost of F&B"}'::jsonb),
('5200', 'opx', '{"lo":"ເງິນເດືອນ ແລະ ສະຫວັດດີການ","th":"เงินเดือนและสวัสดิการ","en":"Salaries & benefits"}'::jsonb),
('5300', 'opx', '{"lo":"ຄ່ານາຍໜ້າຊ່ອງທາງຂາຍ","th":"ค่าคอมมิชชั่นช่องทางขาย","en":"Distribution commissions"}'::jsonb),
('5400', 'opx', '{"lo":"ຄ່ານ້ຳ ຄ່າໄຟ","th":"ค่าน้ำค่าไฟ","en":"Utilities"}'::jsonb),
('5500', 'opx', '{"lo":"ເຄື່ອງໃຊ້ໃນຫ້ອງພັກ","th":"ของใช้ในห้องพัก","en":"Guest supplies"}'::jsonb),
('5600', 'opx', '{"lo":"ການຕະຫຼາດ ແລະ ໂຄສະນາ","th":"การตลาดและโฆษณา","en":"Marketing"}'::jsonb),
('5700', 'opx', '{"lo":"ສ້ອມແປງ ແລະ ບຳລຸງຮັກສາ","th":"ซ่อมแซมและบำรุงรักษา","en":"Repairs & maintenance"}'::jsonb),
('5800', 'opx', '{"lo":"ຄ່າຫຼຸ້ຍຫ້ຽນ","th":"ค่าเสื่อมราคา","en":"Depreciation"}'::jsonb),
('5900', 'fin', '{"lo":"ດອກເບ້ຍເງິນກູ້","th":"ดอกเบี้ยเงินกู้","en":"Interest expense"}'::jsonb)
on conflict do nothing;

insert into channels (id, commission, mode, name) values
('DIR', 0, 'hotel', '{"lo":"ເວັບໄຊໂຮງແຮມ","th":"เว็บไซต์โรงแรม","en":"Hotel website"}'::jsonb),
('FB', 0, 'hotel', '{"lo":"Facebook / WhatsApp","th":"Facebook / WhatsApp","en":"Facebook / WhatsApp"}'::jsonb),
('WALK', 0, 'hotel', '{"lo":"ຍ່າງເຂົ້າມາເອງ","th":"วอล์คอิน","en":"Walk-in"}'::jsonb),
('BKG', 0.15, 'hotel', '{"lo":"Booking.com","th":"Booking.com","en":"Booking.com"}'::jsonb),
('AGD', 0.17, 'ota', '{"lo":"Agoda","th":"Agoda","en":"Agoda"}'::jsonb),
('EXP', 0.18, 'ota', '{"lo":"Expedia","th":"Expedia","en":"Expedia"}'::jsonb),
('TA', 0.1, 'hotel', '{"lo":"ບໍລິສັດທ່ອງທ່ຽວ","th":"บริษัททัวร์","en":"Travel agent"}'::jsonb)
on conflict do nothing;

insert into amenities (id, icon, name, sort) values
('wifi', 'wifi', '{"lo":"Wi-Fi ໄວທົ່ວໂຮງແຮມ","th":"Wi-Fi ความเร็วสูงทั่วโรงแรม","en":"Fast Wi-Fi everywhere"}'::jsonb, 0),
('breakfast', 'cup', '{"lo":"ອາຫານເຊົ້າ","th":"อาหารเช้า","en":"Breakfast included"}'::jsonb, 1),
('river', 'wave', '{"lo":"ຮ້ານອາຫານລຽບນ້ຳ","th":"ร้านอาหารริมน้ำ","en":"Riverside restaurant"}'::jsonb, 2),
('aircon', 'snow', '{"lo":"ແອທຸກຫ້ອງ","th":"แอร์ทุกห้อง","en":"Air-conditioning"}'::jsonb, 3),
('airport', 'plane', '{"lo":"ລົດຮັບສົ່ງສະໜາມບິນ","th":"รถรับส่งสนามบิน","en":"Airport transfer"}'::jsonb, 4),
('parking', 'car', '{"lo":"ບ່ອນຈອດລົດຟຣີ","th":"ที่จอดรถฟรี","en":"Free parking"}'::jsonb, 5),
('laundry', 'shirt', '{"lo":"ບໍລິການຊັກລີດ","th":"บริการซักรีด","en":"Laundry service"}'::jsonb, 6),
('desk', 'clock', '{"lo":"ເຄົາເຕີ 24 ຊົ່ວໂມງ","th":"แผนกต้อนรับ 24 ชั่วโมง","en":"24-hour front desk"}'::jsonb, 7),
('tours', 'map', '{"lo":"ຈອງທົວ ແລະ ເຊົ່າລົດຖີບ","th":"จองทัวร์และเช่าจักรยาน","en":"Tours and bike hire"}'::jsonb, 8),
('tv', 'tv', '{"lo":"ສະມາດທີວີ","th":"สมาร์ททีวี","en":"Smart TV"}'::jsonb, 9),
('bath', 'bath', '{"lo":"ອ່າງອາບນ້ຳ","th":"อ่างอาบน้ำ","en":"Bathtub"}'::jsonb, 10),
('balcony', 'sun', '{"lo":"ລະບຽງວິວແມ່ນ້ຳ","th":"ระเบียงวิวแม่น้ำ","en":"River-view balcony"}'::jsonb, 11),
('kettle', 'kettle', '{"lo":"ກາຕົ້ມນ້ຳ ຊາ ກາເຟ","th":"กาต้มน้ำ ชา กาแฟ","en":"Kettle, tea and coffee"}'::jsonb, 12),
('safe', 'lock', '{"lo":"ຕູ້ເຊບ","th":"ตู้เซฟ","en":"In-room safe"}'::jsonb, 13)
on conflict do nothing;

insert into room_types (id, name, description, capacity, base_rate, size_m2, bed, amenities, sort) values
('STD', '{"lo":"ຫ້ອງມາດຕະຖານ","th":"ห้องสแตนดาร์ด","en":"Standard"}'::jsonb, '{"lo":"ຫ້ອງສະອາດ ງຽບ ເໝາະກັບການເດີນທາງທຸລະກິດ ແລະ ພັກສັ້ນ.","th":"ห้องสะอาด เงียบ เหมาะกับการเดินทางธุรกิจและพักสั้น","en":"A clean, quiet room for business trips and short stays."}'::jsonb, 2, 450000, 22, '{"lo":"ຕຽງຄູ່ ຫຼື ຕຽງແຝດ","th":"เตียงคู่หรือเตียงแฝด","en":"Double or twin beds"}'::jsonb, array['wifi','aircon','tv','kettle','safe']::text[], 0),
('DLX', '{"lo":"ຫ້ອງດີລັກ ວິວແມ່ນ້ຳ","th":"ห้องดีลักซ์ วิวแม่น้ำ","en":"Deluxe river view"}'::jsonb, '{"lo":"ໜ້າຕ່າງກວ້າງເບິ່ງແມ່ນ້ຳຂອງ ແລະ ຕາເວັນຕົກດິນ.","th":"หน้าต่างกว้างมองเห็นแม่น้ำโขงและพระอาทิตย์ตก","en":"Wide windows over the Mekong and its sunsets."}'::jsonb, 2, 650000, 30, '{"lo":"ຕຽງຄິງໄຊ","th":"เตียงคิงไซส์","en":"King bed"}'::jsonb, array['wifi','aircon','tv','kettle','safe','balcony']::text[], 1),
('FAM', '{"lo":"ຫ້ອງຄອບຄົວ","th":"ห้องแฟมิลี่","en":"Family"}'::jsonb, '{"lo":"ກວ້າງພໍສຳລັບ 4 ຄົນ ມີມຸມນັ່ງຫຼິ້ນ ແລະ ຕູ້ເຢັນ.","th":"กว้างพอสำหรับ 4 คน มีมุมนั่งเล่นและตู้เย็น","en":"Room for four, with a sitting corner and fridge."}'::jsonb, 4, 850000, 40, '{"lo":"ຕຽງຄິງ 1 + ຕຽງດ່ຽວ 2","th":"เตียงคิง 1 + เตียงเดี่ยว 2","en":"1 king + 2 single beds"}'::jsonb, array['wifi','aircon','tv','kettle','safe']::text[], 2),
('STE', '{"lo":"ຫ້ອງສະວີດ","th":"ห้องสวีท","en":"Suite"}'::jsonb, '{"lo":"ຫ້ອງນອນ ແລະ ຫ້ອງຮັບແຂກແຍກກັນ, ອ່າງອາບນ້ຳ ແລະ ລະບຽງມຸມເບິ່ງແມ່ນ້ຳ.","th":"ห้องนอนและห้องนั่งเล่นแยกกัน อ่างอาบน้ำ และระเบียงมุมมองแม่น้ำ","en":"Separate bedroom and lounge, a bathtub and a corner river balcony."}'::jsonb, 2, 1250000, 55, '{"lo":"ຕຽງຄິງໄຊ","th":"เตียงคิงไซส์","en":"King bed"}'::jsonb, array['wifi','aircon','tv','kettle','safe','balcony','bath']::text[], 3)
on conflict do nothing;

insert into rooms (no, type_id, floor) values
('101', 'STD', 1), ('102', 'STD', 1), ('103', 'STD', 1), ('104', 'STD', 1), ('105', 'STD', 1), ('106', 'STD', 1), ('107', 'DLX', 1), ('108', 'DLX', 1), ('201', 'DLX', 2), ('202', 'DLX', 2), ('203', 'DLX', 2), ('204', 'DLX', 2), ('205', 'DLX', 2), ('206', 'FAM', 2), ('207', 'FAM', 2), ('208', 'FAM', 2), ('301', 'DLX', 3), ('302', 'DLX', 3), ('303', 'DLX', 3), ('304', 'DLX', 3), ('305', 'FAM', 3), ('306', 'FAM', 3), ('307', 'STE', 3), ('308', 'STE', 3)
on conflict do nothing;

insert into promo_codes (code, pct, valid_to) values
('DIRECT10', 10, null), ('LAOS2026', 8, '2026-12-31'::date)
on conflict do nothing;


-- ---------------------------------------------------------------------
-- Opening balances: replace the amounts with the hotel's real figures on
-- the day it starts using the system, then run this block once.
-- ---------------------------------------------------------------------
-- select post_entry(current_date, '{"k":"open"}', 'OB', 'open', '[
--   {"a":"1110","dr":80000000,"cr":0}, {"a":"1120","dr":450000000,"cr":0},
--   {"a":"1210","dr":6500000000,"cr":0}, {"a":"1220","dr":1200000000,"cr":0},
--   {"a":"1290","dr":0,"cr":900000000}, {"a":"2310","dr":0,"cr":2000000000},
--   {"a":"3100","dr":0,"cr":5330000000}]');

-- ---------------------------------------------------------------------
-- First owner account: create the user in Supabase Auth (Dashboard →
-- Authentication → Add user), then link it here with the real e-mail.
-- The owner adds other staff from the back office afterwards.
-- ---------------------------------------------------------------------
-- insert into staff (user_id, name, role)
-- select id, 'Hotel owner', 'owner' from auth.users where email = 'owner@your-hotel.la';

