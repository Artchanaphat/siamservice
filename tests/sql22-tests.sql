\pset format unaligned
\pset tuples_only on
-- setup (as postgres)
insert into auth.users(id,email) values ('00000000-0000-0000-0000-00000000000a','o@x'),('00000000-0000-0000-0000-00000000000b','h@x'),('00000000-0000-0000-0000-00000000000c','s@x'),('00000000-0000-0000-0000-00000000000d','s2@x'),('00000000-0000-0000-0000-00000000000e','h2@x') on conflict do nothing;
insert into staff(user_id,username,full_name,role,branch_id) values
 ('00000000-0000-0000-0000-00000000000a','o','เจ้าของ','owner',null),
 ('00000000-0000-0000-0000-00000000000b','h','หัวหน้าA','head',1),
 ('00000000-0000-0000-0000-00000000000c','s','พนักงานA','staff',1),
 ('00000000-0000-0000-0000-00000000000d','s2','พนักงานB','staff',2),
 ('00000000-0000-0000-0000-00000000000e','h2','หัวหน้าB','head',2) on conflict do nothing;
insert into app_settings(key,value) values('main','{}') on conflict do nothing;
create or replace function t_fail(q text, pat text) returns text language plpgsql as $$ begin execute q; return 'FAIL(no error) '||left(q,60); exception when others then if sqlerrm ~ pat then return 'PASS'; else return 'FAIL('||sqlerrm||')'; end if; end $$;
create or replace function t_ok(q text) returns text language plpgsql as $$ begin execute q; return 'PASS'; exception when others then return 'FAIL('||sqlerrm||')'; end $$;
grant execute on function t_fail(text,text), t_ok(text) to authenticated;
create or replace function t_bill(br int, tot numeric, pays jsonb) returns jsonb language sql as $$
 select create_bill(jsonb_build_object('client_key',gen_random_uuid(),'branch_id',br,'cust',jsonb_build_object('first_name','ทดสอบ'),
   'veh',jsonb_build_object('plate','กข '||floor(random()*1e6)::text,'province','นราธิวาส'),'bill',jsonb_build_object('total',tot,'items','[["ค่าภาษีรถ",'||tot||']]'),'pays',pays)) $$;
grant execute on function t_bill(int,numeric,jsonb) to authenticated;

\echo == staff A (branch 1)
set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000c';
select '2a direct insert bill', t_fail($$insert into bills(branch_id,customer_id,vehicle_id,total) values(1,1,1,100)$$,'permission');
select '2b direct insert payment', t_fail($$insert into payments(bill_id,branch_id,amount,method) select id,1,1,'เงินสด' from bills limit 1$$,'permission');
select '2c direct insert bill_edits', t_fail($$insert into bill_edits(bill_id,what) select id,'x' from bills limit 1$$,'permission');
select '2d call _insert_pays', t_fail($$select _insert_pays(1,1,'[{"amount":1}]',null)$$,'permission');
select '2e staff create_bill own branch', t_ok($$select t_bill(1,500,'[{"amount":200,"method":"เงินสด"},{"amount":100,"method":"โอน","wait":false}]')$$);
select '2f staff create_bill other branch', t_fail($$select t_bill(2,500,'[]')$$,'ไม่มีสิทธิ์');
select '3 transfer forced pending', (select case when not verified then 'PASS' else 'FAIL' end from payments where method='โอน' order by id desc limit 1);
select '6a client bill_no ignored', (select case when bill_no ~ '^A-[0-9]{6}$' then 'PASS' else 'FAIL '||bill_no end from bills order by id desc limit 1);
select '2g staff update bill', t_fail($$update bills set total=1$$,'permission');
select '5a staff edit_bill', t_fail($$select edit_bill(jsonb_build_object('bill_id',(select max(id) from bills)))$$,'ไม่มีสิทธิ์');
select '7 sms other branch', t_fail($$select sms_send('[{"to":"0812345678","message":"x","branch_id":2}]')$$,'สาขา|Sender');
\echo == double submit same key
select '2h dup key returns same', (with k as (select gen_random_uuid() u), a as (select create_bill(jsonb_build_object('client_key',(select u from k),'branch_id',1,'cust','{"first_name":"ก"}'::jsonb,'veh','{"plate":"ซ้ำ1","province":"นราธิวาส"}'::jsonb,'bill','{"total":100}'::jsonb,'pays','[{"amount":100}]'::jsonb)) r), b as (select create_bill(jsonb_build_object('client_key',(select u from k),'branch_id',1,'cust','{"first_name":"ก"}'::jsonb,'veh','{"plate":"ซ้ำ1","province":"นราธิวาส"}'::jsonb,'bill','{"total":100}'::jsonb,'pays','[{"amount":100}]'::jsonb)) r from a)
  select case when (select r->>'id' from a)=(select r->>'id' from b) and (select r->>'dup' from b)='true' then 'PASS' else 'FAIL' end);
