# Goodix 27c6:5117 设备状态记录

记录时间: 2026-10-20

## 硬件
- USB ID: `27c6:5117`
- 制造商: Shenzhen Goodix Technology
- 产品名: Goodix Fingerprint Device
- 序列号: `<serial>`
- 接口: iface0 = CDC (仅 EP 0x82 中断), iface1 = CDC Data (EP 0x01 OUT / 0x81 IN)

## 固件
- 版本: `GF_ST411SEC_APP_12118`
- 系列: `GF_ST411SEC_APP_121*`
- IAP 固件: `MILAN_ST411SEC_IAP_12001` (推测)

## PSK 状态 (关键)
- 设备读回 PMK: `<redacted-per-device-key>`
- 全零 PSK 的 PMK: `ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43`
- **结论: 设备被 Windows 驱动 provision 过，PSK 是随机值，非全零**

## 为什么 Linux 驱动失败
1. Windows 生成随机 32 字节 PSK，用 SecWhiteEncrypt 加密成 96 字节白盒
2. 通过 `0xe0` 写入设备（仅在 IAP 模式下）
3. 设备固件解密白盒，用该随机 PSK 做 TLS-PSK 握手
4. Linux 驱动用全零 PSK -> TLS Finished 验证失败

## 恢复路径 (需要固件文件)
```
固件 12118 -> mcu_erase_app(0xa4) 擦除 -> 进入 IAP
  -> preset_psk_write(0xe0, 0xbb010003, 全零白盒)
  -> update_firmware() 刷回
```
需要 `GF_ST411SEC_APP_12109.bin`，仓库不提供（法律/技术原因）。

## 已确认的设备行为
- 上电后只响应: `0xae` (MCU状态), `0xd0` (请求TLS)
- 其他命令明文状态全部超时
- TLS 握手: ServerHello 被接受, ClientKeyExchange 正常, Finished 验证失败
- `0xe0` 在 APP 模式无响应（符合文档结论）

## 参考资源
- https://github.com/goodix-fp-linux-dev/goodix-fp-dump
- https://github.com/buxel/libfprint-27c6-5110 (完整逆向分析)
- 本机补丁: /tmp/goodix511-final.diff
