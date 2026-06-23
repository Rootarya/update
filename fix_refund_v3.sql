-- Drop view lama dulu, lalu recreate
DROP VIEW IF EXISTS admin_orders_view;

CREATE OR REPLACE VIEW admin_orders_view AS
SELECT
  o.id,
  o.status,
  o.total_amount,
  o.platform_fee,
  o.seller_payout,
  o.seller_receives,
  o.quantity,
  o.product_price,
  o.commission_rate,
  o.buyer_note,
  o.delivery_note,
  o.midtrans_order_id,
  o.created_at,
  o.updated_at,
  o.delivered_at,
  o.completed_at,
  o.buyer_id,
  o.seller_id,
  o.product_id,
  o.product_title,
  buyer.username  AS buyer_username,
  buyer.full_name AS buyer_name,
  seller.username AS seller_username,
  seller.full_name AS seller_name
FROM orders o
LEFT JOIN profiles buyer  ON buyer.id  = o.buyer_id
LEFT JOIN profiles seller ON seller.id = o.seller_id;
