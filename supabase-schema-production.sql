-- Esty's Pastries production schema. Run in Supabase SQL Editor.
create extension if not exists pgcrypto;
create table if not exists public.products(id uuid primary key default gen_random_uuid(), slug text unique not null, name text not null, price numeric(12,2) not null check(price>=0), stock integer not null default 0 check(stock>=0), is_active boolean not null default true, created_at timestamptz not null default now());
create table if not exists public.customers(id uuid primary key references auth.users(id) on delete cascade, display_name text, customer_code text, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.orders(id uuid primary key default gen_random_uuid(), order_number text unique not null default ('EP'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8))), customer_id uuid not null references public.customers(id), display_name text, customer_code text, total_amount numeric(12,2) not null, payment_method text not null check(payment_method in ('cash','transfer')), payment_status text not null default 'pending' check(payment_status in ('pending','payment_claimed','paid')), supply_status text not null default 'pending' check(supply_status in ('pending','supplied','cancelled')), created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.order_items(id uuid primary key default gen_random_uuid(), order_id uuid not null references public.orders(id) on delete cascade, product_id uuid not null references public.products(id), quantity integer not null check(quantity>0), unit_price numeric(12,2) not null);
create table if not exists public.inventory_transactions(id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id), delta integer not null, reason text, order_id uuid references public.orders(id), created_by uuid references auth.users(id), created_at timestamptz not null default now());
create table if not exists public.payment_settings(id boolean primary key default true, bank text not null default 'Opay', account_name text not null default 'Chisom Jennifer Onuoha', account_number text not null default '8131238561', updated_at timestamptz not null default now());
create table if not exists public.admins(id uuid primary key default gen_random_uuid(), user_id uuid unique not null references auth.users(id) on delete cascade, role text not null default 'admin', created_at timestamptz not null default now());
insert into public.products(slug,name,price,stock) values ('small','Small Chinchin',500,12),('big','Big Chinchin',1000,8) on conflict(slug) do update set name=excluded.name,price=excluded.price;
insert into public.payment_settings(id) values(true) on conflict(id) do nothing;

alter table public.products enable row level security; alter table public.customers enable row level security; alter table public.orders enable row level security; alter table public.order_items enable row level security; alter table public.inventory_transactions enable row level security; alter table public.payment_settings enable row level security; alter table public.admins enable row level security;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from public.admins where user_id=auth.uid()); $$;
create policy products_public_read on public.products for select to anon,authenticated using(is_active=true);
create policy customers_own on public.customers for all to authenticated using(id=auth.uid() or public.is_admin()) with check(id=auth.uid() or public.is_admin());
create policy orders_own_read on public.orders for select to authenticated using(customer_id=auth.uid() or public.is_admin());
create policy order_items_own_read on public.order_items for select to authenticated using(exists(select 1 from public.orders o where o.id=order_id and (o.customer_id=auth.uid() or public.is_admin())));
create policy admin_products on public.products for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy admin_orders on public.orders for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy admin_inventory_read on public.inventory_transactions for select to authenticated using(public.is_admin());
create policy payment_public_read on public.payment_settings for select to anon,authenticated using(true);
create policy payment_admin_update on public.payment_settings for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy admin_admins on public.admins for select to authenticated using(user_id=auth.uid() or public.is_admin());

create or replace function public.place_order(p_display_name text,p_customer_code text,p_items jsonb,p_payment_method text,p_payment_claimed boolean default false) returns setof public.orders language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); sid uuid; bid uuid; sq int:=coalesce((p_items->>'small')::int,0); bq int:=coalesce((p_items->>'big')::int,0); total numeric:=0; oid uuid; r public.orders;
begin if uid is null then raise exception 'Customer session required'; end if; if sq<0 or bq<0 or sq+bq=0 then raise exception 'Choose at least one product'; end if; insert into customers(id,display_name,customer_code,updated_at) values(uid,nullif(trim(p_display_name),''),nullif(trim(p_customer_code),''),now()) on conflict(id) do update set display_name=excluded.display_name,customer_code=excluded.customer_code,updated_at=now(); select id,price into sid,total from products where slug='small' and is_active for update; if sq>0 then if (select stock from products where id=sid)<sq then raise exception 'Insufficient small stock'; end if; total:=total*sq; end if; select id,price into bid,total from products where slug='big' and is_active for update; if bq>0 then if (select stock from products where id=bid)<bq then raise exception 'Insufficient big stock'; end if; total:=total+(select price from products where id=bid)*bq; end if; total:=case when sq>0 then (select price from products where id=sid)*sq else 0 end + case when bq>0 then (select price from products where id=bid)*bq else 0 end; insert into orders(customer_id,display_name,customer_code,total_amount,payment_method,payment_status) values(uid,nullif(trim(p_display_name),''),nullif(trim(p_customer_code),''),total,p_payment_method,case when p_payment_claimed then 'payment_claimed' else 'pending' end) returning * into r; oid:=r.id; if sq>0 then update products set stock=stock-sq where id=sid; insert into order_items(order_id,product_id,quantity,unit_price) values(oid,sid,sq,(select price from products where id=sid)); insert into inventory_transactions(product_id,delta,reason,order_id,created_by) values(sid,-sq,'Customer order',oid,uid); end if; if bq>0 then update products set stock=stock-bq where id=bid; insert into order_items(order_id,product_id,quantity,unit_price) values(oid,bid,bq,(select price from products where id=bid)); insert into inventory_transactions(product_id,delta,reason,order_id,created_by) values(bid,-bq,'Customer order',oid,uid); end if; return next r; end $$;

