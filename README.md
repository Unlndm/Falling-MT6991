# Falling-MT6991

天玑 9400（MT6991）智能调度模块，Magisk / KernelSU / APatch 都能刷。

- 适用：MT6991 · Android 15/16 · 内核 6.6+
- 实测机型：一加 Ace 5 至尊版（PLC110），KernelSU，SELinux Enforcing
- 当前版本：**v3.7.0**（[更新日志](Falling-MT6991/webroot/changelog.md)）
- 完整中文说明：[Falling-MT6991/README_zh.md](Falling-MT6991/README_zh.md)

## 功能

| 功能 | 说明 |
| --- | --- |
| 智能调度 | 按温度 / 整机与分簇占用率 / 帧率 / 前台应用 / 屏态自动选档，不用手动设置 |
| 决策遥测 | 每次换档记录原因、分数、温度、占用、帧率，并累计各档驻留时长 |
| 智能温控 | 恒开：<55℃ 全速 · 55-70℃ 85% · 70-80℃ 70% · >80℃ 55% |
| 游戏调度 | 二选一：交官方风驰整体让路，或模块接管 `game_medium` 保底 |
| 触控采样率 | 日常 / 游戏两档，也能给单个应用指定 |
| 应用策略 | 按包名指定档位，优先于自动评分 |
| 极致省电 | 叠加在当前档位之上的限制层（不是新档位），游戏期间自动失效 |
| ZRAM | 按 12/16/24G 改写 `oplus_mm_config.xml`，开机 bind 覆盖 |
| 存活监控 | 守护异常退出按退避重启，崩溃不会静默失效 |

调度参数不暴露给用户：用户只需配应用策略、触控采样率、游戏调度归属三项，
其余由 `lib/smart.sh` 自动决定。游戏 CPU 一律不管（v9.0 起不写 scx、不碰 HyperBoost）。

## 安装

1. 从 [Releases](https://github.com/Unlndm/Falling-MT6991/releases) 下载 `Falling-MT6991-v3.7.0.zip`
2. 在 Magisk / KernelSU / APatch 里刷入（检测到旧安装会问「保留 / 覆盖配置」）
3. 按音量键选功能（后台守护 / 触控采样率 / ZRAM / 通知）
4. 重启

## 仓库结构

```
Falling-MT6991/          模块本体（可直接打包刷入）
├── lib/                 调度实现：metrics / smart / loop / sched / thermal / governor / extreme
├── bin/falling_daemon   守护进程
├── webroot/             WebUI（概览 / 调度 / 触控 / 我的）
├── config/              档位、调度策略、应用策略、触控配置
├── odm/                 ZRAM 的 bind 覆盖文件
└── README_zh.md         完整中文说明
docs/                    实机节点可靠度、UI 设计评审
tools/                   真机自检、测试环境、UI 校验脚本
selftest*.sh             本地测试套件（testlib.sh 为公共函数）
```

## 自检与工具

| 命令 | 作用 |
| --- | --- |
| `sh tools/run_device_selftest.sh` | 把测试套件推到手机，用真机 mksh 跑一遍（改过 `lib/*.sh` 必跑） |
| `bash selftest_perf.sh` | 数一次 `apply_profile` 的子进程数（改切档链路必跑） |
| `sh selftest_extreme.sh` | 极致省电限制层 45 项断言 |
| `python tools/ui_check.py` | 校验 WebUI 的 HTML / CSS / id / 玻璃角色 / page 结构 |
| `node tools/test_viz.js` | 原创可视化断言 |
| `node tools/test_glass.js` | 液态玻璃引擎（假 WebGL context 计数） |

真机 `/system/bin/sh` 是 mksh，本地 bash 全绿不代表真机全绿，原因见
[docs/arch-realdevice.md](docs/arch-realdevice.md) 与仓库根 `AGENTS.md`。

## 文档

- [完整中文说明](Falling-MT6991/README_zh.md)（功能、控制链、评分模型、配置、排障）
- [实机节点可靠度](docs/arch-realdevice.md)（哪些节点写得稳、哪些会被系统抢占）
- [更新日志](Falling-MT6991/webroot/changelog.md)
- [工作规则](AGENTS.md)（改代码前必读的硬规则与踩坑记录）

## 许可

GPL-3.0-or-later，见 [LICENSE](Falling-MT6991/LICENSE)。
模块内的厂商闭源组件/二进制（如有）不适用本许可，请遵守其各自授权。

## 免责

超频、锁频、绕温控都可能让机器发热、不稳定甚至损坏硬件，后果自负。
