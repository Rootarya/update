-- =========================================================
--  REKBERIN — Tambahan Schema: Chat Realtime
--  Jalankan SETELAH schema.sql (di Supabase Dashboard → SQL Editor)
-- =========================================================

-- ── 1. CONVERSATIONS ─────────────────────────────────────
-- Satu conversation = satu pasangan user (apapun role mereka saat ini).
-- product_id hanya konteks "mulai dari produk apa", bukan pengikat hard.
create table if not exists public.conversations (
  id            uuid primary key default gen_random_uuid(),
  user_a_id     uuid not null references public.profiles(id) on delete cascade,
  user_b_id     uuid not null references public.profiles(id) on delete cascade,
  product_id    uuid references public.products(id) on delete set null,
  last_message  text,
  last_message_at timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  constraint different_users check (user_a_id <> user_b_id),
  -- urutan a < b dipaksa di application layer supaya pasangan tidak duplikat
  constraint ordered_pair check (user_a_id < user_b_id)
);

create unique index if not exists conversations_pair_unique
  on public.conversations (user_a_id, user_b_id);

create index if not exists conversations_user_a_idx on public.conversations(user_a_id);
create index if not exists conversations_user_b_idx on public.conversations(user_b_id);

-- ── 2. MESSAGES ───────────────────────────────────────────
create table if not exists public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid not null references public.profiles(id) on delete cascade,
  body            text not null check (char_length(trim(body)) > 0),
  is_read         boolean not null default false,
  created_at      timestamptz not null default now()
);

create index if not exists messages_conversation_idx on public.messages(conversation_id, created_at);
create index if not exists messages_sender_idx on public.messages(sender_id);

-- ── 3. AUTO-UPDATE last_message / last_message_at ────────
create or replace function public.handle_new_message()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.conversations
  set last_message = new.body,
      last_message_at = new.created_at
  where id = new.conversation_id;
  return new;
end;
$$;

drop trigger if exists on_message_created on public.messages;
create trigger on_message_created
  after insert on public.messages
  for each row execute procedure public.handle_new_message();

-- ── 4. RLS ────────────────────────────────────────────────
alter table public.conversations enable row level security;
alter table public.messages      enable row level security;

-- conversations: hanya partisipan yang boleh lihat/buat
create policy "conversations_participant_select" on public.conversations
  for select using (auth.uid() = user_a_id or auth.uid() = user_b_id);

create policy "conversations_participant_insert" on public.conversations
  for insert with check (auth.uid() = user_a_id or auth.uid() = user_b_id);

-- messages: hanya partisipan conversation terkait
create policy "messages_participant_select" on public.messages
  for select using (
    conversation_id in (
      select id from public.conversations
      where auth.uid() = user_a_id or auth.uid() = user_b_id
    )
  );

create policy "messages_participant_insert" on public.messages
  for insert with check (
    auth.uid() = sender_id
    and conversation_id in (
      select id from public.conversations
      where auth.uid() = user_a_id or auth.uid() = user_b_id
    )
  );

create policy "messages_participant_update" on public.messages
  for update using (
    conversation_id in (
      select id from public.conversations
      where auth.uid() = user_a_id or auth.uid() = user_b_id
    )
  );

-- ── 5. RPC: get-or-create conversation ────────────────────
-- Dipanggil dari client saat user klik "Chat Penjual".
-- Memaksa urutan (user_a_id < user_b_id) supaya tidak ada pasangan duplikat,
-- dan otomatis attach product_id konteks jika conversation baru dibuat.
create or replace function public.get_or_create_conversation(
  p_other_user_id uuid,
  p_product_id uuid default null
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_a uuid;
  v_b uuid;
  v_conv_id uuid;
begin
  if v_me is null then
    raise exception 'Tidak terautentikasi.';
  end if;
  if v_me = p_other_user_id then
    raise exception 'Tidak bisa membuat percakapan dengan diri sendiri.';
  end if;

  if v_me < p_other_user_id then
    v_a := v_me; v_b := p_other_user_id;
  else
    v_a := p_other_user_id; v_b := v_me;
  end if;

  select id into v_conv_id from public.conversations
  where user_a_id = v_a and user_b_id = v_b;

  if v_conv_id is null then
    insert into public.conversations (user_a_id, user_b_id, product_id)
    values (v_a, v_b, p_product_id)
    returning id into v_conv_id;
  elsif p_product_id is not null then
    -- update konteks produk ke produk yang baru dibahas (opsional, boleh dihapus kalau tidak mau)
    update public.conversations set product_id = p_product_id where id = v_conv_id;
  end if;

  return v_conv_id;
end;
$$;

-- ── 6. VIEW: daftar percakapan untuk inbox ───────────────
-- Mengembalikan lawan bicara + info produk + unread count, dari sudut pandang auth.uid()
create or replace view public.my_conversations as
select
  c.id                as conversation_id,
  c.last_message,
  c.last_message_at,
  c.product_id,
  pr.title             as product_title,
  pr.icon              as product_icon,
  other.id              as other_user_id,
  coalesce(other.full_name, other.username, 'Pengguna Rekberin') as other_name,
  other.avatar_url      as other_avatar,
  (
    select count(*) from public.messages m
    where m.conversation_id = c.id
      and m.sender_id <> auth.uid()
      and m.is_read = false
  ) as unread_count
from public.conversations c
join public.profiles other
  on other.id = (case when c.user_a_id = auth.uid() then c.user_b_id else c.user_a_id end)
left join public.products pr on pr.id = c.product_id
where c.user_a_id = auth.uid() or c.user_b_id = auth.uid()
order by c.last_message_at desc;

-- ── 7. ENABLE REALTIME ───────────────────────────────────
-- Aktifkan replication untuk tabel messages supaya client bisa subscribe.
-- (Kalau project Supabase kamu baru, publication "supabase_realtime" sudah ada bawaan)
alter publication supabase_realtime add table public.messages;
