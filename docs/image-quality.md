# 图像质量：实测数据与结论

本文记录对"按歪就识别不了"这一已知限制的定量查证。
结论基于 **4 张真实指纹帧**（27c6:5117 / GF_ST411SEC_APP_12118）经 SIGFM 实测。

---

## 一、先搞清判定门槛在哪

驱动侧的门槛在 `libfprint/fp-image.c`：

```c
if (sigfm_keypoints_count (data->sigfm_info) < 25)
  {
    g_task_return_new_error (task, G_IO_ERROR, G_IO_ERROR_FAILED,
                             "No enough keypoints found");
```

日志里表现为：

```text
Failed to detect minutiae: No enough keypoints found
report_verify_status: result verify-retry-scan
```

**fprintd 会自动要求重按**，所以"按歪要重来"的体验是预期行为，不是故障。

关键数字是 **25** 个 keypoint。

---

## 二、真实帧的 keypoint 分布

同一根手指、同一天、正常按压，4 张真实帧：

| 帧 | keypoints | 距阈值 25 | 结论 |
|---|---|---|---|
| #1 | **124** | +99 | 充裕 |
| #2 | **30** | **+5** | 擦边 |
| #3 | 126 | +101 | 充裕 |
| #4 | 120 | +95 | 充裕 |

**最重要的一条：同一根手指的两次按压，keypoint 数可以是 124 和 30，相差 4 倍。**

#2 只比阈值高 5 个点。这意味着它不是"图像坏了"，而是**刚好在门槛边缘**——
再轻微一点的对比度下降就会掉到 25 以下。

### 为什么会有这种差异

这与指纹本身无关，而取决于**这一帧的局部对比度**。下面用 #1（124）和 #2（30）
做同样的降质测试，对比非常清楚。

---

## 三、不同降质方式的影响（用 #1，基准 124）

| 降质方式 | keypoints | 结论 |
|---|---|---|
| 原始 | 124 | 通过 |
| 对比度 ×0.80 | 122 | 通过 |
| 对比度 ×0.65 | 122 | 通过 |
| 对比度 ×0.50 | 116 | 通过 |
| 对比度 ×0.35 | 106 | 通过 |
| 对比度 ×0.20 | **5** | 拒绝 |
| 模糊半径 1 | 99 | 通过 |
| 模糊半径 2 | 79 | 通过 |
| 模糊半径 3 | 55 | 通过 |
| 覆盖 90% | 115 | 通过 |
| 覆盖 75% | 103 | 通过 |
| 覆盖 60% | 78 | 通过 |
| 覆盖 45% | 59 | 通过 |

**从 124 的帧出发，几乎没有哪种"按歪"能把它打到 25 以下。**
即使只覆盖 45%、模糊到半径 3，仍有 59 和 55。

## 四、同样的降质作用在 #2（基准 30）

| 降质方式 | keypoints | 结论 |
|---|---|---|
| 原始 | 30 | 通过 |
| 对比度 ×0.80 | **19** | 拒绝 |
| 对比度 ×0.65 | 15 | 拒绝 |
| 模糊半径 1 | **18** | 拒绝 |
| 覆盖 90% | 29 | 通过 |
| 覆盖 75% | **19** | 拒绝 |

**从 30 的帧出发，最轻微的降质就会掉出阈值。**

---

## 五、结论：问题不在"按歪"，在于起点太低

| 起点 | 能承受的降质 |
|---|---|
| 120 左右 | 很大：暗到 1/3、糊到半径 3、只盖 45% 都还能用 |
| 30 左右 | 几乎没有：对比度降 20%、轻微模糊就失败 |

所以：

- **"按歪"本身不是主因**。从一张好帧出发，偏一点、轻一点都还能过。
- **真正的问题是有些帧的起点就只有 30**。这类帧稍微一偏就掉出去。
- 这才是"按歪就 0/24"体验的本质——不是传感器对角度特别敏感，
  而是**部分采集帧的对比度本来就偏低**。

---

## 六、可尝试的改进：局部直方图均衡

既然问题是"低对比度帧起步低"，那么**在提取 keypoint 前先做局部对比度增强**
是有理论依据的。实测（同一套 SIGFM 参数）：

