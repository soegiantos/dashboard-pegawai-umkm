-- ============================================================================
-- SQL APLIKASI PEGAWAI — APLIKASI INTROSPEKSI UMKM
-- ============================================================================
-- Proyek cloud : aplikasi-introspeksi-umkm
-- Ref          : bdnqsxwypbrdiwaxydoh
--
-- TUJUAN FILE
-- Membuat 5 tabel + 19 fungsi untuk aplikasi pegawai terpisah
-- (dashboard-pegawai-umkm, "Aplikasi Pegawai — UMKM Tumbuh"): pegawai
-- menjalankan SOP usaha pemiliknya sebagai daftar centang harian,
-- mengirim laporan harian (foto kegiatan / kwitansi) ke pemilik,
-- mencatat presensi masuk/pulang, dan memakai bantuan AI untuk
-- menulis isiannya. Pemeriksa SOP (pengecek) menandai pekerjaan
-- yang sudah selesai sebagai sudah dicek.
-- Aplikasi ini TIDAK menampilkan data keuangan usaha apa pun — tidak
-- ada angka usaha, rincian pencatatan, atau lokasi di hasil RPC di
-- bawah. Yang dikembalikan hanya daftar SOP (nama, penanggung jawab,
-- tujuan, langkah), nama usaha, dan catatan jalankan hari ini.
-- Satu pengecualian yang dijelaskan di bagian 7: jumlah pada kwitansi
-- adalah data kwitansi itu sendiri yang diserahkan pegawai, BUKAN
-- angka keuangan usaha — pemilik melihatnya sebagai bukti
-- pengeluaran yang dilaporkan pegawainya, pegawai hanya melihat
-- kwitansinya sendiri.
--
-- CARA MENJALANKAN
-- 1. Buka Dashboard proyek di atas -> SQL Editor -> New query.
-- 2. Tempel SELURUH isi file ini, lalu klik "Run".
-- 3. File ini idempotent (aman dijalankan ulang).
--
-- PRASYARAT
-- Tabel umkm_data (user_id uuid, data jsonb) dan profiles (id uuid,
-- nama_usaha text) SUDAH ada dari sql utama aplikasi. Daftar SOP
-- dibaca dari umkm_data.data -> 'sops' (daftar SOP yang disimpan
-- aplikasi utama; tiap SOP berisi id, nama, pj, tujuan, steps[],
-- dibuat). Nama usaha dibaca dari umkm_data.data -> 'inputs' ->>
-- 'inNama', dengan cadangan profiles.nama_usaha.
--
-- PERINGATAN — FILE INI TIDAK MENGUBAH TABEL YANG SUDAH ADA
-- File ini hanya membuat 5 tabel BARU (akses_pegawai, sop_jalankan,
-- laporan_pegawai, presensi, pemakaian_ai), menambah SATU kolom baru
-- foto_path di akses_pegawai dan TIGA kolom baru (dicek_oleh,
-- dicek_pada, catatan) di sop_jalankan, membuat SATU bucket privat
-- bukti-pegawai, dan 19 fungsi BARU. Tabel yang sudah ada TIDAK
-- diubah strukturnya selain kolom-kolom itu, TIDAK dihapus, dan data
-- pengguna yang sudah ada TIDAK disentuh.
-- Tidak ada baris data yang disisipkan oleh file ini — pemilik
-- menambahkan pegawai lewat daftar tim di aplikasi utama, setelah
-- file ini jalan. Pegawai mendaftar sendiri dengan email + kata
-- sandinya sendiri; pemilik TIDAK PERNAH membuat akun untuk pegawai.
--
-- TEMUAN KOLOM (diperiksa dari berkas aplikasi sebelum file ini
-- ditulis — TIDAK ADA kolom yang diasumsikan):
--   * umkm_data:       user_id uuid, data jsonb, updated_at saja
--     (tanpa created_at). Daftar SOP: data -> 'sops' (array jsonb;
--     tiap entri {id, nama, pj, tujuan, steps[], dibuat}).
--     Nama usaha: data -> 'inputs' ->> 'inNama'.
--   * profiles:        id uuid, nama_usaha text, no_hp text,
--     kode_marketing text, created_at timestamptz.
--   * auth.users:      email varchar(255), created_at. Email yang
--     dikembalikan RPC di-cast ke ::text.
-- ============================================================================

-- ============================================================================
-- 1. TABEL akses_pegawai — siapa saja pegawai yang boleh masuk
-- ============================================================================
-- Satu baris = satu pegawai dari satu usaha. Pemilik usaha (pemilik_id)
-- menambahkan pegawai lewat daftar tim di aplikasi utama: email, nama,
-- dan peran yang sudah dilatih (kas / produksi / stok). Pegawai
-- mendaftar sendiri di aplikasi pegawai dengan email yang sama.
create table if not exists public.akses_pegawai (
  email text not null primary key,
  pemilik_id uuid not null,
  nama text not null,
  peran text[] not null default '{}'::text[],
  aktif boolean not null default true,
  created_at timestamptz not null default now(),
  constraint akses_pegawai_peran_valid
    check (peran <@ array['kas','produksi','stok']::text[])
);
comment on table public.akses_pegawai is 'Daftar pegawai yang diizinkan masuk Aplikasi Pegawai, beserta peran yang sudah dilatih tiap orang (kas / produksi / stok). Satu baris = satu pegawai. Pemilik menambahkan pegawai lewat daftar tim di aplikasi utama.';
comment on column public.akses_pegawai.pemilik_id is 'ID akun pemilik usaha (auth.users.id) yang mempekerjakan pegawai ini.';
comment on column public.akses_pegawai.peran is 'Peran yang sudah dilatih pegawai ini: kas, produksi, dan/atau stok.';

-- Pas foto pegawai: satu foto wajah per pegawai, dipakai pemilik untuk
-- mengenali pegawainya. Disimpan di akses_pegawai (bukan di
-- laporan_pegawai). Jalur berkas menunjuk ke bucket privat
-- bukti-pegawai dengan awalan pasfoto/ (lihat bagian 8). Pegawai lama
-- yang belum mengunggah mendapat nilai null — aplikasi utama
-- menampilkan inisial nama sebagai pengganti, bukan gambar rusak.
alter table public.akses_pegawai
  add column if not exists foto_path text;
comment on column public.akses_pegawai.foto_path is 'Jalur pas foto wajah pegawai di bucket privat bukti-pegawai (awalan pasfoto/). Null bila pegawai belum mengunggah — aplikasi utama menampilkan inisial nama sebagai pengganti.';

alter table public.akses_pegawai enable row level security;

-- Membaca: setiap orang boleh membaca barisnya sendiri.
drop policy if exists "akses pegawai baca sendiri" on public.akses_pegawai;
create policy "akses pegawai baca sendiri" on public.akses_pegawai
  for select using (auth.jwt() ->> 'email' = email);

-- Pemilik usaha boleh membaca, menambah, mengubah, dan menghapus
-- baris pegawai usahanya sendiri saja.
drop policy if exists "akses pegawai pemilik semua" on public.akses_pegawai;
create policy "akses pegawai pemilik semua" on public.akses_pegawai
  for all
  using (auth.uid() = pemilik_id)
  with check (auth.uid() = pemilik_id);

-- ============================================================================
-- 2. TABEL sop_jalankan — catatan harian jalankan SOP per pegawai
-- ============================================================================
-- Satu baris = satu SOP yang dijalankan satu pegawai pada satu hari.
-- langkah_selesai = jumlah langkah yang sudah dicentang hari itu
-- (0 sampai jumlah langkah SOP); selesai = true bila seluruh langkah
-- sudah dicentang. Satu pegawai hanya punya satu baris per SOP per
-- hari — centang berikutnya memperbarui baris yang sama.
create table if not exists public.sop_jalankan (
  id uuid not null primary key default gen_random_uuid(),
  pegawai_email text not null,
  pemilik_id uuid not null,
  sop_id text not null,
  tanggal date not null default current_date,
  langkah_selesai int not null default 0,
  selesai boolean not null default false,
  created_at timestamptz not null default now(),
  constraint sop_jalankan_langkah_tidak_negatif check (langkah_selesai >= 0),
  constraint sop_jalankan_satu_baris_per_hari
    unique (pegawai_email, sop_id, tanggal)
);
comment on table public.sop_jalankan is 'Catatan harian jalankan SOP: satu baris per pegawai per SOP per hari. Pegawai mencatat berapa langkah yang sudah dicentang dan apakah SOP selesai hari itu.';
comment on column public.sop_jalankan.langkah_selesai is 'Jumlah langkah SOP yang sudah dicentang pegawai hari itu (0 sampai jumlah langkah SOP).';
comment on column public.sop_jalankan.selesai is 'Benar bila seluruh langkah SOP sudah dicentang hari itu.';

-- Verifikasi + catatan SOP (item 9): satu baris per pegawai per SOP
-- per hari TETAP dipertahankan — verifikasi tidak memakai tabel baru,
-- melainkan tiga kolom di baris yang sama:
--   dicek_oleh : nama pemeriksa yang menandai pekerjaan ini sudah
--     dicek ("Pemilik" bila yang memeriksa pemilik usaha; nama
--     pegawai bila pemeriksa yang ditunjuk di SOP). Null = belum dicek.
--   dicek_pada : kapan ditandai sudah dicek (null bila belum dicek).
--   catatan    : catatan singkat pegawai untuk SOP hari itu (boleh
--     kosong; ditulis pegawai, boleh dibantu AI — lihat bagian 11).
alter table public.sop_jalankan
  add column if not exists dicek_oleh text,
  add column if not exists dicek_pada timestamptz,
  add column if not exists catatan text;
comment on column public.sop_jalankan.dicek_oleh is 'Nama pemeriksa yang menandai pekerjaan ini sudah dicek (Pemilik bila pemilik usaha; nama pegawai bila pemeriksa yang ditunjuk di SOP). Null bila belum dicek.';
comment on column public.sop_jalankan.dicek_pada is 'Waktu pekerjaan ditandai sudah dicek. Null bila belum dicek.';
comment on column public.sop_jalankan.catatan is 'Catatan singkat pegawai untuk SOP hari itu (boleh kosong).';

alter table public.sop_jalankan enable row level security;

-- Membaca: pegawai hanya membaca barisnya sendiri; pemilik usaha
-- membaca baris pegawai usahanya sendiri.
drop policy if exists "sop jalankan baca sendiri" on public.sop_jalankan;
create policy "sop jalankan baca sendiri" on public.sop_jalankan
  for select using (auth.jwt() ->> 'email' = pegawai_email);

drop policy if exists "sop jalankan baca pemilik" on public.sop_jalankan;
create policy "sop jalankan baca pemilik" on public.sop_jalankan
  for select using (auth.uid() = pemilik_id);

-- Menulis: pegawai hanya menulis baris atas namanya sendiri.
drop policy if exists "sop jalankan tulis sendiri" on public.sop_jalankan;
create policy "sop jalankan tulis sendiri" on public.sop_jalankan
  for insert to authenticated
  with check (auth.jwt() ->> 'email' = pegawai_email);

drop policy if exists "sop jalankan ubah sendiri" on public.sop_jalankan;
create policy "sop jalankan ubah sendiri" on public.sop_jalankan
  for update to authenticated
  using (auth.jwt() ->> 'email' = pegawai_email)
  with check (auth.jwt() ->> 'email' = pegawai_email);

