# 固件镜像的获取与提取（已实测）

本文说明如何从 Microsoft Update Catalog 的 Goodix Windows 驱动中提取
`27c6:5117` 的原厂固件镜像。整个过程在 Linux 上完成，不需要 Windows。

固件是厂商二进制，**不随本仓库分发**。你需要自己下载驱动包并提取。

---

## 一、先弄清一件事：哪个驱动包才有 5117 固件

这是最容易浪费时间的地方。Microsoft Update Catalog 上有多个 Goodix 驱动，
**只有其中一个**包含 `27c6:5117` 的固件：

| 驱动包 | 记录时间 | inf 匹配的硬件 | 含 5117 固件？ |
|---|---|---|---|
| Goodix FP - Biometric - **1.1.18.27** | 2025-01 | `ACPI\GXFP5130`（Nuvoton EC） | **否** |
| Goodix FP - Biometric - **1.1.124.115** | 2024-07 | `USB\VID_27C6&PID_5117` 等 | **是** |

`1.1.18.27` 的 `gfspi.dll` 只有 920 KB，里面没有任何 `GF_ST411SEC_APP_`
字符串，扫描不到镜像。`1.1.124.115` 的 `gfspi.dll` 有 5.52 MB，内含 32 份固件。

> 本仓库早期文档给出的下载链接指向的是 `1.1.18.27`，因此"提取不到固件"。
> 下面给出正确的获取方式。

---

## 二、定位并下载正确的驱动包

### 1. 在 Catalog 中确认条目

UpdateID 是这个（2026-10 实测仍可访问）：

```text
5075f1e9-7377-49b2-b7f5-eef87d69d067
```

详情页：

```text
https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=5075f1e9-7377-49b2-b7f5-eef87d69d067
```

页面上的关键信息：

```text
Title         : Goodix FP - Biometric - 1.1.124.115
Last Modified : 7/12/2024
Size          : 943 KB
Architecture  : AMD64
Driver Model  : Goodix Fingerprint USB Device
Driver Provider : Goodix FP
Company       : Huawei Device Co., Ltd.
```

### 2. 取下载直链

Catalog 的下载框是弹窗，直链要经过 `DownloadDialog.aspx` 才能拿到：

```bash
ID=5075f1e9-7377-49b2-b7f5-eef87d69d067
curl -sS -L -A 'Mozilla/5.0' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -X POST 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' \
  --data-urlencode "updateIDs=[{\"size\":0,\"updateID\":\"$ID\",\"uidInfo\":\"$ID\"}]" \
  -o download-dialog.html

grep -oE 'https?://[^"<> ]+\.cab' download-dialog.html
```

实测得到的直链（2026-10 有效，带时效性，建议按上面的方法现查）：

```text
https://catalog.s.download.windowsupdate.com/c/msdownload/update/driver/drvs/2024/08/0e3b5d0d-2680-490f-be54-c74728d34b24_4b367f0bd9b93bc414e067ebb4b0dcb2e4e9b1c1.cab
```

### 3. 下载并解包

```bash
curl -L --fail -o goodix-1.1.124.115.cab '<上面的链接>'
7z x -y -ogoodix goodix-1.1.124.115.cab
ls -l goodix/gfspi.dll
```

期望看到 `gfspi.dll` 约 **5.52 MB**（`5521920` 字节）。
如果只有 920 KB，说明下错包了。

解包后目录内容：

```text
gfspi.dll             5521920    ← 固件在这里
EngineAdapter.dll     1149880
AlgoMilan.dll          906680
AlgoChicago.dll        682936
SessionService.exe      32344
GoodixEventLog.dll      19736
gfspi.cat               38669
gfspi.inf               11417
```

---

## 三、从 gfspi.dll 提取固件

### 镜像记录格式

`gfspi.dll` 的 `.rdata` 段里，每份固件是这样一个记录：

```text
[镜像本体][trailer: 01 00 00 00][4 字节厂商私有校验][00 00][name_len:1][名称][下一份镜像]
```

判断依据：

- 镜像起点固定以 `00 00 02 20` 开头
- 紧随其后 4 字节是 ARM 向量表，落在 `0x08000000`–`0x08FFFFFF`
- 名称（`GF_ST411SEC_APP_xxxxx`）紧贴镜像之前，无填充

### 提取脚本

不依赖偏移、按签名扫描，并逐份做 CRC 校验：

```bash
python3 - <<'PY'
import struct, hashlib, os

dll = 'goodix/gfspi.dll'
data = open(dll, 'rb').read()
MAGIC = b'\x00\x00\x02\x20'
LEN = 102336                      # 12118 家族的长度
TARGET_CRC = 0xD90EC273           # 12118 / 5117
os.makedirs('firmware', exist_ok=True)

def crc32_mpeg(b):
    c = 0xFFFFFFFF
    for x in b:
        c ^= x << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if c & 0x80000000 else (c << 1) & 0xFFFFFFFF
    return c

hits, start = [], 0
while True:
    i = data.find(MAGIC, start)
    if i < 0:
        break
    start = i + 1
    if i + LEN > len(data):
        continue
    vec = struct.unpack_from('<I', data, i + 4)[0]
    if not (0x08000000 <= vec <= 0x08FFFFFF):
        continue
    blob = data[i:i + LEN]
    if crc32_mpeg(blob) == TARGET_CRC:
        hits.append((i, blob))

assert hits, '没有找到 12118/5117 镜像'
print(f'找到 {len(hits)} 份副本')
assert len({b for _, b in hits}) == 1, '副本内容不一致！'

off, blob = hits[0]
open('firmware/GF_ST411SEC_APP_12118_5117.bin', 'wb').write(blob)
print(f'起始偏移 0x{off:x}')
print(f'长度   {len(blob)}')
print(f'CRC    0x{crc32_mpeg(blob):08X}')
print(f'SHA256 {hashlib.sha256(blob).hexdigest()}')
PY
```

