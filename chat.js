/* =========================================================
   REKBERIN — chat.js
   Modul chat realtime antar pembeli & penjual via Supabase Realtime.
   Dipakai di: modal produk (chat cepat ke penjual) dan dashboard
   (tab "Pesan" dengan daftar percakapan).
   ========================================================= */

let chatChannel = null;          // Supabase realtime channel aktif
let chatActiveConvId = null;     // conversation_id yang sedang dibuka
let chatMe = null;               // { id, email } user saat ini

/* ---------- util ---------- */
function chatTimeLabel(iso){
  const d = new Date(iso);
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  return sameDay
    ? d.toLocaleTimeString("id-ID", { hour:"2-digit", minute:"2-digit" })
    : d.toLocaleDateString("id-ID", { day:"numeric", month:"short" }) + " " +
      d.toLocaleTimeString("id-ID", { hour:"2-digit", minute:"2-digit" });
}

function chatBubbleHTML(msg, isMine){
  return `
  <div class="chat-row ${isMine ? "mine" : "theirs"}">
    <div class="chat-bubble">
      <span class="chat-text"></span>
      <span class="chat-time">${chatTimeLabel(msg.created_at)}</span>
    </div>
  </div>`;
}

/* Render bubble dengan text di-escape via textContent (hindari XSS dari pesan user lain) */
function renderChatBubble(container, msg, isMine){
  const wrap = document.createElement("div");
  wrap.className = `chat-row ${isMine ? "mine" : "theirs"}`;
  wrap.innerHTML = `<div class="chat-bubble"><span class="chat-text"></span><span class="chat-time">${chatTimeLabel(msg.created_at)}</span></div>`;
  wrap.querySelector(".chat-text").textContent = msg.body;
  container.appendChild(wrap);
}

/* ---------- core: open / subscribe to a conversation ----------
   targetEl: container element where messages get rendered
   conversationId: uuid
   meId: current user's id (to know which side is "mine") */
async function chatLoadAndSubscribe(conversationId, targetEl, meId){
  chatActiveConvId = conversationId;

  // teardown previous subscription if switching conversations
  if(chatChannel){
    await supabaseClient.removeChannel(chatChannel);
    chatChannel = null;
  }

  targetEl.innerHTML = `<div class="chat-loading">Memuat pesan…</div>`;

  const { data: messages, error } = await supabaseClient
    .from("messages")
    .select("*")
    .eq("conversation_id", conversationId)
    .order("created_at", { ascending: true })
    .limit(200);

  if(error){
    targetEl.innerHTML = `<div class="chat-loading">Gagal memuat pesan: ${error.message}</div>`;
    return;
  }

  targetEl.innerHTML = "";
  if(!messages.length){
    targetEl.innerHTML = `<div class="chat-empty">Belum ada pesan. Mulai percakapan di bawah 👇</div>`;
  } else {
    messages.forEach(m => renderChatBubble(targetEl, m, m.sender_id === meId));
    targetEl.scrollTop = targetEl.scrollHeight;
  }

  // mark incoming (not-mine) messages as read
  const unreadIds = messages.filter(m => m.sender_id !== meId && !m.is_read).map(m => m.id);
  if(unreadIds.length){
    supabaseClient.from("messages").update({ is_read: true }).in("id", unreadIds);
  }

  // subscribe realtime to new messages in this conversation
  chatChannel = supabaseClient
    .channel("chat-" + conversationId)
    .on("postgres_changes", {
      event: "INSERT", schema: "public", table: "messages",
      filter: `conversation_id=eq.${conversationId}`,
    }, payload => {
      const m = payload.new;
      // avoid double-render if this is our own optimistic message
      if(targetEl.querySelector(`[data-msg-id="${m.id}"]`)) return;
      const emptyNote = targetEl.querySelector(".chat-empty");
      if(emptyNote) emptyNote.remove();
      renderChatBubble(targetEl, m, m.sender_id === meId);
      targetEl.scrollTop = targetEl.scrollHeight;
      if(m.sender_id !== meId){
        supabaseClient.from("messages").update({ is_read: true }).eq("id", m.id);
      }
    })
    .subscribe();
}

