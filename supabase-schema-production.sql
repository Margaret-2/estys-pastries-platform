-- Esty's Pastries production schema + payment/cancellation/customer tracking update.
-- Run this entire file in Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.weekly_periods(
  id uuid primary key default gen_random_uuid(),
  week_start date not null unique,
  week_end date not null,
  status text not null default 'closed',
  started_at timestamptz,
  ended_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check(week_end=week_start+4),
  check(status in ('open','closed'))
);

create table if not exists public.products(id uuid primary key default gen_random_uuid(), slug text unique not null, name text not null, price numeric(12,2) not null check(price>=0), stock integer not null default 0 check(stock>=0), is_active boolean not null default true, created_at timestamptz not null default now());
create table if not exists public.customers(id uuid primary key references auth.users(id) on delete cascade, display_name text, customer_code text, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.orders(id uuid primary key default gen_random_uuid(), order_number text unique, customer_id uuid not null references public.customers(id), display_name text, customer_code text, total_amount numeric(12,2) not null, payment_method text not null default 'cash', payment_status text not null default 'pending', supply_status text not null default 'pending', refund_status text not null default 'not_applicable', credit_confirmed boolean not null default false, cancellation_source text, payment_received_at timestamptz, refunded_at timestamptz, supplied_at timestamptz, week_id uuid references public.weekly_periods(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.order_items(id uuid primary key default gen_random_uuid(), order_id uuid not null references public.orders(id) on delete cascade, product_id uuid not null references public.products(id), quantity integer not null check(quantity>0), unit_price numeric(12,2) not null);
create table if not exists public.inventory_transactions(id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id), delta integer not null, reason text, order_id uuid references public.orders(id), created_by uuid references auth.users(id), created_at timestamptz not null default now());
create table if not exists public.payment_settings(id boolean primary key default true, bank text not null default 'Opay', account_name text not null default 'Chisom Jennifer Onuoha', account_number text not null default '8131238561', updated_at timestamptz not null default now());
create table if not exists public.admins(id uuid primary key default gen_random_uuid(), user_id uuid unique not null references auth.users(id) on delete cascade, role text not null default 'admin', created_at timestamptz not null default now());


-- Upgrade existing production orders table without destroying existing data.
alter table public.orders add column if not exists refund_status text default 'not_applicable';
alter table public.orders add column if not exists credit_confirmed boolean default false;
alter table public.orders add column if not exists cancellation_source text;
alter table public.orders add column if not exists payment_received_at timestamptz;
alter table public.orders add column if not exists refunded_at timestamptz;
alter table public.orders add column if not exists supplied_at timestamptz;
alter table public.orders add column if not exists week_id uuid references public.weekly_periods(id);
alter table public.inventory_transactions add column if not exists week_id uuid references public.weekly_periods(id);
update public.orders set refund_status='not_applicable' where refund_status is null;
update public.orders set credit_confirmed=false where credit_confirmed is null;
update public.orders set refund_status='pending' where supply_status='cancelled' and payment_status='paid' and refund_status='not_applicable';
alter table public.orders alter column order_number set not null;
alter table public.orders alter column order_number drop default;

-- Replace restrictive old payment/supply checks with the new states.
do $$ declare r record; begin
  for r in select conname from pg_constraint where conrelid='public.orders'::regclass and contype='c' and (pg_get_constraintdef(oid) ilike '%payment_method%' or pg_get_constraintdef(oid) ilike '%payment_status%' or pg_get_constraintdef(oid) ilike '%supply_status%' or pg_get_constraintdef(oid) ilike '%refund_status%') loop
    execute format('alter table public.orders drop constraint if exists %I', r.conname);
  end loop;
end $$;
alter table public.orders add constraint orders_payment_method_check check(payment_method in ('cash','transfer','credit'));
alter table public.orders add constraint orders_payment_status_check check(payment_status in ('pending','payment_claimed','unpaid','paid'));
alter table public.orders add constraint orders_supply_status_check check(supply_status in ('pending','supplied','cancelled'));
alter table public.orders add constraint orders_refund_status_check check(refund_status in ('not_applicable','pending','refunded'));

create sequence if not exists public.estys_order_number_seq;
select setval('public.estys_order_number_seq', coalesce((select max((substring(order_number from '^EP([0-9]+)$'))::bigint) from public.orders where order_number ~ '^EP[0-9]+$'),1), exists(select 1 from public.orders where order_number ~ '^EP[0-9]+$'));
alter table public.orders alter column order_number set default ('EP'||nextval('public.estys_order_number_seq'));
update public.orders set order_number='EP'||nextval('public.estys_order_number_seq') where order_number is null;

insert into public.products(slug,name,price,stock) values ('small','Small Chinchin',500,12),('big','Big Chinchin',1000,8) on conflict(slug) do update set name=excluded.name,price=excluded.price;
insert into public.payment_settings(id) values(true) on conflict(id) do nothing;

alter table public.products enable row level security; alter table public.customers enable row level security; alter table public.orders enable row level security; alter table public.order_items enable row level security; alter table public.inventory_transactions enable row level security; alter table public.payment_settings enable row level security; alter table public.admins enable row level security;

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from public.admins where user_id=auth.uid()); $$;

alter table public.weekly_periods enable row level security;
drop policy if exists admin_weekly_periods on public.weekly_periods;
create policy admin_weekly_periods on public.weekly_periods for all to authenticated using(public.is_admin()) with check(public.is_admin());
create unique index if not exists weekly_periods_one_open_idx on public.weekly_periods(status) where status='open';

create or replace function public.lagos_week_start() returns date language sql stable as $$
  select ((now() at time zone 'Africa/Lagos')::date - (extract(isodow from (now() at time zone 'Africa/Lagos')::date)::int - 1));
$$;

create or replace function public.current_weekly_period() returns public.weekly_periods language sql stable security definer set search_path=public as $$
  select * from public.weekly_periods where week_start=public.lagos_week_start() and status='open' limit 1;
$$;

create or replace function public.start_new_week(p_week_start date default public.lagos_week_start(), p_small_stock int default 0, p_big_stock int default 0) returns public.weekly_periods language plpgsql security definer set search_path=public as $$
declare r public.weekly_periods; sm uuid; bg uuid;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  if extract(isodow from p_week_start)<>1 then raise exception 'Week start must be a Monday'; end if;
  if p_week_start<>public.lagos_week_start() then raise exception 'Only the current Monday can be opened'; end if;
  if p_small_stock<0 or p_big_stock<0 then raise exception 'New stock cannot be negative'; end if;
  update public.weekly_periods set status='closed',ended_at=coalesce(ended_at,now()) where status='open';
  insert into public.weekly_periods(week_start,week_end,status,started_at,created_by) values(p_week_start,p_week_start+4,'open',now(),auth.uid())
  on conflict(week_start) do update set status='open',started_at=now(),ended_at=null,created_by=auth.uid() returning * into r;
  if p_small_stock>0 then
    update public.products set stock=stock+p_small_stock where slug='small' returning id into sm;
    if sm is null then raise exception 'Small Chinchin product not found'; end if;
    insert into public.inventory_transactions(product_id,delta,reason,created_by,week_id) values(sm,p_small_stock,'New weekly stock - '||to_char(p_week_start,'DD/MM/YYYY'),auth.uid(),r.id);
  end if;
  if p_big_stock>0 then
    update public.products set stock=stock+p_big_stock where slug='big' returning id into bg;
    if bg is null then raise exception 'Big Chinchin product not found'; end if;
    insert into public.inventory_transactions(product_id,delta,reason,created_by,week_id) values(bg,p_big_stock,'New weekly stock - '||to_char(p_week_start,'DD/MM/YYYY'),auth.uid(),r.id);
  end if;
  return r;
end $$;

create or replace function public.close_current_week() returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  update public.weekly_periods set status='closed',ended_at=coalesce(ended_at,now()) where status='open';
end $$;


drop policy if exists products_public_read on public.products; create policy products_public_read on public.products for select to anon,authenticated using(is_active=true);
drop policy if exists customers_own on public.customers; create policy customers_own on public.customers for all to authenticated using(id=auth.uid() or public.is_admin()) with check(id=auth.uid() or public.is_admin());
drop policy if exists orders_own_read on public.orders; create policy orders_own_read on public.orders for select to authenticated using(customer_id=auth.uid() or public.is_admin());
drop policy if exists order_items_own_read on public.order_items; create policy order_items_own_read on public.order_items for select to authenticated using(exists(select 1 from public.orders o where o.id=order_id and (o.customer_id=auth.uid() or public.is_admin())));
drop policy if exists admin_products on public.products; create policy admin_products on public.products for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists admin_orders on public.orders; create policy admin_orders on public.orders for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists admin_inventory_read on public.inventory_transactions; create policy admin_inventory_read on public.inventory_transactions for select to authenticated using(public.is_admin());
drop policy if exists payment_public_read on public.payment_settings; create policy payment_public_read on public.payment_settings for select to anon,authenticated using(true);
drop policy if exists payment_admin_update on public.payment_settings; create policy payment_admin_update on public.payment_settings for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists admin_admins on public.admins; create policy admin_admins on public.admins for select to authenticated using(user_id=auth.uid() or public.is_admin());

create or replace function public.is_order_window_open() returns boolean language plpgsql stable as $$ declare n int; t time; ws date; begin n:=extract(isodow from (now() at time zone 'Africa/Lagos')); t:=(now() at time zone 'Africa/Lagos')::time; ws:=(now() at time zone 'Africa/Lagos')::date-(n-1); return n between 1 and 5 and t >= time '07:30' and t < time '17:00' and exists(select 1 from public.weekly_periods where week_start=ws and status='open'); end $$;

create or replace function public.place_order(p_display_name text,p_customer_code text,p_items jsonb,p_payment_method text,p_payment_claimed boolean default false) returns setof public.orders language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); sid uuid; wid uuid; bid uuid; sq int:=coalesce((p_items->>'small')::int,0); bq int:=coalesce((p_items->>'big')::int,0); total numeric:=0; oid uuid; r public.orders; sp numeric; bp numeric; initial_status text;
begin
  if uid is null then raise exception 'Customer session required'; end if;
  if trim(coalesce(p_display_name,''))='' then raise exception 'Order name is required'; end if;
  if not public.is_order_window_open() then raise exception 'Orders are closed. Ordering is Monday to Friday, 7:30 AM to 5:00 PM, after the admin starts the current week.'; end if;
  select id into wid from public.weekly_periods where week_start=public.lagos_week_start() and status='open' limit 1;
  if p_payment_method not in ('cash','transfer','credit') then raise exception 'Invalid payment method'; end if;
  if sq<0 or bq<0 or sq+bq=0 then raise exception 'Choose at least one product'; end if;
  if sq>50 or bq>50 then raise exception 'Maximum 50 packs per product per order'; end if;
  insert into customers(id,display_name,customer_code,updated_at) values(uid,nullif(trim(p_display_name),''),nullif(trim(p_customer_code),''),now()) on conflict(id) do update set display_name=coalesce(nullif(trim(excluded.display_name),''),customers.display_name),customer_code=coalesce(nullif(trim(excluded.customer_code),''),customers.customer_code),updated_at=now();
  select id,price into sid,sp from products where slug='small' and is_active for update;
  if sq>0 and (sid is null or sp is null) then raise exception 'Small Chinchin is unavailable'; end if;
  if sq>0 and (select stock from products where id=sid)<sq then raise exception 'Insufficient small stock'; end if;
  select id,price into bid,bp from products where slug='big' and is_active for update;
  if bq>0 and (bid is null or bp is null) then raise exception 'Big Chinchin is unavailable'; end if;
  if bq>0 and (select stock from products where id=bid)<bq then raise exception 'Insufficient big stock'; end if;
  total:=coalesce(sp,0)*sq+coalesce(bp,0)*bq;
  initial_status:=case when p_payment_method='credit' then 'unpaid' when p_payment_claimed then 'payment_claimed' else 'pending' end;
  insert into orders(customer_id,display_name,customer_code,total_amount,payment_method,payment_status,credit_confirmed,week_id) values(uid,nullif(trim(p_display_name),''),nullif(trim(p_customer_code),''),total,p_payment_method,initial_status,false,wid) returning * into r;
  oid:=r.id;
  if sq>0 then update products set stock=stock-sq where id=sid; insert into order_items(order_id,product_id,quantity,unit_price) values(oid,sid,sq,sp); insert into inventory_transactions(product_id,delta,reason,order_id,created_by,week_id) values(sid,-sq,'Customer order',oid,uid,wid); end if;
  if bq>0 then update products set stock=stock-bq where id=bid; insert into order_items(order_id,product_id,quantity,unit_price) values(oid,bid,bq,bp); insert into inventory_transactions(product_id,delta,reason,order_id,created_by,week_id) values(bid,-bq,'Customer order',oid,uid,wid); end if;
  return next r;
