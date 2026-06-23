-- =========================================================
--  REKBERIN — Schema Forum Live Chat Publik (LENGKAP)
--  Aman dijalankan ulang — semua pakai IF EXISTS
-- =========================================================

-- ── 1. TABEL & KOLOM ─────────────────────────────────────
create table if not exists public.forum_messages (
  id          uuid primary key default gen_random_uuid(),
  room_id     text not null,
  sender_id   uuid not null references public.profiles(id) on delete cascade,
  sender_name text not null,
  sender_role text not null default 'pembeli' check (sender_role in ('pembeli','penjual')),
  body        text not null default '',
  image_url   text,
  created_at  timestamptz not null default now()
);

-- Tambah kolom image_url kalau belum ada
alter table public.forum_messages
  add column if not exists image_url text;

create index if not exists forum_messages_room_idx
  on public.forum_messages(room_id, created_at);

-- ── 2. RLS ───────────────────────────────────────────────
alter table public.forum_messages enable row level security;

-- Hapus dulu kalau sudah ada, lalu buat ulang
drop policy if exists "forum_read_all"    on public.forum_messages;
drop policy if exists "forum_insert_auth" on public.forum_messages;
drop policy if exists "forum_delete_own"  on public.forum_messages;

create policy "forum_read_all"
  on public.forum_messages for select using (true);

create policy "forum_insert_auth"
  on public.forum_messages for insert
  with check (auth.uid() = sender_id);

create policy "forum_delete_own"
  on public.forum_messages for delete
  using (auth.uid() = sender_id);

-- ── 3. REALTIME ──────────────────────────────────────────
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'forum_messages'
  ) then
    alter publication supabase_realtime add table public.forum_messages;
  end if;
end;
$$;

-- ── 4. STORAGE BUCKET GAMBAR ─────────────────────────────
insert into storage.buckets (id, name, public)
values ('forum-images', 'forum-images', true)
on conflict (id) do nothing;

drop policy if exists "forum_images_public_read"   on storage.objects;
drop policy if exists "forum_images_auth_upload"   on storage.objects;
drop policy if exists "forum_images_owner_delete"  on storage.objects;

create policy "forum_images_public_read" on storage.objects
  for select using (bucket_id = 'forum-images');

create policy "forum_images_auth_upload" on storage.objects
  for insert with check (
    bucket_id = 'forum-images'
    and auth.role() = 'authenticated'
  );

create policy "forum_images_owner_delete" on storage.objects
  for delete using (
    bucket_id = 'forum-images'
    and auth.uid()::text = (storage.foldername(name))[1]
  );
