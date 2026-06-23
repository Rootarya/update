/* =========================================================
   REKBERIN — mock catalog data
   This is template data so the site has something to show.
   Swap PRODUCTS for real records from your own database/API
   once a backend is connected.
   ========================================================= */

const CATEGORIES = [
  { id: "digital", label: "Produk Digital" },
  { id: "game",    label: "Produk Game" },
  { id: "jasa",    label: "Jasa" },
];

const GAME_SUBCATEGORIES = [
  { id: "mobile-legends", label: "Mobile Legends" },
  { id: "free-fire",      label: "Free Fire" },
  { id: "pubg-mobile",    label: "PUBG Mobile" },
  { id: "valorant",       label: "Valorant" },
  { id: "genshin-impact", label: "Genshin Impact" },
  { id: "roblox",         label: "Roblox" },
];

/* gradient pairs used as placeholder thumbnails */
const G = {
  emerald: ["#16A37A", "#0E7C5B"],
  gold:    ["#E7A93D", "#B97E1C"],
  stamp:   ["#E2472A", "#A8331B"],
  ink:     ["#2A3656", "#19233D"],
  violet:  ["#6C5CE7", "#4834A6"],
  blue:    ["#2E86DE", "#1E5FA8"],
};

/* PRODUCTS sekarang diisi dari tabel `products` di Supabase saat halaman
   dimuat — lihat fetchProductsFromSupabase() di app.js. Array ini dimulai
   kosong dan akan terisi otomatis begitu data dari database datang. */
let PRODUCTS = [];

function formatRupiah(n){
  return "Rp " + n.toLocaleString("id-ID");
}
