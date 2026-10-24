# Windows 上恢复 27c6:5117 的 TLS-PSK（不刷机）

本文说明如何在一台 **Windows** 机器上，从 Goodix 驱动留下的 DPAPI 缓存中
取出 `27c6:5117` 的每设备 32 字节 TLS-PSK，供 Linux 的 `goodixtls511`
驱动使用。整个过程只读，不擦除、不刷写、不影响 Windows Hello。

适用条件：

- 传感器已经被 Windows 的 Goodix 驱动 provision 过（正常装过驱动并接触过
  传感器即可，不要求登记 Windows Hello 指纹）；
- `C:\ProgramData\Goodix\Goodix_Cache.bin` 存在；
- 在写入缓存的同一个 Windows 用户下运行，或以 SYSTEM 身份运行。

实测环境：Honor MagicBook Pro 2020（HLYL-WXX9），Windows build 26300，
Goodix FP `1.1.124.115`，固件 `GF_ST411SEC_APP_12118`。

---

## 1. 先确认缓存和设备

```powershell
Get-PnpDevice -PresentOnly |
  Where-Object { $_.InstanceId -match 'VID_27C6&PID_5117' } |
  Select-Object Status, Class, FriendlyName, InstanceId

Get-Item C:\ProgramData\Goodix\Goodix_Cache.bin |
  Select-Object FullName, Length, LastWriteTime
```

本文对应的缓存长度是 **332 字节**：

```text
[ 324 B DPAPI blob ][ 8 B seed ]
```

如果文件不存在，先让 Windows 驱动接触一次传感器（打开 Windows Hello
指纹设置即可），再检查。不要删除或改写这个文件。

---

## 2. 解密 PSK

仓库自带脚本：

```powershell
powershell -ExecutionPolicy Bypass -File `
  .\tools\goodix-psk-decrypt.ps1 `
  -OutFile C:\Users\<你>\goodix5117\psk
```

默认只输出掩码和 SHA256，不把完整密钥打到日志里。需要看完整密钥时加
`-ShowKey`。常用参数：

| 参数 | 用途 |
|---|---|
| `-CachePath` | 缓存不在默认位置时指定 |
| `-DriverPath` | 自动找不到 `gfspi.dll` 时指定 |
| `-OutFile` | 写成 `/etc/goodix5117/psk` 可用的 64 hex + 换行 |
| `-Scope CurrentUser` / `LocalMachine` / `Auto` | DPAPI 范围，默认先试 CurrentUser 再试 LocalMachine |
| `-ShowKey` | 在控制台打印完整密钥（默认关闭） |

期望输出类似：

```text
Cache : C:\ProgramData\Goodix\Goodix_Cache.bin
Driver: C:\Windows\System32\DriverStore\FileRepository\gfspi.inf_amd64_...\gfspi.dll
Scope : CurrentUser
PSK   : 32 bytes, SHA256 <redacted>
PSK   : <first 4 bytes>...<last 4 bytes> (masked)
Wrote : C:\Users\...\goodix5117\psk
```

脚本会：

1. 在 `gfspi.dll` 中搜索三组 16 字节常量（不依赖固定偏移）；
2. 验证派生出的 root key 是否等于文档值 `04e0b0f3f5598417dde298e467c795f7`；
3. 用 seed 派生 48 字节 DPAPI entropy；
4. 调用 `CryptUnprotectData`（`System.Security.Cryptography.ProtectedData`）；
5. 校验结果是 32 字节，并可选写入文件、收紧 ACL。

### 算法

```text
seed_hash = SHA256(seed)                       # 32 B
material  = seed_hash[0:16] || root_key        # 32 B
entropy   = seed_hash[16:32] || SHA256(material)  # 48 B
PSK       = DPAPI_Unprotect(blob, entropy)
```

root key 由 `gfspi.dll` 里的三组常量异或得到。常量位置随驱动版本变化：
本机 `1.1.124.115` 在 `0x537e40`，仓库旧文档里的另一个版本在 `0xd35f0`。
因此脚本按 48 字节序列搜索，而不是硬编码偏移。

---

## 3. 复制到 Linux

把生成的 `psk` 放到 Linux 的：

```bash
sudo install -d -m 755 /etc/goodix5117
sudo install -m 600 -o root -g root psk /etc/goodix5117/psk
sudo systemctl restart fprintd
```

文件内容必须是 **64 个十六进制字符**，末尾可以有空白/换行；不要加
`PSK=`、引号或注释。驱动在第一次建立 TLS 时读取该文件，所以改完文件后要
重启 fprintd（或让 fprintd 重新加载）。

验证：