-- Menghapus: hanya pemilik usaha, untuk baris pegawai usahanya.
drop policy if exists "sop jalankan hapus pemilik" on public.sop_jalankan;
create policy "sop jalankan hapus pemilik" on public.sop_jalankan
  for delete using (auth.uid() = pemilik_id);

-- ============================================================================
-- 3. PEMERIKSA IZIN — dipakai di awal setiap RPC di bawah
-- ============================================================================
-- Benar bila pemanggil terdaftar aktif di akses_pegawai. Security
-- definer supaya bisa membaca akses_pegawai walau RLS membatasi
-- pembacaan langsung.
create or replace function public.adalah_pegawai()
returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.akses_pegawai a
    where a.email = auth.jwt() ->> 'email' and a.aktif
  )
$$;
comment on function public.adalah_pegawai() is 'Benar bila pemanggil terdaftar aktif di akses_pegawai. Dipakai di awal setiap RPC pegawai.';

-- Berhenti dengan pesan bila pemanggil bukan pegawai aktif. Setiap RPC
-- pegawai memanggil fungsi ini dulu; pemanggil yang bukan pegawai
-- mendapat error (bukan data kosong yang bisa disalahartikan sebagai
-- "belum ada SOP").
create or replace function public.periksa_pegawai()
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.adalah_pegawai() then
    raise exception 'Hanya pegawai yang terdaftar oleh pemilik usaha yang boleh melihat data ini.';
  end if;
end;
$$;
comment on function public.periksa_pegawai() is 'Berhenti dengan pesan bila pemanggil bukan pegawai aktif. Dipanggil di awal setiap RPC pegawai.';

-- Benar bila pemanggil adalah pemilik aplikasi (pemilik usaha).
create or replace function public.adalah_pemilik_aplikasi()
returns boolean
language sql security definer stable set search_path = public as $$
  select auth.jwt() ->> 'email' = 'soegianto@fst.unair.ac.id'
$$;
comment on function public.adalah_pemilik_aplikasi() is 'Benar bila pemanggil adalah pemilik aplikasi (soegianto@fst.unair.ac.id). Disimpan untuk kemungkinan pemeriksaan khusus pemilik di masa depan; TIDAK dipakai ringkasan tim (log tim sengaja terbuka untuk setiap pemilik, dibatasi pemilik_id = auth.uid()).';

revoke execute on function public.adalah_pegawai() from public;
grant execute on function public.adalah_pegawai() to authenticated;
revoke execute on function public.periksa_pegawai() from public;
grant execute on function public.periksa_pegawai() to authenticated;
revoke execute on function public.adalah_pemilik_aplikasi() from public;
grant execute on function public.adalah_pemilik_aplikasi() to authenticated;

-- ============================================================================
-- 4. RPC sops_untuk_pegawai() — SOP pemilik + catatan hari ini (satu objek JSON)
-- ============================================================================
-- Mengembalikan satu objek JSON (TANPA data keuangan apa pun):
--   nama_usaha       : nama usaha pemilik (dari umkm_data.inputs.inNama,
--     cadangan profiles.nama_usaha; null bila belum diisi)
--   pegawai_nama     : nama pegawai pemanggil (dari akses_pegawai)
--   peran            : peran yang sudah dilatih pegawai ini
--     (array dari akses_pegawai: 'kas' / 'produksi' / 'stok')
--   sops             : [{id, nama, pj, tujuan, steps[], pengecek}] —
--     daftar SOP pemilik dari umkm_data.data -> 'sops'; steps adalah
--     array langkah (string), urut seperti di aplikasi utama;
--     pengecek adalah nama orang yang memeriksa pekerjaan SOP ini
--     (null/kosong bila belum diisi — di aplikasi pegawai dan utama
--     ditampilkan sebagai "Pemilik").
--   jalankan_hari_ini: [{sop_id, langkah_selesai, selesai, dicek_oleh,
--     dicek_pada, catatan}] — catatan pegawai ini hari ini saja,
--     supaya daftar centang + status dicek + catatan tampil sama
--     setelah halaman dimuat ulang.
-- Hanya pegawai aktif. Pemilik usaha yang memanggil tanpa baris
-- akses_pegawai mendapat error — pemilik memantau tim lewat aplikasi
-- utama, bukan lewat aplikasi pegawai.
create or replace function public.sops_untuk_pegawai()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_pemilik_id uuid;
  v_nama text;
  v_peran text[];
  v_nama_usaha text;
  v_sops jsonb;
  v_jalankan jsonb;
begin
  perform public.periksa_pegawai();

  select a.pemilik_id, a.nama, a.peran
    into v_pemilik_id, v_nama, v_peran
  from public.akses_pegawai a
  where a.email = v_email and a.aktif
  limit 1;

  -- Nama usaha + daftar SOP dari data usaha pemilik.
  select
    nullif(ud.data -> 'inputs' ->> 'inNama', ''),
    coalesce(ud.data -> 'sops', '[]'::jsonb)
    into v_nama_usaha, v_sops
  from public.umkm_data ud
  where ud.user_id = v_pemilik_id;

  -- Cadangan nama usaha dari profiles bila data usaha belum diisi.
  if v_nama_usaha is null then
    select nullif(p.nama_usaha, '') into v_nama_usaha
    from public.profiles p where p.id = v_pemilik_id;
  end if;

  -- Hanya SOP yang bentuknya benar yang dikembalikan (nama + steps).
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', s ->> 'id',
        'nama', s ->> 'nama',
        'pj', s ->> 'pj',
        'tujuan', s ->> 'tujuan',
        'pengecek', nullif(s ->> 'pengecek', ''),
        'steps', coalesce(s -> 'steps', '[]'::jsonb)
      ) order by (s ->> 'nama')
    ),
    '[]'::jsonb
  ) into v_sops
  from jsonb_array_elements(coalesce(v_sops, '[]'::jsonb)) as s
  where s ->> 'nama' is not null and s ->> 'nama' <> ''
    and jsonb_typeof(s -> 'steps') = 'array';

  -- Catatan pegawai ini hari ini saja (untuk memulihkan centang).
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'sop_id', j.sop_id,
        'langkah_selesai', j.langkah_selesai,
        'selesai', j.selesai,
        'dicek_oleh', j.dicek_oleh,
        'dicek_pada', j.dicek_pada,
        'catatan', j.catatan
      )
    ),
    '[]'::jsonb
  ) into v_jalankan
  from public.sop_jalankan j
  where j.pegawai_email = v_email
    and j.pemilik_id = v_pemilik_id
    and j.tanggal = current_date;

  return jsonb_build_object(
    'nama_usaha', v_nama_usaha,
    'pegawai_nama', v_nama,
    'peran', coalesce(v_peran, '{}'::text[]),
    'sops', coalesce(v_sops, '[]'::jsonb),
    'jalankan_hari_ini', coalesce(v_jalankan, '[]'::jsonb)
  );
end;
$$;
comment on function public.sops_untuk_pegawai() is 'SOP usaha pemilik untuk pegawai yang masuk: nama usaha, nama + peran pegawai, daftar SOP (nama, penanggung jawab, tujuan, langkah, pengecek), dan catatan jalankan pegawai itu hari ini (untuk memulihkan centang + status dicek + catatan). Hanya pegawai aktif. Tanpa data keuangan.';

revoke execute on function public.sops_untuk_pegawai() from public;
grant execute on function public.sops_untuk_pegawai() to authenticated;

