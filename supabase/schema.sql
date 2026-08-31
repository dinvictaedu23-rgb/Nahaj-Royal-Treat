-- =====================================================================
-- NAHAJ ROYAL TREAT — Supabase schema
-- Run this once in your Supabase project: Dashboard → SQL Editor → New query
-- =====================================================================

-- ---------- TABLES ----------

create table if not exists products (
  id text primary key,
  name text not null,
  category text not null,
  price numeric not null default 0,
  stock integer not null default 0,
  description text,
  emoji text default '🎂',
  img text,
  price_history jsonb not null default '[]',
  scheduled_prices jsonb not null default '[]',
  created_at timestamptz not null default now()
);

create table if not exists orders (
  id text primary key,
  customer_name text not null,
  phone text not null,
  email text,
  address text not null,
  items jsonb not null,
  total numeric not null default 0,
  payment_method text not null default 'Pay on Delivery',
  payment_status text not null default 'Unpaid',
  flutterwave_ref text,
  status text not null default 'Pending',
  source text not null default 'Website',
  created_at timestamptz not null default now()
);

create table if not exists customers (
  id text primary key,
  name text not null,
  phone text unique not null,
  email text,
  joined timestamptz not null default now(),
  orders integer not null default 0,
  spent numeric not null default 0
);

create table if not exists expenses (
  id text primary key,
  description text not null,
  category text not null default 'Other',
  amount numeric not null default 0,
  date timestamptz not null default now()
);

create table if not exists settings (
  id int primary key default 1,
  bank_name text default '',
  bank_account_number text default '',
  bank_account_name text default 'Nahaj Royal Treat',
  card_payment_note text default 'Our team will send you a secure card payment link on WhatsApp after your order is confirmed.',
  flutterwave_public_key text default '',
  constraint settings_single_row check (id = 1)
);
insert into settings (id) values (1) on conflict (id) do nothing;

-- ---------- ROW LEVEL SECURITY ----------

alter table products  enable row level security;
alter table orders    enable row level security;
alter table customers enable row level security;
alter table expenses  enable row level security;
alter table settings  enable row level security;

-- Products: everyone can browse the catalogue; only logged-in admin/staff can change it
create policy "products_public_read"   on products for select using (true);
create policy "products_admin_write"   on products for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- Orders: only admin/staff can list all orders (customers use the get_orders_by_phone
-- function below instead, so a stranger with the public anon key can't browse everyone's
-- name/phone/address). Creating an order goes through place_order(), not a direct insert.
create policy "orders_admin_read"  on orders for select using (auth.role() = 'authenticated');
create policy "orders_admin_write" on orders for update
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- Customers: admin/staff only — contains phone/email/spend history
create policy "customers_admin_read" on customers for select using (auth.role() = 'authenticated');

-- Expenses: admin/staff only — internal financial data
create policy "expenses_admin_all" on expenses for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- Settings: publicly readable (storefront needs bank details / Flutterwave key at checkout),
-- only admin/staff can change them
create policy "settings_public_read" on settings for select using (true);
create policy "settings_admin_write" on settings for update
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- ---------- FUNCTIONS ----------

-- Places an order as one atomic, safe operation: inserts the order, decrements stock
-- for every item, and upserts the customer record. Runs as SECURITY DEFINER so it can
-- do all of this even though the public "anon" role has no direct write access to
-- products/orders/customers — this is the only door into those tables for customers.
create or replace function place_order(
  p_id text,
  p_customer_name text,
  p_phone text,
  p_email text,
  p_address text,
  p_items jsonb,
  p_total numeric,
  p_payment_method text,
  p_flutterwave_ref text,
  p_payment_status text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  item jsonb;
  new_customer_id text;
begin
  insert into orders (id, customer_name, phone, email, address, items, total, payment_method, flutterwave_ref, payment_status, status, source)
  values (p_id, p_customer_name, p_phone, p_email, p_address, p_items, p_total, coalesce(p_payment_method,'Pay on Delivery'), p_flutterwave_ref, coalesce(p_payment_status,'Unpaid'), 'Pending', 'Website');

  for item in select * from jsonb_array_elements(p_items) loop
    update products
      set stock = greatest(0, stock - coalesce((item->>'qty')::int, 0))
      where id = item->>'productId';
  end loop;

  new_customer_id := 'CUS-' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);

  insert into customers (id, name, phone, email, joined, orders, spent)
  values (new_customer_id, p_customer_name, p_phone, p_email, now(), 1, p_total)
  on conflict (phone) do update
    set name   = excluded.name,
        email  = coalesce(excluded.email, customers.email),
        orders = customers.orders + 1,
        spent  = customers.spent + excluded.spent;
end;
$$;
grant execute on function place_order(text,text,text,text,text,jsonb,numeric,text,text,text) to anon, authenticated;

