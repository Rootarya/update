# Menyambungkan Pembayaran Asli (Midtrans) ke Rekberin

Status sebelumnya: tombol **Beli Sekarang** cuma menampilkan toast "demo".
Sekarang kodenya sudah diubah supaya tombol itu memanggil **Edge Function
Supabase**, yang lalu membuat transaksi di **Midtrans** dan membuka popup
pembayaran asli (Snap).

Kenapa harus lewat Edge Function dan tidak langsung dari browser? Karena
membuat transaksi Midtrans butuh **Server Key** yang harus dirahasiakan —
kalau ditaruh di kode browser, siapa pun bisa mencurinya dan membuat
transaksi atas nama kamu.

Total waktu: ±15 menit.

---

## 1. Buat Akun Midtrans (Sandbox dulu)

1. Daftar di **https://dashboard.midtrans.com/register**
2. Setelah masuk, pastikan kamu berada di mode **Sandbox** (switch di kiri
   atas dashboard) — ini buat testing, belum pakai uang asli.
3. Buka **Settings → Access Keys**. Catat dua nilai ini:
   - **Client Key** (`SB-Mid-client-...`) — boleh publik, dipakai di browser
   - **Server Key** (`SB-Mid-server-...`) — RAHASIA, jangan taruh di kode
     browser manapun

---

## 2. Pasang Client Key di Frontend

Buka `config.js` dan `index.html` + `products.html`, ganti semua tulisan
`GANTI_DENGAN_MIDTRANS_CLIENT_KEY_KAMU` dengan **Client Key** kamu.

Di `index.html` / `products.html` ada baris:
```html
<script src="https://app.sandbox.midtrans.com/snap/snap.js" data-client-key="GANTI_DENGAN_MIDTRANS_CLIENT_KEY_KAMU"></script>
```

---

## 3. Install Supabase CLI & Login

```bash
npm install -g supabase
supabase login
```

Hubungkan ke project Supabase kamu (Project Ref ada di URL dashboard
Supabase, contoh: `aktgklmbrxwohugrfjrr`):

```bash
supabase link --project-ref aktgklmbrxwohugrfjrr
```

---

## 4. Set Rahasia (Secrets) di Supabase

**Server Key** Midtrans disimpan di Supabase, bukan di kode:

```bash
supabase secrets set MIDTRANS_SERVER_KEY=SB-Mid-server-xxxxxxxxxxxx
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, dan `SUPABASE_SERVICE_ROLE_KEY` otomatis
tersedia di Edge Function, tidak perlu di-set manual.

---

## 5. Deploy Edge Functions

Dua fungsi baru sudah dibuat di folder `supabase/functions/`:

- **`create-transaction`** — dipanggil saat user klik "Beli Sekarang"
- **`midtrans-webhook`** — dipanggil oleh Midtrans saat status pembayaran berubah

```bash
supabase functions deploy create-transaction
supabase functions deploy midtrans-webhook --no-verify-jwt
```

> `--no-verify-jwt` dipakai khusus untuk webhook karena yang memanggilnya
> adalah server Midtrans, bukan user yang login.

---

## 6. Daftarkan URL Webhook di Midtrans

1. Setelah deploy, Supabase akan menampilkan URL functions, bentuknya:
   `https://aktgklmbrxwohugrfjrr.supabase.co/functions/v1/midtrans-webhook`
2. Buka **Midtrans Dashboard → Settings → Configuration**
3. Tempel URL itu di kolom **Payment Notification URL**, simpan.

---

## 7. Sesuaikan Tabel `orders` (kalau perlu)

Edge Function `create-transaction` mengasumsikan tabel `orders` punya kolom:
`id`, `user_id`, `product_id`, `amount`, `status`. Dan tabel `products` punya
kolom `id`, `title`, `price`. Kalau nama kolom di `schema.sql` kamu beda,
sesuaikan query di `supabase/functions/create-transaction/index.ts`.

---

## 8. Coba di Sandbox

1. Jalankan situs lewat `localhost` (lihat SETUP.md langkah 4).
2. Daftar/masuk akun.
3. Buka produk apa saja → **Beli Sekarang** → popup Snap muncul.
4. Di sandbox, pakai **kartu test Midtrans** (bukan kartu asli):
   - Nomor: `4811 1111 1111 1114`, exp: bulan/tahun manapun di masa depan,
     CVV: `123`, OTP: `112233`
   - Atau pilih metode lain (GoPay, dll) — sandbox punya simulator sendiri.
5. Setelah sukses, cek tabel `orders` di Supabase — status harus berubah
   jadi `dibayar` (lewat webhook).

---

## 9. Pindah ke Production (uang asli)

Setelah testing di sandbox lancar:

1. Di Midtrans Dashboard, aktifkan akun production (perlu verifikasi
   bisnis/KYC — ini proses dari pihak Midtrans, butuh beberapa hari).
2. Ambil **Client Key** dan **Server Key** versi production (`Mid-client-...`
   dan `Mid-server-...`, tanpa awalan `SB-`).
3. Update:
   - `config.js` & `data-client-key` di HTML → Client Key production
   - `supabase secrets set MIDTRANS_SERVER_KEY=Mid-server-...`
   - Di `supabase/functions/create-transaction/index.ts`, ganti
     `MIDTRANS_SNAP_URL` ke `https://app.midtrans.com/snap/v1/transactions`
     (hilangkan `.sandbox`)
4. Deploy ulang: `supabase functions deploy create-transaction`
5. Daftarkan ulang webhook URL production di dashboard Midtrans mode Production.

---

## Catatan soal "Rekber"

Webhook saat ini mengubah status order jadi `dibayar` begitu Midtrans
konfirmasi dana masuk — ini **bukan** "selesai". Supaya konsep rekber-nya
benar (dana ditahan sampai pembeli konfirmasi terima barang), kamu masih
perlu:

- Tombol "Konfirmasi Diterima" di sisi pembeli yang mengubah status jadi
  `selesai`
- Proses pencairan dana ke penjual setelah status `selesai` (lewat
  Midtrans Payout API atau transfer manual oleh admin)

Kalau mau, bagian ini bisa dikerjakan berikutnya — tinggal bilang.