end $$;

create or replace function public.adjust_stock(p_slug text,p_delta int,p_reason text) returns void language plpgsql security definer set search_path=public as $$ declare pid uuid; newstock int; wid uuid; begin if not public.is_admin() then raise exception 'Admin access required'; end if; select id into wid from public.weekly_periods where week_start=public.lagos_week_start() and status='open' limit 1; select id,stock into pid,newstock from products where slug=p_slug for update; if pid is null then raise exception 'Product not found'; end if; newstock:=newstock+p_delta; if newstock<0 then raise exception 'Stock cannot go below zero'; end if; update products set stock=newstock where id=pid; insert into inventory_transactions(product_id,delta,reason,created_by,week_id) values(pid,p_delta,coalesce(p_reason,'Manual adjustment'),auth.uid(),wid); end $$;

create or replace function public.confirm_payment(p_order_number text) returns void language plpgsql security definer set search_path=public as $$ begin if not public.is_admin() then raise exception 'Admin access required'; end if; update orders set payment_status='paid',payment_received_at=coalesce(payment_received_at,now()),updated_at=now() where order_number=p_order_number and supply_status<>'cancelled' and refund_status<>'refunded'; end $$;
create or replace function public.confirm_credit_purchase(p_order_number text) returns void language plpgsql security definer set search_path=public as $$ begin if not public.is_admin() then raise exception 'Admin access required'; end if; update orders set payment_method='credit',payment_status='unpaid',credit_confirmed=true,updated_at=now() where order_number=p_order_number and supply_status<>'cancelled'; end $$;
create or replace function public.mark_supplied(p_order_number text) returns void language plpgsql security definer set search_path=public as $$ begin if not public.is_admin() then raise exception 'Admin access required'; end if; update orders set supply_status='supplied',supplied_at=coalesce(supplied_at,now()),updated_at=now() where order_number=p_order_number and supply_status='pending'; end $$;

