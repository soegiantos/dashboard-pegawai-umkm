// Vercel Serverless Function: /api/ai-chat (Aplikasi Pegawai)
// ------------------------------------------------------------
// KENAPA ADA FUNGSI INI (bukan memanggil /api/ai-chat aplikasi utama):
// proxy aplikasi utama TIDAK mengirim header CORS, jadi panggilan
// lintas origin dari aplikasi pegawai ini akan diblokir peramban.
// Fungsi ini same-origin dengan aplikasi pegawai, pola yang sama
// dengan proxy aplikasi utama, dan kunci DeepSeek hanya dibaca dari
// environment variable — TIDAK PERNAH ada di frontend.
// ------------------------------------------------------------
// README (baca dulu sebelum deploy):
// 1. File ini harus ikut ter-deploy BERSAMA aplikasi pegawai, di
//    folder api/ pada root proyek Vercel (api/ai-chat.js).
// 2. Di Vercel Dashboard, buka proyek dashboard-pegawai-umkm,
//    lalu Settings -> Environment Variables, tambahkan:
//       DEEPSEEK_API_KEY = <kunci DeepSeek yang sama dengan aplikasi utama>
//    Pilih Production (dan Preview bila perlu), lalu Save.
//    JANGAN pernah menulis kunci itu di kode aplikasi, di HTML,
//    di chat, atau di file ini.
// 3. Redeploy proyek setelah menambah environment variable.
// 4. Drop to Deploy (unggah satu file HTML statis saja) TIDAK
//    bisa menjalankan fungsi ini. Proyek harus di-deploy dari
//    Git atau dari Vercel CLI dengan folder api/ ikut serta.
// 5. Kalau kunci belum diset, fungsi ini menjawab 503 dengan
//    pesan yang ramah, dan aplikasi pegawai tetap bisa dipakai
//    (pegawai menulis isiannya sendiri).
// ------------------------------------------------------------
// Peran fungsi ini: hanya menyusun DRAF TEKS untuk isian pegawai
// (keterangan kwitansi, caption foto, catatan SOP). DeepSeek HANYA
// menyusun/menjelaskan teks. DeepSeek TIDAK PERNAH membuat angka:
// jumlah kwitansi selalu dari kolom angka yang diisi pegawai
// sendiri, bukan dari AI.
// SEBELUM memanggil DeepSeek, fungsi ini memeriksa kuota lewat RPC
// pakai_ai_pegawai (tabel pemakaian_ai di cloud): batas lunak 20
// isian dibantu AI per pegawai per bulan, dihitung terhadap kuota
// pemilik (Gratis 20, Mikro 300, Kecil 600, Menengah 1.000/bulan).
// Bila batas tercapai, fungsi menjawab 429 dan TIDAK memanggil
// DeepSeek (tidak ada biaya). Token sesi pegawai (Authorization:
// Bearer <token>) dipakai untuk memanggil RPC itu — tanpa token,
// fungsi menjawab 401.
// ------------------------------------------------------------
// SUPABASE_URL / SUPABASE_ANON_KEY: kunci anon adalah nilai PUBLIK
// (sama persis dengan yang sudah ada di frontend aplikasi pegawai),
// jadi aman dipakai di sini sebagai cadangan; bila mau, isi keduanya
// lewat environment variable Vercel dan nilai itu yang dipakai.

const SUPABASE_URL = process.env.SUPABASE_URL || "https://bdnqsxwypbrdiwaxydoh.supabase.co";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJkbnFzeHd5cGJyZGl3YXh5ZG9oIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ1OTQ3NDUsImV4cCI6MjExMDE3MDc0NX0.MsdIzw-CAqJiBp3McXZ-6XLzLakmo0S5w7RhHHXMCQc";

const LABEL_JENIS = {
  foto: "caption foto kegiatan",
  kwitansi: "keterangan kwitansi belanja",
  sop: "catatan SOP harian",
};

