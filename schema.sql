-- =========================================================
--  REKBERIN — Database Schema
--  Jalankan di: Supabase Dashboard → SQL Editor → New Query
-- =========================================================

-- ── 1. ENUM STATUS ──────────────────────────────────────
create type order_status as enum (
  'pending_payment',   -- menunggu bayar
  'paid',              -- sudah bayar, dana ditahan rekber
  'processing',        -- penjual sedang proses
  'delivered',         -- penjual klaim sudah kirim
  'completed',         -- pembeli konfirmasi terima → dana cair ke penjual
  'disputed',          -- ada sengketa
  'refunded',          -- dana dikembalikan ke pembeli
  'cancelled'          -- dibatalkan
);

create type wallet_tx_type as enum (
  'topup',             -- isi saldo
  'escrow_hold',       -- dana ditahan rekber saat bayar
  'escrow_release',    -- dana cair ke penjual setelah selesai
  'refund',            -- dana dikembalikan ke pembeli
  'withdrawal'         -- penjual tarik saldo ke rekening
);

-- ── 2. PROFIL PENGGUNA ───────────────────────────────────
-- Extend auth.users bawaan Supabase
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  full_name    text,
  username     text unique,
  role         text not null default 'pembeli' check (role in ('pembeli','penjual')),
  avatar_url   text,
  phone        text,
  bio          text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Auto-create profile saat user baru daftar
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'role', 'pembeli')
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ── 3. DOMPET (WALLET) ───────────────────────────────────
create table if not exists public.wallets (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null unique references public.profiles(id) on delete cascade,
  balance      bigint not null default 0 check (balance >= 0),  -- dalam Rupiah
  escrow_hold  bigint not null default 0,  -- saldo sedang ditahan rekber
  total_in     bigint not null default 0,  -- akumulasi masuk
  total_out    bigint not null default 0,  -- akumulasi keluar
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Auto-create wallet saat profil dibuat
create or replace function public.handle_new_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.wallets (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_profile_created on public.profiles;
create trigger on_profile_created
  after insert on public.profiles
  for each row execute procedure public.handle_new_profile();

-- ── 4. TRANSAKSI DOMPET ──────────────────────────────────
create table if not exists public.wallet_transactions (
  id           uuid primary key default gen_random_uuid(),
  wallet_id    uuid not null references public.wallets(id) on delete cascade,
  type         wallet_tx_type not null,
  amount       bigint not null,           -- selalu positif
  balance_after bigint not null,
  description  text,
  ref_order_id uuid,                      -- FK ke orders (nullable, set nanti)
  created_at   timestamptz not null default now()
);

-- ── 5. PRODUK (dari penjual) ─────────────────────────────
create table if not exists public.products (
  id           uuid primary key default gen_random_uuid(),
  seller_id    uuid not null references public.profiles(id) on delete cascade,
  title        text not null,
  description  text,
  category     text not null,             -- 'digital','game','jasa'
  subcategory  text,
  price        bigint not null check (price > 0),
  stock        int not null default 1,
  badge        text default 'Instan',
  icon         text,
  grad_start   text default '#16A37A',
  grad_end     text default '#0E7C5B',
  is_active    boolean not null default true,
  rating_sum   numeric not null default 0,
  rating_count int not null default 0,
  sold_count   int not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ── 6. PESANAN (ORDERS) ──────────────────────────────────
create table if not exists public.orders (
  id                uuid primary key default gen_random_uuid(),
  buyer_id          uuid not null references public.profiles(id),
  seller_id         uuid not null references public.profiles(id),
  product_id        uuid references public.products(id) on delete set null,
  product_title     text not null,        -- snapshot judul saat beli
  product_price     bigint not null,      -- snapshot harga saat beli
  quantity          int not null default 1,
  total_amount      bigint not null,      -- product_price * quantity
  platform_fee      bigint not null default 0,
  seller_receives   bigint not null,      -- total_amount - platform_fee
  status            order_status not null default 'pending_payment',
  midtrans_order_id text unique,
  midtrans_token    text,
  buyer_note        text,
  delivery_note     text,                 -- catatan dari penjual
  delivered_at      timestamptz,
  completed_at      timestamptz,
  auto_complete_at  timestamptz,          -- auto complete 3 hari setelah delivered
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- FK wallet_transactions → orders
alter table public.wallet_transactions
  add constraint fk_wallet_tx_order
  foreign key (ref_order_id) references public.orders(id) on delete set null;

-- ── 7. NOTIFIKASI ────────────────────────────────────────
create table if not exists public.notifications (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  title        text not null,
  body         text not null,
  type         text not null default 'info',  -- 'info','success','warning','error'
  is_read      boolean not null default false,
  ref_order_id uuid references public.orders(id) on delete set null,
  created_at   timestamptz not null default now()
);

-- ── 8. REVIEW/RATING ─────────────────────────────────────
create table if not exists public.reviews (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null unique references public.orders(id) on delete cascade,
  buyer_id     uuid not null references public.profiles(id),
  seller_id    uuid not null references public.profiles(id),
  product_id   uuid references public.products(id) on delete set null,
  rating       int not null check (rating between 1 and 5),
  comment      text,
  created_at   timestamptz not null default now()
);

-- ── 9. ROW LEVEL SECURITY (RLS) ──────────────────────────
alter table public.profiles           enable row level security;
alter table public.wallets            enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.products           enable row level security;
alter table public.orders             enable row level security;
alter table public.notifications      enable row level security;
alter table public.reviews            enable row level security;

-- profiles: bisa lihat semua, edit milik sendiri
create policy "profiles_read_all"   on public.profiles for select using (true);
create policy "profiles_update_own" on public.profiles for update using (auth.uid() = id);

-- wallets: hanya pemilik
create policy "wallets_own" on public.wallets for all using (auth.uid() = user_id);

-- wallet_transactions: hanya pemilik wallet
create policy "wallet_tx_own" on public.wallet_transactions for select
  using (wallet_id in (select id from public.wallets where user_id = auth.uid()));

-- products: baca semua, ubah milik sendiri
create policy "products_read_all"    on public.products for select using (true);
create policy "products_manage_own"  on public.products for all using (auth.uid() = seller_id);

-- orders: pembeli atau penjual di pesanan itu
create policy "orders_participant" on public.orders for all
  using (auth.uid() = buyer_id or auth.uid() = seller_id);

-- notifications: pemilik saja
create policy "notif_own" on public.notifications for all using (auth.uid() = user_id);

-- reviews: baca semua, buat/edit milik sendiri
create policy "reviews_read_all" on public.reviews for select using (true);
create policy "reviews_own"      on public.reviews for all using (auth.uid() = buyer_id);

-- ── 10. VIEW DASHBOARD PEMBELI ───────────────────────────
create or replace view public.buyer_dashboard as
select
  p.id                        as user_id,
  p.full_name,
  p.role,
  w.balance                   as wallet_balance,
  w.escrow_hold               as wallet_escrow,
  count(o.id)                 as total_orders,
  count(o.id) filter (where o.status = 'completed')   as completed_orders,
  count(o.id) filter (where o.status in ('paid','processing','delivered')) as active_orders,
  coalesce(sum(o.total_amount) filter (where o.status = 'completed'), 0) as total_spent
from public.profiles p
left join public.wallets w on w.user_id = p.id
left join public.orders o on o.buyer_id = p.id
where p.id = auth.uid()
group by p.id, p.full_name, p.role, w.balance, w.escrow_hold;

-- ── 11. VIEW DASHBOARD PENJUAL ───────────────────────────
create or replace view public.seller_dashboard as
select
  p.id                        as user_id,
  p.full_name,
  p.role,
  w.balance                   as wallet_balance,
  w.escrow_hold               as wallet_escrow,
  count(o.id)                 as total_orders,
  count(o.id) filter (where o.status = 'completed')   as completed_orders,
  count(o.id) filter (where o.status in ('paid','processing','delivered')) as active_orders,
  count(o.id) filter (where o.status = 'pending_payment') as pending_orders,
  coalesce(sum(o.seller_receives) filter (where o.status = 'completed'), 0) as total_revenue,
  coalesce(avg(r.rating), 0) as avg_rating,
  count(r.id)                 as total_reviews,
  count(pr.id) filter (where pr.is_active) as active_products
from public.profiles p
left join public.wallets w on w.user_id = p.id
left join public.orders o on o.seller_id = p.id
left join public.reviews r on r.seller_id = p.id
left join public.products pr on pr.seller_id = p.id
where p.id = auth.uid()
group by p.id, p.full_name, p.role, w.balance, w.escrow_hold;

-- ── 12. FUNCTION: KONFIRMASI PESANAN ─────────────────────
-- Dipanggil pembeli setelah terima barang → status jadi completed
-- dana rekber cair ke saldo penjual
create or replace function public.confirm_order(p_order_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_order orders%rowtype;
  v_seller_wallet wallets%rowtype;
  v_new_balance bigint;
begin
  -- ambil order, pastikan caller adalah pembeli
  select * into v_order from orders
  where id = p_order_id and buyer_id = auth.uid() and status = 'delivered';

  if not found then
    return json_build_object('ok', false, 'error', 'Pesanan tidak ditemukan atau belum berstatus delivered.');
  end if;

  -- update status order
  update orders set status = 'completed', completed_at = now(), updated_at = now()
  where id = p_order_id;

  -- cair ke saldo penjual
  update wallets
  set balance = balance + v_order.seller_receives,
      escrow_hold = greatest(escrow_hold - v_order.total_amount, 0),
      total_in = total_in + v_order.seller_receives,
      updated_at = now()
  where user_id = v_order.seller_id
  returning balance into v_new_balance;

  -- rekam transaksi dompet penjual
  insert into wallet_transactions (wallet_id, type, amount, balance_after, description, ref_order_id)
  select id, 'escrow_release', v_order.seller_receives, v_new_balance,
    'Dana rekber cair — ' || v_order.product_title, p_order_id
  from wallets where user_id = v_order.seller_id;

  -- notif penjual
  insert into notifications (user_id, title, body, type, ref_order_id)
  values (v_order.seller_id,
    '✅ Dana rekber cair!',
    'Pembeli konfirmasi terima pesanan "' || v_order.product_title || '". Dana Rp ' ||
    to_char(v_order.seller_receives, 'FM999,999,999') || ' sudah masuk ke saldo kamu.',
    'success', p_order_id);

  -- notif pembeli
  insert into notifications (user_id, title, body, type, ref_order_id)
  values (v_order.buyer_id,
    '🎉 Pesanan selesai!',
    'Pesanan "' || v_order.product_title || '" sudah kamu konfirmasi selesai.',
    'success', p_order_id);

  return json_build_object('ok', true);
end;
$$;

-- ── 13. SEED DATA DEMO (opsional, buat testing) ──────────
-- Hapus blok ini kalau tidak mau data dummy
/*
do $$
declare
  v_buyer_id  uuid := gen_random_uuid();
  v_seller_id uuid := gen_random_uuid();
begin
  -- Catatan: seed ini hanya untuk testing via service_role,
  -- tidak bisa dijalankan dari browser karena auth.users butuh Supabase Auth.
  -- Gunakan Supabase Dashboard → Authentication → Users untuk buat user test.
  raise notice 'Buat user lewat Supabase Auth UI, lalu update role di tabel profiles.';
end;
$$;
*/
