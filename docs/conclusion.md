# 结论: 为什么这块指纹在 Linux 上用不了

## 一句话
设备被 Windows 驱动用**随机 PSK** 重新配置过，而 Linux 需要**全零 PSK**。
改回来需要刷固件，而固件文件不公开。

## 完整因果链

```
Windows 安装时
  └─> 生成随机 32 字节 PSK (CryptGenRandom)
      └─> SecWhiteEncrypt 加密成 96 字节白盒
          └─> 切到 IAP 模式 (擦除 APP 固件)
              └─> 0xe0 写入白盒
                  └─> 刷回固件, 重启
                      └─> 此后 TLS 用【这个随机 PSK】

Linux 驱动
  └─> 用全零 PSK 尝试 TLS
      └─> Finished 验证失败 (密钥不匹配)
          └─> 握手失败, 所有命令超时
```

## 已排除的方案

| 方案 | 结果 | 原因 |
|---|---|---|
| 换 GnuTLS 后端 | 已实现 | 握手推进到 Finished 仍失败 |
| 用设备 PSK (91d8b7..) | 失败 | 那是 PMK 哈希, 不是 TLS 密钥 |
| 用 PMK (ba1a86..) | 失败 | 同上 |
| 穷举 PSK 长度/PRF/顺序 | 失败 | 密钥是随机值, 不可能猜中 |
| APP 模式写 PSK (0xe0) | 失败 | 12118 固件已移除该命令 |
| 读固件 (0xf2) | 失败 | 12117+ 已移除 |
| 从 Windows 分区提取 | 不可行 | 本机无 Windows 分区 |

## 唯一可行路径

需要 `GF_ST411SEC_APP_12109.bin` (或 12117) 固件文件：

```bash
# 1. 擦除 APP 固件 -> 进入 IAP
python3 -c "..."  # device.mcu_erase_app(0, False)

# 2. IAP 模式下写全零 PSK
#    flags=0xbb010003, payload=96字节白盒
#    全零 PSK 白盒 = 见 PSK_WHITE_BOX (driver_51x7.py)

# 3. 刷回固件
#    device.write_firmware(...)
```

固件获取途径 (均需自行承担风险):
- 同型号笔记本的 Windows 驱动包 (`GoodixFingerPrint.sys` 配套固件)
- 厂商 BIOS 更新包中提取
- 社区分享 (goodix-fp-linux-dev 组织)

## 风险
擦除固件后若无固件可刷 -> **指纹模组永久变砖**
(BIOS 和 Windows 下也无法使用)

## 本机当前状态
- 已编译并安装 GnuTLS 版 libfprint
- 设备可识别, 设置里出现指纹 UI
- 登记会在 TLS Finished 阶段失败
- 原版备份: /root/libfprint-backup/
- 补丁: /tmp/goodix511-final.diff