-- ============================================================================
-- 5. RPC catat_sop_jalankan(p_sop_id, p_langkah_selesai, p_selesai, p_catatan)
--    — simpan / perbarui catatan harian satu SOP
-- ============================================================================
-- Menyimpan berapa langkah SOP yang sudah dicentang pegawai hari ini.
-- Satu pegawai punya SATU baris per SOP per hari: bila belum ada baris
-- hari ini, baris baru disisipkan; bila sudah ada, baris itu
-- diperbarui (upsert pada pegawai_email + sop_id + tanggal hari ini).
-- p_langkah_selesai dibatasi 0 sampai jumlah langkah SOP (bila SOP
-- ditemukan di data usaha pemilik); p_selesai benar hanya bila
-- seluruh langkah sudah dicentang.
-- p_catatan (opsional, maksimal 500 karakter): catatan singkat pegawai
-- untuk SOP hari itu. Bila tidak dikirim (null), catatan lama
-- dipertahankan; bila dikirim (termasuk string kosong), catatan
-- diganti. Panggilan lama dengan 3 argumen tetap berfungsi karena
-- parameter ke-4 punya nilai default.
-- Mengembalikan satu objek JSON: {sop_id, tanggal, langkah_selesai,
-- selesai, dicek_oleh, dicek_pada, catatan} — kolom verifikasi ikut
-- dikembalikan supaya aplikasi pegawai memulihkan keadaan yang sama
-- persis setelah muat ulang. Hanya pegawai aktif; pegawai hanya
-- mencatat atas namanya sendiri (pegawai_email selalu diambil dari
-- pemanggil, bukan dari argumen — argumen tidak bisa dipakai untuk
-- mencatat atas nama orang lain).
create or replace function public.catat_sop_jalankan(
  p_sop_id text,
  p_langkah_selesai int,
  p_selesai boolean,
  p_catatan text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_pemilik_id uuid;
  v_jumlah_langkah int;
  v_langkah int;
  v_selesai boolean;
  v_tanggal date := current_date;
  v_dicek_oleh text;
  v_dicek_pada timestamptz;
  v_catatan text;
begin
  perform public.periksa_pegawai();

  select a.pemilik_id into v_pemilik_id
  from public.akses_pegawai a
  where a.email = v_email and a.aktif
  limit 1;

  if p_sop_id is null or p_sop_id = '' then
    raise exception 'SOP tidak dikenal.';
  end if;

  -- Jumlah langkah SOP (bila SOP ditemukan di data usaha pemilik).
  select jsonb_array_length(s -> 'steps') into v_jumlah_langkah
  from public.umkm_data ud,
       jsonb_array_elements(coalesce(ud.data -> 'sops', '[]'::jsonb)) as s
  where ud.user_id = v_pemilik_id
    and s ->> 'id' = p_sop_id
    and jsonb_typeof(s -> 'steps') = 'array'
  limit 1;

  v_langkah := greatest(coalesce(p_langkah_selesai, 0), 0);
  if v_jumlah_langkah is not null then
    v_langkah := least(v_langkah, v_jumlah_langkah);
    v_selesai := (v_langkah >= v_jumlah_langkah and v_jumlah_langkah > 0);
  else
    v_selesai := coalesce(p_selesai, false);
  end if;

  if p_catatan is not null and char_length(p_catatan) > 500 then
    raise exception 'Catatan terlalu panjang (maksimal 500 karakter).';
  end if;

  insert into public.sop_jalankan
    (pegawai_email, pemilik_id, sop_id, tanggal, langkah_selesai, selesai, catatan)
  values (v_email, v_pemilik_id, p_sop_id, v_tanggal, v_langkah, v_selesai, p_catatan)
  on conflict (pegawai_email, sop_id, tanggal)
  do update set langkah_selesai = excluded.langkah_selesai,
                selesai = excluded.selesai,
                catatan = coalesce(excluded.catatan, sop_jalankan.catatan);

  select j.dicek_oleh, j.dicek_pada, j.catatan
    into v_dicek_oleh, v_dicek_pada, v_catatan
  from public.sop_jalankan j
  where j.pegawai_email = v_email and j.sop_id = p_sop_id and j.tanggal = v_tanggal;

  return jsonb_build_object(
    'sop_id', p_sop_id,
    'tanggal', v_tanggal,
    'langkah_selesai', v_langkah,
    'selesai', v_selesai,
    'dicek_oleh', v_dicek_oleh,
    'dicek_pada', v_dicek_pada,
    'catatan', v_catatan
  );
end;
$$;
comment on function public.catat_sop_jalankan(text, integer, boolean, text) is 'Simpan/perbarui catatan harian satu SOP untuk pegawai yang masuk: jumlah langkah yang sudah dicentang + apakah SOP selesai hari itu + catatan singkat (opsional, maksimal 500 karakter). Satu baris per pegawai per SOP per hari (upsert). Hanya pegawai aktif; pegawai hanya mencatat atas namanya sendiri.';

revoke execute on function public.catat_sop_jalankan(text, integer, boolean, text) from public;
grant execute on function public.catat_sop_jalankan(text, integer, boolean, text) to authenticated;

-- ============================================================================
-- 6. RPC ringkasan_tim_untuk_pemilik() — siapa menjalankan SOP apa, kapan
-- ============================================================================
-- Mengembalikan satu baris per catatan jalankan SOP pegawai usaha
-- pemilik yang memanggil (paling baru dulu, maks 200 baris):
--   pegawai_nama   : nama pegawai (dari akses_pegawai)
--   pegawai_email  : email pegawai (di-cast ke ::text)
--   sop_id         : id SOP di data usaha pemilik
--   sop_nama       : nama SOP (dicari di umkm_data.data -> 'sops';
--     null bila SOP sudah dihapus pemilik, sop_id tetap tampil)
--   tanggal        : tanggal SOP dijalankan
--   langkah_selesai: jumlah langkah yang dicentang hari itu
--   selesai        : apakah SOP selesai hari itu
--   dicatat_pada   : waktu baris pertama kali dicatat
--   dicek_oleh     : nama pemeriksa yang menandai pekerjaan ini sudah
--     dicek (null bila belum dicek; "Pemilik" bila pemilik usaha)
--   dicek_pada     : waktu pekerjaan ditandai sudah dicek (null bila
--     belum dicek)
--   foto_path      : jalur pas foto wajah pegawai (dari akses_pegawai;
--     null bila pegawai belum mengunggah — aplikasi utama menampilkan
--     inisial nama sebagai pengganti)
-- Setiap pemilik usaha yang terautentikasi boleh memanggil dan hanya
-- melihat log timnya sendiri (dibatasi pemilik_id = auth.uid()).
-- Pemanggil yang belum punya pegawai mendapat himpunan kosong, bukan
-- error. Dipakai aplikasi utama (modul Orang & SOP) untuk tampilan
-- "Siapa menjalankan SOP".
create or replace function public.ringkasan_tim_untuk_pemilik()
returns table(
  pegawai_nama text,
  pegawai_email text,
  foto_path text,
  sop_id text,
  sop_nama text,
  tanggal date,
  langkah_selesai int,
  selesai boolean,
  dicatat_pada timestamptz,
  dicek_oleh text,
  dicek_pada timestamptz
)
language plpgsql security definer set search_path = public as $$
declare
  v_pemilik_id uuid := auth.uid();
begin
  return query
  select
    a.nama::text as pegawai_nama,
    j.pegawai_email::text as pegawai_email,
    a.foto_path::text as foto_path,
    j.sop_id::text as sop_id,
    (
      select s ->> 'nama'
      from public.umkm_data ud,
           jsonb_array_elements(coalesce(ud.data -> 'sops', '[]'::jsonb)) as s
      where ud.user_id = j.pemilik_id
        and s ->> 'id' = j.sop_id
      limit 1
    )::text as sop_nama,
    j.tanggal,
    j.langkah_selesai,
    j.selesai,
    j.created_at as dicatat_pada,
    j.dicek_oleh,
    j.dicek_pada
  from public.sop_jalankan j
  left join public.akses_pegawai a on a.email = j.pegawai_email
  where j.pemilik_id = v_pemilik_id
  order by j.tanggal desc, j.created_at desc
  limit 200;
end;
$$;
comment on function public.ringkasan_tim_untuk_pemilik() is 'Ringkasan tim untuk setiap pemilik usaha: siapa (nama + email + pas foto pegawai) menjalankan SOP apa (nama SOP), kapan, berapa langkah, apakah selesai, dan siapa yang memeriksanya (dicek_oleh, dicek_pada). Hanya log tim pemanggil sendiri (pemilik_id = auth.uid()); pemanggil tanpa pegawai mendapat himpunan kosong, bukan error. Maks 200 baris, paling baru dulu.';

revoke execute on function public.ringkasan_tim_untuk_pemilik() from public;
grant execute on function public.ringkasan_tim_untuk_pemilik() to authenticated;

-- ============================================================================
-- 7. TABEL laporan_pegawai — laporan harian pegawai (foto / kwitansi)
-- ============================================================================
-- Satu baris = satu laporan yang dikirim pegawai ke pemilik usahanya.
--   jenis      : 'foto' (foto kegiatan — misal kondisi warung, hasil
--     kerja) atau 'kwitansi' (bukti belanja / bayar dengan jumlah Rp).
--   jumlah     : hanya untuk kwitansi (jumlah Rp yang tertulis di
--     kwitansi itu). PRIVASI: jumlah ini adalah data kwitansi itu
--     sendiri yang diserahkan pegawai, BUKAN angka keuangan usaha —
--     pegawai hanya melihat kwitansinya sendiri, pemilik melihat
--     kwitansi pegawainya sendiri. Foto tidak punya jumlah (null).
--   file_path  : jalur berkas foto di bucket privat bukti-pegawai
--     (lihat bagian 8); null bila laporan tanpa foto.
--   dicatat    : true bila pemilik sudah mencatat kwitansi ini ke
--     dalam catatannya (diubah pemilik lewat RPC tandai, bagian 9);
--     foto tidak pernah dicatat (tetap false).
--   tanggal    : tanggal laporan dikirim (dipakai batas foto harian).
-- Batas foto harian ditegakkan DI DALAM RPC kirim (bagian 9), bukan
-- di tabel: maks 5 foto per pegawai per hari. Pas foto TIDAK dihitung
-- ke batas ini — pas foto sekali per pegawai, bukan laporan harian.
-- Retensi: foto laporan disimpan 12 bulan; pemilik memeriksa bila
-- penyimpanan mulai penuh (tidak ada hapus otomatis di build ini).
create table if not exists public.laporan_pegawai (
  id uuid not null primary key default gen_random_uuid(),
  pegawai_email text not null,
  pemilik_id uuid not null,
  jenis text not null check (jenis in ('foto','kwitansi')),
  keterangan text not null,
  jumlah numeric,
  file_path text,
  sop_id text,
  tanggal date not null default current_date,
  dicatat boolean not null default false,
  dicatat_pada timestamptz,
  created_at timestamptz not null default now()
);
comment on table public.laporan_pegawai is 'Laporan harian pegawai ke pemilik usaha: foto kegiatan atau kwitansi belanja/bayar. Jumlah hanya ada pada kwitansi — itu data kwitansi yang diserahkan pegawai, bukan angka keuangan usaha.';
comment on column public.laporan_pegawai.jumlah is 'Jumlah Rp pada kwitansi (hanya jenis kwitansi; null untuk foto). Data kwitansi yang diserahkan pegawai, bukan angka keuangan usaha.';
comment on column public.laporan_pegawai.file_path is 'Jalur foto di bucket privat bukti-pegawai (awalan pemilik_id/email). Null bila laporan tanpa foto.';
comment on column public.laporan_pegawai.dicatat is 'Benar bila pemilik sudah mencatat kwitansi ini ke dalam catatannya (diubah pemilik lewat RPC tandai_laporan_dicatat). Foto tidak pernah dicatat.';
comment on column public.laporan_pegawai.tanggal is 'Tanggal laporan dikirim; dipakai batas 5 foto per pegawai per hari.';

alter table public.laporan_pegawai enable row level security;

-- Membaca: pegawai hanya membaca laporannya sendiri; pemilik usaha
-- membaca laporan pegawai usahanya sendiri.
drop policy if exists "laporan baca sendiri" on public.laporan_pegawai;
create policy "laporan baca sendiri" on public.laporan_pegawai
  for select using (auth.jwt() ->> 'email' = pegawai_email);

drop policy if exists "laporan baca pemilik" on public.laporan_pegawai;
create policy "laporan baca pemilik" on public.laporan_pegawai
  for select using (auth.uid() = pemilik_id);

-- Menulis: pegawai hanya menulis laporan atas namanya sendiri
-- (RPC kirim tetap memeriksa izin + batas foto harian di dalam).
drop policy if exists "laporan tulis sendiri" on public.laporan_pegawai;
create policy "laporan tulis sendiri" on public.laporan_pegawai
  for insert to authenticated
  with check (auth.jwt() ->> 'email' = pegawai_email);

-- Mengubah: hanya pemilik usaha, untuk laporan pegawai usahanya
-- (menandai kwitansi sudah dicatat — lihat RPC tandai, bagian 9).
drop policy if exists "laporan ubah pemilik" on public.laporan_pegawai;
create policy "laporan ubah pemilik" on public.laporan_pegawai
  for update to authenticated
  using (auth.uid() = pemilik_id)
  with check (auth.uid() = pemilik_id);

-- ============================================================================
-- 8. BUCKET PRIVAT bukti-pegawai — foto laporan + pas foto
-- ============================================================================
-- Satu bucket privat untuk SEMUA foto pegawai (bukan bucket publik —
-- foto hanya dibuka lewat tautan bertanda tangan 1 jam, tidak pernah
-- lewat tautan publik).
--   Foto laporan : <pemilik_id>/<pegawai_email>/<uuid>.jpg
--   Pas foto     : pasfoto/<pemilik_id>/<pegawai_email>/<uuid>.jpg
-- Folder pertama membedakan pemilik (foto laporan) atau awalan
-- pasfoto/; kebijakan di bawah membatasi berdasarkan folder itu.
-- Foto laporan dikompres di HP pegawai sebelum diunggah (kanvas maks
-- 1200px, JPEG 0.7, target ~100–300 KB, tipikal ~150 KB). Pas foto
-- sekali per pegawai (~150 KB sekali) — biaya penyimpanannya dapat
-- diabaikan (~Rp8 sekali per pegawai) dan TIDAK dihitung ke batas
-- foto harian.
insert into storage.buckets (id, name, public)
values ('bukti-pegawai', 'bukti-pegawai', false)
on conflict (id) do nothing;

alter table storage.objects enable row level security;

-- Foto laporan — pegawai mengunggah hanya ke folder pemiliknya
-- sendiri, atas namanya sendiri (pemilik_id diambil dari baris
-- akses_pegawai pegawai itu; perbandingan sebagai teks supaya jalur
-- yang bukan UUID — misal awalan pasfoto/ — sekadar tidak cocok,
-- bukan galat).
drop policy if exists "bukti pegawai laporan unggah sendiri" on storage.objects;
create policy "bukti pegawai laporan unggah sendiri" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'bukti-pegawai'
    and (storage.foldername(name))[2] = auth.jwt() ->> 'email'
    and (storage.foldername(name))[1] = (
      select a.pemilik_id::text from public.akses_pegawai a
      where a.email = auth.jwt() ->> 'email' and a.aktif
      limit 1
    )
  );