create or replace function public.adjust_stock(p_slug text,p_delta int,p_reason text) returns void language plpgsql security definer set search_path=public as $$ declare pid uuid; newstock int; begin if not public.is_admin() then raise exception 'Admin access required'; end if; select id,stock into pid,newstock from products where slug=p_slug for update; if pid is null then raise exception 'Product not found'; end if; newstock:=newstock+p_delta; if newstock<0 then raise exception 'Stock cannot go below zero'; end if; update products set stock=newstock where id=pid; insert into inventory_transactions(product_id,delta,reason,created_by) values(pid,p_delta,coalesce(p_reason,'Manual adjustment'),auth.uid()); end $$;
create or replace function public.confirm_payment(p_order_number text) returns void language plpgsql security definer set search_path=public as $$ begin if not public.is_admin() then raise exception 'Admin access required'; end if; update orders set payment_status='paid',updated_at=now() where order_number=p_order_number; end $$;
create or replace function public.mark_supplied(p_order_number text) returns void language plpgsql security definer set search_path=public as $$ begin if not public.is_admin() then raise exception 'Admin access required'; end if; update orders set supply_status='supplied',updated_at=now() where order_number=p_order_number; end $$;
create or replace function public.set_payment_details(p_bank text,p_account_name text,p_account_number text) returns void language plpgsql security definer set search_path=public as $$ begin if not public.is_admin() then raise exception 'Admin access required'; end if; update payment_settings set bank=p_bank,account_name=p_account_name,account_number=p_account_number,updated_at=now() where id=true; end $$;
create or replace view public.admin_order_summary as select o.order_number,o.display_name,o.total_amount,o.payment_status,o.supply_status,o.created_at,coalesce(string_agg(p.name||' × '||oi.quantity,', '),'') items_text from orders o left join order_items oi on oi.order_id=o.id left join products p on p.id=oi.product_id where public.is_admin() group by o.id;
revoke all on public.admin_order_summary from anon; grant select on public.admin_order_summary to authenticated;


-- Production hardening ------------------------------------------------------
create index if not exists orders_customer_id_created_at_idx on public.orders(customer_id, created_at desc);
create index if not exists order_items_order_id_idx on public.order_items(order_id);
create index if not exists inventory_transactions_product_id_created_at_idx on public.inventory_transactions(product_id, created_at desc);

-- Only authenticated customers/admins should call business functions.
revoke execute on function public.place_order(text,text,jsonb,text,boolean) from anon;
grant execute on function public.place_order(text,text,jsonb,text,boolean) to authenticated;
revoke execute on function public.adjust_stock(text,int,text) from anon;
grant execute on function public.adjust_stock(text,int,text) to authenticated;
revoke execute on function public.confirm_payment(text) from anon;
grant execute on function public.confirm_payment(text) to authenticated;
revoke execute on function public.mark_supplied(text) from anon;
grant execute on function public.mark_supplied(text) to authenticated;
revoke execute on function public.set_payment_details(text,text,text) from anon;
grant execute on function public.set_payment_details(text,text,text) to authenticated;

-- Customers can create/update only their own profile through the app.
-- Orders and order_items are created only by the security-definer order function.
revoke insert, update, delete on public.orders from anon, authenticated;
revoke insert, update, delete on public.order_items from anon, authenticated;
revoke insert, update, delete on public.inventory_transactions from anon, authenticated;
revoke insert, delete on public.payment_settings from anon, authenticated;
revoke insert, update, delete on public.admins from anon, authenticated;
grant select on public.products to anon, authenticated;
grant select on public.payment_settings to anon, authenticated;
grant select on public.customers, public.orders, public.order_items, public.inventory_transactions, public.admins to authenticated;
grant update on public.products to authenticated;
grant update on public.orders to authenticated;
grant update on public.payment_settings to authenticated;

