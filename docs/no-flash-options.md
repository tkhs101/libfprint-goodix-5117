# 不刷机方案分析 (最终版)

日期: 2026-10-20
机型: Honor MagicBook Pro (HLYL-WXX9), 固件 GF_ST411SEC_APP_12118
设备: Goodix 27c6:5117, 序列号 <serial>

---

## 一、问题本质 (已完全查清)

Goodix 5117 有**两个完全独立的密钥**:

| 名称 | 长度 | 来源 | 用途 |
|---|---|---|---|
| **Preset PSK** (混淆) | 32B | 设备 `0xE4` 读出 | 仅用于比对告警, **不参与加密** |
| **TLS 会话 PSK** (明文) | 32B | Windows 驱动内部生成 | **真正的 TLS 加密密钥** |

### 证据: Windows 驱动日志 (WBDI.log) 完整暴露了流程
```
production_get_host_psk_data:
  .get seal data -> read 332 bytes
  unseal return 0x0  length before 324, length after: 32   <- DPAPI 解密 324->32 (明文PSK)
  .wb data
  wb      return 0x0  length before 32,  length after: 96   <- 白盒加密 32->96
  .hash
  hash    return 0x0  length before 96,  length after: 32   <- SHA256 96->32
```
因此: **`0xE4` 返回的是 SHA256(96字节白盒)**, 与明文 PSK 无直接关系。

独立验证:
```
SHA256(PSK_WHITE_BOX) = ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43
                        ↑ 正是出厂值
```

### 已排除的路径
| 尝试 | 结果 | 原因 |
|---|---|---|
| 用 `0xE4` 的值当 TLS 密钥 | 失败 | 那是 SHA256(白盒), 不是 PSK |
| 用全零 (出厂 PSK) | 失败 | 设备已被重新 provision |
| 穷举 PSK 长度/PRF/random 顺序 | 192 种全失败 | PSK 是 32 字节随机值 |
| 从 `0xE4` 反推明文 | **数学上不可行** | 32B 哈希 vs 32B 未知 |
| 用作者的 OpenSSL 工具交叉验证 | 结果一致 | 证明我的 GnuTLS 实现无 bug |

---

## 二、关键背景: 本机从未装过 Windows

| 检查项 | 结果 |
|---|---|
| 分区表 | 只有 ESP(fat32) + ext4 + swap, **无 NTFS** |
| ext4 空闲块 | **0** (100% 已用) |
| 全盘 `Goodix_Cache.bin` | 仅命中我自己写的笔记/下载的脚本 |
| `SYSTEM`/`SECURITY` hive | 无 |
| EFI 目录 | 只有 `BOOT/` + `debian/` |

=> 设备 PSK `91d8b7...` 是**出厂时 OEM 预置**的。
=> 传统"离线 DPAPI 提取"在本机**无法执行** (缺 DPAPI 材料)。

---

## 三、方案清单

### 方案 A: FirPE 免安装重置 + 提取 [推荐]
**可行性: 高** | 不装回本机 | 需一台能启动 U 盘的手