-- Foto laporan — pegawai membaca hanya fotonya sendiri.
drop policy if exists "bukti pegawai laporan baca sendiri" on storage.objects;
create policy "bukti pegawai laporan baca sendiri" on storage.objects
  for select using (
    bucket_id = 'bukti-pegawai'
    and (storage.foldername(name))[2] = auth.jwt() ->> 'email'
    and (storage.foldername(name))[1] = (
      select a.pemilik_id::text from public.akses_pegawai a
      where a.email = auth.jwt() ->> 'email' and a.aktif
      limit 1
    )
  );

-- Pas foto — pegawai mengunggah hanya pas fotonya sendiri.
drop policy if exists "bukti pegawai pasfoto unggah sendiri" on storage.objects;
create policy "bukti pegawai pasfoto unggah sendiri" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'bukti-pegawai'
    and (storage.foldername(name))[1] = 'pasfoto'
    and (storage.foldername(name))[3] = auth.jwt() ->> 'email'
    and (storage.foldername(name))[2] = (
      select a.pemilik_id::text from public.akses_pegawai a
      where a.email = auth.jwt() ->> 'email' and a.aktif
      limit 1
    )
  );

-- Pas foto — pegawai membaca hanya pas fotonya sendiri (TIDAK pernah
-- pas foto pegawai lain).
drop policy if exists "bukti pegawai pasfoto baca sendiri" on storage.objects;
create policy "bukti pegawai pasfoto baca sendiri" on storage.objects
  for select using (
    bucket_id = 'bukti-pegawai'
    and (storage.foldername(name))[1] = 'pasfoto'
    and (storage.foldername(name))[3] = auth.jwt() ->> 'email'
    and (storage.foldername(name))[2] = (
      select a.pemilik_id::text from public.akses_pegawai a
      where a.email = auth.jwt() ->> 'email' and a.aktif
      limit 1
    )
  );

-- Semua foto — pemilik usaha membaca hanya foto pegawai usahanya
-- sendiri (foto laporan di folder pemilik_id-nya, pas foto di folder
-- pasfoto/pemilik_id-nya).
drop policy if exists "bukti pegawai pemilik baca tim" on storage.objects;
create policy "bukti pegawai pemilik baca tim" on storage.objects
  for select using (
    bucket_id = 'bukti-pegawai'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or ((storage.foldername(name))[1] = 'pasfoto'
          and (storage.foldername(name))[2] = auth.uid()::text)
    )
  );

-- ============================================================================
-- 9. RPC LAPORAN + PAS FOTO
-- ============================================================================
-- Mengirim satu laporan (foto kegiatan atau kwitansi) dari pegawai
-- yang masuk ke pemilik usahanya.
--   p_jenis     : 'foto' atau 'kwitansi'
--   p_keterangan: keterangan laporan (wajib diisi)
--   p_jumlah    : jumlah Rp — wajib > 0 bila jenis kwitansi; diabaikan
--     (disimpan null) bila jenis foto
--   p_file_path : jalur foto di bucket bukti-pegawai — wajib bila jenis
--     foto; boleh kosong bila kwitansi tanpa foto
--   p_sop_id    : SOP terkait (boleh kosong)
-- Batas foto harian: maks 5 foto per pegawai per hari — bila sudah 5
-- laporan jenis foto hari ini, RPC berhenti dengan pesan
-- "Batas foto hari ini sudah tercapai (5 foto)." (pas foto TIDAK
-- dihitung — pas foto sekali per pegawai, lewat RPC simpan_pas_foto
-- di bawah, bukan lewat RPC ini).
-- pegawai_email + pemilik_id selalu diambil dari pemanggil, bukan
-- dari argumen. Mengembalikan satu objek JSON: {id, jenis,
-- keterangan, jumlah, file_path, sop_id, tanggal, dicatat}.
create or replace function public.kirim_laporan_pegawai(
  p_jenis text,
  p_keterangan text,
  p_jumlah numeric,
  p_file_path text,
  p_sop_id text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_pemilik_id uuid;
  v_foto_hari_ini int;
  v_id uuid;
  v_keterangan text := btrim(coalesce(p_keterangan, ''));
  v_file_path text := nullif(btrim(coalesce(p_file_path, '')), '');
  v_sop_id text := nullif(btrim(coalesce(p_sop_id, '')), '');
  v_jumlah numeric;
begin
  perform public.periksa_pegawai();

  select a.pemilik_id into v_pemilik_id
  from public.akses_pegawai a
  where a.email = v_email and a.aktif
  limit 1;

  if p_jenis is null or p_jenis not in ('foto', 'kwitansi') then
    raise exception 'Jenis laporan tidak dikenal.';
  end if;
  if v_keterangan = '' then
    raise exception 'Keterangan laporan belum diisi.';
  end if;

  if p_jenis = 'kwitansi' then
    if p_jumlah is null or p_jumlah <= 0 then
      raise exception 'Jumlah kwitansi harus lebih dari Rp 0.';
    end if;
    v_jumlah := p_jumlah;
  else
    v_jumlah := null;
    if v_file_path is null then
      raise exception 'Foto laporan belum diunggah.';
    end if;
  end if;

  if p_jenis = 'foto' then
    select count(*) into v_foto_hari_ini
    from public.laporan_pegawai l
    where l.pegawai_email = v_email
      and l.jenis = 'foto'
      and l.tanggal = current_date;
    if v_foto_hari_ini >= 5 then
      raise exception 'Batas foto hari ini sudah tercapai (5 foto).';
    end if;
  end if;

  insert into public.laporan_pegawai
    (pegawai_email, pemilik_id, jenis, keterangan, jumlah, file_path, sop_id)
  values (v_email, v_pemilik_id, p_jenis, v_keterangan, v_jumlah, v_file_path, v_sop_id)
  returning id into v_id;

  return jsonb_build_object(
    'id', v_id,
    'jenis', p_jenis,
    'keterangan', v_keterangan,
    'jumlah', v_jumlah,
    'file_path', v_file_path,
    'sop_id', v_sop_id,
    'tanggal', current_date,
    'dicatat', false
  );
end;
$$;
comment on function public.kirim_laporan_pegawai(text, text, numeric, text, text) is 'Kirim satu laporan pegawai (foto kegiatan / kwitansi) ke pemilik usaha. Hanya pegawai aktif; pegawai hanya mengirim atas namanya sendiri. Batas 5 foto per pegawai per hari (pas foto tidak dihitung). Jumlah wajib > 0 untuk kwitansi; foto wajib membawa jalur foto.';

revoke execute on function public.kirim_laporan_pegawai(text, text, numeric, text, text) from public;
grant execute on function public.kirim_laporan_pegawai(text, text, numeric, text, text) to authenticated;

-- Laporan pegawai yang masuk, paling baru dulu, maks 200 baris:
--   id, jenis, keterangan, jumlah, file_path, sop_id, sop_nama,
--   tanggal, dicatat.
-- sop_nama dicari di umkm_data.data -> 'sops'; null bila SOP sudah
-- dihapus pemilik, sop_id tetap tampil. Hanya laporan pegawai itu
-- sendiri — pegawai TIDAK PERNAH melihat laporan pegawai lain.
create or replace function public.laporan_saya()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_hasil jsonb;
begin
  perform public.periksa_pegawai();

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', x.id,
        'jenis', x.jenis,
        'keterangan', x.keterangan,
        'jumlah', x.jumlah,
        'file_path', x.file_path,
        'sop_id', x.sop_id,
        'sop_nama', x.sop_nama,
        'tanggal', x.tanggal,
        'dicatat', x.dicatat
      ) order by x.tanggal desc, x.created_at desc
    ),
    '[]'::jsonb
  ) into v_hasil
  from (
    select
      l.id, l.jenis, l.keterangan, l.jumlah, l.file_path,
      l.sop_id, l.tanggal, l.dicatat, l.created_at,
      (
        select s ->> 'nama'
        from public.umkm_data ud,
             jsonb_array_elements(coalesce(ud.data -> 'sops', '[]'::jsonb)) as s
        where ud.user_id = l.pemilik_id
          and s ->> 'id' = l.sop_id
        limit 1
      )::text as sop_nama
    from public.laporan_pegawai l
    where l.pegawai_email = v_email
    order by l.tanggal desc, l.created_at desc
    limit 200
  ) as x;

  return v_hasil;
end;
$$;
comment on function public.laporan_saya() is 'Laporan pegawai yang masuk (paling baru dulu, maks 200): foto/kwitansi, keterangan, jumlah kwitansi, jalur foto, SOP terkait, tanggal, dan apakah sudah dicatat pemilik. Hanya laporan pegawai itu sendiri.';

revoke execute on function public.laporan_saya() from public;
grant execute on function public.laporan_saya() to authenticated;

-- Laporan tim untuk setiap pemilik usaha yang masuk (paling baru dulu,
-- maks 200 baris):
--   id, pegawai_nama, pegawai_email, foto_path, jenis, keterangan,
--   jumlah, file_path, sop_id, sop_nama, tanggal, dicatat, dicatat_pada.
-- id dipakai aplikasi utama untuk menandai kwitansi sudah dicatat.
-- foto_path = jalur pas foto wajah pegawai (null bila belum diunggah).
-- TANPA gate pemilik aplikasi (pelajaran dari perbaikan gate
-- ringkasan tim): setiap pemilik hanya melihat laporan timnya sendiri
-- (pemilik_id = auth.uid()). Pemanggil yang belum punya pegawai
-- mendapat himpunan kosong, bukan error. Dipakai aplikasi utama
-- (modul Orang & SOP) untuk tampilan "Laporan pegawai".
create or replace function public.laporan_tim_untuk_pemilik()
returns table(
  id uuid,
  pegawai_nama text,
  pegawai_email text,
  foto_path text,
  jenis text,
  keterangan text,
  jumlah numeric,
  file_path text,
  sop_id text,
  sop_nama text,
  tanggal date,
  dicatat boolean,
  dicatat_pada timestamptz
)
language plpgsql security definer set search_path = public as $$
declare
  v_pemilik_id uuid := auth.uid();
begin
  return query
  select
    l.id as id,
    a.nama::text as pegawai_nama,
    l.pegawai_email::text as pegawai_email,
    a.foto_path::text as foto_path,
    l.jenis::text as jenis,
    l.keterangan::text as keterangan,
    l.jumlah as jumlah,
    l.file_path::text as file_path,
    l.sop_id::text as sop_id,
    (
      select s ->> 'nama'
      from public.umkm_data ud,
           jsonb_array_elements(coalesce(ud.data -> 'sops', '[]'::jsonb)) as s
      where ud.user_id = l.pemilik_id
        and s ->> 'id' = l.sop_id
      limit 1
    )::text as sop_nama,
    l.tanggal,
    l.dicatat,
    l.dicatat_pada
  from public.laporan_pegawai l
  left join public.akses_pegawai a on a.email = l.pegawai_email
  where l.pemilik_id = v_pemilik_id
  order by l.tanggal desc, l.created_at desc
  limit 200;