create or replace function public.cancel_order(p_order_number text,p_reason text default 'Cancelled by admin') returns void language plpgsql security definer set search_path=public as $$
declare o record; i record;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  select * into o from orders where order_number=p_order_number for update;
  if o.id is null then raise exception 'Order not found'; end if;
  if o.supply_status='supplied' then raise exception 'Supplied orders cannot be cancelled because the stock has already left inventory'; end if;
  if o.supply_status='cancelled' then return; end if;
  for i in select * from order_items where order_id=o.id loop
    update products set stock=stock+i.quantity where id=i.product_id;
    insert into inventory_transactions(product_id,delta,reason,order_id,created_by,week_id) values(i.product_id,i.quantity,coalesce(p_reason,'Order cancelled'),o.id,auth.uid(),o.week_id);
  end loop;
  update orders set supply_status='cancelled',cancellation_source='admin',refund_status=case when payment_status='paid' then 'pending' else 'not_applicable' end,updated_at=now() where id=o.id;
end $$;

create or replace function public.customer_cancel_order(p_order_number text) returns void language plpgsql security definer set search_path=public as $$
declare o record; i record;
begin
  if auth.uid() is null then raise exception 'Customer session required'; end if;
  select * into o from orders where order_number=p_order_number and customer_id=auth.uid() for update;
  if o.id is null then raise exception 'Order not found'; end if;
  if o.supply_status='supplied' then raise exception 'This order has already been supplied and can no longer be cancelled'; end if;
  if o.supply_status='cancelled' then return; end if;
  for i in select * from order_items where order_id=o.id loop
    update products set stock=stock+i.quantity where id=i.product_id;
    insert into inventory_transactions(product_id,delta,reason,order_id,created_by,week_id) values(i.product_id,i.quantity,'Cancelled by customer',o.id,auth.uid(),o.week_id);
  end loop;
  update orders set supply_status='cancelled',cancellation_source='customer',refund_status=case when payment_status='paid' then 'pending' else 'not_applicable' end,updated_at=now() where id=o.id;
