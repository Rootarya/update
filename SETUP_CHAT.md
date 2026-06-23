# Menyambungkan Fitur Chat Realtime ke Rekberin

Fitur chat antara pembeli & penjual sudah ditambahkan, jalan lewat
**Supabase Realtime** — tidak perlu service pihak ketiga, dan gratis di
tier Supabase yang sama dengan yang sudah kamu pakai.

Total waktu: ±5 menit.

---

## 1. Jalankan Schema Tambahan

1. Buka **Supabase Dashboard → SQL Editor → New Query**
2. Pastikan `schema.sql` (yang lama) sudah pernah dijalankan duluan.
3. Copy-paste isi **`schema_chat.sql`**, lalu klik **Run**.

Ini akan membuat:
- Tabel `conversations` — satu baris per pasangan pembeli↔penjual
- Tabel `messages` — isi pesan, dengan `is_read` untuk badge unread
- Function `get_or_create_conversation()` — dipanggil saat user klik "Chat Penjual"
- View `my_conversations` — daftar inbox dari sudut pandang user yang login
- RLS supaya pesan hanya bisa dibaca oleh 2 orang yang terlibat
- Registrasi tabel `messages` ke publication `supabase_realtime`

> Kalau project Supabase kamu sudah aktif sebelumnya dan publication
> `supabase_realtime` ternyata sudah berisi tabel lain, baris terakhir
> (`alter publication ... add table public.messages;`) tetap aman
> dijalankan — hanya menambahkan satu tabel ke publication yang sama.

---

## 2. Cek Realtime Aktif di Dashboard

1. Buka **Database → Replication** di Supabase Dashboard.
2. Pastikan tabel `messages` muncul dengan toggle **Source** menyala
   di bawah publication `supabase_realtime`. Kalau langkah 1 berhasil,
   ini biasanya sudah otomatis menyala.

---

## 3. File Baru di Frontend

Tidak ada konfigurasi tambahan — `chat.js` memakai `supabaseClient` yang
sama dari `config.js`. Yang perlu dipastikan hanya urutan `<script>` di
setiap halaman:

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="data.js"></script>
<script src="config.js"></script>
<script src="chat.js"></script>   <!-- harus sebelum app.js -->
<script src="app.js"></script>
```

Halaman yang sudah disesuaikan: `index.html`, `products.html`,
`login.html`, `register.html`, `dashboard-pembeli.html`,
`dashboard-penjual.html`.

---

## 4. Cara Pakai (sisi pengguna)

- **Dari modal produk**: klik **Chat Penjual** di halaman Beranda/Produk.
  Kalau belum login, akan diarahkan ke halaman masuk dulu. Setelah login,
  panel chat muncul langsung di dalam modal yang sama (tombol "← Kembali
  ke detail produk" untuk balik ke info beli).
- **Dari dashboard**: tab baru **💬 Pesan** muncul di sidebar dashboard
  pembeli maupun penjual — menampilkan daftar semua percakapan (inbox)
  di kiri, dan jendela chat di kanan. Badge angka muncul untuk pesan
  yang belum dibaca.
- Pesan baru muncul **realtime** tanpa refresh, baik di modal maupun di
  dashboard, selama kedua pihak sedang membuka chat tersebut.

---

## Catatan Desain

- Chat **tidak terikat ke order tertentu** — satu percakapan dipakai
  terus-menerus antara dua user yang sama, apapun produk yang sedang
  dibahas. Kolom `product_id` di `conversations` hanya menyimpan
  "konteks awal/terakhir" supaya inbox bisa menunjukkan produk apa yang
  sedang dibahas — bukan pengikat hard.
- Karena satu akun bisa berperan sebagai pembeli **dan** penjual,
  conversation disimpan netral terhadap role (`user_a_id` / `user_b_id`,
  diurutkan oleh UUID supaya tidak ada pasangan duplikat) — bukan
  `buyer_id` / `seller_id`.
- RLS memastikan pesan hanya bisa dibaca/ditulis oleh dua partisipan
  yang tercatat di baris `conversations` terkait.

## Pengembangan Lanjutan (opsional)

Kalau nanti mau ditingkatkan, beberapa ide lanjutan:
- Notifikasi browser/push saat ada pesan baru sementara user di tab lain.
- Indikator "sedang mengetik…" lewat Supabase Presence.
- Lampiran gambar (screenshot bukti transfer, dll) via Supabase Storage.
- Soft-block / report user dari dalam jendela chat.

Kalau mau salah satu dari ini dikerjakan, tinggal bilang.