end;
$$;
comment on function public.laporan_tim_untuk_pemilik() is 'Laporan tim untuk setiap pemilik usaha: id laporan, pegawai (nama + email + pas foto), jenis laporan, keterangan, jumlah kwitansi, jalur foto, SOP terkait, tanggal, dan apakah sudah dicatat pemilik. Hanya laporan tim pemanggil sendiri (pemilik_id = auth.uid()); pemanggil tanpa pegawai mendapat himpunan kosong, bukan error. Maks 200 baris, paling baru dulu.';

revoke execute on function public.laporan_tim_untuk_pemilik() from public;
grant execute on function public.laporan_tim_untuk_pemilik() to authenticated;

-- Menandai satu kwitansi sudah dicatat pemilik. Hanya pemilik usaha
-- untuk laporan pegawai usahanya sendiri (pemilik_id = auth.uid()).
-- Mengubah dicatat=true + dicatat_pada=now() HANYA bila dicatat masih
-- false — bila laporan sudah dicatat, baris dikembalikan apa adanya
-- (tanpa perubahan, tanpa galat), supaya pemanggil yang mengetuk dua
-- kali tidak mencatat ganda. Laporan yang bukan milik tim pemanggil
-- tidak ditemukan (bukan galat akses).
create or replace function public.tandai_laporan_dicatat(
  p_laporan_id uuid
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_pemilik_id uuid := auth.uid();
  v_id uuid;
  v_dicatat boolean;
begin
  update public.laporan_pegawai l
  set dicatat = true, dicatat_pada = now()
  where l.id = p_laporan_id
    and l.pemilik_id = v_pemilik_id
    and l.dicatat = false
  returning l.id, l.dicatat into v_id, v_dicatat;

  if v_id is null then
    select l.id, l.dicatat into v_id, v_dicatat
    from public.laporan_pegawai l
    where l.id = p_laporan_id
      and l.pemilik_id = v_pemilik_id;
    if v_id is null then
      raise exception 'Laporan tidak ditemukan.';
    end if;
  end if;

  return jsonb_build_object('id', v_id, 'dicatat', v_dicatat);
end;
$$;
comment on function public.tandai_laporan_dicatat(uuid) is 'Menandai satu laporan tim sudah dicatat pemilik (dicatat=true + waktu dicatat). Hanya pemilik untuk laporan timnya sendiri. Bila sudah dicatat, baris dikembalikan apa adanya tanpa galat — tidak pernah mencatat ganda.';

revoke execute on function public.tandai_laporan_dicatat(uuid) from public;
grant execute on function public.tandai_laporan_dicatat(uuid) to authenticated;

-- Menyimpan jalur pas foto wajah pegawai yang masuk.
--   p_foto_path: jalur di bucket bukti-pegawai, harus berawalan
--     pasfoto/ (lihat bagian 8).
-- Hanya pegawai aktif; yang diubah HANYA kolom foto_path pada baris
-- pegawai itu sendiri (nama, peran, dan aktif TIDAK disentuh).
-- CATATAN KEAMANAN: jalur ini sengaja TIDAK dibuka lewat kebijakan
-- tulis langsung di tabel akses_pegawai — kebijakan tulis langsung
-- akan membiarkan pegawai mengubah nama, peran, atau aktifnya
-- sendiri. RPC security definer ini hanya menulis foto_path.
-- Mengembalikan satu objek JSON: {foto_path}.
create or replace function public.simpan_pas_foto(
  p_foto_path text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_jalur text := btrim(coalesce(p_foto_path, ''));
begin
  perform public.periksa_pegawai();

  if v_jalur = '' then
    raise exception 'Pas foto belum diunggah.';
  end if;
  if left(v_jalur, 8) <> 'pasfoto/' then
    raise exception 'Jalur pas foto tidak dikenal.';
  end if;

  update public.akses_pegawai a
  set foto_path = v_jalur
  where a.email = v_email and a.aktif;

  return jsonb_build_object('foto_path', v_jalur);
end;
$$;
comment on function public.simpan_pas_foto(text) is 'Menyimpan jalur pas foto wajah pegawai yang masuk (harus berawalan pasfoto/). Hanya pegawai aktif; hanya kolom foto_path pada baris pegawai itu sendiri yang diubah.';

revoke execute on function public.simpan_pas_foto(text) from public;
grant execute on function public.simpan_pas_foto(text) to authenticated;

-- ============================================================================
-- 10. RPC VERIFIKASI SOP — siapa memeriksa pekerjaan siapa
-- ============================================================================
-- Pegawai mencentang semua langkah -> SOP menunggu dicek -> pemeriksa
-- (yang ditunjuk di kolom "pengecek" SOP itu, atau pemilik usaha)
-- menandainya sudah dicek. Verifikasi dicatat di baris sop_jalankan
-- yang sama (kolom dicek_oleh + dicek_pada, bagian 2) — tidak ada
-- tabel baru.
--
-- Aturan pemeriksa (mengikuti aturan "SOP yang saya pimpin" yang
-- sudah ada di aplikasi pegawai — bandingkan nama dengan trim +
-- huruf kecil):
--   * Pemilik usaha boleh menandai sudah dicek untuk BARIS TIMNYA
--     SENDIRI (pemilik_id = auth.uid()); dicatat dicek_oleh 'Pemilik'.
--   * Pegawai hanya boleh menandai pekerjaan pegawai LAIN dari usaha
--     yang sama, dan hanya bila namanya cocok dengan pengecek SOP itu.
--     Ada SATU larangan tambahan: pemeriksa TIDAK BOLEH menandai
--     pekerjaannya sendiri (pengecek memeriksa orang lain — bila ia
--     sendiri yang menjalankan SOP itu, yang menandai adalah pemilik
--     usaha). Larangan ini dijaga server, bukan hanya di layar.
--   * SOP tanpa pengecek (kosong) diperiksa oleh pemilik usaha saja.
-- Pekerjaan yang belum selesai (selesai = false) tidak bisa ditandai
-- sudah dicek. Bila sudah dicek, panggilan kedua mengembalikan baris
-- yang sama tanpa galat dan tanpa mengubah dicek_pada.
create or replace function public.verifikasi_sop_jalankan(
  p_pegawai_email text,
  p_sop_id text,
  p_tanggal date
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_pemilik_id uuid;
  v_nama text;
  v_sop_pengecek text;
  v_selesai boolean;
  v_dicek_oleh text;
  v_dicek_pada timestamptz;
begin
  if p_pegawai_email is null or btrim(p_pegawai_email) = '' then
    raise exception 'Pegawai tidak dikenal.';
  end if;
  if p_sop_id is null or p_sop_id = '' then
    raise exception 'SOP tidak dikenal.';
  end if;
  if p_tanggal is null then
    raise exception 'Tanggal tidak dikenal.';
  end if;

  -- Apakah pemanggil pegawai aktif (punya baris akses_pegawai)?
  select a.pemilik_id, a.nama into v_pemilik_id, v_nama
  from public.akses_pegawai a
  where a.email = v_email and a.aktif
  limit 1;

  if v_pemilik_id is null then
    -- Pemanggil bukan pegawai aktif: ia adalah pemilik usaha yang
    -- memverifikasi timnya sendiri. Nama yang dicatat: 'Pemilik'.
    v_pemilik_id := auth.uid();
    v_nama := 'Pemilik';
    select j.selesai, j.dicek_oleh, j.dicek_pada
      into v_selesai, v_dicek_oleh, v_dicek_pada
    from public.sop_jalankan j
    where j.pegawai_email = p_pegawai_email
      and j.sop_id = p_sop_id
      and j.tanggal = p_tanggal
      and j.pemilik_id = v_pemilik_id;
    if not found then
      raise exception 'Hanya pemilik usaha yang boleh menandai pekerjaan ini sudah dicek.';
    end if;
  else
    -- Pemanggil pegawai aktif: baris yang dicek harus dari usaha
    -- yang sama; pemanggil tidak boleh memeriksa pekerjaannya
    -- sendiri; dan namanya harus cocok dengan pengecek SOP itu.
    select j.selesai, j.dicek_oleh, j.dicek_pada
      into v_selesai, v_dicek_oleh, v_dicek_pada
    from public.sop_jalankan j
    where j.pegawai_email = p_pegawai_email
      and j.sop_id = p_sop_id
      and j.tanggal = p_tanggal
      and j.pemilik_id = v_pemilik_id;
    if not found then
      raise exception 'Hanya pemeriksa SOP ini yang boleh menandainya sudah dicek.';
    end if;
    if lower(btrim(p_pegawai_email)) = lower(btrim(v_email)) then
      raise exception 'Pemeriksa tidak boleh menandai pekerjaannya sendiri.';
    end if;
    select nullif(s ->> 'pengecek', '') into v_sop_pengecek
    from public.umkm_data ud,
         jsonb_array_elements(coalesce(ud.data -> 'sops', '[]'::jsonb)) as s
    where ud.user_id = v_pemilik_id
      and s ->> 'id' = p_sop_id
    limit 1;
    if v_sop_pengecek is null then
      raise exception 'SOP ini diperiksa oleh pemilik usaha.';
    end if;
    if lower(btrim(v_sop_pengecek)) <> lower(btrim(v_nama)) then
      raise exception 'Hanya pemeriksa SOP ini yang boleh menandainya sudah dicek.';
    end if;
  end if;

  if not coalesce(v_selesai, false) then
    raise exception 'Pekerjaan belum selesai — tandai sudah dicek hanya bila seluruh langkah sudah dicentang.';
  end if;

  if v_dicek_oleh is not null then
    -- Sudah dicek sebelumnya: kembalikan baris yang sama tanpa
    -- galat dan tanpa mengubah dicek_pada.
    return jsonb_build_object(
      'pegawai_email', p_pegawai_email,
      'sop_id', p_sop_id,
      'tanggal', p_tanggal,
      'dicek_oleh', v_dicek_oleh,
      'dicek_pada', v_dicek_pada
    );
  end if;

  update public.sop_jalankan j
    set dicek_oleh = v_nama, dicek_pada = now()
  where j.pegawai_email = p_pegawai_email
    and j.sop_id = p_sop_id
    and j.tanggal = p_tanggal
    and j.dicek_oleh is null
  returning j.dicek_oleh, j.dicek_pada into v_dicek_oleh, v_dicek_pada;

  if v_dicek_oleh is null then
    -- Perlumbaan dengan panggilan lain yang menandai lebih dulu:
    -- baca ulang baris yang sudah terverifikasi itu.
    select j.dicek_oleh, j.dicek_pada into v_dicek_oleh, v_dicek_pada
    from public.sop_jalankan j
    where j.pegawai_email = p_pegawai_email
      and j.sop_id = p_sop_id
      and j.tanggal = p_tanggal;
  end if;

  return jsonb_build_object(
    'pegawai_email', p_pegawai_email,
    'sop_id', p_sop_id,
    'tanggal', p_tanggal,
    'dicek_oleh', v_dicek_oleh,
    'dicek_pada', v_dicek_pada
  );
end;
$$;
comment on function public.verifikasi_sop_jalankan(text, text, date) is 'Tandai pekerjaan SOP yang sudah selesai sebagai sudah dicek, dicatat siapa dan kapan. Pemilik usaha boleh untuk timnya sendiri (dicek_oleh Pemilik); pegawai hanya bila namanya cocok dengan pengecek SOP itu dan bukan pekerjaannya sendiri. Bila sudah dicek, panggilan kedua mengembalikan baris yang sama tanpa galat.';

revoke execute on function public.verifikasi_sop_jalankan(text, text, date) from public;
grant execute on function public.verifikasi_sop_jalankan(text, text, date) to authenticated;

-- RPC perlu_dicek_untuk_pegawai() — daftar pekerjaan yang harus dicek
-- pegawai yang masuk (sebagai pemeriksa yang ditunjuk).
-- Mengembalikan array JSON, paling baru dulu, maks 200:
--   [{pegawai_nama, pegawai_email, sop_id, sop_nama, tanggal,
--     langkah_selesai}]
-- Hanya baris  selesai = true, dicek_oleh masih null, milik usaha
-- yang sama, SOP-nya menunjuk pemanggil sebagai pengecek (trim +
-- huruf kecil), dan BUKAN pekerjaan pemanggil sendiri. Pegawai yang
-- bukan pemeriksa SOP mana pun mendapat array kosong, bukan error.
create or replace function public.perlu_dicek_untuk_pegawai()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_pemilik_id uuid;
  v_nama text;
  v_daftar jsonb;
begin
  perform public.periksa_pegawai();

  select a.pemilik_id, a.nama into v_pemilik_id, v_nama
  from public.akses_pegawai a
  where a.email = v_email and a.aktif
  limit 1;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'pegawai_nama', r.pegawai_nama,
        'pegawai_email', r.pegawai_email,
        'sop_id', r.sop_id,
        'sop_nama', r.sop_nama,
        'tanggal', r.tanggal,
        'langkah_selesai', r.langkah_selesai
      ) order by r.tanggal desc, r.dicatat_pada desc
    ),
    '[]'::jsonb
  ) into v_daftar
  from (
    select
      a2.nama::text as pegawai_nama,
      j.pegawai_email::text as pegawai_email,
      j.sop_id::text as sop_id,
      (
        select s ->> 'nama'
        from public.umkm_data ud,
             jsonb_array_elements(coalesce(ud.data -> 'sops', '[]'::jsonb)) as s
        where ud.user_id = j.pemilik_id
          and s ->> 'id' = j.sop_id
        limit 1
      )::text as sop_nama,
      j.tanggal,
      j.langkah_selesai,
      j.created_at as dicatat_pada
    from public.sop_jalankan j
    left join public.akses_pegawai a2 on a2.email = j.pegawai_email
    where j.pemilik_id = v_pemilik_id
      and j.pegawai_email <> v_email
      and j.selesai = true
      and j.dicek_oleh is null
      and exists (
        select 1
        from public.umkm_data ud,
             jsonb_array_elements(coalesce(ud.data -> 'sops', '[]'::jsonb)) as s
        where ud.user_id = j.pemilik_id
          and s ->> 'id' = j.sop_id
          and lower(btrim(coalesce(s ->> 'pengecek', ''))) = lower(btrim(v_nama))
      )
    order by j.tanggal desc, j.created_at desc
    limit 200
  ) as r;

  return coalesce(v_daftar, '[]'::jsonb);
