#!/usr/bin/env python3
"""只读探测: 读取 Goodix 27c6:5117 的固件版本和出厂 PSK 摘要。

用途: 在刷机之前判断设备的当前状态。**这个脚本不写入任何东西**,
不会改 PSK, 不会动固件, 只发 0xae / 0xe4 这类查询命令。

判读方法:
  * 读回的摘要 == ba1a8603...d72d43  -> 设备是出厂状态, 全零密钥即可用,
    不需要刷机
  * 读回的是别的值                  -> 设备已被 Windows 重新 provision,
    Linux 侧必须拿到那个随机密钥, 或者刷机恢复出厂

依赖 (与 restore_5117.py 相同):
  * goodix-fp-dump (提供 goodix / protocol 模块)
  * pyusb, spidev
  * 设备当前不被 fprintd 占用

用法:
  sudo systemctl stop fprintd
  sudo GOODIX_FP_DUMP=~/goodix-fp-dump python3 tools/probe_psk.py
  sudo systemctl start fprintd
"""
import os
import sys
import time
import types

FP_DUMP = os.environ.get("GOODIX_FP_DUMP", os.path.expanduser("~/goodix-fp-dump"))
sys.path.insert(0, FP_DUMP)

# protocol.py 在导入时就 import periphery (树莓派 GPIO 库)。我们只用 USB,
# 所以用一个空实现顶替, 避免为了跑一次只读探测去装整个 periphery。
_periphery = types.ModuleType("periphery")


class _CdevGPIO:
    def __init__(self, *args, **kwargs):
        pass


_periphery.CdevGPIO = _CdevGPIO
sys.modules.setdefault("periphery", _periphery)

FACTORY_PMK = "ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43"
PSK_FLAGS_READ = 0xBB020003


def main():
    try:
        import usb.core
        import usb.util
        import goodix
        import protocol
    except ImportError as error:
        print(f"!! 导入失败: {error}")
        print("   需要: pip install pyusb spidev, 以及 goodix-fp-dump")
        return 2

    dev = usb.core.find(idVendor=0x27C6, idProduct=0x5117)
    if dev is None:
        print("!! 找不到 27c6:5117 设备")
        print("   确认传感器已连接, 且 fprintd 已停止 (fprintd 会占用设备)")
        return 1

    cfg = dev.get_active_configuration()
    interfaces = [i for i in cfg if i.bInterfaceClass == 10]
    if not interfaces:
        print("!! 找不到数据接口 (bInterfaceClass == 10)")
        return 1
    iface = interfaces[0]

    try:
        if dev.is_kernel_driver_active(iface.bInterfaceNumber):
            dev.detach_kernel_driver(iface.bInterfaceNumber)
    except Exception:
        pass

    try:
        usb.util.claim_interface(dev, iface.bInterfaceNumber)

        p = protocol.USBProtocol.__new__(protocol.USBProtocol)
        p.device = dev
        p.endpoint_in = 0x81
        p.endpoint_out = 0x01
        d = goodix.Device.__new__(goodix.Device)
        d.protocol = p

        # 传感器会吞掉唤醒后的第一条命令, 所以先 nop 再等一会儿。
        d.nop()
        time.sleep(0.8)
        d.enable_chip(True)
        d.nop()

        firmware = d.firmware_version()
        ok, flags, psk = d.preset_psk_read(PSK_FLAGS_READ)

        digest = psk.hex() if isinstance(psk, (bytes, bytearray)) else str(psk)

        print()
        print(f"固件版本 : {firmware}")
        print(f"读取成功 : {ok}")
        print(f"PSK flags: 0x{flags:08x}")
        print(f"PSK 摘要 : {digest}")
        print()

        if not ok:
            print("判读: 读取失败, 设备可能处于异常状态 (可试 0xd4 解锁)")
            return 1
        if digest == FACTORY_PMK:
            print("判读: ★ 出厂状态 —— TLS 全零密钥即可用, 不需要刷机")
            return 0
        print("判读: 设备已被重新 provision (每设备随机 PSK)")
        print("      两条路: 从 Windows 缓存导出密钥, 或刷机恢复出厂")
        return 3
    finally:
        try:
            usb.util.dispose_resources(dev)
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
