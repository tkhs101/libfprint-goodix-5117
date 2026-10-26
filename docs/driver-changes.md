# 驱动改造: 让两条恢复路径都能工作

日期: 2026-10-20

## 关键发现 (差点让两条路都白走)

已安装的驱动里有两处会导致"设备恢复了但驱动依然用不了":

### 1. PSK 比对是致命的
```c
if (memcmp (psk, cls->psk, cls->psk_len))
  fpi_ssm_mark_failed (user_data, error);   /* ← 直接失败 */
```
而 `goodix_511_psk_0[]` 当时硬编码的是 `91d8b7...` (当前设备值)。
- 刷机恢复出厂后, 设备返回 `ba1a86...` -> 不匹配 -> 驱动挂掉
- FirPE 方案里 Windows 生成随机 PSK -> 更对不上 -> 同样挂掉

**修法**: 比对失败降级为 `fp_warn` (issue #83 与 PR #1 都是这个做法)。

### 2. TLS 密钥写死在代码里
```c
static const guint8 goodix_tls_psk[32] = { 0 };
```
FirPE 方案下设备密钥是 Windows 生成的随机值, 写死全零就没法用。

**修法**: 支持从文件读取。

## 最终改动

### `libfprint/drivers/goodixtls/goodix511.h`
- `goodix_511_psk_0[]` 改回**出厂值** `ba1a8603...d72d43`
- 注释说明它是白盒摘要, 不是 TLS 密钥

### `libfprint/drivers/goodixtls/goodix5xx.c`
- `memcmp` 失败 -> `fp_warn ("Device PSK differs from the factory value: ...")`
  而非致命失败。flags 与 length 仍严格校验。

### `libfprint/drivers/goodixtls/goodixtls.c`
- 新增 `goodix_tls_load_psk()`:
  - 优先读环境变量 `GOODIX_PSK_FILE`, 否则 `/etc/goodix5117/psk`
  - 解析 64 位十六进制 (忽略空白/换行), 非十六进制字符跳过
  - 长度不对 -> `fp_warn` 并回退全零
  - 文件不存在 -> 静默回退全零 (出厂设备正确行为)
- `goodix_tls_psk` 从 `const` 改为普通数组, 在 `goodix_tls_server_init()` 里加载
- 加载后用 `explicit_bzero` 清除临时缓冲

---

## 补丁的完整改动清单（2026-10-26 复核）

上面三处是早期排查出的改动。补丁 `0001` 实际改了 **9 个文件、9 组行为**，
下表是可对照源码的完整清单——**任何一项缺失都会导致失败**：

| # | 文件 | 改动 | 缺了会怎样 |
|---|---|---|---|
| 1 | `goodix511.h` | `GOODIX_511_INTERFACE` 0 → **1** | 命令发往错误接口，全线超时 |
| 2 | `goodix511.h` | PSK 常量 = 出厂值；新增 `GOODIX_511_FIRMWARE_PREFIX` | PSK 比对失败 / 版本检查失败 |
| 3 | `goodix.c` | 无关协议命令（杂散 `0xd0`）由报错改为 `fp_dbg` | 状态机卡死 |
| 4 | `goodix.c` | TLS record 只送一次进引擎 | `unexpected TLS handshake packet` |
| 5 | `goodix.c` | 读图缓冲 `0xffff` → `0x4000` | `gnutls_record_recv` 等不到数据 |
| 6 | `goodix.h` | 新增 `GOODIX_IMAGE_TIMEOUT` = 10s | 采集 1 秒就超时 |
| 7 | `goodix511.c` | **先 `goodix_tls_init()`，再跑激活序列** | 12118 上激活全部超时 |
| 8 | `goodix511.c` | `get_mcu_cfg_for_mode`：`0x32/0x34/0x36` 各用独立寄存器表 | `0x20` 永远拿不到帧 |
| 9 | `goodix5xx.c` | 采集后非录入动作立即上报 finger-off | 成功匹配被记成 `verify-no-match` |
| 10 | `goodix5xx.c` | 固件版本失败改为同族前缀告警 | 12118 被 12109 检查拒绝 |
| 11 | `goodix5xx.c` | PSK 摘要不匹配改为 `fp_warn` | 被 provision 的设备直接失败 |
| 12 | `goodixtls.c` | OpenSSL → GnuTLS，内存 transport | 52 字节 ClientHello 被拒 |
| 13 | `goodixtls.c` | TLS 密钥从 `/etc/goodix5117/psk` 读取 | 每设备密钥无法使用 |
| 14 | `meson.build` | `openssl`+`threads` → `gnutls` | 构建失败 |

### 实测确认的关键两条

2026-10-26 的复现中，最能体现"缺一不可"的是第 1 条和第 7 条：

- **接口号**：interface 0 只有中断端点 `0x82`，数据端点在 interface 1。
  写错时现象是 `did not claim interface 1 before use`。
- **激活顺序**：12118 上电即进 TLS 传输层，明文只答 `0xae` / `0xd0`。
  先跑激活序列的话，`enable_chip` / 读固件 / 读 PSK / reset / 上传配置
  全部超时。

## 验证

| 测试 | 结果 |
|---|---|
| 64 位合法 hex 文件 | 加载成功, 字节级一致 ✓ (用临时 fp_info 打印比对) |
| 长度错误的文件 | 触发 "PSK file ... is malformed" 警告 ✓ |
| 文件不存在 | 静默回退全零, 无警告 ✓ |
| PSK 不匹配时 | 驱动打印 "Device PSK differs from the factory value" 而非失败 ✓ |
| 临时调试代码 | 已移除 (二进制中 TEMP-DEBUG 残留 = 0) ✓ |

## 配套工具

- `/usr/local/bin/goodix-apply-psk` — 从 FirPE 取回 PSK 后的一键安装 + 验证 + 启用 PAM
  ```bash
  sudo goodix-apply-psk /media/<U盘>/goodix_psk.txt
  ```
  它会: 校验格式 -> 写 /etc/goodix5117/psk (600) -> 用**作者独立的 OpenSSL 工具**
  验证握手 -> 成功才启用 PAM 指纹认证。

---

## 补丁 0003: 背景减法回绕与稳健归一化 (2026-10-27)

早期文档把 `linear_subtract_inplace()` 描述为"在 `MAX(0, cal - scan)` 处饱和,
会永久丢弃细节"。实际查证后结论不同: 它不是饱和, 而是 **uint16 回绕**。

### 问题

```c
const guint16 max = -1;
src[n] = MAX(0, max - ((max - src[n]) - (max - by[n])));
```

代数上等价于 `src - by + 65535 (mod 65536)`, 只在 `src <= by` 时正确。
当扫描像素比校准帧亮时:

```text
src=3573, by=2000   ->   1572      (应为 65535)
```

**一个这样的像素就能毁掉整帧**: 观测范围被拉成 `0..65535`, 归一化后真实像素
被压进约 8 个灰度级。这就是日志里
`residual range after calibration: 0..65535` 的来源。

### 修法

1. 用 `gint32` 计算差再 `CLAMP(0, 65535)`, 回绕分支改为在白色处饱和;
2. 偏置保持 `GOODIX_SUBTRACT_OFFSET = 0xffff`, 保证原本可用的帧**输出逐字节不变**;
3. `goodixtls5xx_squash_frame_linear()` 改用 65536 桶直方图的 1%/99% 百分位,
   不再用绝对 min/max。

### 关于第 3 点的重要限定

百分位归一化是**防御性改动, 不是问题的解药**。用与真实残差范围相符的合成帧
实测:

```text
无异常像素时:       两种方法差异 0 / 7040 像素
含 1 个异常像素时:  min/max 会把整帧压平, 百分位不受影响
```

所以它只在坏像素漏网时才有意义; 回绕修好之后, 这种情况已经大幅减少。

### 实测验证

在 27c6:5117 / GF_ST411SEC_APP_12118 上:

| 项 | 结果 |
|---|---|
| 连续两次 verify | 均 `verify-match` |
| sigfm 提取耗时 | 0.0046 s / 0.0031 s (基线 0.0046 s, 无退化) |
| span 65535 坏帧 | 修复后会话中未再出现 |

### 一个调试发现

`GOODIX_DUMP_DIR` 在 fprintd 下默认**写不出文件**: fprintd 是沙箱化服务,
`/tmp` 被 `PrivateTmp` 隔离。需要 drop-in:

```ini
[Service]
Environment=GOODIX_DUMP_DIR=/path/to/frames
PrivateTmp=false
ReadWritePaths=-/path/to/frames
```

注意不能只写 `ReadWritePaths` —— 它会覆盖服务原有的 `ProtectSystem` 相关配置,
导致服务启动失败 (`active=failed`)。
