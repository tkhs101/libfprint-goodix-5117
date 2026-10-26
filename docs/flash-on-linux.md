# Linux 端刷机实录（2026-10-26 实测）

这份文档记录一次**完整、成功、在 Linux 上完成**的恢复过程：
从"传感器被 Windows 重新 provision、Linux 握手失败"到"录入 + 验证全部可用"。

和 `docs/results.md` 的区别：那份记录的是 2026-10-20 的第一次恢复，
本轮是第二次（PSK 又被 Windows 改写之后），并且补充了第一次没记下的细节。

---

## 一、起点状态

```text
主机      Fedora 45
设备      Goodix 27c6:5117
固件      GF_ST411SEC_APP_12118（只读探测确认）
libfprint 系统自带 1.94.100（原版，不认识该设备）
fprintd   1.94.5
PSK       设备已被 Windows 驱动重新 provision，为每设备随机值
Windows   环境已不存在，无法再导出缓存
```

只读探测读到的 PSK 摘要（每设备不同，此处脱敏）：

```text
flags = 0xbb020003
psk   = <per-device digest, redacted>
```

出厂值应为 `ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43`。
两者不同，即可判定设备已被重新 provision。

---

## 二、装补丁库后先试全零密钥

这一步值得单独记：**先试再刷**，能避免 90% 的无谓刷机。

安装补丁库后启动 fprintd，日志给出：

```text
No PSK file at /etc/goodix5117/psk, using the all-zero key
GnuTLS PSK server ready (TLS 1.2)
PSK requested (identity: "Client_identity")
handshake step: r=-24 (解密失败。)
gnutls_handshake: 解密失败。
Device PSK: 0x<per-device digest>   ← 与探测值一致
```

`r=-24` 是 GnuTLS 的 `GNUTLS_E_DECRYPTION_FAILED`，含义就是 **PSK 不匹配**。
看到这个返回值就不要再怀疑 TLS 配置、优先级串或激活顺序——那些都已经是好的，
问题只在密钥本身。

---

## 三、准备固件

按 `docs/firmware-extraction.md` 从 `1.1.124.115` 驱动中提取：

```text
文件   GF_ST411SEC_APP_12118_5117.bin
长度   102336
CRC    0xD90EC273
SHA256 d7fb2f4c7a4c8bc53b34deef7f4c2cbda783cb699e37b6bb3b24724bb6288fd1
副本   16 份，字节完全一致
```

离线预检全部通过（长度 / 向量表 / 版本串 / PID / 分块）。

---

## 四、执行刷机

脚本路径：`tools/restore_5117.py`。分两次调用，中间设备会重新枚举。

### 步骤 1：擦除 APP 固件

```bash
export GOODIX_FP_DUMP=~/goodix-fp-dump
export GOODIX_FW_DIR=~/firmware

systemd-inhibit --what=sleep:idle:handle-lid-switch \
  --who=goodix-flash --why="Goodix 5117 firmware recovery" \
  sudo python3 tools/restore_5117.py --step 1
```

实测输出：

```text
[00:03:43] 打开 USB 设备 27c6:5117 ...
[00:03:43] 步骤 1: mcu_erase_app -> 进入 IAP 模式
[00:03:43]    已擦除, 等待设备重新枚举 (10 秒) ...
[00:03:53]    设备已断开. 请重新运行本脚本 (--step 2) 继续.
```

设备重新枚举，Bus 地址变化（Device 004 → 006），VID:PID **保持不变**。

### 步骤 2–6：写 PSK → 刷固件 → 校验 → 重启

```bash
systemd-inhibit --what=sleep:idle:handle-lid-switch \
  --who=goodix-flash --why="Goodix 5117 firmware recovery" \
  sudo python3 tools/restore_5117.py --step 2
```

实测输出：

```text
[00:04:03] 打开 USB 设备 27c6:5117 ...
[00:04:03] 唤醒序列: nop() -> 等待 0.8s -> enable_chip() -> nop()
[00:04:04] 固件就绪: .../GF_ST411SEC_APP_12118_5117.bin
[00:04:04]    len=102336  crc=0xD90EC273  (版本 12118)
[00:04:04] 步骤 2: preset_psk_write (全零 PSK 白盒, flags=0xbb010003)
[00:04:04]    写入完成
[00:04:04] 步骤 3: preset_psk_read 验证
[00:04:04]    flags = 0xbb020003
[00:04:04]    读回: ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43
[00:04:04]    ★ PSK 已回到出厂值
[00:04:04] 步骤 4: write_firmware (102336 字节, 1008/块)
[00:04:05]    已写 20160/102336 (19%)
[00:04:06]    已写 40320/102336 (39%)
[00:04:06]    已写 60480/102336 (59%)
[00:04:06]    已写 80640/102336 (78%)
[00:04:06]    已写 100800/102336 (98%)
[00:04:06]    写入完成, 共 102 块
[00:04:06] 步骤 5: check_firmware CRC 校验
[00:04:06]    ★ CRC 校验通过
[00:04:06] 步骤 6: reset -> 启动新固件
[00:04:06]    完成. 设备应已重新枚举为 APP 模式.
```

