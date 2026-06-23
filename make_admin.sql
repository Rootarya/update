-- =========================================================
--  REKBERIN — Jadikan akun ini sebagai admin pertama
--  Jalankan SETELAH schema_admin.sql berhasil dijalankan.
--  Lokasi: Supabase Dashboard → SQL Editor → New Query
-- =========================================================

update public.profiles
set role = 'admin'
where id = (
  select id from auth.users where email = 'ahmadarya2223@gmail.com'
);

-- Verifikasi hasilnya (harus muncul 1 baris dengan role = 'admin'):
select p.id, p.full_name, p.username, p.role, u.email
from public.profiles p
join auth.users u on u.id = p.id
where u.email = 'ahmadarya2223@gmail.com';
