# libfprint-goodix-5117

Make the **Goodix `27c6:5117`** fingerprint sensor work end to end on Linux —
including a sensor that the Windows driver has already re-provisioned and that
therefore no longer accepts the factory TLS key.

Tested on an **Honor MagicBook Pro 2020 (HLYL-WXX9)**, firmware
`GF_ST411SEC_APP_12118`, libfprint 1.94.5 / fprintd 1.94.5.

Also verified on **Fedora 45** with libfprint 1.94.100 / fprintd 1.94.5
(GCC 16, OpenCV 4.13, GnuTLS 3.8) — see
[docs/flash-on-linux.md](docs/flash-on-linux.md) for the full recovery log.

Also verified on **CachyOS** (Arch-based) with the same libfprint 1.94.100 /
fprintd 1.94.5 packages, building the patched library against **OpenCV 5** —
see [docs/cachyos-install.md](docs/cachyos-install.md).

This repository is an **incremental patch** on top of
[`gulp/libfprint-1`](https://github.com/gulp/libfprint-1), branch
`goodix-5117-support`, which already carries the basic 5117 support. Everything
here fixes what that branch could not do on 12118 hardware.

> **No Windows install required.** The whole recovery — firmware extraction,
> PSK reset, reflash, enroll, verify — was completed on a Linux-only machine.
> Windows is one of two routes, not a requirement.

---

## TL;DR

```bash
git clone -b goodix-5117-support https://github.com/gulp/libfprint-1.git
cd libfprint-1
git am /path/to/patches/0001-goodixtls-make-the-27c6-5117-sensor-usable-end-to-en.patch \
       /path/to/patches/0002-sigfm-do-not-require-doctest-to-build.patch \
       /path/to/patches/0003-goodixtls-fix-background-subtraction-wraparound.patch \
       /path/to/patches/0004-goodixtls-tests-for-the-image-pipeline.patch
# then run scripts/install.sh (Debian/Ubuntu) or scripts/install-fedora.sh,
# or build manually (see below)
```

---

## What was broken, and what this patch does

### 1. TLS never completed (`server ready failed` / `decryption failed`)

The GF511 sensors send a **trimmed-down ClientHello**: 52 bytes, no extensions.
OpenSSL rejects it outright. The transport is ported to **GnuTLS**, restricted to
the single real suite the sensor offers:

```
NORMAL:-VERS-ALL:+VERS-TLS1.2:-KX-ALL:+PSK:-CIPHER-ALL:+AES-128-GCM
```

Two further bugs kept the handshake from finishing even with a correct key:

* records were fed into the TLS engine from two different places, so the same
  record was processed twice → `unexpected TLS handshake packet`;
* a stray `0xd0` (request-TLS) packet arrives around the handshake and used to
  fail the state machine, after which every command timed out.

### 2. Two independent key layers (the part that trips everyone up)

| Layer | Size | Read with | Meaning |
|---|---|---|---|
| **Preset PSK** (obfuscated) | 32 B | `0xe4` | `SHA256(96-byte white-box blob)` — a *digest*, **not** a key |
| **TLS session PSK** | 32 B | — | the actual AES-128-GCM key |

They are unrelated. Using the `0xe4` value as the TLS key is the classic
mistake, and it can never work: a 32-byte hash is not invertible into the
32-byte key it was derived from.

A **factory-provisioned** sensor uses **32 zero bytes** as the TLS key. A sensor
that Windows has touched carries a **per-device random** key. The patch reads
the real key from `/etc/goodix5117/psk` (or `$GOODIX_PSK_FILE`, 64 hex digits)
and falls back to the all-zero key when that file is absent.

The `0xe4` comparison is also downgraded from a fatal error to a warning, since
the digest legitimately differs per device and changes whenever Windows
re-provisions the sensor.

### 3. Activation order is wrong for 12118

On `GF_ST411SEC_APP_12118` the sensor boots **straight into its TLS transport**
and only answers `0xae` (query MCU state) and `0xd0` (request TLS) in clear
text. `enable_chip`, the firmware query, the PSK read, reset and the config
upload all time out until the session is up — so the stock order (activate
commands, *then* TLS) can never complete. The patch brings TLS up first and runs
the activation sequence afterwards.

Also: image capture **blocks until a finger is placed**, so the 1 s command
budget is far too short. It is raised to 10 s.

### 4. A successful match was reported as `verify-no-match`

After a successful capture the driver waited for the `FTD_UP` command, which
only completes once the finger is **lifted**. The action therefore stayed
pending until fprintd cancelled it (`Idle cancelling on ongoing operation!`),
and the successful match was recorded as a failure.

The patch reports finger-off right after the capture for non-enrol actions,
matching what upstream image drivers do (`aes3k.c`, `egis0570.c`,
`upektc_img.c`).

---

## If your sensor was re-provisioned by Windows

You cannot recover the key from the digest, and you cannot write a new one from
the application firmware: on the `MILAN_ST411SEC_IAP_*` family (which 51x0/51x7
belong to) `0xe0` and the newer `0xe2` production-layer write are both **silently
ignored** in APP mode — they return a transport ACK and nothing else. The
`MILAN_RTSEC` family (5503, 55x4) is the one that writes in place.

Two ways out, both documented in [docs/psk-write-findings.md](docs/psk-write-findings.md):

**A. Let the Windows driver provision it** (no flashing).
Boot any Windows environment, install the Goodix UMDF driver (`gfspi.inf`
matches `USB\VID_27C6&PID_5117`), let it touch the sensor once, then decrypt
`C:\ProgramData\Goodix\Goodix_Cache.bin` with DPAPI entropy. On Windows,
[`tools/goodix-psk-decrypt.ps1`](tools/goodix-psk-decrypt.ps1) automates this;
see [docs/windows-psk-recovery.md](docs/windows-psk-recovery.md). The key goes
to `/etc/goodix5117/psk`.

> This route only works while that Windows install still exists. DPAPI binds the
> cache to the user/machine that wrote it: once the Windows environment is gone,
> the key is unrecoverable. If you might need it later, decrypt and save the key
> **before** wiping Windows.

**B. Reflash with the PSK written in IAP mode** (what we did).
`tools/restore_5117.py` performs:

```
mcu_erase_app  ->  IAP bootloader (MILAN_ST411SEC_IAP_12001)
preset_psk_write(0xbb010003, <all-zero white box>)
preset_psk_read  ->  expect ba1a8603…d72d43  (factory digest)
write_firmware   ->  the original image, 1008-byte chunks
check_firmware   ->  CRC-32/MPEG-2 must match
reset            ->  back to APP mode
```

This is the only route that works **without** Windows, and the whole procedure
runs on Linux. A full end-to-end run (erase → reflash → enroll → verify) took
about **three seconds** of actual flashing; see
[docs/flash-on-linux.md](docs/flash-on-linux.md) for the measured log.

> **The firmware image is required and is not shipped here** — it is a vendor
> binary. Point `GOODIX_FW_DIR` at a directory containing
> `GF_ST411SEC_APP_12118_5117.bin` (102336 B, CRC-32/MPEG-2 `0xD90EC273`,
> SHA256 `d7fb2f4c…88fd1`).
>
> **[docs/firmware-extraction.md](docs/firmware-extraction.md) has the verified
> extraction procedure.** Note that most driver packages on Microsoft Update
> Catalog do **not** contain this firmware: you need *Goodix FP - Biometric -
> 1.1.124.115* (UpdateID `5075f1e9-…`), not the commonly-cited 1.1.18.27, whose
> `gfspi.dll` has no images at all.
>
> **Without the image, do not erase**: the bootloader survives, but an empty APP
> partition on a sensor whose `0xf2` (read firmware) is unimplemented means there
> is no way to get the old image back off the device.

The script never erases twice: every failure path leaves the sensor in IAP mode,
which is recoverable by re-running step 4.

---

## Build and install

### Debian / Ubuntu

```bash
sudo apt install build-essential meson ninja-build pkg-config \
    libglib2.0-dev libgusb-dev libcairo2-dev libgnutls28-dev \
    libgudev-1.0-dev libnss3-dev libpixman-1-dev libgirepository1.0-dev \
    libopencv-dev
```

```bash
git clone -b goodix-5117-support https://github.com/gulp/libfprint-1.git
cd libfprint-1
git am /path/to/patches/000*.patch
meson setup build --prefix=/usr -Ddrivers=goodixtls511 \
    -Dudev_rules=disabled -Dudev_hwdb=disabled
ninja -C build
sudo ninja -C build install
sudo ldconfig
sudo systemctl restart fprintd
```

`scripts/install.sh` does the clone + patches + build + install in one go.

### Fedora 44

```bash
./scripts/install-fedora.sh            # --no-install, --skip-deps, --base-dir DIR
```

The script installs the dnf build dependencies, clones the base branch, applies
both patches, builds and installs. Differences from the Debian path:

* the driver option is **`goodixtls511`** — `goodixtls` is only a helper, and
  meson aborts with `Key goodixtls is not in the dictionary` if you select it;
* **SIGFM/OpenCV is compiled into the library** (`opencv-devel`, `gcc-c++`), and
  patch 0002 drops its hard `doctest` dependency — Fedora ships doctest as a
  CMake-only package without a `.pc` file;
* only the shared library is replaced (`/usr/lib64/libfprint-2.so.2.0.0`), so no
  `libfprint-devel` files are overwritten;
* the backup lives in `/var/backups/libfprint-goodix5117/`. Keeping it next to
  the library lets `ldconfig` register it as another provider of
  `libfprint-2.so.2`, and fprintd then loads the **old** library — the symptom
  is `No devices available` even though `lsusb` shows the sensor;
* `restorecon` is run so the replacement keeps the `lib_t` SELinux label.

Fedora notes:

* `fprintd` is D-Bus activated; `systemctl is-enabled fprintd` reports `static`,
  which is expected.
* Fingerprint works for **sudo/su** (`pam_fprintd` is already in
  `system-auth` when `authselect` has `with-fingerprint`) and for the **KDE lock
  screen** (`/etc/pam.d/kde-fingerprint`, used by `kscreenlocker_greet`).
  Plasma's login manager (`plasmalogin`) has no fingerprint UI, so the login
  screen still asks for a password.
* A long enrollment session can end with
  `Device disabled to prevent overheating`; that is libfprint's thermal model,
  wait a few minutes.
* A `dnf update libfprint` replaces the patched library. Re-run
  `install-fedora.sh` (it reuses the build) or copy
  `~/src/libfprint-1/build/libfprint/libfprint-2.so.2.0.0` into place and run
  `ldconfig`.

### CachyOS / Arch

There is no install script for Arch-based distributions yet; use the manual
steps in [docs/cachyos-install.md](docs/cachyos-install.md). The important
differences are the library path (`/usr/lib/libfprint-2.so.2.0.0`), the
`opencv5.pc` → `opencv4.pc` compatibility shim needed by the current Arch
`opencv` package, and `glib-mkenums` living in `glib2-devel`.

Then:

```bash
sudo mkdir -p /etc/goodix5117
# only if your sensor is not factory-provisioned:
#   printf '%s\n' "<64 hex digits>" | sudo tee /etc/goodix5117/psk
#   sudo chmod 600 /etc/goodix5117/psk
fprintd-enroll
```

`scripts/install.sh` does the clone + patch + build + install in one go.

---

## Tools

| Tool | Platform | Purpose |
|---|---|---|
| `tools/probe_psk.py` | Linux | **Read-only** diagnostic: prints the firmware version and the PSK digest, and tells you whether the sensor is factory-state or re-provisioned. Run this *before* deciding to flash. |
| `tools/restore_5117.py` | Linux | Erase → write PSK in IAP → reflash → verify. Step-by-step, `--step N` to resume. |
| `tools/goodix-psk-decrypt.ps1` | Windows | Decrypt the per-device PSK from `Goodix_Cache.bin` (DPAPI, no flashing). |
| `tools/extract-goodix-firmware.ps1` | Windows | Extract and CRC/SHA-verify the firmware images embedded in `gfspi.dll`. |
| `tools/goodix-dump-view` | Linux | Convert the per-frame PGM dumps into contrast-stretched PNGs. |

`goodix-dump-view` pairs with `GOODIX_DUMP_DIR` (dump every captured frame as
PGM, env-gated):

```bash
GOODIX_DUMP_DIR=/tmp/goodix-dump fprintd-verify
tools/goodix-dump-view
```

### Reading the logs

The patch logs `residual range after calibration: X..Y (span Z)`. Use the span
to judge frame quality:

| Span | Meaning |
|---|---|
| ~1000–2000 | Good ridge detail, frame is usable |
| `0..65535` (span 65535) | Fully saturated — finger pressed too hard or badly placed; libfprint will ask you to re-scan |
| near 0 | Calibration frame no longer describes the sensor (temperature drift); ridges flattened |

And for the handshake, the decisive line is `handshake step: r=<code>`:

| Code | Meaning |
|---|---|
| `r=0` | Handshake succeeded — the PSK is correct |
| `r=-24` | `GNUTLS_E_DECRYPTION_FAILED`: **wrong PSK**. Do not chase TLS settings |
| `r=-38` | `GNUTLS_E_GOT_APPLICATION_DATA`: harmless, arrives after a *successful* handshake |

---

## Image quality: what the old suspects turned out to be

A badly placed finger yields `0/24` minutiae. Three suspects were documented as
"not yet changed"; investigating them (2026-10-27) showed that one was an actual
bug and the other two are lower priority than they looked:

### 1. `linear_subtract_inplace()` did not merely saturate — it wrapped

This was a real bug, now fixed by patch `0003`. The old formula was

```
max - ((max - src) - (max - by))    ==    src - by + max    (mod 65536)
```

which is only correct while `src <= by`. Whenever a scan pixel is **brighter**
than the same pixel of the calibration frame — ordinary noise, or a finger that
reflects more than the empty sensor — the subtraction wraps and lands near 0:

```
src=3573, by=2000   ->   1572      (should be 65535)
```

One such pixel is enough to destroy the frame: the observed range becomes
roughly `0..65535`, and the normalisation then squeezes every real pixel into
~8 grey levels. This is exactly the `residual range after calibration: 0..65535`
frame the driver rejects.

The fix computes the difference in `gint32` and clamps. The bias is unchanged
(`0xffff`), so every frame that worked before produces byte-identical output.

### 2. min/max normalisation → now percentile-based

Also fixed in `0003`, but this one is a **defensive** change, not a cure.
Measured on synthetic frames matching the real residual range (ridge contrast
~1700 over a 65535 window): with no outlier present, min/max and 1%/99%
percentile normalisation differ by **0 of 7040 pixels**. It only matters when a
bad pixel survives, and with the wraparound fixed that is much rarer.

### 3. Calibration frame age — still open, and not the limiting factor

The calibration frame is still captured at activation, 1–2 s before the scan.
Measured spans stay in the 1100–1750 range on successful scans, i.e. the
calibration is *not* stale — a stale frame would show a near-zero span. So
there is no evidence this needs changing.

**Bottom line:** a normal press works. The 2026-10 enroll completed 20/20
stages with one `enroll-retry-scan`.

What actually limits recognition is **not** pressure or contrast but **overlap
between presses**. Measured on real frames: a frame pair with normalised
cross-correlation 0.68 scores 8252 (passes), while pairs at 0.38 and 0.30 score
6 and 0 (fail). Contrast can drop to a third and still leave 106 keypoints;
a few pixels of positional drift is what kills the match.

Since libfprint's matcher already tries every stored template
(`fpi-print.c` iterates `template->prints` and takes the best score), the
practical advice is: **during enrolment, deliberately press slightly different
positions** — centre, a bit left, a bit right, a bit high, a bit low. The wider
the coverage, the more likely a random daily press hits one of them.

Local histogram equalisation was measured and **rejected**: it raised the
keypoint count but dropped the only passing cross-match from 8252 to 2616
(−68%), because per-tile equalisation manufactures edges that the detector
counts as features. See [docs/image-quality.md](docs/image-quality.md).

`GOODIX_DUMP_DIR` still exists for comparing captures; note that fprintd runs a
sandboxed service, so set `PrivateTmp=false` and a writable path in a drop-in
for the dump to land anywhere useful.

---

## Documentation

| File | Contents |
|---|---|
| [docs/firmware-extraction.md](docs/firmware-extraction.md) | **Verified** firmware extraction from the right driver package, plus the traps (wrong package, fake "12117"). |
| [docs/flash-on-linux.md](docs/flash-on-linux.md) | Full recovery log: Linux-only, measured timings, post-flash verification. |
| [docs/image-quality.md](docs/image-quality.md) | **Measured** keypoint data: why some presses fail, and what local equalisation would buy. |
| [docs/cachyos-install.md](docs/cachyos-install.md) | CachyOS/Arch install: package names, OpenCV 5 shim, library path, PAM. |
| [docs/windows-psk-recovery.md](docs/windows-psk-recovery.md) | Windows-only PSK extraction (DPAPI, no flashing). |
| [docs/psk-recovery.md](docs/psk-recovery.md) | The two PSK layers, the IAP reflash procedure, API audit. |
| [docs/psk-write-findings.md](docs/psk-write-findings.md) | Exhaustive proof that APP-mode PSK writes are ignored on this family. |
| [docs/driver-changes.md](docs/driver-changes.md) | Per-change notes on the driver patch. |
| [docs/results.md](docs/results.md) | Before/after measurements (first recovery, 2026-10-20). |
| [docs/device-state.md](docs/device-state.md) | USB layout, firmware, key state, confirmed device behaviour. |
| [docs/conclusion.md](docs/conclusion.md) | One-page summary of the causal chain and the two routes. |
| [docs/no-flash-options.md](docs/no-flash-options.md) | The non-flashing route in detail. |
| [docs/flash-preview.md](docs/flash-preview.md) | Historical pre-flight checks for the reflash. |

---

## What is deliberately not in this repository

* **Firmware images** (`GF_ST411SEC_APP_*.bin`) — vendor binaries. Extraction is
  documented; the files are not redistributed here.
* **Goodix Windows driver files** (`gfspi.dll`, `EngineAdapter.dll`, …) — same
  reason. Obtain them from Microsoft Update Catalog or your OEM.

---

## Credits

* [`gulp/libfprint-1`](https://github.com/gulp/libfprint-1) — the base
  `goodix-5117-support` branch this patch builds on.
* [`goodix-fp-linux-dev/goodix-fp-dump`](https://github.com/goodix-fp-linux-dev/goodix-fp-dump)
  — the reference implementation and the authoritative protocol documentation
  (`SPEC.md`). Issue #83 is the community-verified recovery flow; issue #67 is
  the same 5117/12118 hardware failing for want of a firmware image.
* `soroushdeimi/goodix-521d-project` — the per-family table showing which
  silicon can write a PSK in place.
* `Sbenazar/goodix-5f10-psk`, `senyakirilovich` — DPAPI entropy derivation for
  the offline (non-flashing) recovery route.

---

## License

LGPL-2.1-or-later, matching libfprint. See [LICENSE](LICENSE).

---

<details>
<summary>中文说明</summary>

### 这是什么

让 **Goodix `27c6:5117`** 指纹传感器在 Linux 上完整可用，包括**已被 Windows
重新 provision 过、不再接受出厂密钥**的传感器。

实测机型：**荣耀 MagicBook Pro 2020 (HLYL-WXX9)**，固件
`GF_ST411SEC_APP_12118`。

本仓库是 [`gulp/libfprint-1`](https://github.com/gulp/libfprint-1)
`goodix-5117-support` 分支之上的**增量补丁**。那个分支已经带了 5117 的基本支持，
这里修的是它在 12118 硬件上跑不通的部分。

### 修了什么

1. **TLS 握手** —— 传感器发的是 52 字节、无扩展的 ClientHello，OpenSSL 直接拒绝，
   改用 GnuTLS 并锁定唯一可用的套件 `0x00a8`（AES-128-GCM）。另外修了两处：
   同一条记录被送进 TLS 引擎两次；握手期间会冒出杂散 `0xd0` 包，原来会把状态机打死。
2. **两层独立的密钥** —— `0xe4` 读回的是 96 字节白盒的 SHA256 **摘要**，不是密钥；
   两者无关。出厂设备 TLS 密钥是**全零 32 字节**，被 Windows 碰过的设备是
   **每设备随机**。补丁从 `/etc/goodix5117/psk` 读取真实密钥。
3. **激活顺序** —— 12118 一上电就进 TLS 传输层，明文只应答 `0xae` 和 `0xd0`，
   其余命令全部超时。必须**先建 TLS，再跑激活序列**。
   图像采集会阻塞等手指，1 秒超时太短，改为 10 秒。
4. **匹配成功却被报成 `verify-no-match`** —— 原来在等 `FTD_UP`（要抬手才回），
   动作一直挂到 fprintd 取消。改为采集成功后立即上报 finger-off。

### 如果你的传感器已被 Windows 重新 provision

摘要不可逆，APP 模式下也写不进新密钥 —— `MILAN_ST411SEC_IAP_*` 家族（51x0/51x7）
的 `0xe0` 和新式 `0xe2` 在 APP 模式下**都被静默忽略**，只回一个传输层 ACK。

两条路：

- **A. 让 Windows 驱动去写**（不刷机）：任意 Windows 环境装
  `gfspi.inf`（匹配 `USB\VID_27C6&PID_5117`），让它碰一次传感器，
  再用 DPAPI 熵解密 `Goodix_Cache.bin`。
- **B. 进 IAP 模式写密钥再刷回固件**（我们采用的）：
  `tools/restore_5117.py`，全程可逆。

> **固件镜像不在本仓库**（厂商二进制）。需要把 `GOODIX_FW_DIR` 指向含有
> `GF_ST411SEC_APP_12118_5117.bin`（102336 字节，CRC-32/MPEG-2 `0xD90EC273`）
> 的目录。**没有镜像就不要擦除** —— bootloader 还在，但该传感器 `0xf2`
> （读固件）未实现，擦掉之后原镜像无法从设备里取回来。

### 构建

```bash
git clone -b goodix-5117-support https://github.com/gulp/libfprint-1.git
cd libfprint-1
git am /path/to/patches/000*.patch
meson setup build --prefix=/usr -Ddrivers=goodixtls511 \
    -Dudev_rules=disabled -Dudev_hwdb=disabled
ninja -C build && sudo ninja -C build install && sudo ldconfig
sudo systemctl restart fprintd && fprintd-enroll
```

Fedora 可直接用 `scripts/install-fedora.sh`（Fedora 44 与 45 均实测通过）。
CachyOS/Arch 没有安装脚本，手动步骤见
[docs/cachyos-install.md](docs/cachyos-install.md)（2026-10 实测通过）。注意：

- 驱动选项是 **`goodixtls511`**，`goodixtls` 只是 helper（选中会报
  `Key goodixtls is not in the dictionary`）；
- 本分支把 SIGFM 编进库，需要 `opencv-devel`/`gcc-c++`；补丁 0002 去掉了它的
  doctest 硬依赖（Fedora 的 doctest 没有 `.pc` 文件）；
- 原库备份放在 `/var/backups/libfprint-goodix5117/`。放在库目录里会被
  `ldconfig` 当成另一个 `libfprint-2.so.2` 提供者，fprintd 反而加载旧库
  （现象是 `No devices available`）；
- Fedora 上 sudo/su 和 KDE 锁屏支持指纹（`system-auth` / `kde-fingerprint`），
  登录界面 `plasmalogin` 没有指纹 UI，仍需密码。

Fedora 45 实测环境：libfprint 1.94.100、fprintd 1.94.5、GCC 16.2、OpenCV 4.13、
GnuTLS 3.8.13，构建无报错（仅有来自 OpenCV 头文件的格式属性警告，无害）。

### 固件从哪里来（重要）

绝大多数 Catalog 驱动包**不含** 5117 固件。必须用
**Goodix FP - Biometric - 1.1.124.115**（UpdateID `5075f1e9-…`），
它的 `gfspi.dll` 有 5.52 MB，内含 32 份镜像（16×5110 + 16×5117）。

常见错误是下载 `1.1.18.27`（`gfspi.dll` 只有 920 KB），里面一个固件字符串都没有。
另一个坑：按 `102264` 字节切同一份 12118 镜像会得到一个 CRC 为 `0xE4DDD1B7`
的"假 12117"，那不是真 12117（真 12117 的 CRC 是 `0xDBD51539`，且版本串为
`12117`）。

完整流程（含直链获取、提取脚本、三重验证）见
[docs/firmware-extraction.md](docs/firmware-extraction.md)。

### 先把状态探清楚，再决定要不要刷

```bash
sudo systemctl stop fprintd
sudo GOODIX_FP_DUMP=~/goodix-fp-dump python3 tools/probe_psk.py
sudo systemctl start fprintd
```

它会打印固件版本和 PSK 摘要，并直接告诉你结论：

- 摘要 = `ba1a8603...` → **出厂状态**，全零密钥即可用，**不需要刷机**
- 摘要 ≠ 出厂值 → 已被重新 provision，需要导密钥或刷机

这一步能避免绝大多数无谓的刷机。

### 刷机实录

一次完整的 Linux 单系统恢复（擦除 → 写 PSK → 刷固件 → 录入 → 验证）
实测只用了约 **3 秒**的刷写时间，全程不需要 Windows。日志与判读方法见
[docs/flash-on-linux.md](docs/flash-on-linux.md)。

关键日志判读：

| 日志 | 含义 |
|---|---|
| `handshake step: r=0` | 握手成功，密钥正确 |
| `handshake step: r=-24` | **密钥错误**，不要再查 TLS 配置 |
| `handshake step: r=-38` | 握手已完成后的应用数据，无害 |
| `residual range after calibration: 0..65535` | 整幅饱和，会自动要求重按 |

### 图像质量：三个怀疑点的最终结论

2026-10-27 逐条查证后，结论是**一个真 bug + 一个防御性改动 + 一个不成立**：

**1. `linear_subtract_inplace()` 不只是饱和，它会回绕 —— 真 bug，已修（补丁 0003）**

原公式等价于 `src - by + 65535`（uint16 取模），只在 `src <= by` 时正确。
一旦某个扫描像素比校准帧**更亮**，中间结果变负并回绕：

```
src=3573, by=2000  ->  1572      （应为 65535）
```

**一个这样的像素就足以毁掉整帧**：观测范围被拉成 `0..65535`，归一化后所有
真实像素被压进约 8 个灰度级。这正是日志里那个被拒绝的
`residual range after calibration: 0..65535`。

修法：改用 `gint32` 算差并钳位；偏置仍是 `0xffff`，所以**原本能用的帧输出
完全不变**。

**2. min/max 归一化 → 改为 1%/99% 百分位 —— 防御性，不是解药**

同样在补丁 0003 里。用与真实残差范围相符的合成帧实测：**没有异常像素时，
两种方法的输出差异为 0/7040 像素**。它只在坏像素漏网时才起作用，而回绕修好
之后这种情况已经少了很多。

**3. 校准帧老化 —— 不成立**

校准帧仍在激活时采集，比扫描早 1–2 秒。但实测成功扫描的 span 稳定在
1100–1750，**说明校准帧没有失效**（失效会表现为 span 接近 0）。没有证据支持
需要改动。

**结论：正常按压可正常使用。** 2026-10 那次录入 20/20 阶段全部通过，只有
一次 `enroll-retry-scan`。

**真正限制识别率的不是压力或对比度，而是两次按压的重叠程度。** 真实帧实测：

| 帧对 | 归一化互相关 | 匹配分数 | 结果 |
|---|---|---|---|
| A↔B | 0.68 | 8252 | 通过 |
| A↔C | 0.38 | 6 | 失败 |
| B↔C | 0.30 | 0 | 失败 |

对比度降到 1/3 仍有 106 个 keypoint（采集不失败），但**几个像素的位置偏移
就足以让匹配归零**。

因为 libfprint 的匹配逻辑本来就是遍历模板取最高分
（`fpi-print.c` 里的 `template->prints`），所以实用建议是：

> **录入时刻意按不同位置**——正面、略偏左、略偏右、略偏上、略偏下，每个位置
> 按一次。覆盖范围越广，日常随机按下的位置越容易命中某个模板。

**局部直方图均衡实测后被否决**：它确实能提高 keypoint 数，但让唯一能通过的
交叉匹配从 8252 掉到 2616（−68%），因为分块均衡会在块边界制造伪边缘，
被检测器当成特征。详见 [docs/image-quality.md](docs/image-quality.md)。

> `GOODIX_DUMP_DIR` 仍然可用，但 fprintd 是沙箱化服务：要让转储文件落到有用
> 的位置，需要在 drop-in 里设 `PrivateTmp=false` 并给出可写路径。

### 刷完之后注意

- **不要再让任何 Windows 环境接触这个传感器**。Windows 驱动会重新 provision，
  PSK 变回随机值，当前全零配置立刻失效，必须再刷一次。
- `dnf update libfprint` 会覆盖补丁库，需要重新部署。
- 固件镜像和驱动包建议长期保留，它们是唯一的恢复保险。

</details>
