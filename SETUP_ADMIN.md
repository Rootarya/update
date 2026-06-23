# Menyambungkan Panel Admin ke Rekberin

Panel admin baru ditambahkan di **`dashboard-admin.html`** — bisa kelola
transaksi (ubah status, force-refund), pengguna (suspend, ubah role,
sesuaikan saldo), produk (nonaktifkan), dan lihat statistik platform.
Semua aksi tercatat di log audit (`admin_logs`).

Total waktu: ±10 menit.

---

## 1. Jalankan Schema Tambahan

1. Buka **Supabase Dashboard → SQL Editor → New Query**
2. Pastikan `schema.sql` (dan `schema_chat.sql` kalau sudah pakai fitur
   chat) sudah pernah dijalankan duluan.
3. Copy-paste isi **`schema_admin.sql`**, lalu klik **Run**.

Ini akan membuat:
- Role baru `admin` (selain `pembeli`/`penjual` yang sudah ada)
- Kolom `is_suspended` & `suspended_reason` di tabel `profiles`
- Tabel `admin_logs` — audit trail setiap aksi admin
- Function `is_admin()` — helper RLS, dipakai semua policy admin
- RPC: `admin_suspend_user`, `admin_change_role`,
  `admin_update_order_status`, `admin_force_refund`,
  `admin_adjust_wallet`, `admin_toggle_product`
- View `admin_stats` (statistik platform) & `admin_orders_view`
  (semua order + nama pembeli/penjual)

---

## 2. Jadikan Akun Kamu Admin

RLS dirancang supaya **hanya admin yang bisa mengubah role orang lain**
lewat RPC — jadi admin pertama harus diset manual lewat SQL Editor:

```sql
update public.profiles
set role = 'admin'
where id = (select id from auth.users where email = 'emailkamu@gmail.com');
```

Ganti `emailkamu@gmail.com` dengan email akun yang sudah kamu daftarkan
di Rekberin. Setelah ini, akun tersebut otomatis diarahkan ke
`dashboard-admin.html` setiap kali login — apapun tab (pembeli/penjual)
yang diklik di halaman login.

---

## 3. Akses Panel Admin

- Login seperti biasa di `login.html`.
- Karena role asli di database sekarang `admin`, sistem akan **override**
  redirect dan mengarahkan ke `dashboard-admin.html` otomatis.
- Kalau mau langsung buka tanpa lewat form login (saat sudah ada sesi
  aktif), buka langsung `dashboard-admin.html` — halaman ini punya guard
  sendiri yang menolak akses kalau role bukan `admin`.

---

## 4. Yang Bisa Dilakukan di Panel Admin

**Tab Ringkasan**
- Statistik: total pembeli/penjual, akun disuspend, produk aktif,
  total/selesai/sengketa/pending order, GMV, revenue platform, dana
  ditahan rekber, total saldo seluruh user.
- Daftar pesanan berstatus **Sengketa** muncul langsung di sini untuk
  ditindak cepat.

**Tab Transaksi**
- Lihat semua order, cari/filter by status.
- Ubah status order langsung lewat dropdown (misal: paksa jadi
  `completed` kalau ada masalah teknis di sisi pembeli).
- **Force Refund** — tombol khusus untuk order yang masih
  `paid`/`processing`/`delivered`/`disputed`. Ini akan: melepas escrow
  penjual, mengembalikan dana ke saldo pembeli, ubah status jadi
  `refunded`, kirim notifikasi ke kedua pihak. **Wajib isi alasan.**

**Tab Pengguna**
- Lihat semua user + saldo wallet mereka.
- Ubah role langsung dari dropdown (pembeli/penjual/admin).
- **Suspend/Aktifkan** — user yang disuspend akan otomatis di-sign-out
  dan ditolak login berikutnya (dicek di `login.html` dan kedua
  dashboard biasa).
- **Sesuaikan Saldo** — nominal positif menambah, negatif mengurangi.
  Wajib isi alasan. Tidak bisa membuat saldo jadi negatif (RPC akan
  menolak otomatis).

**Tab Produk**
- Lihat semua produk dari semua penjual.
- Nonaktifkan produk mencurigakan (hilang dari katalog publik tapi data
  tetap ada, bisa diaktifkan lagi kapan saja).

**Tab Log Aktivitas**
- Riwayat 100 aksi admin terakhir: siapa, apa, kapan, dan detail
  (alasan/nominal/perubahan status) dalam format JSON ringkas.

---

## Catatan Keamanan

- Semua RPC admin **mengecek `is_admin()` di server**, bukan cuma
  menyembunyikan tombol di frontend — jadi walau seseorang mencoba
  memanggil RPC langsung lewat browser console tanpa role admin,
  tetap akan ditolak dengan `{ ok:false, error:"Tidak punya akses admin." }`.
- `admin_adjust_wallet` **wajib** disertai alasan (validasi di level SQL),
  dan tidak akan pernah membuat saldo user menjadi negatif.
- Akun yang disuspend langsung di-sign-out begitu mencoba login lagi —
  dicek dari 3 tempat: `login.html`, `dashboard-pembeli.html`,
  `dashboard-penjual.html`.
- Admin pertama **tidak bisa dibuat dari UI** — sengaja, supaya tidak
  ada celah seseorang menaikkan role dirinya sendiri jadi admin lewat
  bug di frontend. Harus lewat SQL Editor dengan akses service-level ke
  Supabase Dashboard kamu.

## Pengembangan Lanjutan (opsional)

- Export data transaksi/user ke CSV dari tab Transaksi/Pengguna.
- Grafik tren GMV harian/mingguan di tab Ringkasan.
- Multi-level admin (super-admin vs admin biasa dengan izin terbatas).
- Notifikasi otomatis ke admin saat order baru masuk status `disputed`.

Kalau mau salah satu dikerjakan, tinggal bilang.
