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
