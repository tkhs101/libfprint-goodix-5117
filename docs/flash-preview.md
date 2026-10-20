# 刷机预演报告 (只读, 未执行任何写入)

日期: 2026-10-20

## 重大发现

本机 `/opt/goodix5117/` 下已有一套**完整可用**的方案:

| 组件 | 路径 | 状态 |
|---|---|---|
| 固件 12109 | `fp-dump/firmware/51x7/GF_ST411SEC_APP_12109.bin` | ✓ 75032 字节 |
| 固件 12117 | `fp-dump/firmware/51x0/GF_ST411SEC_APP_12117.bin` | ✓ 102268 字节 |
| 刷机工具 | `fp-dump/driver_51x7.py` | ✓ 完整 |
| Python 环境 | `venv/` (usb, crcmod, periphery) | ✓ 就绪 |
| 原生工具 | `driver/build/` (init/capture/enroll/verify/unlock) | ✓ 已编译 |

## 关键实测结果

### 1. 设备明文模式完全可用!
```
$ ./build/init
 1/10  nop                    ✓
 2/10  enable chip            ✓
 3/10  nop                    ✓
 4/10  firmware version       ✓  GF_ST411SEC_APP_12118
 5/10  read psk               ✓  <old per-device key> (非出厂值)
 6/10  reset sensor           ✓
 7/10  mcu idle mode          ✓
 8/10  read otp, calibration  ✓  0bc8 00be 00bc 00bc
 9/10  upload mcu config      ✓
10/10  powerdown scan freq    ✓
```

**这推翻了我之前的判断** — 设备在明文模式下完全正常,只有图像数据需要 TLS。

### 2. 0xD4 可以解锁设备
```
$ ./build/unlock
0xd4: acknowledged
sensor responding: GF_ST411SEC_APP_12118
```
TLS 握手失败后设备会锁死(仅响应 0xD0),`0xD4` 可立即解锁。

### 3. TLS 失败原因确认
```
$ ./build/tlshandshake
handshake failed: TLS failure
openssl: cipher operation failed
  sensor ->   52 bytes  [handshake]     ClientHello
  host   ->   95 bytes  [handshake]     ServerHello + HelloDone
  sensor ->   26 bytes  [handshake]     ClientKeyExchange
  sensor ->    6 bytes  [change cipher spec]
  sensor ->   45 bytes  [handshake]     Finished
  host   ->    7 bytes  [alert] level 2, bad_record_mac (20)
```
与 SPEC.md §6 描述的"密钥不匹配"签名完全一致。

## 刷机流程 (6 步)

| 步骤 | 命令 | 作用 | 风险 |
|---|---|---|---|
| 0 | — | 前置检查 | 无 |
| 1 | `0xA4` | 擦除 APP 固件 → 只剩 IAP | **不可逆** |
| 2 | `0xE0` | 写全零 PSK 白盒 (96B, flags=0xbb010003) | 低 |
| 3 | `0xE4` | 读回验证 PMK == ba1a86... | 无 |
| 4 | `0xF0` | 刷固件 75 块 × 1008B | **关键** |
| 5 | `0xF4` | CRC32-MPEG 校验 = 0x5a78935d | 无 |
| 6 | `0xA2` | 重启进入新固件 | 无 |

## 校验值
```
固件 SHA256 : 100fc8a9fc3b37d018e6ffc7cd84ac7b28c8f1f71e9e8d7b94c1b1a96bf8a585
固件 CRC32-MPEG : 0x5a78935d
白盒 (96B) : ec35ae3abb45ed3f12c4751f1e5c2cc0...
期望 PMK    : ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43
```

## 风险与缓解

**风险 1: 无法备份当前固件**
`0xF2` (READ_FIRMWARE) 在 12118 上不响应,所以刷之前无法保存原固件。

**风险 2: driver_51x7.py 的错误处理会二次擦除**
```python
except Exception as error:
    erase_firmware(device)   # ← 失败时再擦一次,可能变砖
    raise error
```
建议改用自定义分步脚本,失败时保留 IAP 状态以便重试。

**风险 3: 降级**
当前 12118 → 刷 12109,属降级。CRC 只验证传输完整性,不验证兼容性。

**缓解措施**
- 全程保持 USB 连接,不要断电/休眠
- 失败时停在 IAP 模式,可重新执行 0xF0(不要拔线)
- IAP bootloader (MILAN_ST411SEC_IAP_12001) 不会被擦除

## 建议

先做**最小验证**:只执行到步骤 3(擦除+写PSK+验证),
不刷固件。此时设备停在 IAP 模式,PSK 已是全零。
如果 IAP 模式下能通过 TLS 握手验证,再刷固件。

但这仍需要先擦除。**没有零风险的验证方式。**