end $$;

create or replace function public.mark_refunded(p_order_number text) returns void language plpgsql security definer set search_path=public as $$ begin if not public.is_admin() then raise exception 'Admin access required'; end if; update orders set refund_status='refunded',refunded_at=now(),updated_at=now() where order_number=p_order_number and supply_status='cancelled' and payment_status='paid' and refund_status='pending'; end $$;
create or replace function public.set_payment_details(p_bank text,p_account_name text,p_account_number text) returns void language plpgsql security definer set search_path=public as $$ begin if not public.is_admin() then raise exception 'Admin access required'; end if; update payment_settings set bank=p_bank,account_name=p_account_name,account_number=p_account_number,updated_at=now() where id=true; end $$;

-- Existing views may have a different column order in the production database.
-- Drop and recreate ONLY these views; this does not delete orders, customers, stock, or tables.
drop view if exists public.admin_order_summary;
drop view if exists public.customer_order_summary;
drop view if exists public.customer_loyalty_summary;

create or replace view public.admin_order_summary as select o.id,o.order_number,o.display_name,o.customer_code,o.customer_id,o.total_amount,o.payment_method,o.payment_status,o.supply_status,o.refund_status,o.credit_confirmed,o.cancellation_source,o.created_at,o.payment_received_at,o.refunded_at,o.supplied_at,o.week_id,coalesce(string_agg(p.name||' × '||oi.quantity,', '),'') items_text from orders o left join order_items oi on oi.order_id=o.id left join products p on p.id=oi.product_id where public.is_admin() group by o.id;
revoke all on public.admin_order_summary from anon; grant select on public.admin_order_summary to authenticated;