end;
$$;
comment on function public.perlu_dicek_untuk_pegawai() is 'Pekerjaan SOP yang selesai dan menunggu dicek oleh pegawai yang masuk (sebagai pemeriksa yang ditunjuk di SOP). Hanya usaha yang sama, bukan pekerjaan sendiri. Array JSON, paling baru dulu, maks 200.';

revoke execute on function public.perlu_dicek_untuk_pegawai() from public;
grant execute on function public.perlu_dicek_untuk_pegawai() to authenticated;

-- ============================================================================
-- 11. TABEL presensi — siapa masuk / pulang, kapan
-- ============================================================================
-- Satu baris = satu pegawai pada satu hari. Masuk dan pulang dicatat
-- dengan stempel waktu server (now()); ketukan kedua pada hari yang
-- sama TIDAK menimpa stempel pertama (yang pertama yang menang).
-- TIDAK ADA lokasi/GPS di tabel ini dan di mana pun di aplikasi
-- pegawai — aturan yang berlaku.
create table if not exists public.presensi (
  id uuid not null primary key default gen_random_uuid(),
  pegawai_email text not null,
  pemilik_id uuid not null,
  tanggal date not null default current_date,
  masuk_pada timestamptz,
  pulang_pada timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint presensi_satu_baris_per_hari unique (pegawai_email, tanggal)
);
comment on table public.presensi is 'Presensi pegawai: satu baris per pegawai per hari; masuk_pada dan pulang_pada adalah stempel waktu server. Tanpa lokasi (tidak ada GPS di aplikasi pegawai).';
comment on column public.presensi.masuk_pada is 'Waktu pegawai menekan Masuk hari itu (stempel waktu server; ketukan Masuk berikutnya hari itu tidak menimpanya).';
comment on column public.presensi.pulang_pada is 'Waktu pegawai menekan Pulang hari itu (stempel waktu server; ketukan Pulang berikutnya hari itu tidak menimpanya).';

alter table public.presensi enable row level security;

-- Membaca: pegawai hanya membaca barisnya sendiri; pemilik usaha
-- membaca baris pegawai usahanya sendiri.
drop policy if exists "presensi baca sendiri" on public.presensi;
create policy "presensi baca sendiri" on public.presensi
  for select using (auth.jwt() ->> 'email' = pegawai_email);

drop policy if exists "presensi baca pemilik" on public.presensi;
create policy "presensi baca pemilik" on public.presensi
  for select using (auth.uid() = pemilik_id);

-- Menulis: pegawai hanya menulis baris atas namanya sendiri.
drop policy if exists "presensi tulis sendiri" on public.presensi;
create policy "presensi tulis sendiri" on public.presensi
  for insert to authenticated
  with check (auth.jwt() ->> 'email' = pegawai_email);

drop policy if exists "presensi ubah sendiri" on public.presensi;
create policy "presensi ubah sendiri" on public.presensi
  for update to authenticated
  using (auth.jwt() ->> 'email' = pegawai_email)
  with check (auth.jwt() ->> 'email' = pegawai_email);

-- Menghapus: hanya pemilik usaha, untuk baris pegawai usahanya.
drop policy if exists "presensi hapus pemilik" on public.presensi;
create policy "presensi hapus pemilik" on public.presensi
  for delete using (auth.uid() = pemilik_id);

-- RPC catat_presensi(p_jenis) — pegawai menekan Masuk / Pulang.
-- p_jenis harus 'masuk' atau 'pulang'. Upsert baris hari ini: Masuk
-- pertama yang menang, Pulang pertama yang menang; ketukan ulang
-- mengembalikan baris yang sama tanpa mengubah stempel. Pulang tanpa
-- Masuk tetap dicatat (masuk_pada null) — pegawai bisa masuk tanpa
-- sempat menekan Masuk. Hanya pegawai aktif; pegawai hanya mencatat
-- atas namanya sendiri. Mengembalikan {tanggal, masuk_pada,
-- pulang_pada}.
create or replace function public.catat_presensi(p_jenis text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_pemilik_id uuid;
  v_tanggal date := current_date;
  v_masuk timestamptz;
  v_pulang timestamptz;
begin
  perform public.periksa_pegawai();

  select a.pemilik_id into v_pemilik_id
  from public.akses_pegawai a
  where a.email = v_email and a.aktif
  limit 1;

  if p_jenis is null or p_jenis not in ('masuk', 'pulang') then
    raise exception 'Jenis presensi tidak dikenal.';
  end if;

  insert into public.presensi (pegawai_email, pemilik_id, tanggal,
    masuk_pada, pulang_pada, updated_at)
  values (v_email, v_pemilik_id, v_tanggal,
    case when p_jenis = 'masuk' then now() else null end,
    case when p_jenis = 'pulang' then now() else null end,
    now())
  on conflict (pegawai_email, tanggal)
  do update set
    masuk_pada = coalesce(presensi.masuk_pada, excluded.masuk_pada),
    pulang_pada = coalesce(presensi.pulang_pada, excluded.pulang_pada),
    updated_at = now();

  select p.masuk_pada, p.pulang_pada into v_masuk, v_pulang
  from public.presensi p
  where p.pegawai_email = v_email and p.tanggal = v_tanggal;

  return jsonb_build_object(
    'tanggal', v_tanggal,
    'masuk_pada', v_masuk,
    'pulang_pada', v_pulang
  );
end;
$$;
comment on function public.catat_presensi(text) is 'Catat presensi Masuk/Pulang pegawai hari ini (stempel waktu server). Satu baris per pegawai per hari (upsert); ketukan pertama yang menang. Pulang tanpa Masuk tetap dicatat. Hanya pegawai aktif, atas namanya sendiri.';

revoke execute on function public.catat_presensi(text) from public;
grant execute on function public.catat_presensi(text) to authenticated;

-- RPC presensi_saya() — presensi pegawai yang masuk hari ini +
-- riwayat 7 hari terakhir (untuk layar Presensi di aplikasi pegawai).
-- Mengembalikan {hari_ini: {tanggal, masuk_pada, pulang_pada} | null,
-- riwayat: [{tanggal, masuk_pada, pulang_pada}] paling baru dulu,
-- maks 7}. Hanya pegawai aktif, atas namanya sendiri.
create or replace function public.presensi_saya()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_hari_ini jsonb;
  v_riwayat jsonb;
begin
  perform public.periksa_pegawai();

  select jsonb_build_object(
    'tanggal', p.tanggal,
    'masuk_pada', p.masuk_pada,
    'pulang_pada', p.pulang_pada
  ) into v_hari_ini
  from public.presensi p
  where p.pegawai_email = v_email and p.tanggal = current_date;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'tanggal', p.tanggal,
        'masuk_pada', p.masuk_pada,
        'pulang_pada', p.pulang_pada
      ) order by p.tanggal desc
    ),
    '[]'::jsonb
  ) into v_riwayat
  from (
    select p.tanggal, p.masuk_pada, p.pulang_pada
    from public.presensi p
    where p.pegawai_email = v_email
      and p.tanggal < current_date
    order by p.tanggal desc
    limit 7
  ) as p;

  return jsonb_build_object(
    'hari_ini', v_hari_ini,
    'riwayat', coalesce(v_riwayat, '[]'::jsonb)
  );
end;
$$;
comment on function public.presensi_saya() is 'Presensi pegawai yang masuk: hari ini + riwayat 7 hari terakhir. Hanya pegawai aktif, atas namanya sendiri.';

revoke execute on function public.presensi_saya() from public;
grant execute on function public.presensi_saya() to authenticated;

-- RPC presensi_hari_ini_untuk_pemilik() — siapa yang hadir hari ini
-- untuk pemilik usaha yang memanggil (dipakai modul Orang & SOP di
-- aplikasi utama). Satu baris per pegawai yang punya catatan
-- presensi hari ini (pegawai yang belum menekan Masuk belum punya
-- baris — aplikasi utama menampilkannya dari daftar tim sebagai
-- "belum masuk"). Urut masuk_pada paling awal dulu; yang belum
-- menekan Masuk (masuk_pada null, hanya Pulang) di akhir. Maks 200.
-- TANPA gate pemilik aplikasi: setiap pemilik usaha boleh memanggil
-- dan hanya melihat timnya sendiri (pemilik_id = auth.uid());
-- pemanggil tanpa tim mendapat himpunan kosong, bukan error.
create or replace function public.presensi_hari_ini_untuk_pemilik()
returns table(
  pegawai_nama text,
  pegawai_email text,
  foto_path text,
  tanggal date,
  masuk_pada timestamptz,
  pulang_pada timestamptz
)
language plpgsql security definer set search_path = public as $$
declare
  v_pemilik_id uuid := auth.uid();