原理 (来自 [Sbenazar/goodix-5f10-psk](https://github.com/Sbenazar/goodix-5f10-psk)):
> **PSK 由 Goodix Windows 驱动在首次接触芯片时自动生成**, 不需要注册指纹。
> 驱动会: 生成随机 32B PSK -> 写芯片 -> DPAPI 封存到 `Goodix_Cache.bin`

所以只要让驱动在**任意** Windows 环境碰一次芯片即可。

步骤:
1. U 盘启动 FirPE (本机已有 ISO)
2. 准备 5117 的 USB 内核驱动 (见"待补"一节)
3. 在 FirPE 里加载驱动, 接触芯片 -> 生成新 PSK + Cache.bin
4. 跑 `goodix_psk_decrypt.ps1` 解密得到明文 PSK
5. 写回本机 `/etc/goodix5117/psk`

优点: **完全不碰本机硬盘**, 关机即还原
风险: 驱动可能触发 IAP 切换 (Windows 自带固件, 理论安全); FirPE 的 DPAPI 会话需实测

### 方案 B: 借一台 Windows 机器 [最省事]
**可行性: 高**

把设备插到**任何**装了 Goodix 驱动的 Windows 机器 -> 驱动自动 provision ->
在那台机器上解密 -> 拷回本机。
(PSK 是每设备独立的, 在别的机器上 provision 后, 那台机器的 Cache.bin 里就是**你这块**设备的 PSK)

### 方案 C: x64dbg 内存转储 [次选]
**可行性: 中** | 需 Windows 会话

社区已验证 (PR: [gulp/libfprint-1#1](https://github.com/gulp/libfprint-1/pull/1)):
附加 `wudfhost.exe`, 拦截 `mbedtls_ssl_conf_psk`, dump 32 字节明文 PSK。
比方案 A 复杂, 但不依赖 DPAPI, 且能直接确认拿到的是明文。

### 方案 D: 刷机回出厂 PSK [最终采用的就是这条]

见 [`flash-on-linux.md`](flash-on-linux.md)（实测实录）与
[`firmware-extraction.md`](firmware-extraction.md)（固件提取）。

**后续结论**：方案 A/B/C 都依赖"那个 Windows 环境仍然存在"。一旦 Windows 被
清除，DPAPI 缓存无法解密，A/B/C 全部失效，方案 D 成为唯一可行路径。它不需要
Windows，全程可在 Linux 完成，且 2026-10 已实测成功。

---

## 四、已完成的技术验证 (关键成果)

### 1. 熵派生完全离线可算
`gfspi.dll` @ `0xd35f0` 处的三个常量, 与 senyakirilovich 脚本中的**完全一致**:
```
CONST_1 = 9d7992b38402b66c81d1f555218942a9   (小端序存储, 已验证)
CONST_2 = 1848d71550d270d219c80632ab4f8bb3
CONST_3 = e47c8938db5250f0205617ee17da4eb4

root_key = 04e0b0f3f5598417dde298e467c795f7
entropy  = SHA256(seed)[16:32] || SHA256(SHA256(seed)[0:16] || root_key)   (48B)
```
=> 除 DPAPI_BLOB 本体外, 全部是纯计算。

### 2. 设备状态完全可控
`/opt/goodix5117/driver/build/` 已编译好:
- `init`       -> 初始化序列 10/10 成功
- `fwversion`  -> 读固件版本
- `tlshandshake` -> **PSK 验证闭环**
- `unlock`     -> `0xD4` 解锁被握手失败卡住的设备
- `capture` / `enroll` / `verify` -> 完整图像流程

### 3. 已下载归档
| 资源 | 位置 |
|---|---|
| Goodix FP 驱动 1.1.18.27 | `/opt/goodix5117/windows-driver/goodix.cab` |
| ├ gfspi.inf / gfspi.dll | `/opt/goodix5117/windows-driver/files/` |
| ├ EngineAdapter.dll | (含 PSK 符号) |
| ├ AlgoMilan.dll | (5110/5117 算法) |
| └ SessionService.exe | |
| DPAPI 解密脚本 | `/opt/goodix5117/windows-driver/scripts/goodix_psk_decrypt.ps1` |
| FirPE ISO | `/mnt/vt/ISO/FirPE-V1.9.2.iso` |

### 4. 验证闭环
```bash
echo "<32字节明文PSK的64位hex>" > /opt/goodix5117/driver/clef.txt
sudo /opt/goodix5117/driver/build/tlshandshake
# 期望: handshake complete / cipher: PSK-AES128-GCM-SHA256

sudo mkdir -p /etc/goodix5117
sudo cp /opt/goodix5117/driver/clef.txt /etc/goodix5117/psk
```

---

## 五、仍待解决: 5117 的 USB 内核驱动

Microsoft Update Catalog 里**没有** 5117 的 USB 驱动:
- "Goodix FP - Biometric 1.1.18.27" 只匹配 `ACPI\GXFP5130` (Nuvoton EC), 是 UMDF 用户态栈
- 搜索 `VID_27C6` 得到的 25 个包**全是 MOC 触控板驱动**
- 华为 PC Manager 11.1.6.31 也不含指纹驱动 (其 `TriFinger` 是屏下指纹 UI)

WBDI.log 证明该驱动的身份:
```
Goodix>>> WBDI Build Dec 10 2020
Hardware ID: USB\VID_27C6&PID_5110&REV_0200
driver version: 1.1.124.12
```

**获取途径 (待尝试)**:
1. Honor/MagicBook 官方 Windows 驱动包 (华为官网/PC Manager 内的驱动仓库)
2. 联想 ThinkPad 驱动页 (Goodix 驱动通用, 5125/5110 多数通用)
3. [goodix-fp-linux-dev/goodix-fp-dump](https://github.com/goodix-fp-linux-dev/goodix-fp-dump) 仓库或 issue 区
4. 闲鱼/淘宝二手的"指纹驱动包"
5. 方案 C (x64dbg) —— 需要同一个驱动, 但只需用户态 DLL, 门槛更低

---

## 六、附: 关键文件位置

> 下表是 2026-10-20 那台机器上的临时布局，**换机器后这些路径都不存在**。
> 仓库内的正式位置见第二列。

| 内容 | 当时的临时路径 | 现在应该用 |
|---|---|---|
| 设备固件 | `/opt/goodix5117/fp-dump/firmware/` | `$GOODIX_FW_DIR/`，见 [`firmware-extraction.md`](firmware-extraction.md) |
| 刷机工具 | `/opt/goodix5117/fp-dump/driver_51x7.py` | [`tools/restore_5117.py`](../tools/restore_5117.py) |
| 原生工具（已编译） | `/opt/goodix5117/driver/build/` | 无对应，已被补丁驱动取代 |
| Windows 驱动包 | `/opt/goodix5117/windows-driver/` | 从 Catalog 重新下载，见 [`firmware-extraction.md`](firmware-extraction.md) |
| 逆向文档 SPEC.md | `/opt/goodix5117/driver/SPEC.md` | `goodix-fp-dump` 仓库内 |
| 本机 libfprint 补丁 | `/tmp/goodix511-final.diff` | [`patches/`](../patches/) |
| 原版库备份 | `/root/libfprint-backup/` | `/var/backups/libfprint-goodix5117/` |

**`/tmp` 下的东西重启即失效**，不要依赖它们。真正需要长期保留的只有两样：
固件镜像、原版 `libfprint-2.so.2.0.0`。
