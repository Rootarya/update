-- =========================================================
--  REKBERIN — Tambahan Schema: Panel Admin
--  Jalankan SETELAH schema.sql dan schema_chat.sql
--  (di Supabase Dashboard → SQL Editor)
-- =========================================================

-- ── 1. TAMBAH ROLE 'admin' ───────────────────────────────
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('pembeli','penjual','admin'));

-- ── 2. HELPER: cek apakah caller adalah admin ────────────
create or replace function public.is_admin()
returns boolean language sql security definer set search_path = public stable as $$
  select exists(
    select 1 from public.profiles where id = auth.uid() and role = 'admin'
  );
$$;

-- ── 3. AUDIT LOG ──────────────────────────────────────────
create table if not exists public.admin_logs (
  id          uuid primary key default gen_random_uuid(),
  admin_id    uuid not null references public.profiles(id),
  action      text not null,         -- 'suspend_user','change_role','update_order_status', dst
  target_type text not null,         -- 'user','order','product','wallet'
  target_id   uuid not null,
  detail      jsonb,                 -- snapshot before/after, alasan, dll
  created_at  timestamptz not null default now()
);

create index if not exists admin_logs_admin_idx  on public.admin_logs(admin_id);
create index if not exists admin_logs_target_idx  on public.admin_logs(target_type, target_id);

alter table public.admin_logs enable row level security;
create policy "admin_logs_admin_only" on public.admin_logs
  for all using (public.is_admin());

-- ── 4. KOLOM TAMBAHAN: suspend status di profiles ────────
alter table public.profiles add column if not exists is_suspended boolean not null default false;
alter table public.profiles add column if not exists suspended_reason text;

-- ── 5. RLS TAMBAHAN: admin bisa lihat & ubah semua ───────
-- (policy lama tetap berlaku untuk non-admin; ini cuma tambahan akses admin)

create policy "profiles_admin_all" on public.profiles
  for all using (public.is_admin());

create policy "orders_admin_all" on public.orders
  for all using (public.is_admin());

create policy "products_admin_all" on public.products
  for all using (public.is_admin());

create policy "wallets_admin_all" on public.wallets
  for all using (public.is_admin());

create policy "wallet_tx_admin_all" on public.wallet_transactions
  for all using (public.is_admin());

create policy "reviews_admin_all" on public.reviews
  for all using (public.is_admin());

create policy "notif_admin_all" on public.notifications
  for all using (public.is_admin());

-- ── 6. RPC: SUSPEND / UNSUSPEND USER ─────────────────────
create or replace function public.admin_suspend_user(p_user_id uuid, p_suspend boolean, p_reason text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_before record;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'Tidak punya akses admin.');
  end if;

  select is_suspended, suspended_reason into v_before from public.profiles where id = p_user_id;
  if v_before is null then
    return json_build_object('ok', false, 'error', 'Pengguna tidak ditemukan.');
  end if;

  update public.profiles
  set is_suspended = p_suspend,
      suspended_reason = case when p_suspend then p_reason else null end,
      updated_at = now()
  where id = p_user_id;

  insert into admin_logs (admin_id, action, target_type, target_id, detail)
  values (auth.uid(), case when p_suspend then 'suspend_user' else 'unsuspend_user' end,
    'user', p_user_id, jsonb_build_object('reason', p_reason, 'was_suspended', v_before.is_suspended));

  if p_suspend then
    insert into notifications (user_id, title, body, type)
    values (p_user_id, '⚠️ Akun Disuspend',
      'Akun kamu disuspend oleh admin.' || coalesce(' Alasan: ' || p_reason, ''), 'warning');
  end if;

  return json_build_object('ok', true);
end;
$$;

-- ── 7. RPC: UBAH ROLE USER ───────────────────────────────
create or replace function public.admin_change_role(p_user_id uuid, p_new_role text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_old_role text;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'Tidak punya akses admin.');
  end if;
  if p_new_role not in ('pembeli','penjual','admin') then
    return json_build_object('ok', false, 'error', 'Role tidak valid.');
  end if;

  select role into v_old_role from public.profiles where id = p_user_id;
  if v_old_role is null then
    return json_build_object('ok', false, 'error', 'Pengguna tidak ditemukan.');
  end if;

  update public.profiles set role = p_new_role, updated_at = now() where id = p_user_id;

  insert into admin_logs (admin_id, action, target_type, target_id, detail)
  values (auth.uid(), 'change_role', 'user', p_user_id,
    jsonb_build_object('from', v_old_role, 'to', p_new_role));

  return json_build_object('ok', true);
