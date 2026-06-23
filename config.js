/* =========================================================
   REKBERIN — koneksi database (Supabase) & payment (Midtrans)

   1. Buat project gratis di https://supabase.com
   2. Buka  Project Settings -> API
   3. Salin "Project URL" dan "anon public" key ke bawah ini
   4. Jalankan schema.sql di SQL Editor Supabase (lihat SETUP.md)
   5. Untuk pembayaran: lihat SETUP_MIDTRANS.md

   File ini AMAN untuk dipakai di sisi browser — anon key Supabase
   dan client key Midtrans memang didesain untuk dipakai di client.
   JANGAN PERNAH menaruh "service_role key" Supabase atau
   "server key" Midtrans di file ini atau di kode sisi browser manapun.
   ========================================================= */

const SUPABASE_URL = "https://aktgklmbrxwohugrfjrr.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFrdGdrbG1icnh3b2h1Z3JmanJyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIwNjM5OTYsImV4cCI6MjA5NzYzOTk5Nn0.8U8jGfWbnWRrQMekfHmeO3msubVW2DLRe6CS6wJWW4A";

const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const MIDTRANS_CLIENT_KEY = "Mid-client-3a96ocnU5RrQ3ShE"; // Client Key Midtrans Production