### 期望结果（本次实测）

```text
找到 16 份副本
起始偏移 0x94d36
长度   102336
CRC    0xD90EC273
SHA256 d7fb2f4c7a4c8bc53b34deef7f4c2cbda783cb699e37b6bb3b24724bb6288fd1
```

### 提取正确性的三重验证

1. **16 份副本字节完全一致** —— 同一个 DLL 里嵌了 16 份，内容全等
2. **5110 / 5117 只差 1 个字节** —— 相对偏移 `0x18f42` 处为 `0x10` / `0x17`，
   正是 USB PID，说明提取边界精确
3. **长度自洽** —— `12118 = 102336`，比 `12117` 的 `102264` 多 72 字节

---

## 四、这个驱动包里到底有什么

实测 1.1.124.115 的 `gfspi.dll` 一共 32 份镜像候选，分类如下：

| 长度 | 版本 | PID | CRC-32/MPEG-2 | 份数 |
|---|---|---|---|---|
| 102336 | `GF_ST411SEC_APP_12118` | 5110 | `0x886AE278` | 16 |
| 102336 | `GF_ST411SEC_APP_12118` | **5117** | **`0xD90EC273`** | **16** |

**关键点：这个包里只有 12118，没有 12117，也没有 12109。**

所以：

- `tools/restore_5117.py --fw 12118` 可以用本方法提取的镜像直接跑
- `--fw 12117` 需要另外从 issue #83 作者分享的华为 OEM 包里获取，
  本驱动包提取不到

> 另有一个容易踩的坑：如果你按 `102264` 字节去切同一份 12118 镜像，
> 会得到一个 CRC 为 `0xE4DDD1B7` 的"假 12117"——那只是 12118 的前缀，
> 不是真正的 12117（真 12117 的 CRC 是 `0xDBD51539`）。
> 判断方法：真 12117 里的版本字符串应为 `GF_ST411SEC_APP_12117`，
> 而按前缀截出来的东西里写的仍是 `12118`。

---

## 五、离线预检

刷机前用下面这段自查，全部通过再动设备：

```bash
python3 - <<'PY'
import struct, hashlib
p = 'firmware/GF_ST411SEC_APP_12118_5117.bin'
d = open(p, 'rb').read()
assert len(d) == 102336, len(d)
assert d[:4] == b'\x00\x00\x02\x20'
vec = struct.unpack_from('<I', d, 4)[0]
assert 0x08000000 <= vec <= 0x08FFFFFF, hex(vec)
v = d.find(b'GF_ST411SEC_APP_')
assert d[v:v+21] == b'GF_ST411SEC_APP_12118', d[v:v+30]
assert d[0x18f42] == 0x17, hex(d[0x18f42])   # PID 5117
print('长度 OK / 向量表 OK / 版本串 OK / PID OK')
print('分块数', (len(d) + 1007) // 1008, '末块', len(d) % 1008 or 1008)
PY
```

期望：

```text
长度 OK / 向量表 OK / 版本串 OK / PID OK
分块数 102 末块 528
```

---

## 六、把镜像放到脚本能找到的位置

`tools/restore_5117.py` 默认在下面这个目录找镜像：

```text
~/.local/share/goodix5117/firmware/
```

也可以显式指定：

```bash
export GOODIX_FW_DIR=/path/to/firmware
```

放进目录：

```bash
mkdir -p ~/.local/share/goodix5117/firmware
cp firmware/GF_ST411SEC_APP_12118_5117.bin ~/.local/share/goodix5117/firmware/
sha256sum ~/.local/share/goodix5117/firmware/GF_ST411SEC_APP_12118_5117.bin
```

SHA256 应为 `d7fb2f4c7a4c8bc53b34deef7f4c2cbda783cb699e37b6bb3b24724bb6288fd1`。

---

## 七、Windows 侧的等价做法

如果你在 Windows 上，仓库自带脚本可以直接完成同样的事：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\extract-goodix-firmware.ps1 `
  -OutDir .\firmware
```

它会自动在 DriverStore 里找最新的 `gfspi.inf_*`，扫描镜像、按 CRC/SHA256
分组并输出。

---

## 八、注意

- **固件不要提交到仓库，也不要公开分发** —— 厂商二进制。
- **没有镜像就不要执行擦除**。这块设备 `0xf2`（读固件）不响应，
  擦掉之后原镜像无法从设备里取回。
- 下载链接有时效性。Catalog 的 CAB 直链带有日期路径（`.../2024/08/...`），
  失效时按第二节的方法重新获取。
- `1.1.124.115` 的 `gfspi.inf` 同时匹配 `PID_5110`、`PID_5117`、`PID_5130`，
  但固件只有 5110 和 5117 两版。
