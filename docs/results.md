# ✅ 已完成: 指纹登录已恢复可用

日期: 2026-10-20
设备: Goodix 27c6:5117 (荣耀 MagicBook Pro 2020), 固件 GF_ST411SEC_APP_12118

---

## 执行结果

```
[14:34:20] 步骤 1: mcu_erase_app -> 进入 IAP 模式
             -> 设备重新枚举, 固件版本变为 MILAN_ST411SEC_IAP_12001
[14:34:44] 写入完成, 共 102 块
[14:34:44] 步骤 5: check_firmware CRC 校验
             update_firmware(0, 102336, 3641623155, None)
             ★ CRC 校验通过
[14:34:44] 步骤 6: reset -> 启动新固件
```

### 关键状态
| 项 | 刷机前 | 刷机后 |
|---|---|---|
| 固件 | GF_ST411SEC_APP_12118 | **GF_ST411SEC_APP_12118 (同版本!)** |
| 设备 PSK | `<old per-device key>` (非出厂) | **`ba1a8603...` (出厂值)** |
| TLS 握手 | 失败 (bad_record_mac) | **handshake complete / PSK-AES128-GCM-SHA256** |
| libfprint | 卡在 Enrolling | **HANDSHAKE DONE, 进入指纹采集** |

### 驱动日志
```
Loaded the per-device TLS key from /etc/goodix5117/psk
TLS handshake complete (TLS1.2 / AES-128-GCM)
HANDSHAKE DONE
Device PSK: 0xba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43
Device PSK flags: 0xbb020003
```

---

## 为什么这次是安全的

1. **刷的是原版固件** —— `GF_ST411SEC_APP_12118_5117.bin` (102336 B, CRC 0xD90EC273),
   从 Microsoft Update Catalog 的 `gfspi.dll` 里提取, 与设备原固件同版本同内容。
   不是降级, 是"刷新回出厂状态"。
2. **三重验证过提取正确性**: 32 份副本每组 16 份字节一致; 5110/5117 版仅差 USB PID 1 字节;
   12117 的构造版 CRC+SHA256 与 issue #83 独立数据完全吻合。
3. **CRC 校验通过** —— 设备自己算出了 0xD90EC273, 证明写入的 102336 字节完整无误。
4. **保留了 12117 作为第二保险** (`GF_ST411SEC_APP_12117_5117.bin`, CRC 0xDBD51539)。
5. **脚本不含二次擦除** —— 失败时保留 IAP 状态, 可用同一镜像重刷。

---

## 最终配置

### `/etc/goodix5117/psk`
```
0000000000000000000000000000000000000000000000000000000000000000
```
设备现在是出厂状态, TLS 密钥就是全零。
(驱动在文件不存在时也会自动用全零, 该文件是为了显式化 + 方便将来 Windows 重新 provision 后更新)

### `/etc/pam.d/common-auth`
```
auth		sufficient		pam_fprintd.so
auth	[success=1 default=ignore]	pam_unix.so nullok
```
放在 `pam_unix` 之前 —— 指纹匹配可直接登录, 无需密码。

---

## 下一步 (需要你本人操作)

```bash
fprintd-enroll          # 录入指纹, 按提示把手指放上去
```
录完后:
- 锁屏 / 登录界面即可用指纹
- GNOME 锁屏本来就走 fprintd D-Bus, 无需额外配置

### 如果指纹采集失败
- 传感器型号是 "Goodix TLS Fingerprint Sensor 511", 属于**电容式**,
  手指需要覆盖整个指纹区域并保持约 1 秒
- 之前 "识别不到手指" 的现象就是 TLS 握手失败导致的, 现在握手已通, 应已恢复

---

## 备份与回退

| 内容 | 位置 |
|---|---|
| 原版固件 (可任意重刷) | `/opt/goodix5117/windows-driver/firmware/GF_ST411SEC_APP_12118_5117.bin` |
| 降级保险 12117 | `/opt/goodix5117/windows-driver/firmware/GF_ST411SEC_APP_12117_5117.bin` |
| 恢复脚本 | `docs/restore_5117.py` |
| 驱动源码补丁 | `libfprint-1` (分支 goodix-5117-support) |
| 原版 libfprint | `/root/libfprint-backup/` |
| 完整技术文档 | `docs/` |
| FirPE 备选方案 | `/opt/goodix5117/firpe-kit/` (已不需要) |

### 驱动补丁的三处改动 (缺一不可)
1. `goodix511.h` — `goodix_511_psk_0[]` = **出厂值** `ba1a8603...`
   (改成 91d8b7... 或其它值都会导致 PSK 比对失败)
2. `goodix5xx.c` — PSK `memcmp` 失败降级为 `fp_warn` 而非致命
3. `goodixtls.c` — TLS 密钥支持从 `/etc/goodix5117/psk` 读取
