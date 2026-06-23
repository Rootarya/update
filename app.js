/* =========================================================
   REKBERIN — shared behaviors
   ========================================================= */

/* ---------- fallback gradient palette for products without colors ---------- */
const FALLBACK_GRAD = ["#16A37A", "#0E7C5B"];

/* ---------- biaya admin / komisi platform ----------
   Dibaca dari Supabase → tabel app_settings (key: "commission_rate").
   Nilai disimpan sebagai desimal, misal 0.01 = 1%, 0.05 = 5%.
   Cache di memori selama sesi agar tidak terlalu banyak request.
   Default fallback: 5%, min Rp 500, maks tanpa batas. */
let _commissionCache = null; // { rate: number, fetchedAt: timestamp }

async function getAdminFeeSettings(){
  // Pakai cache kalau masih fresh (< 5 menit)
  if(_commissionCache && (Date.now() - _commissionCache.fetchedAt < 5 * 60 * 1000)){
    return _commissionCache.settings;
  }
  try{
    if(supabaseClient){
      const { data, error } = await supabaseClient
        .from("app_settings")
        .select("value")
        .eq("key", "commission_rate")
        .maybeSingle();
      if(!error && data){
        const rate = parseFloat(data.value) * 100; // desimal -> persen: 0.01 -> 1
        const settings = { rate: isNaN(rate) ? 5 : rate, min: 0, max: 0 }; // min=0, tidak ada minimum fee
        _commissionCache = { settings, fetchedAt: Date.now() };
        return settings;
      }
    }
  } catch(e){ console.warn("Gagal ambil commission rate dari Supabase:", e.message); }
  return { rate: 5, min: 0, max: 0 }; // fallback default 5%, tanpa minimum fee
}

async function calcAdminFee(productPrice){
  const cfg = await getAdminFeeSettings();
  const fee = productPrice * (cfg.rate / 100);
  if(cfg.max > 0 && fee > cfg.max) return Math.round(cfg.max);
  return Math.round(fee); // tidak ada minimum fee, murni persentase
}
async function buyerTotal(productPrice){
  return productPrice + await calcAdminFee(productPrice);
}

/* ---------- fetch live products from Supabase ----------
   Converts rows from public.products (joined with seller name)
   into the shape app.js's cardHTML()/openModal() expect:
   { id, title, price, cat, sub, seller, rating, sold, icon, grad, badge } */
async function fetchProductsFromSupabase(){
  if(!supabaseClient) return [];
  try{
    const { data, error } = await supabaseClient
      .from("products")
      .select("id,title,price,category,subcategory,icon,grad_start,grad_end,badge,sold_count,rating_sum,rating_count,seller_id,is_active,description,stock,photos,cover_image,profiles:seller_id(full_name,username)")
      .eq("is_active", true)
      .order("created_at", { ascending:false });

    if(error) throw error;

    return (data||[]).map(p => ({
      id:        p.id,
      title:     p.title,
      price:     p.price,
      cat:       p.category,
      sub:       p.subcategory,
      sellerId:  p.seller_id,
      seller:    p.profiles?.username ? "@" + p.profiles.username : (p.profiles?.full_name || "Penjual Rekberin"),
      sellerEmail: p.profiles?.username || p.profiles?.full_name || "Penjual",
      rating:    p.rating_count > 0 ? (p.rating_sum / p.rating_count) : 5,
      sold:      p.sold_count || 0,
      icon:      p.icon || "📦",
      grad:      (p.grad_start && p.grad_end) ? [p.grad_start, p.grad_end] : FALLBACK_GRAD,
      badge:     p.badge || "Instan",
      description: p.description || "",
      stock:     p.stock ?? null,
      photos:    Array.isArray(p.photos) ? p.photos : (p.cover_image ? [p.cover_image] : []),
    }));
  } catch(e){
    console.error("Gagal memuat produk:", e.message);
    return [];
  }
}

/* Loads products into the global PRODUCTS array (used by openModal & grids).
   Call this once on page load before rendering any grid. */
