/* =========================================================
   REKBERIN — Perbaikan bug wallet/refund/commission
   Jalankan SELURUH isi file ini di Supabase SQL Editor.
   Setiap CREATE OR REPLACE akan menimpa function lama dengan
   nama yang sama, jadi aman dijalankan langsung di production.
   ========================================================= */

-- =========================================================
-- 0. HELPER: pastikan wallet user selalu ada (auto-create jika belum)
--    Dipakai oleh semua function di bawah supaya tidak ada lagi
--    "UPDATE wallets WHERE id = NULL" yang diam-diam tidak ngapa-ngapain.
-- =========================================================
CREATE OR REPLACE FUNCTION public.fn_get_or_create_wallet(p_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_wallet_id uuid;
BEGIN
  SELECT id INTO v_wallet_id FROM wallets WHERE user_id = p_user_id;
  IF v_wallet_id IS NULL THEN
    INSERT INTO wallets (user_id, balance, total_in, total_out, escrow_hold)
    VALUES (p_user_id, 0, 0, 0, 0)
    RETURNING id INTO v_wallet_id;
  END IF;
  RETURN v_wallet_id;
END;
$$;


-- =========================================================
-- 1. admin_adjust_wallet
--    Bug lama: caller di frontend hanya cek error level RPC, bukan
--    data.ok — sudah diperbaiki di sisi frontend (dashboard-admin.html).
--    Perbaikan di SQL: pastikan wallet selalu ada via fn_get_or_create_wallet.
-- =========================================================
CREATE OR REPLACE FUNCTION public.admin_adjust_wallet(
  p_user_id uuid,
  p_amount  bigint,
  p_reason  text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_wallet_id   uuid;
  v_new_balance bigint;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN json_build_object('ok', false, 'error', 'Tidak punya akses admin.');
  END IF;
  IF p_amount = 0 THEN
    RETURN json_build_object('ok', false, 'error', 'Jumlah tidak boleh nol.');
  END IF;
  IF p_reason IS NULL OR trim(p_reason) = '' THEN
    RETURN json_build_object('ok', false, 'error', 'Alasan wajib diisi untuk audit.');
  END IF;

  -- Auto-create wallet kalau belum ada (alih-alih diam-diam gagal)
  v_wallet_id := public.fn_get_or_create_wallet(p_user_id);

  UPDATE wallets
  SET balance   = balance + p_amount,
      total_in  = total_in  + (CASE WHEN p_amount > 0 THEN p_amount ELSE 0 END),
      total_out = total_out + (CASE WHEN p_amount < 0 THEN -p_amount ELSE 0 END),
      updated_at = now()
  WHERE id = v_wallet_id
  RETURNING balance INTO v_new_balance;

  IF v_new_balance < 0 THEN
    RAISE EXCEPTION 'Saldo tidak boleh negatif (hasil akhir: %).', v_new_balance;
  END IF;

  INSERT INTO wallet_transactions (wallet_id, type, amount, balance_after, description)
  VALUES (v_wallet_id, CASE WHEN p_amount > 0 THEN 'topup' ELSE 'withdrawal' END,
    abs(p_amount), v_new_balance, 'Penyesuaian admin — ' || p_reason);

  INSERT INTO admin_logs (admin_id, action, target_type, target_id, detail)
  VALUES (auth.uid(), 'adjust_wallet', 'wallet', v_wallet_id,
    jsonb_build_object('amount', p_amount, 'reason', p_reason, 'new_balance', v_new_balance));

  INSERT INTO notifications (user_id, title, body, type)
  VALUES (p_user_id,
    CASE WHEN p_amount > 0 THEN '💰 Saldo Ditambahkan' ELSE '⚠️ Saldo Dikurangi' END,
    'Saldo kamu disesuaikan admin sebesar Rp ' || to_char(abs(p_amount), 'FM999,999,999') ||
    '. Alasan: ' || p_reason, 'info');

  RETURN json_build_object('ok', true, 'new_balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok', false, 'error', sqlerrm);
END;
$$;


-- =========================================================
-- 2. admin_force_refund
--    Bug lama: tidak cek apakah buyer/seller wallet ada → kalau
--    NULL, UPDATE diam-diam 0 baris dan tetap return ok:true.
--    Perbaikan: pakai fn_get_or_create_wallet + bungkus exception.
-- =========================================================
CREATE OR REPLACE FUNCTION public.admin_force_refund(
  p_order_id uuid,
  p_reason   text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_order            orders%rowtype;
  v_buyer_wallet_id  uuid;
  v_seller_wallet_id uuid;
  v_new_balance      bigint;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN json_build_object('ok', false, 'error', 'Tidak punya akses admin.');
  END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Pesanan tidak ditemukan.');
  END IF;

  IF v_order.status NOT IN ('paid','processing','delivered','disputed') THEN
    RETURN json_build_object('ok', false, 'error', 'Status pesanan tidak bisa direfund (' || v_order.status || ').');
  END IF;

  -- Auto-create wallet kalau buyer/seller belum punya (tidak lagi diam-diam gagal)
  v_buyer_wallet_id  := public.fn_get_or_create_wallet(v_order.buyer_id);
  v_seller_wallet_id := public.fn_get_or_create_wallet(v_order.seller_id);

  UPDATE wallets
  SET escrow_hold = GREATEST(escrow_hold - v_order.total_amount, 0),
      updated_at = now()
  WHERE id = v_seller_wallet_id;

  UPDATE wallets
  SET balance   = balance + v_order.total_amount,
      total_in  = total_in + v_order.total_amount,
      updated_at = now()
  WHERE id = v_buyer_wallet_id
  RETURNING balance INTO v_new_balance;

  INSERT INTO wallet_transactions (wallet_id, type, amount, balance_after, description, ref_order_id)
  VALUES (
    v_buyer_wallet_id, 'refund', v_order.total_amount, v_new_balance,
    'Refund admin - ' || v_order.product_title || COALESCE(' (' || p_reason || ')', ''),
    p_order_id
  );

  UPDATE orders SET status = 'refunded', updated_at = now() WHERE id = p_order_id;

  INSERT INTO admin_logs (admin_id, action, target_type, target_id, detail)
  VALUES (
    auth.uid(), 'force_refund', 'order', p_order_id,
    jsonb_build_object('amount', v_order.total_amount, 'reason', p_reason)
  );

  INSERT INTO notifications (user_id, title, body, type, ref_order_id)
  VALUES (
    v_order.buyer_id, 'Dana Dikembalikan',
    'Pesanan "' || v_order.product_title || '" direfund oleh admin.' || COALESCE(' Alasan: ' || p_reason, ''),
    'info', p_order_id
  );

  INSERT INTO notifications (user_id, title, body, type, ref_order_id)
  VALUES (
    v_order.seller_id, 'Pesanan Direfund Admin',
    'Pesanan "' || v_order.product_title || '" direfund ke pembeli oleh admin.' || COALESCE(' Alasan: ' || p_reason, ''),
    'warning', p_order_id
  );

  RETURN json_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok', false, 'error', sqlerrm);
END;
$$;


-- =========================================================
-- 3. fn_process_commission
--    Bug lama:
--      a) Tidak cek wallet seller ada → diam-diam 0 baris ter-update.
--      b) UPDATE admin_wallet tanpa WHERE → salah kalau >1 baris.
--      c) Tidak ada exception handling.
--      d) Caller (admin_update_order_status) pakai PERFORM, jadi
--         walau function ini gagal, hasilnya diabaikan total.
--    Perbaikan: tambah parameter p_admin_wallet_id (singleton wallet
--    diambil via subquery aman), auto-create wallet seller, exception.
-- =========================================================
CREATE OR REPLACE FUNCTION public.fn_process_commission(
  p_order_id uuid,
  p_rate     numeric
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_order          RECORD;
  v_fee            BIGINT;
  v_seller_net     BIGINT;
  v_seller_id      UUID;
  v_seller_wallet_id uuid;
  v_admin_wallet_id  uuid;
BEGIN
  SELECT o.*, p.seller_id
    INTO v_order
  FROM orders o
  JOIN products p ON p.id = o.product_id
  WHERE o.id = p_order_id;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Order tidak ditemukan');
  END IF;

  v_fee        := FLOOR(v_order.total_amount * p_rate);
  v_seller_net := v_order.total_amount - v_fee;
  v_seller_id  := v_order.seller_id;

  -- Auto-create wallet seller kalau belum ada
  v_seller_wallet_id := public.fn_get_or_create_wallet(v_seller_id);

  -- Ambil 1 baris admin_wallet secara eksplisit (hindari UPDATE tanpa WHERE).
  -- Asumsi admin_wallet adalah singleton table; kalau lebih dari 1 baris,
  -- ambil yang paling lama dibuat sebagai "kas utama".
  SELECT id INTO v_admin_wallet_id FROM admin_wallet ORDER BY created_at ASC LIMIT 1;
  IF v_admin_wallet_id IS NULL THEN
    RETURN json_build_object('ok', false, 'error', 'admin_wallet belum ada row sama sekali.');
  END IF;

  UPDATE orders SET
    platform_fee    = v_fee,
    commission_rate = p_rate,
    seller_payout   = v_seller_net
  WHERE id = p_order_id;

  INSERT INTO platform_commission(order_id,gross_amount,rate,fee_amount,seller_net,status,settled_at)
  VALUES (p_order_id, v_order.total_amount, p_rate, v_fee, v_seller_net, 'settled', now())
  ON CONFLICT (order_id) DO UPDATE SET
    fee_amount=v_fee, seller_net=v_seller_net, status='settled', settled_at=now();

  UPDATE admin_wallet SET balance = balance + v_fee, updated_at = now()
  WHERE id = v_admin_wallet_id;

  UPDATE wallets SET balance = balance + v_seller_net, updated_at = now()
  WHERE id = v_seller_wallet_id;

  INSERT INTO wallet_transactions(wallet_id,type,amount,balance_after,description)
  SELECT w.id, 'escrow_release', v_seller_net, w.balance, -- balance sudah ter-update di atas
         'Penjualan order #'||LEFT(p_order_id::TEXT,8)||' (komisi '||ROUND(p_rate*100)||'%)'
  FROM wallets w WHERE w.id = v_seller_wallet_id;

  RETURN json_build_object('ok', true, 'gross', v_order.total_amount, 'fee', v_fee, 'seller_net', v_seller_net);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok', false, 'error', sqlerrm);
END;
$$;


-- =========================================================
-- 4. admin_update_order_status
--    Bug lama: pakai PERFORM fn_process_commission(...) sehingga
--    hasil (ok/error) dari proses komisi diabaikan total — order
--    bisa "completed" sukses padahal dana TIDAK cair ke seller.
--    Perbaikan: tangkap hasilnya, dan kalau gagal, JANGAN anggap
--    sukses — kembalikan error supaya admin tahu & bisa retry.
-- =========================================================
CREATE OR REPLACE FUNCTION public.admin_update_order_status(
  p_order_id   uuid,
  p_new_status text,
  p_note       text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rate   NUMERIC;
  v_commission_result json;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN json_build_object('ok', false, 'error', 'Tidak punya akses admin.');
  END IF;

  SELECT COALESCE((SELECT value::NUMERIC FROM app_settings WHERE key='commission_rate'),0.05)
  INTO v_rate;

  UPDATE orders SET status = p_new_status WHERE id = p_order_id;

  IF p_new_status = 'completed' THEN
    -- Tangkap hasilnya — JANGAN pakai PERFORM, supaya kegagalan
    -- pencairan dana ke seller tidak diam-diam diabaikan.
    SELECT public.fn_process_commission(p_order_id, v_rate) INTO v_commission_result;

    IF NOT (v_commission_result->>'ok')::boolean THEN
      -- Rollback status order, supaya order tidak "completed" tanpa
      -- dana benar-benar cair ke seller. Admin akan lihat error asli.
      RAISE EXCEPTION 'Gagal proses komisi: %', v_commission_result->>'error';
    END IF;
  END IF;

  INSERT INTO admin_logs(admin_id,action,target_type,target_id,detail)
  VALUES(auth.uid(),'update_order_status','order',p_order_id,
         json_build_object('new_status',p_new_status,'note',p_note));

  RETURN json_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok', false, 'error', sqlerrm);
END;
$$;
