# libfprint-goodix-5117

Make the **Goodix `27c6:5117`** fingerprint sensor work end to end on Linux —
including a sensor that the Windows driver has already re-provisioned and that
therefore no longer accepts the factory TLS key.

Tested on an **Honor MagicBook Pro 2020 (HLYL-WXX9)**, firmware
`GF_ST411SEC_APP_12118`, libfprint 1.94.5 / fprintd 1.94.5.

This repository is an **incremental patch** on top of
[`gulp/libfprint-1`](https://github.com/gulp/libfprint-1), branch
`goodix-5117-support`, which already carries the basic 5117 support. Everything
here fixes what that branch could not do on 12118 hardware.

---

## TL;DR

```bash
git clone -b goodix-5117-support https://github.com/gulp/libfprint-1.git
cd libfprint-1
git am /path/to/patches/0001-goodixtls-make-the-27c6-5117-sensor-usable-end-to-en.patch
# then follow scripts/install.sh, or build manually (see below)
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
`C:\ProgramData\Goodix\Goodix_Cache.bin` with DPAPI entropy. Details in
[docs/psk-recovery.md](docs/psk-recovery.md). The key goes to
`/etc/goodix5117/psk`.

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

> **The firmware image is required and is not shipped here** — it is a vendor
> binary. Point `GOODIX_FW_DIR` at a directory containing
> `GF_ST411SEC_APP_12118_5117.bin` (102336 B, CRC-32/MPEG-2 `0xD90EC273`).
> [docs/psk-recovery.md](docs/psk-recovery.md) explains how it was extracted
> from the Windows driver package. **Without the image, do not erase**: the
> bootloader survives, but an empty APP partition on a sensor whose `0xf2`
> (read firmware) is unimplemented means there is no way to get the old image
> back off the device.

The script never erases twice: every failure path leaves the sensor in IAP mode,
which is recoverable by re-running step 4.

---

## Build and install

```bash
sudo apt install build-essential meson ninja-build pkg-config \
    libglib2.0-dev libgusb-dev libcairo2-dev libgnutls28-dev \
    libgudev-1.0-dev libnss3-dev libpixman-1-dev libgirepository1.0-dev
```

```bash
meson setup build -Ddrivers=goodixtls -Dudev_rules=disabled -Dudev_hwdb=disabled
ninja -C build
sudo ninja -C build install
sudo ldconfig
sudo systemctl restart fprintd
```

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

| Tool | Purpose |
|---|---|
| `tools/restore_5117.py` | Erase → write PSK in IAP → reflash → verify. Step-by-step, `--step N` to resume. |
| `tools/goodix-dump-view` | Convert the per-frame PGM dumps into contrast-stretched PNGs. |
| `goodix-dump-view` pairs with `GOODIX_DUMP_DIR`: |
| `GOODIX_DUMP_DIR=/tmp/goodix-dump` | Dump every captured frame as PGM (env-gated). |

The patch also logs `residual range after calibration: X..Y (span Z)` — a small
span means the calibration frame no longer describes the sensor (temperature
drift between activation and scan), which flattens the ridges and makes minutiae
extraction fail entirely.

---

## Known limitation: pressure/angle sensitivity

A badly placed finger yields `0/24` minutiae — that is not a threshold problem,
the image simply contains no extractable ridge detail. Three suspects in the
pipeline are documented but **not yet changed**:

1. `goodixtls5xx_squash_frame_linear()` normalises with the whole-image
   min/max, so one saturated pixel flattens the frame (percentile
   normalisation would help);
2. the calibration frame is captured at activation time, while the scan happens
   1–2 s later with the sensor already warmer;
3. `linear_subtract_inplace()` saturates at `MAX(0, cal - scan)`, permanently
   discarding detail where the finger only partly covers the sensor.

`GOODIX_DUMP_DIR` exists so these can be told apart from real captures.

---

## Documentation

| File | Contents |
|---|---|
| [docs/device-state.md](docs/device-state.md) | USB layout, firmware, current state |
| [docs/psk-recovery.md](docs/psk-recovery.md) | The two PSK layers, firmware extraction, the reflash procedure |
| [docs/psk-write-findings.md](docs/psk-write-findings.md) | Exhaustive proof that APP-mode PSK writes are ignored on this family |
| [docs/driver-changes.md](docs/driver-changes.md) | Per-change notes on the driver patch |
| [docs/results.md](docs/results.md) | Before/after measurements |
| [docs/no-flash-options.md](docs/no-flash-options.md) | The non-flashing route in detail |
| [docs/flash-preview.md](docs/flash-preview.md) | Pre-flight checks for the reflash |

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
git am /path/to/patches/0001-*.patch
meson setup build -Ddrivers=goodixtls -Dudev_rules=disabled -Dudev_hwdb=disabled
ninja -C build && sudo ninja -C build install && sudo ldconfig
sudo systemctl restart fprintd && fprintd-enroll
```

### 已知限制

按歪了会得到 `0/24` 个特征点 —— 这不是阈值问题，是图像里根本没有可提取的脊线。
管线里三个可疑点（全图 min/max 归一化、激活瞬间采的校准帧、`MAX(0, cal-scan)`
饱和）已在 `docs/` 里记录，但**尚未改动**。`GOODIX_DUMP_DIR` 就是为定位它准备的。

</details>