end;
$$;

-- ── 8. RPC: UBAH STATUS ORDER (PAKSA) ────────────────────
create or replace function public.admin_update_order_status(p_order_id uuid, p_new_status order_status, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_old_status order_status;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'Tidak punya akses admin.');
  end if;

  select status into v_old_status from public.orders where id = p_order_id;
  if v_old_status is null then
    return json_build_object('ok', false, 'error', 'Pesanan tidak ditemukan.');
  end if;

  update public.orders
  set status = p_new_status,
      delivery_note = coalesce(p_note, delivery_note),
      completed_at = case when p_new_status = 'completed' then now() else completed_at end,
      delivered_at = case when p_new_status = 'delivered' then now() else delivered_at end,
      updated_at = now()
  where id = p_order_id;

  insert into admin_logs (admin_id, action, target_type, target_id, detail)
  values (auth.uid(), 'update_order_status', 'order', p_order_id,
    jsonb_build_object('from', v_old_status, 'to', p_new_status, 'note', p_note));

  return json_build_object('ok', true);
end;
$$;

-- ── 9. RPC: FORCE REFUND (kembalikan dana ke pembeli) ────
-- Membatalkan escrow_hold penjual & order, kembalikan total_amount ke saldo pembeli.
-- Hanya valid untuk order yang masih dalam status paid/processing/delivered/disputed.
create or replace function public.admin_force_refund(p_order_id uuid, p_reason text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_order orders%rowtype;
  v_buyer_wallet_id uuid;
  v_seller_wallet_id uuid;
  v_new_balance bigint;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'Tidak punya akses admin.');
  end if;

  select * into v_order from orders where id = p_order_id;
  if v_order is null then
    return json_build_object('ok', false, 'error', 'Pesanan tidak ditemukan.');
  end if;
  if v_order.status not in ('paid','processing','delivered','disputed') then
    return json_build_object('ok', false, 'error', 'Status pesanan tidak bisa direfund (' || v_order.status || ').');
  end if;

  select id into v_buyer_wallet_id from wallets where user_id = v_order.buyer_id;
  select id into v_seller_wallet_id from wallets where user_id = v_order.seller_id;

  -- lepas escrow_hold dari penjual (dana tidak pernah benar2 ada di balance penjual)
  update wallets
  set escrow_hold = greatest(escrow_hold - v_order.total_amount, 0), updated_at = now()
  where id = v_seller_wallet_id;

  -- kembalikan dana ke saldo pembeli
  update wallets
  set balance = balance + v_order.total_amount,
      total_in = total_in + v_order.total_amount,
      updated_at = now()
  where id = v_buyer_wallet_id
  returning balance into v_new_balance;

  insert into wallet_transactions (wallet_id, type, amount, balance_after, description, ref_order_id)
  values (v_buyer_wallet_id, 'refund', v_order.total_amount, v_new_balance,
    'Refund admin — ' || v_order.product_title || coalesce(' (' || p_reason || ')', ''), p_order_id);

  update orders set status = 'refunded', updated_at = now() where id = p_order_id;

  insert into admin_logs (admin_id, action, target_type, target_id, detail)
  values (auth.uid(), 'force_refund', 'order', p_order_id,
    jsonb_build_object('amount', v_order.total_amount, 'reason', p_reason));

  insert into notifications (user_id, title, body, type, ref_order_id)
  values (v_order.buyer_id, '💸 Dana Dikembalikan',
    'Pesanan "' || v_order.product_title || '" direfund oleh admin.' || coalesce(' Alasan: ' || p_reason, ''),
    'info', p_order_id);
  insert into notifications (user_id, title, body, type, ref_order_id)
  values (v_order.seller_id, '⚠️ Pesanan Direfund Admin',
    'Pesanan "' || v_order.product_title || '" direfund ke pembeli oleh admin.' || coalesce(' Alasan: ' || p_reason, ''),
    'warning', p_order_id);

  return json_build_object('ok', true);
end;
$$;

