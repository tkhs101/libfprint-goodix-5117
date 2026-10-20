# 关键突破: 完整可逆的恢复方案

日期: 2026-10-20

---

## 一、方案已由社区完整验证 (goodix-fp-dump issue #83)

设备: Goodix 27c6:5110, 固件 GF_ST411SEC_APP_12120 (华为 MateBook 14 2021)

### APP 模式写 PSK **无效**
```
preset_psk_write(0xbb010003, PSK_WHITE_BOX)   # APP 固件运行中
 -> preset_psk_read() 变成 PMK_HASH            # 读回确实变了
 -> 但 TLS 仍然永远失败: gnutls_handshake error: Decryption has failed.
```
无效的尝试: BIOS 断电重启、USBDEVFS_RESET、authorized 开关。

### 有效的流程 (IAP 模式写 PSK + 刷固件)
```
1. mcu_erase_app(0, False)                      -> 重新枚举, 报 MILAN_ST411SEC_IAP_12101
2. preset_psk_write(0xbb010003, PSK_WHITE_BOX)  -> 读回 PMK_HASH
3. write_firmware(offset, chunk)                -> 整份固件, 1008 字节/块
4. check_firmware(0, <len>, <crc32mpeg>)        -> True
5. reset(False, True, 20)
```
结果:
```
libfprint-DEBUG: GnuTLS handshake complete
libfprint-goodixtls5xx-DEBUG: Device PSK: 0xba1a8603...d72d43 (flags=0xbb020003, len=32)
libfprint-goodixtls5xx-DEBUG: Enrollment complete with 20 descriptors
```
=> **PSK 回到出厂值, TLS 用全零密钥打通, 登记与屏幕解锁全部成功。**

本机已独立复现 "APP 模式写 PSK 无效" (0xE0 只有传输层 ACK, 无后续响应, PSK 未变)。

---

## 二、原始固件已提取 (刷机从此完全可逆!)

