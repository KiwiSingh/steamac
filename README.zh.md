# Steamac — Kiwi Build

[English](README.md) · [Русский](README.ru.md) · **简体中文** · [हिंदी](README.hi.md)

[fxgl/steamac](https://github.com/fxgl/steamac) 的个人分支，专注于提升在 Apple Silicon Mac 上运行 SteamOS 游戏的体验与便利性。

当前版本基于 **Steamac 1.9**，集成了上游 1.8、1.8.1、1.8.2 和 1.9 版本的全部改进，以及 Kiwi 专属增强功能（75% 自动内存分配、BepisBridge、Discord Rich Presence、GE-Proton 安装器以及 ReShade/资产 Mod 管理）。

> **最新 Kiwi 版本：** `v1.9-kiwi.1`（[下载](https://github.com/KiwiSingh/steamac/releases/tag/v1.9-kiwi.1)）

Kiwi Build 1.9 搭配 [BepisLoader 2.3.5+](https://github.com/KiwiSingh/BepisLoader/releases/tag/v2.3.5) 进行 Mod 管理和 SteamOS 整合。

## Kiwi Build 1.9 (`v1.9-kiwi.1`) 新功能

### 集成上游 1.8 – 1.9 功能
- **KosmicKrisp 上的 DirectX 12 Feature Level 12_0（macOS 26+）**：
  - 基于 Metal 4 放置稀疏资源（placement sparse resources）实现真正的平铺资源（D3D12 平铺资源 Tier 2）：图像和缓冲区的稀疏绑定、着色器驻留查询（`CheckAccessFullyMapped`）、未绑定图块读取为零以及采样器 min/max 缩减。
  - 支持严格要求 feature level 12_0 的 DirectX 12 游戏（如《生化危机 2：重制版》）启动并使用其扩展渲染路径。
- **最高支持 12 声道的多声道音频**：
  - 虚拟机启动时自动读取 macOS“音频 MIDI 设置”中配置的扬声器布局（支持 5.1、7.1、5.1.2 以及带高程扬声器的 7.1.4）。
  - 将 PCM 声道直接路由至物理硬件扬声器，缺失的声道会自动进行下混（downmix）。
- **即时音频输出切换**：
  - 连接 AirPods 或在 macOS 控制中心切换设备时，音频输出即时切换，无延迟。
- **多手柄玩家支持**：
  - 除主控制器外接入的更多游戏手柄会自动分配给客户机玩家 2–4 槽位。
- **MoltenVK 与 DXVK 兼容性修复**：
  - 《反恐精英 2》（CS2）：通过 `vkCmdBindDescriptorSets` 绑定空（null）描述符集不再导致虚拟机崩溃。
  - 《求生之路 2》与 DXVK：片段着色器将无符号值写入带符号整数渲染目标时不再编译失败。
- **KosmicKrisp 稳定性与诊断**：
  - 《Dota 2》与 CS2：通过分块遮挡查询结果和共享时间戳计数器堆，彻底解决查询池耗尽问题。
  - M3+ GPU 启动修复：渲染通道的目标纹理现已注册进 Metal 4 驻留集中，解决了启动时的 GPU 超时卡死问题。
  - 超时时输出详细诊断报告，明确指明超时的具体 GPU 任务和驱动失败原因。
- **更清晰的网络与证书错误提示**：
  - 当 VPN、代理或网络过滤器干扰安全连接时，提供明确建议而非晦涩的底层系统错误代码。
  - 清晰识别 Valve 开发签名构建（如 `rc` 分支）并建议切换至稳定版（stable）。
- **Metal 编译器缓存回退**：
  - 若应用程序的 Metal 编译器缓存目录不可写，启动器将自动使用自身的缓存目录。
- **界面多语言本地化**：
  - 启动器窗口、菜单、设置和进度提示现已根据 macOS 系统语言支持俄语和简体中文。

### 保留的 Kiwi 专属增强功能
- **75% 虚拟机内存自动分配**：保持大内存规格（最高达物理内存的 75%，4–16 GiB），同时为 macOS 和统一 GPU 负载保留足够空间。
- **BepisBridge 整合**：无缝对接 BepisLoader，用于 Mod 安装、ReShade 注入和游戏库检测。
- **Discord Rich Presence**：原生 macOS Discord IPC 状态显示，展示当前游玩的游戏封面与游玩时间。
- **GE-Proton 运行时安装器**：可在设置中一键将 GE-Proton 下载并安装至 SteamOS 兼容工具。
- **组合资产 Mod 配置文件与 ReShade**：完整支持校验资产替换、MBE CSV 数据表、ADX2 音频库和 DXGI ReShade 运行时注入。

---

## Kiwi Build 有何不同？

### 更充裕的自动虚拟机内存

Kiwi Build 将 Steamac 的自动虚拟机内存分配从**宿主内存的 50% 提升至 75%**，同时保留 4 GiB 最小值与 16 GiB 最大值限制。

常见自动分配情况：

| Mac 物理内存 | SteamOS 虚拟机 |
| ---: | ---: |
| 8 GB | 6 GiB |
| 16 GB | 12 GiB |
| 18 GB | ~14 GiB |
| 24 GB+ | 16 GiB |

这为大型游戏在 SteamOS 内提供了更多运行空间，同时依然为 macOS 系统和共享 GPU 资源预留了内存。您仍可在“设置”中手动调整该数值。

### Kiwi Build 更新器

内置更新检查器跟踪此分支（`KiwiSingh/steamac`）的发布版本，而非上游仓库。版本标签采用 `vX.Y.Z-kiwi.N` 格式（如 `v1.9-kiwi.1`）。

### BepisBridge 整合

Kiwi Build 在设置中包含 **BepisBridge** 配置，以支持与 [BepisLoader](https://github.com/KiwiSingh/BepisLoader) 协同工作。该配置为每个虚拟机配置独立 SSH 认证与 virtio 通信，使 BepisLoader 能够直接与运行中的 SteamOS 客户机交互。

---

## 下载

预编译的 Kiwi 版本可在此获取：

https://github.com/KiwiSingh/steamac/releases

当前发布版本：

**Steamac 1.9 Kiwi Build 1 — `v1.9-kiwi.1`**

发布 ZIP 包使用临时签名（ad-hoc），**未经过 Apple 开发者 ID 公证**。

## 构建

此分支遵循上游 Steamac 构建体系。构建需求和步骤请参阅源码树及上游文档。

Kiwi 专属改动保持精简，且与上游核心功能隔离。

## 上游项目

Steamac 由 **fxgl** 开发：

https://github.com/fxgl/steamac

此分支跟进上游项目并在其基础上添加 Kiwi 专属功能。后续上游已实现或取代的功能将优先使用上游实现，避免维护不必要的冗余代码。

## 许可证

请参阅本仓库现有许可证及上游 Steamac 许可证信息。