-- ── 10. RPC: ADJUST SALDO WALLET MANUAL ──────────────────
-- p_amount boleh positif (tambah) atau negatif (kurangi). Dipakai untuk
-- kompensasi/dispute yang tidak otomatis tertangani oleh refund order biasa.
create or replace function public.admin_adjust_wallet(p_user_id uuid, p_amount bigint, p_reason text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_wallet_id uuid;
  v_new_balance bigint;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'Tidak punya akses admin.');
  end if;
  if p_amount = 0 then
    return json_build_object('ok', false, 'error', 'Jumlah tidak boleh nol.');
  end if;
  if p_reason is null or trim(p_reason) = '' then
    return json_build_object('ok', false, 'error', 'Alasan wajib diisi untuk audit.');
  end if;

  select id into v_wallet_id from wallets where user_id = p_user_id;
  if v_wallet_id is null then
    return json_build_object('ok', false, 'error', 'Dompet pengguna tidak ditemukan.');
  end if;

  update wallets
  set balance = balance + p_amount,
      total_in  = total_in  + (case when p_amount > 0 then p_amount else 0 end),
      total_out = total_out + (case when p_amount < 0 then -p_amount else 0 end),
      updated_at = now()
  where id = v_wallet_id
  returning balance into v_new_balance;

  if v_new_balance < 0 then
    -- rollback dengan exception supaya transaksi dibatalkan total
    raise exception 'Saldo tidak boleh negatif (hasil akhir: %).', v_new_balance;
  end if;

  insert into wallet_transactions (wallet_id, type, amount, balance_after, description)
  values (v_wallet_id, case when p_amount > 0 then 'topup' else 'withdrawal' end,
    abs(p_amount), v_new_balance, 'Penyesuaian admin — ' || p_reason);

  insert into admin_logs (admin_id, action, target_type, target_id, detail)
  values (auth.uid(), 'adjust_wallet', 'wallet', v_wallet_id,
    jsonb_build_object('amount', p_amount, 'reason', p_reason, 'new_balance', v_new_balance));

  insert into notifications (user_id, title, body, type)
  values (p_user_id,
    case when p_amount > 0 then '💰 Saldo Ditambahkan' else '⚠️ Saldo Dikurangi' end,
    'Saldo kamu disesuaikan admin sebesar Rp ' || to_char(abs(p_amount), 'FM999,999,999') ||
    '. Alasan: ' || p_reason, 'info');

  return json_build_object('ok', true, 'new_balance', v_new_balance);
exception when others then
  return json_build_object('ok', false, 'error', sqlerrm);
end;
$$;

-- ── 11. RPC: TOGGLE PRODUK (aktif/nonaktifkan) ───────────
create or replace function public.admin_toggle_product(p_product_id uuid, p_active boolean, p_reason text default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'Tidak punya akses admin.');
  end if;

  update public.products set is_active = p_active, updated_at = now() where id = p_product_id;
  if not found then
    return json_build_object('ok', false, 'error', 'Produk tidak ditemukan.');
  end if;

  insert into admin_logs (admin_id, action, target_type, target_id, detail)
  values (auth.uid(), case when p_active then 'activate_product' else 'deactivate_product' end,
    'product', p_product_id, jsonb_build_object('reason', p_reason));

  return json_build_object('ok', true);
end;
$$;

-- ── 12. VIEW: STATISTIK PLATFORM (admin only, dicek lewat RLS-style guard) ──
create or replace view public.admin_stats as
select
  (select count(*) from profiles where role = 'pembeli') as total_buyers,
  (select count(*) from profiles where role = 'penjual') as total_sellers,
  (select count(*) from profiles where is_suspended) as total_suspended,
  (select count(*) from products where is_active) as active_products,
  (select count(*) from orders) as total_orders,
  (select count(*) from orders where status = 'completed') as completed_orders,
  (select count(*) from orders where status = 'disputed') as disputed_orders,
  (select count(*) from orders where status in ('pending_payment')) as pending_orders,
  (select coalesce(sum(total_amount),0) from orders where status = 'completed') as gmv_completed,
  (select coalesce(sum(platform_fee),0) from orders where status = 'completed') as platform_revenue,
  (select coalesce(sum(escrow_hold),0) from wallets) as total_escrow_held,
  (select coalesce(sum(balance),0) from wallets) as total_wallet_balance;

-- Catatan: view ini tidak punya RLS sendiri (views memakai permission
-- pemanggil + RLS tabel asal). Karena tabel-tabel di atas sudah punya
-- policy *_admin_all, hanya admin yang akan melihat data lengkap di sini —
-- tapi sebagai pertahanan tambahan, query dari frontend tetap divalidasi
-- session.role === 'admin' sebelum tab admin manapun dimuat.

-- ── 13. VIEW: SEMUA ORDER DENGAN INFO PEMBELI/PENJUAL (admin) ──
create or replace view public.admin_orders_view as
select
  o.*,
  b.full_name as buyer_name, b.username as buyer_username,
  s.full_name as seller_name, s.username as seller_username
from orders o
join profiles b on b.id = o.buyer_id
join profiles s on s.id = o.seller_id
order by o.created_at desc;