-- Lets a customer look up only their own orders by phone number, without exposing
-- everyone else's orders (the orders table itself is admin-only, see RLS above).
create or replace function get_orders_by_phone(p_phone text)
returns setof orders
language sql
security definer
set search_path = public
as $$
  select * from orders where phone = p_phone order by created_at desc;
$$;
grant execute on function get_orders_by_phone(text) to anon, authenticated;

-- Records a walk-in / in-store POS sale in one step (used by staff, so it also
-- requires authentication even though it's the same underlying mechanism as place_order).
create or replace function place_pos_sale(
  p_id text, p_customer_name text, p_phone text, p_product_id text, p_qty int, p_price numeric
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total numeric := p_qty * p_price;
  v_items jsonb;
  v_customer_id text;
begin
  if auth.role() <> 'authenticated' then
    raise exception 'Not authorized';
  end if;

  select jsonb_build_array(jsonb_build_object('productId', p_product_id, 'name', name, 'qty', p_qty, 'price', p_price))
    into v_items from products where id = p_product_id;

  insert into orders (id, customer_name, phone, email, address, items, total, payment_method, payment_status, status, source)
  values (p_id, p_customer_name, p_phone, '', 'In-store', v_items, v_total, 'Cash', 'Paid', 'Delivered', 'POS');

  update products set stock = greatest(0, stock - p_qty) where id = p_product_id;

  if p_phone is not null and p_phone <> '' and p_phone <> 'N/A' then
    v_customer_id := 'CUS-' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);
    insert into customers (id, name, phone, email, joined, orders, spent)
    values (v_customer_id, p_customer_name, p_phone, '', now(), 1, v_total)
    on conflict (phone) do update
      set name = excluded.name, orders = customers.orders + 1, spent = customers.spent + excluded.spent;
  end if;
end;
$$;
grant execute on function place_pos_sale(text,text,text,text,int,numeric) to authenticated;

-- ---------- SEED DATA (starter catalogue — feel free to edit/delete from the admin panel) ----------
insert into products (id, name, category, price, stock, description, emoji, price_history) values
('p1','Royal Rose Drip Cake','Cakes',35000,8,'A regal vanilla-sponge cake finished with a golden drip and fresh rose garnish. Perfect for birthdays and celebrations.','🎂','[{"price":35000,"note":"Initial price"}]'),
('p2','Crowned Berry Delight','Cakes',42000,5,'Layers of red velvet and cream cheese frosting, topped with berries and an edible gold crown.','🍰','[{"price":42000,"note":"Initial price"}]'),
('p3','Classic Chocolate Fudge','Cakes',30000,12,'Rich, moist chocolate sponge with silky fudge frosting — a Nahaj bestseller.','🧁','[{"price":30000,"note":"Initial price"}]'),
('p4','Spring Blossom Cake','Cakes',38000,3,'Light lemon sponge with buttercream florals, made for spring occasions.','🎂','[{"price":38000,"note":"Initial price"}]'),
('p5','Crispy Samosa Box (20pc)','Small Chops',8000,20,'Golden, flaky samosas filled with spiced minced meat and vegetables.','🥟','[{"price":8000,"note":"Initial price"}]'),
('p6','Puff-Puff & Chin Chin Mix','Small Chops',6500,18,'A sweet, crunchy party mix — always the first tray to finish.','🍩','[{"price":6500,"note":"Initial price"}]'),
('p7','Spring Roll Platter','Small Chops',9000,15,'Crispy vegetable spring rolls, hand-rolled and fried to order.','🥠','[{"price":9000,"note":"Initial price"}]'),
('p8','Meat Pie Assortment','Small Chops',7500,22,'Flaky, buttery pastry filled with well-seasoned minced meat and potato.','🥧','[{"price":7500,"note":"Initial price"}]'),
('p9','Classic Milk Candy Jar','Milk Candies',4500,30,'Creamy, chewy milk candies made in small batches — a Nahaj signature treat.','🍬','[{"price":4500,"note":"Initial price"}]'),
('p10','Caramel Milk Balls','Milk Candies',5000,2,'Soft caramel-milk candy balls, rich and irresistibly smooth.','🍡','[{"price":5000,"note":"Initial price"}]'),
('p11','Coconut Milk Candy Pack','Milk Candies',4800,16,'Milk candy infused with coconut for a tropical twist.','🥥','[{"price":4800,"note":"Initial price"}]'),
('p12','Handmade Crochet Tote','Crochets',15000,6,'A one-of-a-kind crochet handbag, made stitch by stitch with love.','👜','[{"price":15000,"note":"Initial price"}]'),
('p13','Crochet Bunny Keychain','Crochets',4000,25,'Adorable handmade bunny keychain — a sweet little gift.','🧸','[{"price":4000,"note":"Initial price"}]'),
('p14','Crochet Baby Set','Crochets',18000,1,'A soft, handcrafted crochet outfit set for newborns.','🍼','[{"price":18000,"note":"Initial price"}]')
on conflict (id) do nothing;
