# FPS Tweaker

Aplikasi GUI berbasis PowerShell untuk mengoptimalkan Windows 10/11 agar lebih ringan saat bermain game. Isinya tweak Windows biasa, tweak ala **Atlas OS** (debloat, privasi, performa), penghemat RAM, dan pengelola aplikasi startup. Semuanya berjalan sebagai skrip, jadi **tidak perlu install ulang Windows**.

Semua perubahan dicatat dulu, sehingga bisa dikembalikan lewat tombol **Revert semua**.

## Fitur Utama

- **Tweak dengan checkbox.** Arahkan mouse ke opsi untuk melihat penjelasannya. Setiap opsi diberi label risiko: Aman (hijau), Sedang (oranye), Berisiko (merah).
- **Preset.** Ada tombol Basic, Atlas-like, dan Kosongkan.
- **Backup dan Revert.** Nilai asli registry, service, scheduled task, dan power plan disimpan di `backup\state.json`.
- **Restore point.** Opsi membuat System Restore Point sebelum menerapkan tweak (aktif secara default).
- **Dry Run.** Mode uji yang hanya menampilkan perubahan tanpa mengubah apa pun.
- **Tab Optimize PC (RAM).** Memantau RAM, menutup proses berat, mengelola aplikasi startup, dan membersihkan RAM.
- **Log.** Panel log di kanan, dan log juga disimpan di `backup\log-*.txt`.

## Persyaratan

- Windows 10 atau 11
- Windows PowerShell 5.1 (bawaan Windows)
- Akses Administrator (diminta otomatis)

## Cara Pakai

1. Download atau clone repo ini.
2. Klik dua kali **`Run-FPSTweaker.bat`**, lalu setujui prompt UAC.
3. Di tab **Tweak**, centang tweak yang diinginkan atau pakai preset.
4. Klik **APPLY TWEAK**.
5. Restart PC agar semua perubahan aktif.

Untuk mencoba tanpa mengubah sistem:

```bat
Run-FPSTweaker.bat -DryRun
```

Untuk mengembalikan semua perubahan, klik **Revert semua** lalu restart PC. Tombol **Buka backup** membuka folder backup.

## Daftar Tweak

### Basic (aman)

| Tweak | Fungsi |
|---|---|
| Power plan Ultimate Performance | CPU tidak mudah turun clock. Di laptop baterai jadi lebih boros. |
| Game Mode ON | Windows memprioritaskan game. |
| Hardware-accelerated GPU scheduling | Mengurangi latency CPU ke GPU. Butuh GPU dan driver yang mendukung, dan perlu restart. |
| Matikan Game DVR | Game Bar tidak merekam di background. |
| Matikan mouse acceleration | Gerakan mouse 1:1, aim lebih konsisten. |
| Kurangi animasi dan transparansi | Mematikan efek visual yang tidak perlu. |
| Matikan background apps | Aplikasi Store tidak jalan di background. |
| Prioritas CPU/GPU untuk game | Pengaturan MMCSS, foreground boost, dan network throttling. |
| Hilangkan delay startup | Aplikasi startup langsung jalan setelah login. |
| Bersihkan file temp | Menghapus isi `%TEMP%` dan `C:\Windows\Temp`. |

### Atlas-like (debloat, privasi, performa)

| Tweak | Fungsi |
|---|---|
| Matikan telemetry | Mematikan DiagTrack, laporan error, dan task pengumpul data. |
| Matikan iklan, Bing search, Copilot, Widgets | Start menu dan search jadi bersih dan lokal saja. |
| Hapus bloatware | Menghapus app bawaan (News, Weather, Solitaire, Clipchamp, Teams, dll). |
| Matikan service tidak penting | Maps, Retail Demo, Fax, Remote Registry, dll. |
| Matikan Power Throttling | Proses background tidak diturunkan prioritasnya. |
| Matikan Delivery Optimization | PC tidak meng-upload update ke PC lain. |

### Hemat RAM

| Tweak | Fungsi |
|---|---|
| Edge/Chrome tidak jalan di background | Mematikan Startup Boost dan background mode. Browser akan menampilkan "Managed by your organization", itu normal. |
| Gabungkan proses svchost | Mengurangi jumlah proses svchost. Perlu restart. |

### Extreme (berisiko, tidak pernah dipilih oleh preset)

| Tweak | Risiko |
|---|---|
| Matikan SysMain dan Windows Search | Pencarian file lebih lambat, dan aplikasi di HDD bisa lebih lama dibuka. |
| Matikan mitigasi Spectre/Meltdown | Celah keamanan CPU terbuka. Efeknya hanya terasa di CPU lama. |

## Tab Optimize PC (RAM)

- **Monitor RAM.** Menampilkan pemakaian RAM secara real-time.
- **Proses pemakai RAM terbesar.** Tombol *Tutup proses terpilih* menutup paksa proses. Proses sistem (abu-abu) dilindungi dan tidak bisa ditutup.
- **Aplikasi startup.** Memakai mekanisme yang sama dengan Task Manager (`StartupApproved`). Entri tidak dihapus, jadi bisa di-Enable lagi kapan saja.
- **Trim RAM.** Memaksa proses melepas RAM yang tidak terpakai. Efeknya sementara.
- **Kosongkan Standby List.** Membersihkan cache RAM, mirip ISLC.

## Struktur File

```
FPSTweaker.ps1       Skrip utama (GUI dan logika tweak)
Run-FPSTweaker.bat   Launcher, otomatis meminta Administrator
backup/              state.json (data revert) dan log
```

## Batasan dan Peringatan

> [!WARNING]
> Gunakan dengan risiko sendiri. Disarankan membuat restore point dan mencoba **Dry Run** dulu.

- **Hapus bloatware tidak bisa di-revert otomatis.** App yang sudah dihapus harus di-install ulang dari Microsoft Store.
- Store, Xbox, Kalkulator, Foto, dan Notepad tidak dihapus.
- Revert hanya mengembalikan nilai yang dicatat di `backup\state.json`. Jangan hapus file ini sebelum selesai.
- Tweak **Extreme** sebaiknya dipilih manual dan hanya bila paham risikonya.
- Pada laptop dengan Modern Standby, power plan Ultimate mungkin tidak bisa diaktifkan. Atur manual lewat Settings > Power > Power mode.
- Efek tweak bervariasi tergantung hardware. Sebagian hanya membuat sistem terasa lebih responsif, bukan menaikkan FPS.
