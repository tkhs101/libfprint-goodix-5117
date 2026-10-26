# Goodix 27c6:5117 设备状态与技术画像

最后更新：2026-10-26（Fedora 45 实测复核）

本文记录硬件画像、协议行为与密钥状态判定方法。**当前设备已恢复到出厂状态**，
详见文末"当前状态"。

---

## 一、硬件

| 项 | 值 |
|---|---|
| USB ID | `27c6:5117` |
| 制造商 | Shenzhen Goodix Technology |
| 产品名 | Goodix Fingerprint Device / Goodix Fingerprint USB Device |
| 类别 | 电容式指纹传感器 |
| 实测机型 | Honor MagicBook Pro 2020 (HLYL-WXX9) |

### USB 接口布局（关键）

这台设备的接口是**分离**的，这一点在原驱动里被搞错过：

| 接口 | 类 | 端点 |
|---|---|---|
| interface 0 | CDC | 仅 IN 中断 `0x82` |
| **interface 1** | **CDC Data** | **OUT `0x01` / IN `0x81`** |

真正的数据端点（`0x01`/`0x81`）在 **interface 1** 上。
原驱动 `GOODIX_511_INTERFACE` 写的是 `0`，导致每条命令都发往错误接口，
表现为 `did not claim interface 1 before use` 或全线超时。
补丁已改为 `1`。

---

## 二、固件

| 项 | 值 |
|---|---|
| 运行固件 | `GF_ST411SEC_APP_12118` |
| 固件家族 | `GF_ST411SEC_APP_121xx` |
| IAP bootloader | `MILAN_ST411SEC_IAP_12001`（擦除后可见） |
| 镜像长度 | 102336 字节 |
| 镜像 CRC-32/MPEG-2 | `0xD90EC273` |
| 镜像 SHA256 | `d7fb2f4c7a4c8bc53b34deef7f4c2cbda783cb699e37b6bb3b24724bb6288fd1` |

驱动不要求精确版本号，只按前缀 `GF_ST411SEC_APP_` 校验（不同批次会有 12109 /
12117 / 12118），不匹配时只告警。

---

## 三、两层密钥：最容易搞错的地方

| 层 | 大小 | 怎么读 | 真实含义 |
|---|---|---|---|
| Preset PSK / PMK | 32 B | 命令 `0xe4`（flags `0xbb020003`） | `SHA256(96 字节白盒)` 的**摘要** |
| TLS session PSK | 32 B | 无法从设备读出 | 真正参与握手的 AES-128-GCM 密钥 |

**两者无数学关系。** `0xe4` 读回来的是不可逆的哈希，不能当密钥用。

### 出厂值与"被改过"的区分

出厂 PMK（恒定）：

```text
ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43
```

| 设备状态 | TLS 密钥 | `0xe4` 读回 |
|---|---|---|
| 出厂 | 32 字节全零 | `ba1a8603...d72d43` |
| 被 Windows provision 过 | 每设备随机 32 B | 任意其他值 |

所以 **`0xe4` 的唯一用途是判断设备是否被重新 provision**，
它和"Linux 该用哪个密钥"没有直接关系。

### 2026-10-26 实测的两种状态

刷机前（已被 Windows 改过）。这个摘要**每设备不同**，属于敏感信息，此处脱敏：

```text
flags = 0xbb020003
psk   = <per-device digest, redacted>
```

判据很简单：**只要不等于下面的出厂值，就说明设备被重新 provision 过**。

刷机后（恢复出厂）：

```text
flags = 0xbb020003
psk   = ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43
```

---

## 四、已确认的协议行为

### 明文模式

- 上电后**只响应** `0xae`（查询 MCU 状态）和 `0xd0`（请求 TLS 连接）
- 其余命令在 TLS 建立前全部超时
- 唤醒后会**丢弃第一条命令**：探测前必须 `nop()` 并等约 0.8 秒
- 握手失败后设备会锁死（只答 `0xd0`），`0xd4` 可解锁

### 图像采集

- `0x20`（MCU_GET_IMAGE）会**阻塞直到放下手指**，所以超时必须放宽
  （补丁从 1 秒改为 10 秒）
- 不同 FDT 命令需要不同的寄存器序列：
  `0x32` = fdt_down（布防等手指）、`0x34` = fdt_up、`0x36` = 状态切换。
  原驱动三者共用一个表，导致 `0x20` 永远拿不到帧
