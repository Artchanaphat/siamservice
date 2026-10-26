-- ตรอ.สยามเซอร์วิส : ติดตามงานขนส่ง (ต่อภาษี / โอนย้าย ที่ต้องไปยื่นกรมการขนส่ง)
-- รันครั้งเดียว หลัง 03-staff.sql (รันซ้ำได้ ไม่เสียข้อมูล)
-- บิลที่ยังไม่มีแถวในตารางนี้ = "รอยื่นขนส่ง"

create table if not exists public.dlt_jobs (
  bill_id         bigint primary key references public.bills(id) on delete cascade,
  branch_id       bigint not null references public.branches(id),
  status          text not null default 'received'
                  check (status in ('received','submitted','plate','done')),  -- รอยื่น / ยื่นแล้ว / ได้ป้ายแล้ว / ลูกค้ารับแล้ว
  cert_no         text not null default '',   -- เลขใบรับรองการตรวจสภาพ
  receipt_no      text not null default '',   -- เลขใบเสร็จกรมการขนส่ง
  note            text not null default '',
  submitted_at    timestamptz,
  plate_at        timestamptz,
  done_at         timestamptz,
  updated_by_name text not null default '',
  updated_at      timestamptz not null default now()
);
create index if not exists dlt_jobs_branch_status on public.dlt_jobs (branch_id, status);

drop trigger if exists dlt_jobs_touch on public.dlt_jobs;
create trigger dlt_jobs_touch before update on public.dlt_jobs for each row execute function public.touch();

alter table public.dlt_jobs enable row level security;
-- พนักงานทุกตำแหน่งอัปเดตงานขนส่งของสาขาตัวเองได้ (owner ทุกสาขา) ลบได้เฉพาะ owner
drop policy if exists dj_read on public.dlt_jobs;
drop policy if exists dj_ins  on public.dlt_jobs;
drop policy if exists dj_upd  on public.dlt_jobs;
drop policy if exists dj_del  on public.dlt_jobs;
create policy dj_read on public.dlt_jobs for select to authenticated using (can_see_branch(branch_id));
create policy dj_ins  on public.dlt_jobs for insert to authenticated
  with check (can_see_branch(branch_id)
              and exists (select 1 from public.bills b where b.id = bill_id and b.branch_id = dlt_jobs.branch_id));
create policy dj_upd  on public.dlt_jobs for update to authenticated
  using (can_see_branch(branch_id))
  with check (can_see_branch(branch_id)
              and exists (select 1 from public.bills b where b.id = bill_id and b.branch_id = dlt_jobs.branch_id));
create policy dj_del  on public.dlt_jobs for delete to authenticated using (my_role() = 'owner');

grant select, insert, update, delete on public.dlt_jobs to authenticated;
