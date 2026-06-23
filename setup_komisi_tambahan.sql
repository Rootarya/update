-- ============================================================
-- SETUP KOMISI — hanya tabel yang BELUM ADA
-- Jalankan di Supabase → SQL Editor
-- ============================================================

-- 1. Tambah kolom komisi ke tabel orders (kalau belum ada)
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS platform_fee    BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS commission_rate NUMERIC(5,4) NOT NULL DEFAULT 0.05,
  ADD COLUMN IF NOT EXISTS seller_payout   BIGINT NOT NULL DEFAULT 0;

-- 2. Tabel catatan komisi per transaksi
CREATE TABLE IF NOT EXISTS platform_commission (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id     UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  gross_amount BIGINT NOT NULL,
  rate         NUMERIC(5,4) NOT NULL DEFAULT 0.05,
  fee_amount   BIGINT NOT NULL,
  seller_net   BIGINT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','settled','refunded')),
  settled_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Dompet komisi admin
CREATE TABLE IF NOT EXISTS admin_wallet (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  balance    BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO admin_wallet (id, balance)
SELECT gen_random_uuid(), 0
WHERE NOT EXISTS (SELECT 1 FROM admin_wallet);

-- 4. Pengaturan app (rate komisi bisa diubah dari dashboard)
CREATE TABLE IF NOT EXISTS app_settings (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO app_settings (key, value) VALUES ('commission_rate', '0.05')
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- 5. Update view admin_orders_view — tambah data pembeli & penjual
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

  p.title        AS product_title,
  p.category     AS product_category,

  buyer.id           AS buyer_id,
  buyer.full_name    AS buyer_name,
  buyer.username     AS buyer_username,
  bw.balance         AS buyer_wallet_balance,

  seller.id          AS seller_id,
  seller.full_name   AS seller_name,
  seller.username    AS seller_username,
  sw.balance         AS seller_wallet_balance,

  pc.fee_amount      AS commission_amount,
  pc.status          AS commission_status

FROM orders o
LEFT JOIN products  p      ON p.id = o.product_id
LEFT JOIN profiles  buyer  ON buyer.id = o.buyer_id
LEFT JOIN profiles  seller ON seller.id = p.seller_id
LEFT JOIN wallets   bw     ON bw.user_id = o.buyer_id
LEFT JOIN wallets   sw     ON sw.user_id = p.seller_id
LEFT JOIN platform_commission pc ON pc.order_id = o.id;

-- ============================================================
-- 6. Update view admin_stats — tambah commission balance
-- ============================================================
CREATE OR REPLACE VIEW admin_stats AS
SELECT
  COUNT(*)                                                            AS total_orders,
  COUNT(*) FILTER (WHERE o.status = 'completed')                     AS completed_orders,
  COUNT(*) FILTER (WHERE o.status IN ('pending_payment','pending'))  AS pending_orders,
  COUNT(*) FILTER (WHERE o.status = 'disputed')                      AS disputed_orders,

  COALESCE(SUM(o.total_amount) FILTER (WHERE o.status='completed'),0) AS gmv_completed,
  COALESCE(SUM(o.platform_fee) FILTER (WHERE o.status='completed'),0) AS platform_revenue,
  COALESCE(SUM(o.total_amount) FILTER (WHERE o.status IN ('paid','processing')),0) AS total_escrow_held,

  (SELECT COALESCE(SUM(balance),0) FROM wallets)                     AS total_wallet_balance,
  (SELECT COALESCE(balance,0) FROM admin_wallet LIMIT 1)             AS admin_commission_balance,

  COUNT(DISTINCT o.buyer_id)                                         AS total_buyers,
  (SELECT COUNT(*) FROM profiles WHERE role='penjual')               AS total_sellers,
  (SELECT COUNT(*) FROM profiles WHERE is_suspended=true)            AS total_suspended

FROM orders o;

-- ============================================================
-- 7. Function — hitung & distribusi komisi saat order completed
-- ============================================================
CREATE OR REPLACE FUNCTION fn_process_commission(
  p_order_id UUID,
  p_rate     NUMERIC DEFAULT 0.05
)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_order      RECORD;
  v_fee        BIGINT;
  v_seller_net BIGINT;
  v_seller_id  UUID;
BEGIN
  SELECT o.*, p.seller_id
    INTO v_order
  FROM orders o
  JOIN products p ON p.id = o.product_id
  WHERE o.id = p_order_id;

  IF NOT FOUND THEN
    RETURN json_build_object('ok',false,'error','Order tidak ditemukan');
  END IF;

  v_fee        := FLOOR(v_order.total_amount * p_rate);
  v_seller_net := v_order.total_amount - v_fee;
  v_seller_id  := v_order.seller_id;

  UPDATE orders SET
    platform_fee    = v_fee,
    commission_rate = p_rate,
    seller_payout   = v_seller_net
  WHERE id = p_order_id;

  INSERT INTO platform_commission(order_id,gross_amount,rate,fee_amount,seller_net,status,settled_at)
  VALUES (p_order_id, v_order.total_amount, p_rate, v_fee, v_seller_net, 'settled', now())
  ON CONFLICT (order_id) DO UPDATE SET
    fee_amount=v_fee, seller_net=v_seller_net, status='settled', settled_at=now();

  UPDATE admin_wallet SET balance=balance+v_fee, updated_at=now();

  UPDATE wallets SET balance=balance+v_seller_net WHERE user_id=v_seller_id;

  INSERT INTO wallet_transactions(wallet_id,type,amount,balance_after,description)
  SELECT w.id,'escrow_release',v_seller_net,w.balance+v_seller_net,
         'Penjualan order #'||LEFT(p_order_id::TEXT,8)||' (komisi '||ROUND(p_rate*100)||'%)'
  FROM wallets w WHERE w.user_id=v_seller_id;

  RETURN json_build_object('ok',true,'gross',v_order.total_amount,'fee',v_fee,'seller_net',v_seller_net);
END;
$$;

-- ============================================================
-- 8. Function — update status order + trigger komisi otomatis
-- ============================================================
CREATE OR REPLACE FUNCTION admin_update_order_status(
  p_order_id   UUID,
  p_new_status TEXT,
  p_note       TEXT DEFAULT ''
)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_rate NUMERIC;
BEGIN
  SELECT COALESCE((SELECT value::NUMERIC FROM app_settings WHERE key='commission_rate'),0.05)
  INTO v_rate;

  UPDATE orders SET status=p_new_status WHERE id=p_order_id;

  IF p_new_status='completed' THEN
    PERFORM fn_process_commission(p_order_id, v_rate);
  END IF;

  INSERT INTO admin_logs(admin_id,action,target_type,target_id,detail)
  VALUES(auth.uid(),'update_order_status','order',p_order_id,
         json_build_object('new_status',p_new_status,'note',p_note));

  RETURN json_build_object('ok',true);
END;
$$;

-- ============================================================
-- 9. Function — ringkasan komisi untuk dashboard
-- ============================================================
CREATE OR REPLACE FUNCTION admin_get_commission_summary()
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_total BIGINT; v_today BIGINT; v_month BIGINT; v_bal BIGINT;
BEGIN
  SELECT
    COALESCE(SUM(fee_amount) FILTER (WHERE status='settled'),0),
    COALESCE(SUM(fee_amount) FILTER (WHERE status='settled' AND created_at::DATE=CURRENT_DATE),0),
    COALESCE(SUM(fee_amount) FILTER (WHERE status='settled' AND created_at>=DATE_TRUNC('month',now())),0)
  INTO v_total, v_today, v_month FROM platform_commission;

  SELECT balance INTO v_bal FROM admin_wallet LIMIT 1;

  RETURN json_build_object(
    'total_commission',v_total,
    'today_commission',v_today,
    'month_commission',v_month,
    'admin_balance',   v_bal
  );
END;
$$;

-- ============================================================
-- 10. RLS — hanya admin yang bisa lihat
-- ============================================================
ALTER TABLE platform_commission ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_wallet        ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_settings        ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin only" ON platform_commission;
DROP POLICY IF EXISTS "admin only" ON admin_wallet;
DROP POLICY IF EXISTS "admin only" ON app_settings;

CREATE POLICY "admin only" ON platform_commission FOR ALL
  USING (EXISTS (SELECT 1 FROM profiles WHERE id=auth.uid() AND role='admin'));
CREATE POLICY "admin only" ON admin_wallet FOR ALL
  USING (EXISTS (SELECT 1 FROM profiles WHERE id=auth.uid() AND role='admin'));
CREATE POLICY "admin only" ON app_settings FOR ALL
  USING (EXISTS (SELECT 1 FROM profiles WHERE id=auth.uid() AND role='admin'));

-- SELESAI ✓
SELECT 'Setup komisi berhasil! Refresh dashboard kamu.' AS status;