/* ---------- send a message ---------- */
async function chatSendMessage(conversationId, senderId, body){
  const text = body.trim();
  if(!text) return { ok:false };
  const { data, error } = await supabaseClient
    .from("messages")
    .insert({ conversation_id: conversationId, sender_id: senderId, body: text })
    .select()
    .single();
  if(error) return { ok:false, error };
  return { ok:true, message:data };
}

/* ---------- wire a send form (input + button) to a target conversation ---------- */
function chatWireComposer(formEl, inputEl, targetEl, getConvId, meId){
  formEl.addEventListener("submit", async e => {
    e.preventDefault();
    const text = inputEl.value;
    if(!text.trim()) return;
    const convId = getConvId();
    if(!convId) return;

    inputEl.value = "";
    inputEl.focus();

    const res = await chatSendMessage(convId, meId, text);
    if(!res.ok){
      showToast("Gagal mengirim pesan: " + (res.error?.message || "coba lagi."));
      inputEl.value = text; // restore so user doesn't lose what they typed
      return;
    }
    // optimistic render (tag with data-msg-id so the realtime echo is skipped)
    const emptyNote = targetEl.querySelector(".chat-empty");
    if(emptyNote) emptyNote.remove();
    const wrap = document.createElement("div");
    wrap.className = "chat-row mine";
    wrap.setAttribute("data-msg-id", res.message.id);
    wrap.innerHTML = `<div class="chat-bubble"><span class="chat-text"></span><span class="chat-time">${chatTimeLabel(res.message.created_at)}</span></div>`;
    wrap.querySelector(".chat-text").textContent = res.message.body;
    targetEl.appendChild(wrap);
    targetEl.scrollTop = targetEl.scrollHeight;
  });
}

/* ---------- get-or-create conversation with another user ---------- */
async function chatOpenWith(otherUserId, productId = null){
  const { data, error } = await supabaseClient.rpc("get_or_create_conversation", {
    p_other_user_id: otherUserId,
    p_product_id: productId,
  });
  if(error){ throw new Error(error.message); }
  return data; // conversation_id
}

/* ---------- inbox list (for dashboard "Pesan" tab) ---------- */
async function chatLoadInbox(){
  const { data, error } = await supabaseClient
    .from("my_conversations")
    .select("*")
    .order("last_message_at", { ascending:false });
  if(error) throw new Error(error.message);
  return data || [];
}

function chatInboxItemHTML(c, isActive){
  const initial = (c.other_name || "?").charAt(0).toUpperCase();
  return `
  <button class="chat-inbox-item ${isActive ? "active" : ""}" data-conv-id="${c.conversation_id}" data-other-id="${c.other_user_id}">
    <div class="chat-avatar">${initial}</div>
    <div class="chat-inbox-info">
      <div class="chat-inbox-top">
        <span class="chat-inbox-name"></span>
        ${c.unread_count > 0 ? `<span class="chat-unread-dot">${c.unread_count}</span>` : ""}
      </div>
      <div class="chat-inbox-preview"></div>
      ${c.product_title ? `<div class="chat-inbox-context">${c.product_icon||"📦"} ${c.product_title}</div>` : ""}
    </div>
  </button>`;
}

/* renders inbox list into a container, escaping name/preview safely */
function renderChatInbox(container, conversations, activeId, onSelect){
  if(!conversations.length){
    container.innerHTML = `<div class="chat-empty">Belum ada percakapan. Mulai chat dari halaman produk.</div>`;
    return;
  }
  container.innerHTML = "";
  conversations.forEach(c => {
    const el = document.createElement("div");
    el.innerHTML = chatInboxItemHTML(c, c.conversation_id === activeId);
    const btn = el.firstElementChild;
    btn.querySelector(".chat-inbox-name").textContent = c.other_name;
    btn.querySelector(".chat-inbox-preview").textContent = c.last_message || "Belum ada pesan";
    btn.addEventListener("click", () => onSelect(c));
    container.appendChild(btn);
  });
}