```bash
journalctl -u fprintd -b -f
```

期望：

```text
Loaded the per-device TLS key from /etc/goodix5117/psk
TLS handshake complete (TLS1.2 / AES-128-GCM)
```

这两行是 `fp_dbg` 级别，默认不输出。需要时创建 systemd drop-in：

```bash
sudo systemctl edit fprintd
```

```ini
[Service]
Environment=G_MESSAGES_DEBUG=all
```

```bash
sudo systemctl restart fprintd
journalctl -u fprintd -b -f
```

然后：

```bash
fprintd-enroll
fprintd-verify
```

---

## 4. 故障排查

### DPAPI 解密失败

- 确认是在写入缓存的同一个 Windows 用户下运行。DPAPI 默认绑定用户。
- 驱动可能以 LocalSystem 写入。若 CurrentUser/LocalMachine 都失败，可用
  `psexec -s` 以 SYSTEM 运行 PowerShell，或在计划任务里以 SYSTEM 运行脚本。
- 缓存来自另一台机器/另一次 Windows 安装时，DPAPI master key 不匹配，
  无法解密；这种情况只能重新让当前 Windows 驱动 provision。
- 不要用 `0xe4` 读回的值当密钥：那是 `SHA256(96 字节白盒)` 的摘要，
  不可逆，也不是 TLS 密钥。

### 找不到缓存

常见位置：

```text
C:\ProgramData\Goodix\Goodix_Cache.bin
C:\Windows\ServiceProfiles\LocalService\AppData\Local\Goodix\FingerPrint\Goodix_Cache.bin
```

用 `-CachePath` 显式指定。

### 解密成功但 Linux 握手仍失败

- 文件格式/权限不对：64 hex、`0600 root:root`、目录可读；
- 文件是在 Windows 重新 provision **之前**提取的，密钥已过期；
- 没重启 fprintd，或设置了错误的 `GOODIX_PSK_FILE`；
- 传感器被另一个系统占用（双系统不能同时使用）。

### 密钥会不会变

会。重装 Windows、重置指纹、删除 `Goodix_Cache.bin`、或驱动重新 provision
都可能生成新的每设备密钥。保留一份 `psk` 备份；如果 Windows 侧重新
provision，重新运行本脚本即可。

---

## 5. 固件提取（可选，仅作恢复保险）

同一份驱动 DLL 里还嵌入了完整固件。仓库自带：

```powershell
powershell -ExecutionPolicy Bypass -File `
  .\tools\extract-goodix-firmware.ps1 `
  -OutDir .\firmware
```

脚本会扫描 `00 00 02 20` + ARM 向量表，按 102336 字节切分，用
CRC-32/MPEG-2 和 SHA256 分组。实测 `1.1.124.115`：

- 16 份 5110：CRC `0x886AE278`
- 16 份 5117：CRC `0xD90EC273`
- 5110/5117 只差 `0x18f42` 一个字节（`0x10` / `0x17`）

固件是厂商二进制，**不要提交到仓库或公开分发**。正常使用 PSK 即可，
不要为了“恢复出厂”去刷机；刷机会改变 PSK 并让 Windows Hello 失效。
只有在 PSK 丢失且必须重置传感器时，才按 `docs/psk-recovery.md` 使用
`tools/restore_5117.py`。

---

## 6. 实测记录

| 项 | 值 |
|---|---|
| USB | `USB\VID_27C6&PID_5117\00000000001A` |
| Windows 驱动 | Goodix FP `1.1.124.115`（`oem18.inf`，`WUDFRd`） |
| 缓存 | 332 B = 324 B DPAPI + 8 B seed |
| 常量位置 | `gfspi.dll` `0x537e40` |
| root key | `04e0b0f3f5598417dde298e467c795f7` |
| PSK | 32 B（每设备随机；SHA256 已从本文档隐去） |
| 固件 | `GF_ST411SEC_APP_12118_5117.bin`，102336 B，CRC `0xD90EC273`，SHA256 `D7FB2F4C…88FD1` |

本机 Windows Hello 有登记数据，驱动正常，说明缓存是活跃的。PSK 的最终
验证以 Linux 侧的 `TLS handshake complete (TLS1.2 / AES-128-GCM)` 为准。

---

## 7. 安全提醒

- `psk` 是每设备密钥，不要提交到 git、不要发到公开 issue、不要上传网盘。
- 不要外发 `Goodix_Cache.bin`；在本机/本账户下它可以被 DPAPI 解开。
- 本方法只读取 Windows 已存在的密钥，不会写入传感器，也不会修改 Windows。
- 双系统使用时，同一时刻只能有一个系统占用传感器。