begin
  return query
  select
    a.nama::text as pegawai_nama,
    p.pegawai_email::text as pegawai_email,
    a.foto_path::text as foto_path,
    p.tanggal,
    p.masuk_pada,
    p.pulang_pada
  from public.presensi p
  left join public.akses_pegawai a on a.email = p.pegawai_email
  where p.pemilik_id = v_pemilik_id
    and p.tanggal = current_date
  order by p.masuk_pada asc nulls last, p.created_at asc
  limit 200;
end;
$$;
comment on function public.presensi_hari_ini_untuk_pemilik() is 'Presensi tim hari ini untuk pemilik usaha yang memanggil: siapa hadir beserta jam masuk/pulang. Hanya tim pemanggil sendiri (pemilik_id = auth.uid()); pemanggil tanpa tim mendapat himpunan kosong, bukan error. Maks 200 baris.';

revoke execute on function public.presensi_hari_ini_untuk_pemilik() from public;
grant execute on function public.presensi_hari_ini_untuk_pemilik() to authenticated;

-- ============================================================================
-- 12. TABEL pemakaian_ai + RPC KUOTA AI — anggaran bersama pemilik
-- ============================================================================
-- Pemakaian AI (isikan pegawai yang dibantu AI + pemakaian pemilik
-- sendiri) dihitung terhadap KUOTA PEMILIK per bulan kalender
-- (YYYY-MM). Batas lunak per pegawai: 20 isian dibantu AI per
-- pegawai per bulan; batas pemilik menurut tingkat paket:
--   Gratis 20, Mikro 300, Kecil 600, Menengah 1.000 per bulan.
-- Satu baris per (pemilik_id, pegawai_email, bulan). pegawai_email
-- null = pemakaian pemilik sendiri lewat aplikasi utama (dicadangkan
-- untuk nanti — lihat catatan di bawah).
--
-- TINGKAT PAKET — CELAH YANG DIDOKUMENTASIKAN (jangan diklaim
-- lebih dari ini): tingkat paket pemilik hari ini hanya tersimpan di
-- localStorage aplikasi utama (kunci umkm-introspeksi-tier-dipilih),
-- yang tidak bisa dibaca fungsi server. Aplikasi utama sejak build
-- ini juga menyimpan tingkat paketnya di cloud
-- (umkm_data.data -> 'paket_tier') setiap kali menyimpan — RPC di
-- bawah membacanya DULUAN. Urutan penentuan tingkat paket:
--   (1) paket_tier di cloud (bila valid),
--   (2) p_tier yang dikirim klien (bila valid),
--   (3) 'gratis' (20/bulan) bila tidak dapat dipastikan.
-- Artinya: penegakan batas PER PEGAWAI (20/bulan) dan pencatatan
-- pemakaian adalah penegakan server yang sesungguhnya; tetapi
-- langit-langit tingkat paket hanya sekuat sumber tingkatnya — klien
-- yang mengirim tingkat lebih tinggi bisa menaikkan langit-langit
-- bila cloud belum menyimpan tingkat. Pemilik yang paketnya sudah
-- dibayar tetap memakai tingkat berbayarnya begitu aplikasi utama
-- menyimpan sekali (paket_tier tersinkron ke cloud). Verifikasi
-- pembayaran paket sendiri tetap di alur persetujuan langganan,
-- bukan di RPC ini.
--
-- Pemakaian pemilik sendiri lewat aplikasi utama BELUM dihitung di
-- sini: proxy /api/ai-chat aplikasi utama hari ini tidak menerima
-- token sesi, jadi ia tidak bisa mengenali pemilik untuk memanggil
-- pakai_ai_pemilik. RPC pakai_ai_pemilik sudah ditambahkan sekarang
-- supaya proxy itu bisa memanggilnya nanti begitu ia mengirim token
-- sesi. Sampai saat itu, yang dihitung di tabel ini baru pemakaian
-- pegawai; pemakaian pemilik sendiri masih dihitung di localStorage
-- aplikasi utama seperti sebelumnya.
create table if not exists public.pemakaian_ai (
  id uuid not null primary key default gen_random_uuid(),
  pemilik_id uuid not null,
  pegawai_email text,
  bulan text not null,
  jumlah int not null default 0,
  updated_at timestamptz not null default now(),
  constraint pemakaian_ai_bulan_format check (bulan ~ '^[0-9]{4}-[0-9]{2}$'),
  constraint pemakaian_ai_jumlah_tidak_negatif check (jumlah >= 0)
);
comment on table public.pemakaian_ai is 'Pemakaian AI per pemilik per bulan kalender: satu baris per (pemilik_id, pegawai_email, bulan); pegawai_email null = pemakaian pemilik sendiri. Batas per pegawai 20/bulan; batas pemilik menurut tingkat paket (Gratis 20, Mikro 300, Kecil 600, Menengah 1.000).';
create unique index if not exists pemakaian_ai_unik
  on public.pemakaian_ai (pemilik_id, bulan, coalesce(pegawai_email, ''));

-- RLS aktif TANPA policy: tabel ini hanya dibaca/ditulis lewat RPC
-- security definer di bawah (pelacakan server). Pembacaan langsung
-- lewat REST ditolak — pemilik melihat pemakaian timnya lewat RPC
-- pemakaian_ai_tim_untuk_pemilik, bukan lewat tabel ini.
alter table public.pemakaian_ai enable row level security;