**整个刷写只用了约 3 秒**（从写 PSK 到 reset），比预想的快得多。

---

## 五、刷机后验证

### 1. 设备回到 APP 模式

```text
Bus 003 Device 007: ID 27c6:5117 ...   ← 又一次重新枚举
firmware: GF_ST411SEC_APP_12118         ← 版本不变，说明刷的是原版
psk digest: ba1a8603...d72d43           ← 回到出厂值
```

### 2. TLS 握手成功

```text
PSK requested (identity: "Client_identity")
handshake step: r=0 (成功。)
TLS handshake complete (TLS1.2 / AES-128-GCM)
HANDSHAKE DONE
Device PSK: 0xba1a8603...d72d43 (flags=0xbb020003)
TLS established before activation, running activate sequence
```

`r=0` = 成功。这一行就是判定整个方案是否成立的唯一标准。

### 3. 录入

```text
CALIBRATION_STAGE_NUM completed successfully
residual range after calibration: 63962..65535 (span 1573)
Image device captured an image
Device reported enroll progress, reported 1 of 20 ...
...
Device reported enroll progress, reported 20 of 20 ...
Enroll result: enroll-completed
```

过程中出现过一次：

```text
residual range after calibration: 0..65535 (span 65535)
enroll_stage_cb: result enroll-retry-scan
```

`span 65535` 是整幅饱和（手指没放正/压太重），驱动正确地拒绝了这一帧并
要求重按。这是**正常行为**，不是故障。

### 4. 验证

```text
Verify started!
Verifying: right-index-finger
sigfm extract completed in 0.004567 secs
report_verify_status: result verify-match
Verify result: verify-match (done)
```

### 5. PAM 集成

`authselect` 已启用 `with-fingerprint`，`/etc/pam.d/system-auth` 中：

```text
auth        sufficient                                   pam_fprintd.so
auth        sufficient                                   pam_unix.so nullok
```

实测 `sudo` 触发指纹提示，说明 PAM 链路正常。

---

## 六、刷机后一个已知的无害告警

握手成功后，TLS 引擎仍会被喂入应用数据帧，日志出现：

```text
handshake step: r=-38 (在期望接收 TLS 握手数据时接收到应用数据。)
gnutls_handshake: 在期望接收 TLS 握手数据时接收到应用数据。
```

对应 `GNUTLS_E_GOT_APPLICATION_DATA`。**这不影响使用**：随后的
`CALIBRATION_STAGE_NUM completed successfully` 说明数据被正常处理了。

原因是 `goodix_tls_client_write()` 每次收到记录都会调一次
`gnutls_handshake()`，而握手结束后该调用会拒收应用数据。
更干净的做法是握手完成后置一个标志位，只在未完成时调用 handshake。
当前实现不影响功能，故保留。

---

## 七、这次实测新增的结论

相比 `docs/results.md`，本轮补充确认了：

| 结论 | 说明 |
|---|---|
| **Linux 单系统即可完成全部恢复** | 不需要 Windows，不需要 WinPE。只要有正确的驱动包和 pyusb |
| **刷写极快** | 102336 字节约 3 秒，断电窗口非常小 |
| **设备 VID:PID 在 IAP 模式不变** | 擦除后仍可用 `27c6:5117` 打开，不需要特殊处理 |
| **`1.1.18.27` 驱动不含 5117 固件** | 必须用 `1.1.124.115`，详见 `firmware-extraction.md` |
| **`1.1.124.115` 只有 12118，无 12117** | 12117 需另行获取 |
| **`r=-24` 可直接定位为密钥错误** | 不必再排查 TLS 配置 |
| **`span 65535` 是饱和帧，会自动重按** | 不是故障，属正常质量门控 |

---

## 八、命令速查

```bash
# 只读探测（不改设备状态）
systemctl stop fprintd
python3 tools/probe_psk.py          # 见 docs/firmware-extraction.md 末尾可选探针
systemctl start fprintd

# 完整恢复
sudo systemctl stop fprintd
sudo python3 tools/restore_5117.py --step 1
sudo python3 tools/restore_5117.py --step 2
sudo systemctl start fprintd

# 写入显式 PSK 文件（可选，文件不存在时驱动也用全零）
sudo mkdir -p /etc/goodix5117
printf '%064d\n' 0 | sudo tee /etc/goodix5117/psk
sudo chmod 600 /etc/goodix5117/psk

# 录入与验证
fprintd-enroll -f right-index-finger
fprintd-verify -f right-index-finger
fprintd-list "$USER"
```

---

## 九、事后提醒

- **不要再让任何 Windows 环境接触这个传感器**。一旦 Windows 驱动重新
  provision，PSK 变回随机值，当前全零配置立刻失效，必须再刷一次。
- `dnf update libfprint` 会覆盖补丁库，需要重新部署或重跑构建。
- 固件镜像与驱动包建议长期保留，它们是唯一的恢复保险。