async function loadProducts(){
  const items = await fetchProductsFromSupabase();
  PRODUCTS.length = 0;
  PRODUCTS.push(...items);
  return PRODUCTS;
}

/* ---------- header session sync ----------
   Swaps the "Masuk / Daftar" buttons for a greeting + logout link
   once a Supabase session is detected. Safe to call on any page —
   does nothing if supabaseClient isn't ready or no .header-actions exists. */
async function syncHeaderAuth(){
  if(!supabaseClient) return;
  const actions = document.querySelector(".header-actions");
  if(!actions) return;

  try{
    const { data:{ session } } = await supabaseClient.auth.getSession();
    if(!session) return; // leave default Masuk/Daftar buttons as-is

    // Ambil username dari profiles, jangan pakai email (rawan & tidak aman)
    let displayName = "Pengguna";
    try {
      const { data: profile } = await supabaseClient
        .from("profiles")
        .select("username, full_name")
        .eq("id", session.user.id)
        .single();
      if(profile?.username) displayName = "@" + profile.username;
      else if(profile?.full_name) displayName = profile.full_name;
    } catch(e) { /* fallback ke default */ }

    const menuBtn = actions.querySelector(".menu-toggle");
    actions.innerHTML = `
      <span style="color:rgba(255,255,255,.7);font-size:13px;margin-right:4px;white-space:nowrap;">👋 ${displayName}</span>
      <a href="#" id="navLogout" class="btn btn-ghost-light btn-sm">Keluar</a>`;
    if(menuBtn) actions.appendChild(menuBtn);

    document.getElementById("navLogout")?.addEventListener("click", async e => {
      e.preventDefault();
      await supabaseClient.auth.signOut();
      localStorage.removeItem("rekberin_role");
      window.location.href = "index.html";
    });
  } catch(e){
    console.error("Gagal sinkron sesi:", e.message);
  }
}

/* ---------- mobile drawer ---------- */
function openDrawer(){ document.getElementById("mobileDrawer")?.classList.add("open"); }
function closeDrawer(){ document.getElementById("mobileDrawer")?.classList.remove("open"); }

/* ---------- toast ---------- */
let toastTimer;
function showToast(message){
  let el = document.getElementById("toast");
  if(!el){
    el = document.createElement("div");
    el.id = "toast";
    el.className = "toast";
    el.innerHTML = '<span class="dot"></span><span id="toastMsg"></span>';
    document.body.appendChild(el);
  }
  document.getElementById("toastMsg").textContent = message;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(()=> el.classList.remove("show"), 3200);
}

/* ---------- voucher card markup ---------- */
async function cardHTML(p){
  const grad  = `linear-gradient(135deg, ${p.grad[0]}, ${p.grad[1]})`;
  const fee   = await calcAdminFee(p.price);
  const total = p.price + fee;
  return `
  <button class="vcard" data-product="${p.id}" aria-label="Lihat detail ${p.title}">
    <div class="vcard-thumb" style="background:${grad};position:relative;overflow:hidden;">
      <span class="vcard-badge">${p.badge}</span>
      <span class="vcard-stamp" title="Terverifikasi rekber">✓</span>
      ${(Array.isArray(p.photos) && p.photos[0]) || p.cover_image
        ? (() => { const _u = (p.photos && p.photos[0]) || p.cover_image; return `
          <img src="${_u}" alt="" style="width:100%;height:100%;object-fit:cover;position:absolute;inset:0;filter:blur(18px) brightness(.7);transform:scale(1.2);" loading="lazy" aria-hidden="true">
          <img src="${_u}" alt="${p.title}" style="width:100%;height:100%;object-fit:contain;position:absolute;inset:0;" loading="lazy">`; })()
        : p.icon}
    </div>
    <div class="vcard-body">
      <div class="vcard-title">${p.title}</div>
      <div class="vcard-meta">
        <span class="rating">★ ${p.rating.toFixed(1)}</span>
        <span>·</span>
        <span>${p.seller}</span>
      </div>
      <div class="vcard-tear"></div>
      <div class="vcard-foot">
        <div class="vcard-price">
          ${formatRupiah(total)}
          <small style="display:block;font-size:10px;color:rgba(255,255,255,.4);font-weight:400;">termasuk biaya admin</small>
          <small>${p.sold} terjual</small>
        </div>
        <span class="vcard-buy" aria-hidden="true">→</span>
      </div>
    </div>
  </button>`;
}