- 采集完成后**不必等抬手**：非录入动作应立即上报 finger-off，
  否则动作挂起直到 fprintd 取消，成功匹配会被记成 `verify-no-match`

### 固件读写

| 命令 | 行为 |
|---|---|
| `0xe0` 写 PSK | APP 模式**静默忽略**，只回传输层 ACK |
| `0xe2` 写 PSK（新式 production 层） | 同上，该层不在此固件 |
| `0xe0` 写 PSK | **IAP 模式有效** |
| `0xf2` 读固件 | 12117+ **已移除**，无法从设备备份原镜像 |
| `0xf0` 写固件 | IAP 模式有效，1008 字节/块 |
| `0xf4` 校验固件 | IAP 模式有效，CRC-32/MPEG-2 |

**`0xf2` 不可用是"没有镜像就不要擦除"的根本原因。**

### 家族归属

| 家族 | 机型 | APP 模式能写 PSK？ |
|---|---|---|
| `MILAN_GM168SEC_IAP_*` | 52xd, 53xd | 否，都需先擦除 |
| **`MILAN_ST411SEC_IAP_*`** | **51x0, 51x7（本机）** | **否** |
| `MILAN_RTSEC_IAP_*` | 5503, 55x4 | 是，可原地写 |

---

## 五、日志判读速查

### TLS 握手

| 日志 | 含义 | 该做什么 |
|---|---|---|
| `handshake step: r=0` | 成功 | 继续，密钥正确 |
| `handshake step: r=-24` | `GNUTLS_E_DECRYPTION_FAILED` | **密钥错了**，不要查 TLS 配置 |
| `handshake step: r=-38` | `GNUTLS_E_GOT_APPLICATION_DATA` | 握手已成功后的应用数据，无害 |
| `server ready failed` | OpenSSL 时代的报错 | 已改用 GnuTLS，不应再出现 |

### 图像质量

日志里的 `residual range after calibration: X..Y (span Z)`：

| span | 判读 |
|---|---|
| 1000–2000 | 脊线清晰，可用 |
| `65535`（`0..65535`） | 整幅饱和，手指压太重/没放正，会自动重按 |
| 接近 0 | 校准帧失效（温度漂移），脊线被抹平 |

---

## 六、刷机前后的设备表现

| 观察点 | 擦除前 | IAP 模式 | 刷回后 |
|---|---|---|---|
| USB VID:PID | `27c6:5117` | `27c6:5117`（不变） | `27c6:5117` |
| Bus 地址 | Device 004 | Device 006 | Device 007 |
| 固件版本 | `GF_ST411SEC_APP_12118` | `MILAN_ST411SEC_IAP_12001` | `GF_ST411SEC_APP_12118` |
| `0xe4` | 每设备随机值 | 写后变 `ba1a8603...` | `ba1a8603...` |
| TLS 握手 | `r=-24` 失败 | — | `r=0` 成功 |

注意：**IAP 模式下 VID:PID 不变**，所以擦除后重新枚举不需要特殊处理，
`restore_5117.py` 用同一个 product id 就能重新打开。

---

## 七、当前状态（2026-10-26）

```text
设备       Goodix 27c6:5117, Bus 003 Device 007
固件       GF_ST411SEC_APP_12118
PSK        出厂值 ba1a8603...d72d43  => TLS 密钥 = 全零
握手       r=0 (TLS1.2 / AES-128-GCM)
录入       20/20 阶段通过
验证       verify-match
系统库     /usr/lib64/libfprint-2.so.2.0.0 (补丁版)
原库备份   /var/backups/libfprint-goodix5117/libfprint-2.so.2.0.0
PAM        system-auth 含 pam_fprintd.so, sudo 与 KDE 锁屏可用
```

**重要提醒**：任何时候再让 Windows 驱动接触这个传感器，PSK 都会被重新
provision 成随机值，上述配置立刻失效，需要重新刷机。

---

## 八、参考资源

- <https://github.com/goodix-fp-linux-dev/goodix-fp-dump>
  —— 参考实现与协议文档（SPEC.md），issue #83 是社区验证过的恢复流程
- <https://github.com/buxel/libfprint-27c6-5110> —— 完整逆向分析
- <https://github.com/soroushdeimi/goodix-521d-project> —— 家族对照表
- <https://github.com/Sbenazar/goodix-5f10-psk> —— DPAPI 熵派生