select '2i overpay blocked', t_fail($$select add_payments((select max(id) from bills where total=100),'[{"amount":1}]',gen_random_uuid())$$,'เกินยอด');
\echo == close (staff)
set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000a';
select '8pre owner verifies pending', t_ok($$select verify_payment(id) from payments where not verified and kind='pay'$$);
set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000c';
select '8a staff first close', t_ok($$insert into cash_closes(branch_id,close_date,staff_name,cash,transfer,card,other,closed_by_name) values(1,(now() at time zone 'Asia/Bangkok')::date,'พนักงานA',99999,0,0,0,'ปลอม')$$);
reset role;
select '8b amounts computed', (select case when cash=300 and transfer=100 and closed_by_name='พนักงานA' then 'PASS' else 'FAIL cash='||cash||' tr='||transfer||' by='||closed_by_name end from cash_closes where staff_name='พนักงานA');
set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000c';
select '8c staff re-close blocked', t_fail($$insert into cash_closes(branch_id,close_date,staff_name) values(1,(now() at time zone 'Asia/Bangkok')::date,'ไม่ระบุ') on conflict (branch_id,close_date,staff_name) do update set counted_cash=1$$,'ปิดยอดไปแล้ว');
select '8d staff update blocked', t_fail($$update cash_closes set counted_cash=5 where branch_id=1 returning 1$$,'ปิดยอดไปแล้ว|no error');
\echo == staff B
set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000d';
select '2j staff B sees no A bills', (select case when count(*)=0 then 'PASS' else 'FAIL' end from bills where branch_id=1);
select '8e staff B close branch A', t_fail($$insert into cash_closes(branch_id,close_date,staff_name) values(1,current_date,'x')$$,'สิทธิ์|row-level');
\echo == head A
set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000b';
select '8f head edits close', t_ok($$update cash_closes set counted_cash=300 where branch_id=1$$);
select '5b head edit_bill ok', t_ok($$select edit_bill(jsonb_build_object('bill_id',b.id,'what','แก้ไขข้อมูล: ชื่อ','snapshot','{"name":"ใหม่"}'::jsonb,'note','n','cust_id',b.customer_id,'cust','{"first_name":"ใหม่","tel":"0811111111","id":999}'::jsonb,'veh_id',b.vehicle_id,'veh','{"color":"แดง","customer_id":1}'::jsonb)) from bills b where branch_id=1 order by id desc limit 1$$);
reset role;
select '5c edit applied+audit', (select case when b.snapshot->>'name'='ใหม่' and c.first_name='ใหม่' and v.color='แดง' and e.by_name='หัวหน้าA' and c.id<>999 then 'PASS' else 'FAIL' end from bills b join customers c on c.id=b.customer_id join vehicles v on v.id=b.vehicle_id join lateral (select by_name from bill_edits where bill_id=b.id order by id desc limit 1) e on true where b.branch_id=1 order by b.id desc limit 1);
-- failed edit midway: plate duplicates another car -> whole edit rolls back
insert into vehicles(customer_id,plate,province) select customer_id,'ชน1','นราธิวาส' from vehicles limit 1;
set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000b';
select '5d edit fails midway', t_fail($$select edit_bill(jsonb_build_object('bill_id',b.id,'what','x','snapshot','{"name":"ไม่ควรเห็น"}'::jsonb,'veh_id',b.vehicle_id,'veh','{"plate":"ชน1","province":"นราธิวาส"}'::jsonb)) from bills b where branch_id=1 order by id desc limit 1$$,'duplicate|unique');
reset role;
select '5e nothing saved', (select case when snapshot->>'name'='ใหม่' then 'PASS' else 'FAIL '||(snapshot->>'name') end from bills where branch_id=1 order by id desc limit 1);
select '2k head direct update blocked', (select 'see next');
set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000b';
select '2k head direct update total', t_fail($$update bills set total=1 where branch_id=1$$,'permission');
\echo == refund with pending transfer
set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000c';
select '4pre staff bill cash 100', t_ok($$select t_bill(1,300,'[{"amount":100,"method":"เงินสด"}]')$$);
set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000b';
select '4a head requests refund 50', t_ok($$select request_bill_action((select max(id) from bills),'refund',50,'เงินสด','ทดสอบ')$$);
set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000c';
select '4a2 staff adds transfer during approval', t_ok($$select add_payments((select max(id) from bills),'[{"amount":100,"method":"โอน"}]',gen_random_uuid())$$);
set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000a';
select '4b approve blocked by pending', t_fail($$select decide_bill_action((select max(id) from bill_requests),true,'')$$,'รอตรวจ');
select '4c verify transfer', t_ok($$select verify_payment((select id from payments where not verified and kind='pay' order by id desc limit 1))$$);
select '4d approve after verify', t_ok($$select decide_bill_action((select max(id) from bill_requests),true,'')$$);
select '4e void request', t_ok($$select request_bill_action((select max(id) from bills),'void',0,'เงินสด','ยกเลิก')$$);
select '4f void refunds verified net 150', (select case when (decide_bill_action((select max(id) from bill_requests),true,'')->>'amount')::numeric=150 then 'PASS' else 'FAIL' end);
reset role;
\echo == bill number 9999 -> 10000
update bill_counters set last_no=9998 where branch_id=1;
set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000a';
select t_bill(1,10,'[]')->>'bill_no'; select t_bill(1,10,'[]')->>'bill_no'; select t_bill(1,10,'[]')->>'bill_no';
reset role;
select '6b 10000 not truncated', (select case when count(distinct bill_no)=count(*) and bool_or(bill_no='A-6910000') and bool_or(bill_no='A-6910001') then 'PASS' else 'FAIL' end from bills where branch_id=1);