async function renderGrid(containerId, products){
  const el = document.getElementById(containerId);
  if(!el) return;
  if(products.length === 0){
    el.innerHTML = `<div class="empty-state"><div class="glyph">🎫</div><p><strong>Tidak ada produk yang cocok.</strong><br>Coba ubah kata kunci atau filter kategori.</p></div>`;
    return;
  }
  const cards = await Promise.all(products.map(cardHTML));
  el.innerHTML = cards.join("");
}

/* ---------- product modal ---------- */
function buildModal(){
  if(document.getElementById("productModal")) return;

  // Inject gallery styles sekali saja
  if(!document.getElementById("modalGalleryStyle")){
    const st = document.createElement("style");
    st.id = "modalGalleryStyle";
    st.textContent = `
      .modal-gallery { position:relative; overflow:hidden; border-radius:16px 16px 0 0; background:#111; aspect-ratio:16/9; }
      .modal-gallery img { width:100%; height:100%; object-fit:contain; display:block; }
      .modal-gallery .mg-icon { display:flex; align-items:center; justify-content:center; height:100%; font-size:64px; }
      .modal-thumbs { display:flex; gap:6px; padding:8px 0 4px; flex-wrap:wrap; }
      .modal-thumbs img { width:48px; height:48px; border-radius:8px; object-fit:cover; cursor:pointer;
        opacity:.5; border:2px solid transparent; transition:all .15s; flex-shrink:0; }
      .modal-thumbs img.active { opacity:1; border-color:#16A37A; }
      .modal-desc-box { background:rgba(255,255,255,.06); border-radius:10px; padding:12px 14px;
        font-size:13px; color:var(--text-on-ink-muted); line-height:1.7; white-space:pre-wrap;
        margin:4px 0 10px; max-height:140px; overflow-y:auto; }
    `;
    document.head.appendChild(st);
  }

  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.id = "productModal";
  overlay.innerHTML = `
    <div class="modal-card" style="padding:0;overflow:hidden;">
      <button class="modal-close" id="modalClose" aria-label="Tutup" style="position:absolute;top:12px;right:12px;z-index:10;">✕</button>

      <!-- GALLERY -->
      <div class="modal-gallery" id="modalGallery"></div>
      <div class="modal-thumbs" id="modalThumbs" style="padding:8px 20px 0;"></div>

      <!-- PRODUK VIEW -->
      <div id="modalProductView" style="padding:16px 20px 20px;">
        <h3 id="modalTitle" style="margin:0 0 4px;"></h3>
        <p class="modal-seller" id="modalSeller" style="margin:0 0 2px;"></p>
        <div id="modalDetailExtra"></div>
        <div id="modalDescBox" style="display:none;">
          <div style="font-size:11px;font-weight:700;color:var(--text-on-ink-muted);text-transform:uppercase;letter-spacing:.05em;margin-bottom:6px;">Deskripsi Produk</div>
          <div class="modal-desc-box" id="modalDescText"></div>
        </div>
        <p class="modal-price" id="modalPrice"></p>
        <div class="modal-info">
          <span>✓ <b>Rekber aman</b></span>
          <span id="modalSold"></span>
        </div>
        <div class="modal-actions">
          <button class="btn btn-ghost-dark btn-block" id="modalChat" style="border:1.5px solid var(--ink-line);color:var(--text-on-ink);background:transparent;">Chat Penjual</button>
          <button class="btn btn-verified btn-block" id="modalBuy">Beli Sekarang</button>
        </div>
        <p class="demo-note">Pembayaran diproses lewat Midtrans. Dana ditahan rekber sampai kamu konfirmasi pesanan diterima.</p>
      </div>

      <!-- CHAT VIEW -->
      <div id="modalChatView" style="display:none;padding:16px 20px 20px;">
        <button type="button" id="modalChatBack" style="background:none;border:none;color:var(--text-on-ink-muted);font-size:13px;cursor:pointer;padding:0 0 10px;display:flex;align-items:center;gap:4px;">← Kembali ke detail produk</button>
        <p class="modal-seller" id="modalChatWith" style="margin-bottom:10px;"></p>
        <div class="chat-shell in-modal">
          <div class="chat-messages" id="modalChatMessages"></div>
          <form class="chat-composer" id="modalChatForm">
            <input type="text" id="modalChatInput" placeholder="Tulis pesan…" autocomplete="off">
            <button type="submit" aria-label="Kirim">➤</button>
          </form>
        </div>
      </div>
    </div>`;
  document.body.appendChild(overlay);

  overlay.addEventListener("click", (e)=>{ if(e.target === overlay) closeModal(); });
  document.getElementById("modalClose").addEventListener("click", closeModal);
  document.getElementById("modalChat").addEventListener("click", openModalChat);
  document.getElementById("modalChatBack").addEventListener("click", ()=>{
    document.getElementById("modalChatView").style.display = "none";
    document.getElementById("modalProductView").style.display = "block";
  });
  document.getElementById("modalBuy").addEventListener("click", ()=> { if(currentProduct) startCheckout(currentProduct); });
}