-- RPC pakai_ai_pegawai(p_tier) — cek + catat satu pemakaian AI
-- pegawai. Dipanggil proxy /api/ai-chat aplikasi pegawai SEBELUM
-- memanggil DeepSeek. Mengembalikan JSON:
--   {boleh, alasan, dipakai_pegawai, batas_pegawai: 20,
--    dipakai_pemilik, batas_pemilik, tier}
--   alasan = 'pegawai' bila batas lunak 20/pegawai/bulan tercapai,
--   'pemilik' bila kuota pemilik bulan ini habis, null bila boleh.
-- Bila tidak boleh, pemakaian TIDAK ditambah. Bila boleh, jumlah
-- pegawai + total pemilik bulan ini ditambah 1 (atomik dalam satu
-- pemanggilan RPC; baris pegawai dikunci supaya dua panggilan bersamaan
-- tidak melewati batas). Hanya pegawai aktif.
create or replace function public.pakai_ai_pegawai(p_tier text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_pemilik_id uuid;
  v_bulan text := to_char(current_date, 'YYYY-MM');
  v_tier text;
  v_batas_pemilik int;
  v_batas_pegawai int := 20;
  v_dipakai_pegawai int;
  v_dipakai_pemilik int;
begin
  perform public.periksa_pegawai();

  select a.pemilik_id into v_pemilik_id
  from public.akses_pegawai a
  where a.email = v_email and a.aktif
  limit 1;

  -- Tingkat paket: (1) cloud, (2) klien, (3) 'gratis'.
  select nullif(ud.data ->> 'paket_tier', '') into v_tier
  from public.umkm_data ud
  where ud.user_id = v_pemilik_id;
  if v_tier is null or v_tier not in ('gratis', 'mikro', 'kecil', 'menengah') then
    v_tier := nullif(btrim(coalesce(p_tier, '')), '');
  end if;
  if v_tier is null or v_tier not in ('gratis', 'mikro', 'kecil', 'menengah') then
    v_tier := 'gratis';
  end if;
  v_batas_pemilik := case v_tier
    when 'mikro' then 300
    when 'kecil' then 600
    when 'menengah' then 1000
    else 20
  end;

  -- Total pemakaian pemilik bulan ini (pemilik + semua pegawai).
  select coalesce(sum(jumlah), 0) into v_dipakai_pemilik
  from public.pemakaian_ai
  where pemilik_id = v_pemilik_id and bulan = v_bulan;

  -- Baris pegawai bulan ini (buat bila belum ada), lalu kunci.
  insert into public.pemakaian_ai (pemilik_id, pegawai_email, bulan, jumlah)
  values (v_pemilik_id, v_email, v_bulan, 0)
  on conflict (pemilik_id, bulan, (coalesce(pegawai_email, ''))) do nothing;

  select jumlah into v_dipakai_pegawai
  from public.pemakaian_ai
  where pemilik_id = v_pemilik_id and bulan = v_bulan
    and pegawai_email = v_email
  for update;

  if v_dipakai_pegawai >= v_batas_pegawai then
    return jsonb_build_object(
      'boleh', false,
      'alasan', 'pegawai',
      'dipakai_pegawai', v_dipakai_pegawai,
      'batas_pegawai', v_batas_pegawai,
      'dipakai_pemilik', v_dipakai_pemilik,
      'batas_pemilik', v_batas_pemilik,
      'tier', v_tier
    );
  end if;

  if v_dipakai_pemilik >= v_batas_pemilik then
    return jsonb_build_object(
      'boleh', false,
      'alasan', 'pemilik',
      'dipakai_pegawai', v_dipakai_pegawai,
      'batas_pegawai', v_batas_pegawai,
      'dipakai_pemilik', v_dipakai_pemilik,
      'batas_pemilik', v_batas_pemilik,
      'tier', v_tier
    );
  end if;

  update public.pemakaian_ai
    set jumlah = jumlah + 1, updated_at = now()
  where pemilik_id = v_pemilik_id
    and bulan = v_bulan
    and pegawai_email = v_email;

  return jsonb_build_object(
    'boleh', true,
    'alasan', null,
    'dipakai_pegawai', v_dipakai_pegawai + 1,
    'batas_pegawai', v_batas_pegawai,
    'dipakai_pemilik', v_dipakai_pemilik + 1,
    'batas_pemilik', v_batas_pemilik,
    'tier', v_tier
  );
end;
$$;
comment on function public.pakai_ai_pegawai(text) is 'Cek + catat satu pemakaian AI pegawai terhadap kuota pemilik bulan ini (batas lunak 20/pegawai/bulan; batas pemilik menurut tingkat paket: Gratis 20, Mikro 300, Kecil 600, Menengah 1.000). Tingkat paket dari cloud dulu, lalu klien, lalu gratis. Mengembalikan {boleh, alasan, dipakai_pegawai, batas_pegawai, dipakai_pemilik, batas_pemilik, tier}.';

revoke execute on function public.pakai_ai_pegawai(text) from public;
grant execute on function public.pakai_ai_pegawai(text) to authenticated;

-- RPC pakai_ai_pemilik(p_tier) — cek + catat satu pemakaian AI
-- pemilik sendiri (dipakai proxy /api/ai-chat aplikasi utama NANTI,
-- begitu proxy itu mengirim token sesi; hari ini BELUM dipanggil
-- siapa pun). Mengembalikan {boleh, alasan, dipakai_pemilik,
-- batas_pemilik, tier}; alasan = 'pemilik' bila kuota bulan ini
-- habis, null bila boleh. Pemakaian pemilik TIDAK dibatasi 20 —
-- pemilik memakai kuota paketnya sendiri.
create or replace function public.pakai_ai_pemilik(p_tier text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_pemilik_id uuid := auth.uid();
  v_bulan text := to_char(current_date, 'YYYY-MM');
  v_tier text;
  v_batas_pemilik int;
  v_dipakai_pemilik int;
begin
  if v_pemilik_id is null then
    raise exception 'Masuk dulu untuk memakai AI.';
  end if;

  select nullif(ud.data ->> 'paket_tier', '') into v_tier
  from public.umkm_data ud
  where ud.user_id = v_pemilik_id;
  if v_tier is null or v_tier not in ('gratis', 'mikro', 'kecil', 'menengah') then
    v_tier := nullif(btrim(coalesce(p_tier, '')), '');
  end if;
  if v_tier is null or v_tier not in ('gratis', 'mikro', 'kecil', 'menengah') then
    v_tier := 'gratis';
  end if;
  v_batas_pemilik := case v_tier
    when 'mikro' then 300
    when 'kecil' then 600
    when 'menengah' then 1000
    else 20
  end;

  select coalesce(sum(jumlah), 0) into v_dipakai_pemilik
  from public.pemakaian_ai
  where pemilik_id = v_pemilik_id and bulan = v_bulan;

  if v_dipakai_pemilik >= v_batas_pemilik then
    return jsonb_build_object(
      'boleh', false,
      'alasan', 'pemilik',
      'dipakai_pemilik', v_dipakai_pemilik,
      'batas_pemilik', v_batas_pemilik,
      'tier', v_tier
    );
  end if;

  insert into public.pemakaian_ai (pemilik_id, pegawai_email, bulan, jumlah)
  values (v_pemilik_id, null, v_bulan, 1)
  on conflict (pemilik_id, bulan, (coalesce(pegawai_email, '')))
  do update set jumlah = pemakaian_ai.jumlah + 1, updated_at = now();

  return jsonb_build_object(
    'boleh', true,
    'alasan', null,
    'dipakai_pemilik', v_dipakai_pemilik + 1,
    'batas_pemilik', v_batas_pemilik,
    'tier', v_tier
  );
end;
$$;
comment on function public.pakai_ai_pemilik(text) is 'Cek + catat satu pemakaian AI pemilik sendiri terhadap kuota paket bulan ini (Gratis 20, Mikro 300, Kecil 600, Menengah 1.000). Dicadangkan untuk proxy /api/ai-chat aplikasi utama begitu ia mengirim token sesi; hari ini belum dipanggil.';

revoke execute on function public.pakai_ai_pemilik(text) from public;
grant execute on function public.pakai_ai_pemilik(text) to authenticated;

-- RPC pemakaian_ai_tim_untuk_pemilik() — pemakaian AI tim bulan ini
-- untuk pemilik usaha yang memanggil (dipakai kartu "Pemakaian AI
-- tim" di modul Orang & SOP aplikasi utama). Satu baris per pegawai
-- yang memakai AI bulan ini + satu baris 'Pemilik (aplikasi utama)'
-- bila pemilik sendiri sudah memakai (lewat pakai_ai_pemilik):
--   (pegawai_nama, pegawai_email, dipakai, batas)
--   batas = 20 untuk pegawai; untuk pemilik = batas tingkat paket
--     bulan ini (diambil dari cloud, lalu 'gratis').
-- Urut dipakai paling banyak dulu. TANPA gate pemilik aplikasi:
-- hanya tim pemanggil sendiri (pemilik_id = auth.uid()); pemanggil
-- tanpa pemakaian mendapat himpunan kosong, bukan error.
create or replace function public.pemakaian_ai_tim_untuk_pemilik()
returns table(
  pegawai_nama text,
  pegawai_email text,
  dipakai int,
  batas int
)
language plpgsql security definer set search_path = public as $$
declare
  v_pemilik_id uuid := auth.uid();
  v_tier text;
  v_batas_pemilik int;
begin
  select nullif(ud.data ->> 'paket_tier', '') into v_tier
  from public.umkm_data ud
  where ud.user_id = v_pemilik_id;
  if v_tier is null or v_tier not in ('gratis', 'mikro', 'kecil', 'menengah') then
    v_tier := 'gratis';
  end if;
  v_batas_pemilik := case v_tier
    when 'mikro' then 300
    when 'kecil' then 600
    when 'menengah' then 1000
    else 20
  end;

  return query
  select
    case when p.pegawai_email is null
      then 'Pemilik (aplikasi utama)'::text
      else coalesce(a.nama, p.pegawai_email)::text end,
    p.pegawai_email::text,
    p.jumlah,
    case when p.pegawai_email is null then v_batas_pemilik else 20 end
  from public.pemakaian_ai p
  left join public.akses_pegawai a on a.email = p.pegawai_email
  where p.pemilik_id = v_pemilik_id
    and p.bulan = to_char(current_date, 'YYYY-MM')
    and p.jumlah > 0
  order by p.jumlah desc;
end;
$$;
comment on function public.pemakaian_ai_tim_untuk_pemilik() is 'Pemakaian AI tim bulan ini untuk pemilik usaha yang memanggil: per pegawai (batas 20) + pemilik sendiri (batas tingkat paket). Hanya tim pemanggil sendiri; tanpa pemakaian mendapat himpunan kosong, bukan error.';

revoke execute on function public.pemakaian_ai_tim_untuk_pemilik() from public;
grant execute on function public.pemakaian_ai_tim_untuk_pemilik() to authenticated;

-- ============================================================================
-- PENUTUP — DAFTAR VERIFIKASI SETELAH KLIK RUN
-- ============================================================================
-- Jalankan pemeriksaan berikut di SQL Editor yang sama (satu per satu):
--
-- 1. Kelima tabel masih kosong (pemilik menambahkan pegawai lewat
--    aplikasi utama, setelah file ini jalan):
--      select * from public.akses_pegawai;
--      select * from public.sop_jalankan;
--      select * from public.laporan_pegawai;
--      select * from public.presensi;
--      select * from public.pemakaian_ai;
--    Kelimanya harus mengembalikan 0 baris.
--
-- 2. RLS aktif di kelima tabel:
--      select tablename, rowsecurity from pg_tables
--      where schemaname = 'public'
--        and tablename in ('akses_pegawai', 'sop_jalankan',
--          'laporan_pegawai', 'presensi', 'pemakaian_ai');
--    Kolom rowsecurity harus true di kelima baris.
--
-- 3. Pemanggil yang bukan pegawai mendapat error (bukan data):
--      (masuk dengan akun lain lalu) select public.sops_untuk_pegawai();
--    Harus gagal dengan pesan "Hanya pegawai yang terdaftar oleh
--    pemilik usaha yang boleh melihat data ini."
--
-- 4. Setiap pemilik hanya melihat log timnya sendiri di ringkasan tim:
--      select * from public.ringkasan_tim_untuk_pemilik();
--    Harus mengembalikan HANYA baris tim pemanggil (pemilik_id =
--    auth.uid()). Pemilik yang belum punya pegawai — atau pemanggil
--    lain tanpa tim sendiri (misal pegawai) — mendapat 0 baris,
--    bukan error dan bukan log orang lain.
--
-- 5. Bucket bukti-pegawai ada dan privat:
--      select id, public from storage.buckets where id = 'bukti-pegawai';
--    Harus 1 baris dengan public = false.
--
-- 6. Kolom foto_path ada di akses_pegawai (null untuk pegawai lama):
--      select email, foto_path from public.akses_pegawai;
--    Kolom foto_path harus ada; baris lama bernilai null.
--
-- 7. Batas foto harian: kirim 5 laporan foto hari ini sebagai pegawai,
--    kiriman ke-6 harus gagal dengan pesan "Batas foto hari ini sudah
--    tercapai (5 foto)." (pas foto tidak dihitung ke batas ini).
--
-- 8. Laporan tim pemilik hanya mengembalikan laporan tim pemanggil:
--      select * from public.laporan_tim_untuk_pemilik();
--    Harus HANYA laporan tim pemanggil (pemilik_id = auth.uid());
--    pemanggil tanpa tim mendapat 0 baris, bukan error.
--
-- 9. Tandai sudah dicatat tidak pernah mencatat ganda: panggil
--    tandai_laporan_dicatat dua kali untuk kwitansi yang sama —
--    panggilan kedua mengembalikan baris yang sama tanpa galat dan
--    tanpa mengubah dicatat_pada.
--
-- 10. Verifikasi SOP: selesai-kan satu SOP sebagai pegawai, lalu
--     panggil verifikasi_sop_jalankan sebagai pemilik usaha —
--     dicek_oleh harus 'Pemilik', dicek_pada terisi. Panggil lagi:
--     baris yang sama, dicek_pada tidak berubah. Pekerjaan yang
--     belum selesai tidak bisa ditandai sudah dicek (harus galat).
--     Sebagai pegawai yang BUKAN pengecek SOP itu, pemanggilan
--     harus gagal.
--
-- 11. Presensi: sebagai pegawai, panggil catat_presensi('masuk')
--     dua kali — masuk_pada kedua panggilan HARUS sama (ketukan
--     pertama yang menang). Lalu catat_presensi('pulang') — pulang
--     terisi, masuk tetap. select * from
--     public.presensi_hari_ini_untuk_pemilik(); sebagai pemilik —
--     hanya baris tim pemanggil hari ini; pemanggil tanpa tim
--     mendapat 0 baris, bukan error.
--
-- 12. Kuota AI: sebagai pegawai, panggil pakai_ai_pegawai(null) —
--     {boleh: true, ...} dan jumlah bertambah 1. Panggil sampai
--     20 kali bulan ini — panggilan ke-21 harus {boleh: false,
--     alasan: 'pegawai'}. select * from
--     public.pemakaian_ai_tim_untuk_pemilik(); sebagai pemilik —
--     menampilkan pemakaian tim bulan ini.
--
-- CATATAN:
-- - Menambah pegawai (oleh pemilik, lewat daftar tim di aplikasi
--   utama — atau lewat SQL bila perlu):
--      insert into public.akses_pegawai (email, pemilik_id, nama, peran, aktif)
--      values ('pegawai@contoh.id', auth.uid(), 'Nama Pegawai',
--              array['kas','stok'], true);
--   Pegawai lalu mendaftar sendiri di Aplikasi Pegawai dengan email
--   yang sama + kata sandi buatannya sendiri, lalu mengunggah pas
--   foto wajahnya (wajib sebelum bisa memakai aplikasi).
-- - Aplikasi pegawai memanggil RPC di atas + membaca tabel
--   akses_pegawai langsung untuk memeriksa izin masuk (barisnya
--   sendiri saja). Aplikasi TIDAK membaca tabel pengguna atau data
--   usaha langsung — semua lewat RPC yang memeriksa izin dan
--   membatasi ke SOP pemilik + catatan/laporan/presensi pegawai itu
--   sendiri. Jalur pas foto HANYA ditulis lewat RPC simpan_pas_foto
--   (bukan lewat tulis langsung ke tabel) supaya pegawai tidak bisa
--   mengubah nama, peran, atau aktifnya sendiri.
-- - Tingkat paket pemilik (paket_tier) dibaca RPC pemakaian AI dari
--   umkm_data.data; aplikasi utama menyimpannya setiap kali
--   menyimpan data. Bila belum tersimpan, RPC memakai tingkat yang
--   dikirim klien, lalu 'gratis'.
-- - Sampai file ini dijalankan, aplikasi menampilkan "Fitur ini belum
--   aktif — pengaturan cloud belum dijalankan" beserta salinan SQL ini.
-- ============================================================================