| 帧 | 原始 | 全局均衡 | 局部均衡（16px 分块） |
|---|---|---|---|
| #1 | 124 | 117 (−7) | 120 (−4) |
| #2 | **30** | 31 (+1) | **78 (+48)** |
| #3 | 126 | 116 (−10) | 130 (+4) |
| #4 | 120 | 109 (−11) | 127 (+7) |

**关键结果：**

- **全局均衡有害**：4 帧全部下降，因为它把已经饱和的区域压平了。
- **局部均衡在低质量帧上效果巨大**：#2 从 30 提到 78，直接脱离危险区。
- **在高质量帧上基本无损**：−4 / +4 / +7，属于噪声范围。

### 为什么还没有直接合入

局部均衡**会改变送进 SIGFM 的像素值**，而登记时存下的模板也是从均衡后的图像
提取的。这意味着：

1. 已录入的模板（本次实测录入的 #0 right-index-finger）是用**未均衡**的图像提取的；
2. 如果只对验证阶段做均衡，模板与待测特征会处于不同的特征空间，匹配会失败；
3. 所以要启用它，必须**同时**作用于登记与验证，并且**重新录入**指纹。

因此这是一个需要用户配合（重录）的改动，不是可以静默生效的修复。
在没有更多真实帧验证之前，不推荐直接合入。

### 如果要做，正确的实施路径

1. 在 `scan_on_read_img()` 里，`goodixtls5xx_squash_frame_linear()` 之后、
   `process_frame()` 之前插入局部均衡；
2. 该函数对登记与验证走同一条路径，所以一致性是自动满足的；
3. 删掉已录入模板，重新 `fprintd-enroll`；
4. 用 `tools/probe_keypoints`（见下）对比改动前后的 keypoint 分布。

---

## 七、诊断工具

`tests/diag-keypoints.c` 可以拿任意 PGM 帧测 SIGFM 的 keypoint 数，
用于判断某张帧离阈值有多远，或评估预处理改动的效果。

这是开发期工具，不参与构建。用法：

```bash
# 先在驱动里打开帧转储（注意 fprintd 沙箱，见 docs/driver-changes.md）
sudo mkdir -p /var/lib/fprint/dump
sudo systemd-edit   # 或写 drop-in：Environment=GOODIX_DUMP_DIR=/var/lib/fprint/dump

# 采集若干帧
fprintd-verify -f right-index-finger

# 编译诊断工具
cd ~/src/libfprint-1
g++ -O2 -o /tmp/diag tests/diag-keypoints.c \
  -Ilibfprint -I. \
  $(pkg-config --cflags --libs opencv4) \
  build/libfprint/sigfm/libsigfm.a -lm

/tmp/diag /path/to/goodix-*.pgm
```

> 注意：`libsigfm.a` 是 C++ 静态库，必须用 `g++` 链接，否则会报
> `undefined reference to __throw_length_error` / `DSO missing from command line`。

---

## 八、采集帧的沙箱陷阱（实测踩过）

fprintd 的服务配置是 `ProtectSystem=strict` + `PrivateTmp=yes`，
所以 `GOODIX_DUMP_DIR` **默认写不出任何文件**，日志只会给：

```text
failed to dump image to /tmp/goodix-dump/goodix-....pgm
```

可用的 drop-in：

```ini
[Service]
Environment=GOODIX_DUMP_DIR=/var/lib/fprint/dump
ReadWritePaths=/var/lib/fprint/dump
PrivateTmp=false
ProtectSystem=full
```

**只写 `ReadWritePaths` 而不放松 `ProtectSystem` 会让服务直接启动失败**
（`active=failed`），因为原配置是 `strict`。

---

## 九、尚未回答的问题

- 为什么同一根手指两次按压的 keypoint 会差 4 倍（124 vs 30）？
  可能与按压压力、皮肤湿度、手指位置有关，需要更多样本才能定位。
- 局部均衡用多大的分块最优？目前只试了 16px，值得扫一遍 8/16/24/32。
- 提高对比度能否让 #2 这类帧稳定进入 60+ 区间？需要重录后实测验证匹配率。

这些都需要更多真实帧，欢迎补充采集数据。
