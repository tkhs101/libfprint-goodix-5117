# PSK 写入路径的穷尽性验证

日期: 2026-10-20
目的: 确认能否**不刷机**就重写设备 PSK

---

## 结论 (一句话)

**在 APP 模式下无法写 PSK。** 我们的芯片属于 `MILAN_ST411SEC_IAP_*` 家族,
该家族必须先擦除进入 IAP 模式才能写 PSK。唯一不需要刷机的路径是
**让 Windows 驱动去写** (FirPE 方案)。

---

## 证据 1: 两种命令形式都只得到通用 ACK

### 尝试过的命令形式
| 形式 | 命令 | 编码 |
|---|---|---|
| 旧式 | `0xE0` | `preset_psk_write(0xbb010003, <96B白盒>)` |
| 新式 (production/wrapless) | `0xE2` | `data_type=0xB002` + `len` + `<96B白盒>` |

### 实测响应 (双层框架, 与 0xAE/0xE4 一致)
```
0xAE (已实现)   -> cmd=0xb0 payload=ae01 ; cmd=0xae payload=010031000019...
0xE4 (已实现)   -> cmd=0xb0 payload=e401 ; cmd=0xe4 payload=00030002bb2000000091d8b7...
0xE0 (写PSK)    -> cmd=0xb0 payload=e001                        <-- 仅 ACK, 无数据帧
0xE2 (prod写)   -> cmd=0xb0 payload=e201                        <-- 仅 ACK, 无数据帧
0xEE (不存在)   -> cmd=0xb0 payload=ee01 ; cmd=0xee payload=000f0000000000000000000000
0xE6 (不存在)   -> cmd=0xb0 payload=e601                        <-- 仅 ACK
0xF9 (不存在)   -> (无响应)
```
**已实现的命令会返回 ACK + 数据帧; 0xE0/0xE2 只返回 ACK。**
写完之后 `0xE4` 读回的 PSK 仍是 `<old per-device key>` —— **完全没变**。

### 框架确认
`0xE2` 用单层 (wrapless) 框架发送时**完全无响应**, 用双层框架才有 ACK。
说明本设备 (ST411 家族) 走的是旧的双层协议, 新式 production 层不在其固件里。

---

## 证据 2: 社区的家族对照表 (521d 项目)

| family | drivers | APP 模式写 PSK? |
|---|---|---|
| `MILAN_GM168SEC_IAP_10007` | 52xd, 53xd | **no** — 都先擦除到 IAP |
| **`MILAN_ST411SEC_IAP_*`** | **51x0, 51x7 (本机)** | **no** — 都先擦除到 IAP |
| `MILAN_RTSEC_IAP_10027` | 5503, 55x4 | yes — 原地写入 |

**我们的家族明确属于 "no"。** 与本机实测完全一致。

---

## 证据 3: IAP 模式写入是被验证过的 (issue #67)

有人在自己的 **27c6:5117 / GF_ST411SEC_APP_12118** 上执行 `run_5117.py`:
```
1. 检测到固件 12118, 返回 "Valid PSK: False"
2. 自动调用 mcu_erase_app
3. 切到 IAP 模式并【成功写入了新 PSK】      <-- 关键
4. 尝试刷 firmware/51x7/GF_ST411SEC_APP_12109.bin
5. 因固件文件缺失抛 FileNotFoundError
```
=> **5117 上 IAP 模式的 PSK 写入是成功的**, 那个人只是缺固件。
   我们有固件 (原版 12118 + 12117 双份), 所以流程能走完。

---

## 证据 4: 工厂调试固定 PSK 不存在

buxel 分析提到 `PSKSimulationSwitch` (工厂调试用的固定 PSK)。
在本机的 `gfspi.dll` / `EngineAdapter.dll` / `AlgoMilan.dll` 里搜索:
- 无 `PSKSimulationSwitch`
- 无 `PSKCacheSwitch`
- 无任何固定 PSK 常量

(顺带确认 `psk_key_exchange_modes` 只是 TLS 库里的 TLS1.3 扩展名常量表, 无关)

---

## 已排除的纯软件路径汇总

| 尝试 | 结果 |
|---|---|
| 用 `0xE4` 的值当 TLS 密钥 | 失败 (那是 SHA256(白盒)) |
| 用全零 (出厂) | 失败 (设备已被重新 provision) |
| 用 PMK / 设备 PSK / 社区公开的所有已知 PSK | 失败 (每设备随机) |
| 穷举 PSK 长度 / PRF / random 顺序 (192 种) | 失败 |
| 从 `0xE4` 反推明文 | 数学不可逆 (32B 哈希 vs 32B 未知) |
| APP 模式 `0xE0` 写 PSK | 失败 (仅通用 ACK, 静默忽略) |
| APP 模式 `0xE2` 写 PSK (新式 production 层) | 失败 (同上, 该层不在此固件) |
| 工厂调试固定 PSK | 该驱动版本无此开关 |
| 本机 Windows 分区提取 DPAPI | 本机从未装过 Windows, 无此文件 |
| 借 Windows 机器 / FirPE | **可行, 材料已备齐** (需物理操作) |

---

## 结论

**不刷机 = 必须让 Windows 驱动去写 PSK。**
本机的 `27c6:5117` 驱动包 (Microsoft Update Catalog, Goodix FP 1.1.124.115)
的 inf 明确绑定 `USB\VID_27C6&PID_5117`, 用 WinUSB 无第三方内核驱动,
FirPE 套件已备好在 U 盘上 (`/mnt/vt/goodix-firpe-kit/`)。

---

## 七、脚本补强: 唤醒序列 (issue #83 的警告)

`goodix-fp-dump` 的 `init_device()` 在做任何事之前会先:
```python
device.nop()
device.enable_chip(True)
device.nop()
```
原因 (issue #83 明确记录):
> The sensor drops the **first command after waking up**: any probe must send
> `nop()` and wait ~0.8 s before the first real command, otherwise a live
> device is misreported as dead.

原脚本缺少这段, 在 IAP 模式下第一条真实命令 (写 PSK / 刷固件) 有被吞掉的风险。
已补上:
```python
d.nop(); time.sleep(0.8); d.enable_chip(True); d.nop()
```
实测输出确认唤醒序列执行正常, 后续 `preset_psk_read` 仍能正确读到 PSK。

另外确认: IAP 模式下设备**沿用同一 VID:PID** (`27c6:5117`),
`goodix-fp-dump` 的 `init_device(product)` 也是按同一个 product 打开的,
所以擦除后重新枚举不需要特殊处理。
