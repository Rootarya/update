/* nav-auth.js — Rekberin
   Inject avatar+username navbar on public pages when user is logged in.
   Load this AFTER app.js and supabase on index.html & products.html
*/
(async function(){
  if(typeof supabaseClient === "undefined" || !supabaseClient) return;

  const { data:{ session } } = await supabaseClient.auth.getSession();
  if(!session) return; // not logged in — keep Masuk/Daftar buttons

  const actions = document.querySelector(".header-actions");
  if(!actions) return;

  // Fetch profile for username/name
  const { data: profile } = await supabaseClient
    .from("profiles").select("full_name,username,role").eq("id", session.user.id).single();

  const displayName = profile?.username || profile?.full_name || session.user.email?.split("@")[0] || "Pengguna";
  const initials    = displayName.slice(0,2).toUpperCase();
  const role        = profile?.role || "pembeli";

  const roleLabel = role === "admin"   ? "🛡️ Admin"
                  : role === "penjual" ? "🏪 Penjual"
                  : "🛒 Pembeli";
  const roleColor = role === "admin"   ? "#f87171"
                  : role === "penjual" ? "#f59e0b"
                  : "#10b981";
  const avatarGrad = role === "admin"   ? "linear-gradient(135deg,#ef4444,#b91c1c)"
                   : role === "penjual" ? "linear-gradient(135deg,#f59e0b,#d97706)"
                   : "linear-gradient(135deg,#10b981,#0d9668)";
  const dashUrl  = role === "admin"   ? "dashboard-admin.html"
                 : role === "penjual" ? "dashboard-penjual.html"
                 : "dashboard-pembeli.html";

  // Remove menu-toggle (keep it separate from the replaced buttons)
  const menuBtn = actions.querySelector(".menu-toggle");

  actions.innerHTML = `
    <a href="${dashUrl}" style="display:flex;align-items:center;gap:8px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);border-radius:10px;padding:5px 12px 5px 6px;text-decoration:none;transition:background .15s;" onmouseover="this.style.background='rgba(255,255,255,.1)'" onmouseout="this.style.background='rgba(255,255,255,.06)'">
      <div style="width:30px;height:30px;border-radius:50%;background:${avatarGrad};display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;color:#fff;flex-shrink:0;border:2px solid rgba(255,255,255,.15);overflow:hidden;" id="pubNavAvatar">${initials}</div>
      <div style="display:flex;flex-direction:column;line-height:1.2;">
        <span style="font-size:13px;font-weight:600;color:#f1f5f9;">${displayName}</span>
        <span style="font-size:10px;font-weight:500;color:${roleColor};">${roleLabel}</span>
      </div>
    </div>
    <a href="#" id="pubNavLogout" style="font-size:13px;font-weight:500;padding:7px 14px;border-radius:8px;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.1);color:rgba(255,255,255,.7);text-decoration:none;transition:background .15s;" onmouseover="this.style.background='rgba(255,255,255,.1)'" onmouseout="this.style.background='rgba(255,255,255,.05)'">Keluar</a>
  `;

  // Re-append menu toggle if it existed
  if(menuBtn) actions.appendChild(menuBtn);

  document.getElementById("pubNavLogout").addEventListener("click", async e => {
    e.preventDefault();
    await supabaseClient.auth.signOut();
    localStorage.removeItem("rekberin_role");
    window.location.reload();
  });
})();