function _modalSwitchPhoto(thumb, url){
  document.querySelectorAll("#modalThumbs img").forEach(t => t.classList.remove("active"));
  thumb.classList.add("active");
  const main = document.getElementById("modalMainImg");
  if(main) main.src = url;
}

/* ---------- open chat panel inside the product modal ---------- */
async function openModalChat(){
  if(!supabaseClient){
    showToast("Database belum terhubung. Cek config.js & SETUP.md.");
    return;
  }
  if(!currentProduct) return;

  const { data:{ session } } = await supabaseClient.auth.getSession();
  if(!session){
    showToast("Silakan masuk dulu untuk chat dengan penjual.");
    setTimeout(()=> window.location.href = "login.html", 1200);
    return;
  }
  if(!currentProduct.sellerId){
    showToast("Penjual produk ini tidak ditemukan.");
    return;
  }
  if(session.user.id === currentProduct.sellerId){
    showToast("Ini produkmu sendiri — tidak bisa chat dengan diri sendiri.");
    return;
  }

  document.getElementById("modalProductView").style.display = "none";
  document.getElementById("modalChatView").style.display = "block";
  document.getElementById("modalChatWith").textContent = "Chat dengan " + currentProduct.seller;

  const messagesEl = document.getElementById("modalChatMessages");
  messagesEl.innerHTML = `<div class="chat-loading">Membuka percakapan…</div>`;

  try{
    const convId = await chatOpenWith(currentProduct.sellerId, currentProduct.id);
    await chatLoadAndSubscribe(convId, messagesEl, session.user.id);

    const form = document.getElementById("modalChatForm");
    const freshForm = form.cloneNode(true); // strip old listeners if modal reused
    form.replaceWith(freshForm);
    chatWireComposer(
      freshForm,
      freshForm.querySelector("#modalChatInput"),
      messagesEl,
      ()=> chatActiveConvId,
      session.user.id
    );
  } catch(err){
    messagesEl.innerHTML = `<div class="chat-loading">Gagal membuka chat: ${err.message}</div>`;
  }
}

let currentProduct = null;