-- Prevent customers from ordering outside the business window.
create or replace function public.is_order_window_open() returns boolean language plpgsql stable as $$
declare n int; t time; begin n:=extract(isodow from (now() at time zone 'Africa/Lagos')); t:=(now() at time zone 'Africa/Lagos')::time; return n between 1 and 5 and t < time '17:00'; end $$;

-- Recreate order function with business-hours enforcement.
create or replace function public.place_order(p_display_name text,p_customer_code text,p_items jsonb,p_payment_method text,p_payment_claimed boolean default false) returns setof public.orders language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); sid uuid; bid uuid; sq int:=coalesce((p_items->>'small')::int,0); bq int:=coalesce((p_items->>'big')::int,0); total numeric:=0; oid uuid; r public.orders; sp numeric; bp numeric;
begin
 if uid is null then raise exception 'Customer session required'; end if;
 if not public.is_order_window_open() then raise exception 'Orders are closed. Orders are accepted Monday to Friday before 5:00 PM.'; end if;
 if p_payment_method not in ('cash','transfer') then raise exception 'Invalid payment method'; end if;
 if sq<0 or bq<0 or sq+bq=0 then raise exception 'Choose at least one product'; end if;
 if sq>50 or bq>50 then raise exception 'Maximum 50 packs per product per order'; end if;
 insert into customers(id,display_name,customer_code,updated_at) values(uid,nullif(trim(p_display_name),''),nullif(trim(p_customer_code),''),now()) on conflict(id) do update set display_name=excluded.display_name,customer_code=excluded.customer_code,updated_at=now();
 select id,price,stock into sid,sp from products where slug='small' and is_active for update;
 if sq>0 and (sid is null or sp is null) then raise exception 'Small Chinchin is unavailable'; end if;
 if sq>0 and (select stock from products where id=sid)<sq then raise exception 'Insufficient small stock'; end if;
 select id,price,stock into bid,bp from products where slug='big' and is_active for update;
 if bq>0 and (bid is null or bp is null) then raise exception 'Big Chinchin is unavailable'; end if;
 if bq>0 and (select stock from products where id=bid)<bq then raise exception 'Insufficient big stock'; end if;
 total:=coalesce(sp,0)*sq+coalesce(bp,0)*bq;
 insert into orders(customer_id,display_name,customer_code,total_amount,payment_method,payment_status) values(uid,nullif(trim(p_display_name),''),nullif(trim(p_customer_code),''),total,p_payment_method,case when p_payment_claimed then 'payment_claimed' else 'pending' end) returning * into r;
 oid:=r.id;
 if sq>0 then update products set stock=stock-sq where id=sid; insert into order_items(order_id,product_id,quantity,unit_price) values(oid,sid,sq,sp); insert into inventory_transactions(product_id,delta,reason,order_id,created_by) values(sid,-sq,'Customer order',oid,uid); end if;
 if bq>0 then update products set stock=stock-bq where id=bid; insert into order_items(order_id,product_id,quantity,unit_price) values(oid,bid,bq,bp); insert into inventory_transactions(product_id,delta,reason,order_id,created_by) values(bid,-bq,'Customer order',oid,uid); end if;
 return next r;
end $$;
revoke execute on function public.place_order(text,text,jsonb,text,boolean) from anon;
grant execute on function public.place_order(text,text,jsonb,text,boolean) to authenticated;

-- Admin-only cancellation releases reserved stock before supply.
create or replace function public.cancel_order(p_order_number text,p_reason text default 'Cancelled by admin') returns void language plpgsql security definer set search_path=public as $$
declare o record; i record; begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 select * into o from orders where order_number=p_order_number for update;
 if o.id is null then raise exception 'Order not found'; end if;
 if o.supply_status='supplied' then raise exception 'Supplied orders cannot be cancelled'; end if;
 if o.supply_status='cancelled' then return; end if;
 for i in select * from order_items where order_id=o.id loop
   update products set stock=stock+i.quantity where id=i.product_id;
   insert into inventory_transactions(product_id,delta,reason,order_id,created_by) values(i.product_id,i.quantity,coalesce(p_reason,'Order cancelled'),o.id,auth.uid());
 end loop;
 update orders set supply_status='cancelled',updated_at=now() where id=o.id;
end $$;
revoke execute on function public.cancel_order(text,text) from anon;
grant execute on function public.cancel_order(text,text) to authenticated;