export default async function handler(req, res) {
  // Hanya izinkan POST.
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Hanya POST yang diizinkan." });
  }

  let body = req.body;
  // Vercel kadang memberi body sebagai string; parse bila perlu.
  if (typeof body === "string") {
    try {
      body = JSON.parse(body);
    } catch {
      return res.status(400).json({ error: "Isi permintaan tidak dapat dibaca." });
    }
  }

  const jenis = typeof body?.jenis === "string" ? body.jenis.trim() : "";
  const teks = typeof body?.teks === "string" ? body.teks.trim() : "";
  const tier = typeof body?.tier === "string" ? body.tier.trim() : null;

  if (!LABEL_JENIS[jenis]) {
    return res.status(400).json({ error: "Jenis isian tidak dikenal." });
  }
  if (!teks) {
    return res.status(400).json({ error: "Tulis dulu beberapa kata tentang isian ini." });
  }
  if (teks.length > 500) {
    return res.status(400).json({ error: "Isian terlalu panjang (maksimal 500 karakter)." });
  }

  // Token sesi pegawai (wajib — untuk memeriksa kuota atas namanya).
  const auth = typeof req.headers?.authorization === "string" ? req.headers.authorization : "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!token) {
    return res.status(401).json({ error: "Masuk dulu untuk memakai bantuan AI." });
  }

  const apiKey = process.env.DEEPSEEK_API_KEY;
  if (!apiKey) {
    // Kunci belum diset di Vercel: beri tahu aplikasi dengan jelas.
    // Diperiksa SEBELUM kuota, supaya pemakaian yang gagal karena
    // kunci belum diset tidak menghabiskan jatah pegawai.
    return res.status(503).json({
      error: "AI online belum tersambung. Periksa DEEPSEEK_API_KEY di pengaturan Vercel.",
    });
  }

  // 1. Cek + catat pemakaian ke kuota pemilik (server-side, lewat RPC).
  let kuota;
  try {
    const kuotaRes = await fetch(SUPABASE_URL + "/rest/v1/rpc/pakai_ai_pegawai", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_ANON_KEY,
        Authorization: "Bearer " + token,
      },
      body: JSON.stringify({ p_tier: tier }),
    });
    if (!kuotaRes.ok) {
      if (kuotaRes.status === 404) {
        // RPC belum ada = SQL pegawai belum dijalankan ulang.
        return res.status(503).json({
          error: "Fitur ini belum aktif — pengaturan cloud belum dijalankan.",
        });
      }
      const t = await kuotaRes.text().catch(() => "");
      console.error("Kuota AI error:", kuotaRes.status, t.slice(0, 300));
      return res.status(502).json({
        error: "Kuota AI belum bisa diperiksa. Coba lagi sebentar lagi.",
      });
    }
    kuota = await kuotaRes.json();
  } catch (err) {
    console.error("Kuota AI error:", err);
    return res.status(502).json({
      error: "Kuota AI belum bisa diperiksa. Coba lagi sebentar lagi.",
    });
  }

  if (!kuota || kuota.boleh === false) {
    const alasan = kuota && kuota.alasan ? kuota.alasan : "pemilik";
    const pesan = alasan === "pegawai"
      ? "Bantuan AI untuk Anda bulan ini sudah mencapai batas (20 kali"
        + (kuota && kuota.dipakai_pegawai != null ? ", sudah dipakai " + kuota.dipakai_pegawai + " kali" : "")
        + "). Anda tetap bisa menulis isiannya sendiri, dan batasnya kembali bulan depan."
      : "Kuota AI usaha Anda bulan ini sudah habis"
        + (kuota && kuota.dipakai_pemilik != null && kuota.batas_pemilik != null
          ? " (dipakai " + kuota.dipakai_pemilik + " dari " + kuota.batas_pemilik + ")"
          : "")
        + ". Minta pemilik usaha memeriksa tingkat paketnya. Anda tetap bisa menulis isiannya sendiri.";
    return res.status(429).json({
      error: pesan,
      alasan: alasan,
      dipakai_pegawai: kuota ? kuota.dipakai_pegawai : null,
      batas_pegawai: kuota ? kuota.batas_pegawai : 20,
      dipakai_pemilik: kuota ? kuota.dipakai_pemilik : null,
      batas_pemilik: kuota ? kuota.batas_pemilik : null,
      tier: kuota ? kuota.tier : null,
    });
  }

  // 2. Minta draf teks ke DeepSeek (hanya teks — tidak pernah angka).
  try {
    const response = await fetch("https://api.deepseek.com/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + apiKey,
      },
      body: JSON.stringify({
        model: "deepseek-chat",
        temperature: 0.3,
        max_tokens: 300,
        messages: [
          {
            role: "system",
            content:
              "Kamu adalah pembantu penulisan untuk pegawai UMKM di Indonesia. " +
              "Tugasmu HANYA menyusun draf teks singkat (1-2 kalimat) dalam Bahasa Indonesia sederhana " +
              "dari kata-kata awal yang diberikan pegawai. " +
              "Jangan pernah menulis angka, jumlah uang, harga, atau tanggal — bila kata awal mengandung angka, " +
              "tuliskan apa adanya tanpa mengubahnya. " +
              "Jangan sebut kata bank, kredit, atau KUR. " +
              "Jangan memakai markdown, simbol format, atau emoji. " +
              "Jawab hanya dengan draf teksnya saja, tanpa pembuka dan tanpa penutup.",
          },
          {
            role: "user",
            content:
              "Jenis isian: " + LABEL_JENIS[jenis] + ".\n" +
              "Kata awal pegawai: \"" + teks + "\"\n" +
              "Susun satu draf singkat (1-2 kalimat) dalam Bahasa Indonesia sederhana untuk isian tersebut.",
          },
        ],
      }),
    });

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      console.error("DeepSeek error:", response.status, text.slice(0, 300));
      return res.status(502).json({
        error: "AI online sedang tidak bisa menjawab. Coba lagi sebentar lagi.",
      });
    }

    const data = await response.json();
    const draf = data?.choices?.[0]?.message?.content?.trim() || "";
    if (!draf) {
      return res.status(502).json({
        error: "AI online tidak memberi jawaban. Coba lagi sebentar lagi.",
      });
    }
    return res.status(200).json({ draf });
  } catch (err) {
    console.error("AI proxy error:", err);
    return res.status(502).json({
      error: "AI online sedang tidak bisa dihubungi. Coba lagi sebentar lagi.",
    });
  }
}