async function openModal(productId){
  const p = PRODUCTS.find(x => x.id === productId);
  if(!p) return;
  currentProduct = p;
  buildModal();
  document.getElementById("modalProductView").style.display = "block";
  document.getElementById("modalChatView").style.display = "none";

  document.getElementById("modalTitle").textContent = p.title;
  document.getElementById("modalSeller").textContent = "Dijual oleh " + p.seller;
  document.getElementById("modalSold").innerHTML = `<b>${p.sold}</b> terjual · <b>★ ${p.rating.toFixed(1)}</b>`;

  // ── Gallery foto ──
  const photos = p.photos || [];
  const galleryEl = document.getElementById("modalGallery");
  const thumbsEl  = document.getElementById("modalThumbs");

  if(photos.length > 0){
    galleryEl.innerHTML = `<img id="modalMainImg" src="${photos[0]}" alt="${p.title}">`;
    thumbsEl.style.display = photos.length > 1 ? "flex" : "none";
    thumbsEl.innerHTML = photos.length > 1
      ? photos.map((u,i) => `<img src="${u}" class="${i===0?'active':''}" onclick="_modalSwitchPhoto(this,'${u}')">`).join("")
      : "";
  } else {
    const grad = `linear-gradient(135deg, ${p.grad[0]}, ${p.grad[1]})`;
    galleryEl.innerHTML = `<div class="mg-icon" style="background:${grad};">${p.icon}</div>`;
    thumbsEl.style.display = "none";
    thumbsEl.innerHTML = "";
  }

  // ── Badge kategori & stok ──
  const catLabel = { digital: "Produk Digital", game: "Produk Game", jasa: "Jasa" }[p.cat] || p.cat || "-";
  const stockText = p.stock === null || p.stock === undefined
    ? "" : p.stock > 0 ? `<span style="color:#16A37A;">● Stok tersedia (${p.stock})</span>` : `<span style="color:#e05555;">● Habis</span>`;

  const detailExtra = document.getElementById("modalDetailExtra");
  detailExtra.style.cssText = "margin:6px 0 8px;font-size:12px;color:var(--text-on-ink-muted);display:flex;gap:10px;flex-wrap:wrap;align-items:center;";
  detailExtra.innerHTML = `
    <span>🏷️ ${catLabel}${p.sub ? ` › ${p.sub}` : ""}</span>
    ${p.badge ? `<span>⚡ ${p.badge}</span>` : ""}
    ${stockText}
  `;

  // ── Deskripsi ──
  const descBox  = document.getElementById("modalDescBox");
  const descText = document.getElementById("modalDescText");
  if(p.description){
    descText.textContent = p.description;
    descBox.style.display = "block";
  } else {
    descBox.style.display = "none";
  }

  // ── Harga + breakdown fee admin ──
  const fee   = await calcAdminFee(p.price);
  const total = p.price + fee;
  const cfg   = await getAdminFeeSettings();

  document.getElementById("modalPrice").innerHTML =
    `<span style="font-size:22px;font-weight:800;color:#fff;">${formatRupiah(total)}</span>
     <span style="font-size:11px;color:rgba(255,255,255,.4);margin-left:6px;">total yang kamu bayar</span>`;

  const existingBreakdown = document.getElementById("modalFeeBreakdown");
  if(existingBreakdown) existingBreakdown.remove();

  const breakdown = document.createElement("div");
  breakdown.id = "modalFeeBreakdown";
  breakdown.style.cssText = "background:#0F1117;border-radius:10px;padding:12px 14px;margin:10px 0 14px;font-size:13px;";
  breakdown.innerHTML = `
    <div style="display:flex;justify-content:space-between;color:rgba(255,255,255,.5);margin-bottom:6px;">
      <span>Harga produk</span><span>${formatRupiah(p.price)}</span>
    </div>
    <div style="display:flex;justify-content:space-between;color:#E7A93D;margin-bottom:8px;">
      <span>Biaya admin (${cfg.rate}%)</span><span>+ ${formatRupiah(fee)}</span>
    </div>
    <div style="height:1px;background:rgba(255,255,255,.08);margin-bottom:8px;"></div>
    <div style="display:flex;justify-content:space-between;font-weight:700;color:#fff;">
      <span>Total kamu bayar</span><span style="color:#4DA3F5;">${formatRupiah(total)}</span>
    </div>
    <div style="margin-top:8px;padding-top:8px;border-top:1px solid rgba(255,255,255,.06);display:flex;justify-content:space-between;color:#16A37A;font-size:12px;">
      <span>Seller terima</span><span>${formatRupiah(p.price)}</span>
    </div>`;
  document.getElementById("modalPrice").insertAdjacentElement("afterend", breakdown);

  document.getElementById("productModal").classList.add("open");
}
function closeModal(){
  document.getElementById("productModal")?.classList.remove("open");
  if(chatChannel){
    supabaseClient.removeChannel(chatChannel);
    chatChannel = null;
    chatActiveConvId = null;
  }
}

