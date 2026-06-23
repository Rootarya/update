-- ============================================================
-- SETUP KOMISI ADMIN + KONEKSI DATA PEMBELI & PENJUAL
-- Jalankan file ini di Supabase SQL Editor (satu per satu blok)
-- https://supabase.com/dashboard → project → SQL Editor
-- ============================================================


-- ============================================================
-- STEP 1: Tambah kolom platform_fee & komisi ke tabel orders
-- (skip jika sudah ada)
-- ============================================================
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS platform_fee    BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS commission_rate NUMERIC(5,4) NOT NULL DEFAULT 0.05,
  ADD COLUMN IF NOT EXISTS seller_payout   BIGINT NOT NULL DEFAULT 0;

-- ============================================================
-- STEP 2: Tabel platform_commission — catatan komisi admin
-- ============================================================
CREATE TABLE IF NOT EXISTS platform_commission (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id     UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  gross_amount BIGINT NOT NULL,   -- total yang dibayar pembeli
  rate         NUMERIC(5,4) NOT NULL DEFAULT 0.05,
  fee_amount   BIGINT NOT NULL,   -- komisi admin (gross * rate)
  seller_net   BIGINT NOT NULL,   -- yang diterima penjual
  status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','settled','refunded')),
  settled_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- STEP 3: Tabel admin_wallet — dompet komisi admin
-- ============================================================
CREATE TABLE IF NOT EXISTS admin_wallet (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  balance    BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Isi satu baris awal jika belum ada
INSERT INTO admin_wallet (id, balance)
SELECT gen_random_uuid(), 0
WHERE NOT EXISTS (SELECT 1 FROM admin_wallet);

-- ============================================================
-- STEP 4: View admin_orders_view — data order lengkap
-- (pembeli + penjual + komisi dalam satu query)
-- ============================================================
CREATE OR REPLACE VIEW admin_orders_view AS
SELECT
  o.id,
  o.created_at,
  o.status,
  o.quantity,
  o.total_amount,
  o.platform_fee,
  o.seller_payout,
  o.commission_rate,

  -- Produk
  p.title   AS product_title,
  p.category AS product_category,

  -- Pembeli
  buyer.id          AS buyer_id,
  buyer.full_name   AS buyer_name,
  buyer.username    AS buyer_username,
  buyer.email       AS buyer_email,
  bw.balance        AS buyer_wallet_balance,

  -- Penjual
  seller.id         AS seller_id,
  seller.full_name  AS seller_name,
  seller.username   AS seller_username,
  seller.email      AS seller_email,
  sw.balance        AS seller_wallet_balance,

  -- Komisi
  pc.fee_amount   AS commission_amount,
  pc.status       AS commission_status

FROM orders o
LEFT JOIN products  p      ON p.id = o.product_id
LEFT JOIN profiles  buyer  ON buyer.id = o.buyer_id
LEFT JOIN profiles  seller ON seller.id = p.seller_id
LEFT JOIN wallets   bw     ON bw.user_id = o.buyer_id
LEFT JOIN wallets   sw     ON sw.user_id = p.seller_id
LEFT JOIN platform_commission pc ON pc.order_id = o.id;

-- ============================================================
-- STEP 5: View admin_stats — statistik untuk dashboard
-- ============================================================
CREATE OR REPLACE VIEW admin_stats AS
SELECT
  COUNT(*)                                          AS total_orders,
  COUNT(*) FILTER (WHERE o.status = 'completed')   AS completed_orders,
  COUNT(*) FILTER (WHERE o.status IN ('pending_payment','pending')) AS pending_orders,
  COUNT(*) FILTER (WHERE o.status = 'disputed')    AS disputed_orders,

  COALESCE(SUM(o.total_amount) FILTER (WHERE o.status = 'completed'), 0) AS gmv_completed,
  COALESCE(SUM(o.platform_fee) FILTER (WHERE o.status = 'completed'), 0) AS platform_revenue,
  COALESCE(SUM(o.total_amount) FILTER (WHERE o.status IN ('paid','processing')), 0) AS total_escrow_held,

  (SELECT COALESCE(SUM(balance),0) FROM wallets)  AS total_wallet_balance,
  (SELECT COALESCE(balance,0) FROM admin_wallet LIMIT 1) AS admin_commission_balance,

  COUNT(DISTINCT o.buyer_id)                        AS total_buyers,
  (SELECT COUNT(*) FROM profiles WHERE role = 'penjual') AS total_sellers,
  (SELECT COUNT(*) FROM profiles WHERE is_suspended = true) AS total_suspended

FROM orders o;

-- ============================================================
-- STEP 6: Function — hitung & simpan komisi saat order selesai
-- ============================================================
CREATE OR REPLACE FUNCTION fn_process_commission(
  p_order_id UUID,
  p_rate     NUMERIC DEFAULT 0.05
)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_order       RECORD;
  v_fee         BIGINT;
  v_seller_net  BIGINT;
  v_seller_id   UUID;
BEGIN
  -- Ambil data order
  SELECT o.*, p.seller_id
    INTO v_order
  FROM orders o
  JOIN products p ON p.id = o.product_id
  WHERE o.id = p_order_id;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Order tidak ditemukan');
  END IF;

  IF v_order.status != 'completed' THEN
    RETURN json_build_object('ok', false, 'error', 'Order belum completed');
  END IF;

  -- Hitung komisi
  v_fee        := FLOOR(v_order.total_amount * p_rate);
  v_seller_net := v_order.total_amount - v_fee;
  v_seller_id  := v_order.seller_id;

  -- Update orders
  UPDATE orders SET
    platform_fee    = v_fee,
    commission_rate = p_rate,
    seller_payout   = v_seller_net
  WHERE id = p_order_id;

  -- Simpan ke platform_commission
  INSERT INTO platform_commission (order_id, gross_amount, rate, fee_amount, seller_net, status, settled_at)
  VALUES (p_order_id, v_order.total_amount, p_rate, v_fee, v_seller_net, 'settled', now())
  ON CONFLICT (order_id) DO UPDATE SET
    fee_amount = v_fee,
    seller_net = v_seller_net,
    status     = 'settled',
    settled_at = now();

  -- Tambah saldo komisi ke admin_wallet
  UPDATE admin_wallet SET
    balance    = balance + v_fee,
    updated_at = now();

  -- Cairkan ke dompet penjual
  UPDATE wallets SET balance = balance + v_seller_net
  WHERE user_id = v_seller_id;

  -- Catat transaksi penjual
  INSERT INTO wallet_transactions (wallet_id, type, amount, balance_after, description)
  SELECT w.id, 'escrow_release', v_seller_net, w.balance, 
         'Penjualan order #' || LEFT(p_order_id::TEXT, 8) || ' (setelah komisi ' || ROUND(p_rate*100) || '%)'
  FROM wallets w WHERE w.user_id = v_seller_id;

  RETURN json_build_object(
    'ok',          true,
    'gross',       v_order.total_amount,
    'fee',         v_fee,
    'seller_net',  v_seller_net
  );
END;
$$;

-- ============================================================
-- STEP 7: Function admin_update_order_status — update status + proses komisi otomatis
-- ============================================================
CREATE OR REPLACE FUNCTION admin_update_order_status(
  p_order_id  UUID,
  p_new_status TEXT,
  p_note      TEXT DEFAULT ''
)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_rate NUMERIC;
BEGIN
  -- Ambil rate komisi dari settings (default 5%)
  v_rate := COALESCE(
    (SELECT value::NUMERIC FROM app_settings WHERE key = 'commission_rate' LIMIT 1),
    0.05
  );

  UPDATE orders SET status = p_new_status WHERE id = p_order_id;

  -- Kalau completed → proses komisi otomatis
  IF p_new_status = 'completed' THEN
    PERFORM fn_process_commission(p_order_id, v_rate);
  END IF;

  -- Log aksi admin
  INSERT INTO admin_logs (admin_id, action, target_type, target_id, detail)
  SELECT auth.uid(), 'update_order_status', 'order', p_order_id,
         json_build_object('new_status', p_new_status, 'note', p_note);

  RETURN json_build_object('ok', true);
END;
$$;

-- ============================================================
-- STEP 8: Tabel app_settings — konfigurasi dinamis (komisi bisa diubah dari dashboard)
-- ============================================================
CREATE TABLE IF NOT EXISTS app_settings (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Default komisi 5%
INSERT INTO app_settings (key, value) VALUES ('commission_rate', '0.05')
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- STEP 9: Function admin_get_commission_summary — ringkasan komisi
-- ============================================================
CREATE OR REPLACE FUNCTION admin_get_commission_summary()
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_total_fee     BIGINT;
  v_today_fee     BIGINT;
  v_month_fee     BIGINT;
  v_admin_balance BIGINT;
BEGIN
  SELECT
    COALESCE(SUM(fee_amount) FILTER (WHERE status = 'settled'), 0),
    COALESCE(SUM(fee_amount) FILTER (WHERE status = 'settled' AND created_at::DATE = CURRENT_DATE), 0),
    COALESCE(SUM(fee_amount) FILTER (WHERE status = 'settled' AND created_at >= DATE_TRUNC('month', now())), 0)
  INTO v_total_fee, v_today_fee, v_month_fee
  FROM platform_commission;

  SELECT balance INTO v_admin_balance FROM admin_wallet LIMIT 1;

  RETURN json_build_object(
    'total_commission',  v_total_fee,
    'today_commission',  v_today_fee,
    'month_commission',  v_month_fee,
    'admin_balance',     v_admin_balance
  );
END;
$$;

-- ============================================================
-- STEP 10: RLS (Row Level Security) — admin saja yang bisa lihat komisi
-- ============================================================
ALTER TABLE platform_commission ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_wallet        ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin only" ON platform_commission
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "admin only" ON admin_wallet
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ============================================================
-- SELESAI ✓
-- Sekarang edit dashboard-admin.html:
-- Baris 1024: ganti YOUR_PROJECT → URL Supabase kamu
-- Baris 1025: ganti YOUR_ANON_KEY → Anon key Supabase kamu
-- ============================================================