### 来源
Microsoft Update Catalog -> "Goodix FP - Biometric 1.1.124.115"
(与 issue #83 提到的 OEM 包 "Fingerprint 1.1.124.12" 同系列)
下载链接 (2026-10-20 取得):
```
GUID b2c2cfc4-f216-48d9-86d4-989f439652f2
https://catalog.s.download.windowsupdate.com/c/msdownload/update/driver/drvs/2025/09/
  d93f567f-6244-4974-9348-d83f5262073d_bf3bf694447c87fdc6e4fdf087a608f36fed5571.cab
```
解包后 `gfspi.dll` (5.5 MB) 的 .rdata 段内含 32 份固件副本。

### 固件记录格式 (已完全破解)
```
[image][trailer: 01 00 00 00][4字节厂商私有校验][00 00][name_len:1][name][下一条]
```
- name 紧跟其后即为 image 起点
- 名称后紧接 image, 两者之间无填充
- 每份 image 前 4 字节固定为 `00 00 02 20`, 其后是 ARM 向量表 (0x0803xxxx)

### 提取结果
| 文件 | 长度 | CRC-32/MPEG-2 | SHA256 |
|---|---|---|---|
| **GF_ST411SEC_APP_12118_5117.bin** | **102336** | **0xD90EC273** | d7fb2f4c7a4c8bc53b34deef7f4c2cbda783cb699e37b6bb3b24724bb6288fd1 |
| GF_ST411SEC_APP_12118_5110.bin | 102336 | 0x886AE278 | 3c580fdc2ca0847833a4f940675236f51f7fbc81fc32dfa45ac8142067fb477e |
| GF_ST411SEC_APP_12117.bin (本地已有, 5110版) | 102264 | 0x8AB13532 | b82d1458624f9b4f13c307858177cb3b30476d2250d9e0fc3440caa35c39c24d |

归档位置: `/opt/goodix5117/windows-driver/firmware/`

### 提取正确性的三重验证
1. **32 份副本**: 16 份 5110 版 + 16 份 5117 版, 每组 16 份**字节完全一致** (唯一 SHA256 = 1)
2. **5110 vs 5117 仅差 1 个字节**: 相对 0x18f42 处 `0x10` vs `0x17`
   —— 正是 USB PID (0x5110 / 0x5117), 证明提取边界完全正确
3. **尺寸自洽**: 12118 = 102336 = 12117 的 102264 + **72**;
   而版本串偏移也正好差 72 (0x183c8 - 0x18380) —— 增量位置一致

### 为什么这是关键突破
issue #83 只能刷 12117 (降级), 且**无法备份原固件** (0xF2 在 12117+ 不响应)。
现在我们手里有设备**正在运行的原始 12118 固件**, 所以:
- 刷回的是**同版本**固件, 不是降级
- 万一失败, 可以用同一份镜像重新刷回
- 刷机操作从此**完全可逆**

---

## 三、待执行流程 (用户确认后进行)

```
1. mcu_erase_app(0, False)                     -> 进入 IAP (MILAN_ST411SEC_IAP_12001)
2. preset_psk_write(0xbb010003, PSK_WHITE_BOX) -> 96 字节白盒 (全零 PSK)
3. preset_psk_read(0xbb020003)                 -> 期望 = ba1a8603...d72d43
4. write_firmware(i, chunk)                    -> 102336 字节, 1008/块 (101 块 + 528)
5. check_firmware(0, 102336, 0xD90EC273)       -> True
6. reset(False, True, 20)
```

PSK 白盒 (全零, 96 字节):
```
ec35ae3abb45ed3f12c4751f1e5c2cc05b3c5452e9104d9f2a3118644f37a04b
6fd66b1d97cf80f1345f76c84f03ff30bb51bf308f2a9875c41e6592cd2a2f9e
60809b17b5316037b69bb2fa5d4c8ac31edb3394046ec06bbdacc57da6a756c5
```

### 关键风险与缓解
| 风险 | 缓解 |
|---|---|
| 中途断电/断连 | 停在 IAP 模式, 可用同一镜像重新刷回 (不擦除) |
| `driver_51x7.py` 异常处理会二次擦除 | **不用它**, 自写分步脚本, 失败保留 IAP 状态 |
| 刷入固件有误 | 用 102336 原版镜像重刷即可, 无需降级 |
| 设备变砖 | 理论上不会: IAP bootloader 不会被擦除, 且固件可重刷 |

---

## 四、辅助发现

- `gfspi.dll` @ `0xd35f0` 处的三个常量 (小端序连续) 与 DPAPI 熵派生脚本完全一致:
  ```
  CONST_1 = 9d7992b38402b66c81d1f555218942a9
  CONST_2 = 1848d71550d270d219c80632ab4f8bb3
  CONST_3 = e47c8938db5250f0205617ee17da4eb4
  root_key = 04e0b0f3f5598417dde298e467c795f7
  ```
  => 熵派生纯离线可算, 只有 DPAPI_BLOB 需要 Windows。

- 传感器会丢弃唤醒后的第一条命令 -> 探测必须先 `nop()` 并等 ~0.8 秒
- `read_firmware (0xF2)` 在 12117/12118 上不响应 -> 无法从设备读取固件备份
- 握手失败时 fprintd 会无限挂起 (无错误提示) -> 解释本机"一直 Enrolling"

---

## 五、提取方法的独立验证 (决定性)

issue #83 独立给出了 **5117 版 12117** 固件的 CRC 与 SHA256 (作者从华为 OEM 包提取):
```
GF_ST411SEC_APP_12117 | 27C6:5117 | 102264 | 0xDBD51539 | 57c60649756edd8a455df1bb1e4733b74965cffaac82950c4005691f36b17b90
```

本地已有的 `51x0/GF_ST411SEC_APP_12117.bin` 是 **5110 版**, 其 PID 标记在相对 0x18ef8:
```
c6 27 10 51   ->  VID 0x27C6, PID 0x5110
```
把该字节的 PID 改为 0x5117 后:
```
CRC-32/MPEG-2 = 0xDBD51539   ★ 与 issue #83 完全一致
SHA256        = 57c60649...  ★ 与 issue #83 完全一致
```
=> **提取方法在 issue #83 的独立数据上得到验证**, 且证实
   "5110 版与 5117 版固件仅差 USB PID 一个字节" 这条规律 (12117 和 12118 上都成立)。

## 六、最终固件库

`/opt/goodix5117/windows-driver/firmware/`
| 文件 | 长度 | CRC-32/MPEG-2 | 用途 |
|---|---|---|---|
| GF_ST411SEC_APP_12118_5117.bin | 102336 | 0xD90EC273 | **设备原版固件 (同版本刷新, 可逆)** |
| GF_ST411SEC_APP_12117_5117.bin | 102264 | 0xDBD51539 | issue #83 实证成功版 (降级, 双保险) |
| GF_ST411SEC_APP_12118_5110.bin | 102336 | 0x886AE278 | 对照用 (PID 0x5110) |

## 七、闭环验证: PMK = SHA256(白盒)

```
SHA256(PSK_WHITE_BOX) = ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43
出厂 PMK (期望)        = ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43
完全一致
```
=> 写入该白盒后, 设备 `0xE4` 必然返回出厂 PMK,
   且设备 TLS 密钥 = 全零 PSK => Linux 驱动直接可用 (无需改任何代码)。

## 八、执行脚本

`docs/restore_5117.py`

```bash
sudo /opt/goodix5117/venv/bin/python3 restore_5117.py --fw 12118
# 分步: --step 2 (写PSK) / --step 4 (刷固件) / --step 6 (重启)
```
与 `driver_51x7.py` 的关键差异: **失败时不二次擦除**, 保留 IAP 状态可用同一镜像重试。

## 九、离线预检结果 (全部通过)
```
--fw 12118:  长度 ✓  CRC ✓  ARM向量表 ✓  版本串 ✓  5117 PID ✓  尾部0填充 ✓
             102 块 x 1008 (末块 528)  分块重组一致 ✓
--fw 12117:  长度 ✓  CRC ✓  ARM向量表 ✓  版本串 ✓  5117 PID ✓  尾部0填充 ✓
             102 块 x 1008 (末块 456)  分块重组一致 ✓
PSK 白盒:   96 字节 ✓
```

---

## 十、脚本实测修正 (2026-10-20 第二轮)

对 `restore_5117.py` 做了**非破坏性 live 实测** (只读步骤 3), 发现并修掉 3 个会让脚本完全跑不起来的 bug:

### Bug 1: 同一进程打开了两次设备 (致命)
脚本原本在函数开头和"重新连接"处各有一段设备打开代码。
pyusb 的 `claim_interface` 不会自动释放, 二次 claim 必然 `USBError: [Errno 16] Resource busy`。
**后果: `--step 2` 到 `--step 6` 全部无法执行。**
(issue #83 也提到过这个 pyusb 陷阱)
修法: 抽成 `open_device()` 辅助函数, 每进程只调用一次; 步骤 1 擦除后直接结束进程,
由用户用 `--step 2` 重新开始 (设备此时已重新枚举)。

### Bug 2: `preset_psk_read` 返回值解包错误
参考实现返回 `(success, flags, psk)` **三元组**, 脚本按二元组解包 -> `ValueError: too many values to unpack`。
已按 `driver_51x7.py` 的用法修正为 `ok, flags, psk = ...`。

### Bug 3 (我自己引入的): hex 解析循环边界
`for (i = 0; i < len && out < sizeof (key); i++)` —— 边界应按**十六进制数字个数**算,
即 `sizeof (key) * 2` = 64。写错导致合法的 64 位 key 被误判为 malformed。
该 bug 出现在 libfprint 驱动的 `goodix_tls_load_psk()` 里, 已修正并用临时 `fp_info`
打印做过字节级比对验证 (加载值 == 文件值), 验证后已移除临时代码。

## 十一、API 签名全面审计

脚本用到的每个 API 都与 `goodix-fp-dump/goodix.py` 和 `driver_51x7.py` 逐条核对:

| 脚本调用 | 参考实现 | 状态 |
|---|---|---|
| `d.mcu_erase_app(0, False)` | `device.mcu_erase_app(0, False)` | ✓ |
| `d.preset_psk_write(0xbb010003, PSK_WHITE_BOX)` | 同 | ✓ |
| `ok, flags, psk = d.preset_psk_read(0xbb020003)` | `success, flags, psk = ...` | ✓ (已修) |
| `d.write_firmware(off, chunk)` (1008 字节/块) | `device.write_firmware(i, firmware[i:i+1008])` | ✓ |
| `d.check_firmware(0, 102336, 0xD90EC273)` | `device.check_firmware(0, length, crc)` | ✓ (checksum 按 `<I` 打包, 返回 `msg[0]==0x01`) |
| `d.reset(False, True, 20)` | `device.reset(False, True, 20)` | ✓ |

## 十二、实测结论 (只读步骤)
```
[14:29:07] 打开 USB 设备 27c6:5117 ...
[14:29:07] 固件就绪: .../GF_ST411SEC_APP_12118_5117.bin
[14:29:07]    len=102336  crc=0xD90EC273  (版本 12118)
[14:29:07] 步骤 3: preset_psk_read 验证
[14:29:07]    flags = 0xbb020003
[14:29:07]    读回: <redacted-per-device-key>
```
=> 设备打开、固件加载、CRC 自检、PSK 读取、比对判断、错误提示 **全部实际工作**。
   实测后设备状态未变 (仍是 12118, PSK 未动)。