/* ---------- checkout (Midtrans Snap via Supabase Edge Function) ---------- */
async function startCheckout(p){
  if(!supabaseClient){
    showToast("Database belum terhubung. Cek config.js & SETUP.md.");
    return;
  }
  if(typeof window.snap === "undefined"){
    showToast("Modul pembayaran belum termuat. Cek koneksi internet & coba lagi.");
    return;
  }

  const { data: { session } } = await supabaseClient.auth.getSession();
  if(!session){
    showToast("Silakan masuk dulu sebelum checkout.");
    setTimeout(()=> window.location.href = "login.html", 1200);
    return;
  }

  // Cek stok sebelum checkout
  if(p.stock !== null && p.stock !== undefined && p.stock <= 0){
    showToast("Maaf, stok produk ini sudah habis.");
    return;
  }

  const fee         = await calcAdminFee(p.price);
  const totalAmount = p.price + fee;

  const buyBtn = document.getElementById("modalBuy");
  const originalLabel = buyBtn.textContent;
  buyBtn.disabled = true;
  buyBtn.textContent = "Memproses...";

  try{
    const { data, error } = await supabaseClient.functions.invoke("create-transaction", {
      body: {
        productId:   p.id,
        adminFee:    fee,
        totalAmount: totalAmount,
      },
    });

    if(error) throw new Error("Gagal menghubungi server: " + error.message);
    if(data?.error) throw new Error(data.error);

    // Validasi token sebelum buka Snap
    if(!data?.token){
      throw new Error("Token pembayaran tidak diterima dari server. Pastikan Edge Function 'create-transaction' sudah di-deploy dan Midtrans server key sudah dikonfigurasi.");
    }

    closeModal();

    window.snap.pay(data.token, {
      onSuccess: (result)=>{
        showToast(`✅ Pembayaran ${formatRupiah(totalAmount)} berhasil! Dana ditahan rekber sampai pesanan dikonfirmasi.`);
        console.log("Snap success:", result);
      },
      onPending: (result)=>{
        showToast("⏳ Pembayaran tertunda — selesaikan sesuai instruksi yang muncul.");
        console.log("Snap pending:", result);
      },
      onError: (result)=>{
        showToast("❌ Pembayaran gagal. Coba lagi atau pilih metode lain.");
        console.error("Snap error:", result);
      },
      onClose: ()=> showToast("Kamu menutup jendela pembayaran sebelum selesai."),
    });
  } catch(err){
    console.error("Checkout error:", err);
    showToast("Gagal memulai pembayaran: " + err.message);
  } finally {
    buyBtn.disabled = false;
    buyBtn.textContent = originalLabel;
  }
}

/* delegate clicks on any rendered voucher card */
document.addEventListener("click", (e)=>{
  const card = e.target.closest("[data-product]");
  if(card) openModal(card.getAttribute("data-product"));
});
document.addEventListener("keydown", (e)=>{ if(e.key === "Escape") closeModal(); });

/* ---------- footer year + header auth sync (runs on every page) ---------- */
document.addEventListener("DOMContentLoaded", ()=>{
  const y = document.getElementById("year");
  if(y) y.textContent = new Date().getFullYear();
  syncHeaderAuth();
});

/* ---------- header search -> catalog ---------- */
function wireHeaderSearch(formId){
  const form = document.getElementById(formId);
  if(!form) return;
  form.addEventListener("submit", (e)=>{
    e.preventDefault();
    const q = form.querySelector("input").value.trim();
    window.location.href = "products.html" + (q ? ("?search=" + encodeURIComponent(q)) : "");
  });
}