create or replace view public.customer_order_summary with (security_invoker=true) as select o.id,o.order_number,o.customer_id,o.display_name,o.total_amount,o.payment_method,o.payment_status,o.supply_status,o.refund_status,o.cancellation_source,o.week_id,o.created_at,coalesce(string_agg(p.name||' × '||oi.quantity,', '),'') items_text from orders o left join order_items oi on oi.order_id=o.id left join products p on p.id=oi.product_id group by o.id;
revoke all on public.customer_order_summary from anon; grant select on public.customer_order_summary to authenticated;

create or replace view public.customer_loyalty_summary with (security_invoker=true) as select c.id,c.display_name,count(o.id) filter(where o.supply_status<>'cancelled')::int as order_count,coalesce(sum(o.total_amount) filter(where o.supply_status<>'cancelled' and o.payment_status='paid' and o.refund_status<>'refunded'),0)::numeric as total_spent,min(o.created_at) filter(where o.supply_status<>'cancelled') as first_order_at,max(o.created_at) filter(where o.supply_status<>'cancelled') as last_order_at from customers c left join orders o on o.customer_id=c.id group by c.id,c.display_name;
revoke all on public.customer_loyalty_summary from anon; grant select on public.customer_loyalty_summary to authenticated;

create index if not exists orders_customer_id_created_at_idx on public.orders(customer_id, created_at desc);
create index if not exists orders_week_id_created_at_idx on public.orders(week_id, created_at desc);
create index if not exists inventory_transactions_week_id_created_at_idx on public.inventory_transactions(week_id, created_at desc);
create index if not exists orders_payment_status_idx on public.orders(payment_status);
create index if not exists orders_supply_status_idx on public.orders(supply_status);
create index if not exists order_items_order_id_idx on public.order_items(order_id);
create index if not exists inventory_transactions_product_id_created_at_idx on public.inventory_transactions(product_id, created_at desc);

revoke execute on function public.place_order(text,text,jsonb,text,boolean) from anon; grant execute on function public.place_order(text,text,jsonb,text,boolean) to authenticated;
revoke execute on function public.adjust_stock(text,int,text) from anon; grant execute on function public.adjust_stock(text,int,text) to authenticated;
revoke execute on function public.confirm_payment(text) from anon; grant execute on function public.confirm_payment(text) to authenticated;
revoke execute on function public.confirm_credit_purchase(text) from anon; grant execute on function public.confirm_credit_purchase(text) to authenticated;
revoke execute on function public.mark_supplied(text) from anon; grant execute on function public.mark_supplied(text) to authenticated;
revoke execute on function public.cancel_order(text,text) from anon; grant execute on function public.cancel_order(text,text) to authenticated;
revoke execute on function public.customer_cancel_order(text) from anon; grant execute on function public.customer_cancel_order(text) to authenticated;
revoke execute on function public.mark_refunded(text) from anon; grant execute on function public.mark_refunded(text) to authenticated;
revoke execute on function public.set_payment_details(text,text,text) from anon; grant execute on function public.set_payment_details(text,text,text) to authenticated;

revoke insert, update, delete on public.orders from anon, authenticated;
revoke insert, update, delete on public.order_items from anon, authenticated;
revoke insert, delete on public.inventory_transactions from anon, authenticated;
revoke insert, delete on public.payment_settings from anon, authenticated;
revoke insert, update, delete on public.admins from anon, authenticated;
grant select on public.products,public.payment_settings to anon, authenticated;
grant select on public.customers,public.orders,public.order_items,public.inventory_transactions,public.admins to authenticated;
grant update on public.products,public.orders,public.payment_settings to authenticated;

revoke all on public.weekly_periods from anon; grant select on public.weekly_periods to authenticated;
revoke execute on function public.start_new_week(date,int,int) from anon; grant execute on function public.start_new_week(date,int,int) to authenticated;
revoke execute on function public.close_current_week() from anon; grant execute on function public.close_current_week() to authenticated;
