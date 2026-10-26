# 结论：为什么这块指纹在 Linux 上用不了，以及怎么修好

**状态：已解决。** 2026-10-20 首次恢复成功，2026-10-26 在 Fedora 45 上再次
完整复现并通过。本文是整件事的一页式总结；细节见各专题文档。

---

## 一句话

设备被 Windows 驱动用**每设备随机的 TLS-PSK** 重新配置过，而 Linux 驱动默认用
**全零 PSK** 握手，所以握手永远失败。修法是让 PSK 回到全零——要么从 Windows
缓存里把随机密钥取出来，要么进 IAP 模式重写 PSK 并刷回原厂固件。

**后者不需要 Windows，全程可在 Linux 上完成。**

---

## 完整因果链

```text
Windows 安装 Goodix 驱动
  └─> 生成随机 32 字节 TLS-PSK (CryptGenRandom)
      └─> SecWhiteEncrypt 加密成 96 字节白盒
          └─> 切到 IAP 模式 (擦除 APP 固件)
              └─> 0xe0 写入白盒
                  └─> 刷回固件, 重启
                      └─> 此后 TLS 只认【这个随机 PSK】

Linux 驱动
  └─> 用全零 PSK 尝试 TLS 握手
      └─> Finished 验证失败 / bad_record_mac / GNUTLS r=-24
          └─> 握手失败, 后续命令全部超时
              └─> fprintd 表现为一直 "Enrolling" 或 "No devices available"
```

---

## 关键认知：两层完全不同的"密钥"

这是最容易搞错、也最浪费时间的地方。

| 层 | 大小 | 读取方式 | 真实含义 |
|---|---|---|---|
| Preset PSK / PMK | 32 B | 命令 `0xe4` | `SHA256(96 字节白盒)` 的**摘要** |
| TLS session PSK | 32 B | 无命令 | 真正参与握手的 AES-128-GCM 密钥 |

两者没有数学关系。**用 `0xe4` 读到的值当 TLS 密钥，永远不可能成功**——
32 字节哈希不可逆推回它原本的 32 字节密钥。

出厂设备的 TLS 密钥是**全零 32 字节**；被 Windows 碰过的是**每设备随机**。
`0xe4` 只是用来判断"是否被重新 provision 过"的指纹。

---

## 已排除的方案

| 方案 | 结果 | 原因 |
|---|---|---|
| 换 GnuTLS 后端 | 有效，但不充分 | 握手能推进到 Finished，但密钥不对仍然失败 |
| 用 `0xe4` 读回的值当 TLS 密钥 | 失败 | 那是摘要，不是密钥 |
| 用 PMK (`ba1a86...`) 当密钥 | 失败 | 同上 |
| 穷举 PSK 长度 / PRF / 随机数顺序 | 失败（192 种） | 密钥是 32 字节随机值 |
| APP 模式写 PSK（`0xe0`） | 失败 | 该家族固件在 APP 模式静默忽略 |
| APP 模式写 PSK（新式 `0xe2`） | 失败 | 该协议层不在本固件里 |
| 从设备读固件备份（`0xf2`） | 失败 | 12117+ 已移除该命令 |
| 从「没装过 Windows 的机器」离线 DPAPI | 不可行 | 缺 DPAPI 材料 |

---

## 两条可行路径

### A. 从 Windows 缓存导出密钥（不刷机）

前提：**那个 Windows 环境仍然存在**。DPAPI 把缓存绑定到写入它的用户/机器，
Windows 没了，密钥就永久取不回来了。

```text
C:\ProgramData\Goodix\Goodix_Cache.bin
  或 C:\Windows\ServiceProfiles\LocalService\AppData\Local\Goodix\...
```

用 `tools/goodix-psk-decrypt.ps1` 解出 64 位 hex，写到 `/etc/goodix5117/psk`。
详见 [windows-psk-recovery.md](windows-psk-recovery.md)。

### B. IAP 模式重写 PSK + 刷回原厂固件（已实测，可逆）

不需要 Windows。流程：

```bash
# 1. 擦除 APP 固件 -> 进入 IAP
sudo python3 tools/restore_5117.py --step 1

# 2. 写全零白盒 -> 校验 PMK -> 刷回 12118 -> CRC 校验 -> reset
sudo python3 tools/restore_5117.py --step 2
```

实测输出（2026-10-26）：

```text
步骤 2: preset_psk_write (全零 PSK 白盒, flags=0xbb010003)  写入完成
步骤 3: preset_psk_read 验证  读回: ba1a8603...d72d43  ★ 已回到出厂值
步骤 4: write_firmware 102336 字节, 102 块 × 1008          写入完成
步骤 5: check_firmware  CRC 校验                            ★ 通过
步骤 6: reset -> 启动新固件
```

随后握手：

```text
handshake step: r=0 (成功。)
TLS handshake complete (TLS1.2 / AES-128-GCM)
Device PSK: 0xba1a8603...d72d43
```

完整日志见 [flash-on-linux.md](flash-on-linux.md)。

---

## 刷机前必须做的一件事

**先确认设备到底是不是被重新 provision 过。**

```bash
sudo systemctl stop fprintd
sudo GOODIX_FP_DUMP=~/goodix-fp-dump python3 tools/probe_psk.py
sudo systemctl start fprintd
```

- 摘要 = `ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43`
  → 出厂状态，**不需要刷机**，全零密钥直接可用
- 摘要 ≠ 该值 → 需要导密钥或刷机

很多人卡在"以为要刷机"，其实装好补丁库就能用。

---

## 固件的唯一正确来源

必须用 **Goodix FP - Biometric - 1.1.124.115**
（UpdateID `5075f1e9-7377-49b2-b7f5-eef87d69d067`），其 `gfspi.dll` 为 5.52 MB，
内含 32 份镜像：

| 长度 | 版本 | PID | CRC-32/MPEG-2 | 份数 |
|---|---|---|---|---|
| 102336 | `GF_ST411SEC_APP_12118` | 5110 | `0x886AE278` | 16 |
| 102336 | `GF_ST411SEC_APP_12118` | **5117** | **`0xD90EC273`** | **16** |

**该包里没有 12117，也没有 12109。**

常见错误：下载 `1.1.18.27`（`gfspi.dll` 仅 920 KB），里面**一个固件都没有**。
提取流程见 [firmware-extraction.md](firmware-extraction.md)。

---

## 风险

| 风险 | 后果 | 缓解 |
|---|---|---|
| 刷写中断电 | 停在 IAP 模式 | 重跑 `--step 2` 即可，bootloader 不擦 |
| 无固件就擦除 | APP 分区空，`0xf2` 读不出来 | **没有镜像绝对不要擦** |
| Windows 再次 provision | 全零配置失效 | 别再让 Windows 碰这个传感器 |
| 刷写误用错误镜像 | CRC 校验会拦住 | 脚本强制校验长度 + CRC |

**刷机不写本机磁盘**，只写传感器内部的 SPI flash。本机数据不受影响。

---

## 本机当前状态（2026-10-26 实测）

```text
主机      Fedora 45
设备      Goodix 27c6:5117
固件      GF_ST411SEC_APP_12118
库        /usr/lib64/libfprint-2.so.2.0.0 (补丁版)
备份      /var/backups/libfprint-goodix5117/libfprint-2.so.2.0.0 (原版)
PSK       /etc/goodix5117/psk = 64 个零, 600 root:root
指纹      /var/lib/fprint/yang/goodixtls511/0/7
状态      录入 20/20 通过, verify-match, sudo/KDE 锁屏可用
```
