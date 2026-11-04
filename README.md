# oci-keepalive

防止 Oracle Cloud **Always Free** 实例因"闲置"被 Oracle 回收（停机）。一个脚本同时支持 AMD（x86_64, VM.Standard.E2.1.Micro）和 ARM（aarch64, VM.Standard.A1.Flex），自动识别机型。

## Oracle 的闲置判定

[官方文档](https://docs.oracle.com/en-us/iaas/Content/FreeTier/resourceref.htm)：7 天内以下条件**同时**成立才算闲置：

- CPU 使用率 95 分位 < 20%
- 网络使用率 < 20%
- 内存使用率 < 20%（仅 A1/ARM）

只要打破其中一条就不算闲置。

## 本脚本做了什么

| | AMD | ARM |
|---|---|---|
| CPU | 保持 ~25% | 保持 ~25% |
| 内存 | 不占（不考核） | 保持 ~30% |
| 网络 | 每小时下载约 20MB | 同左 |

- **不影响业务**：CPU 占用是最低调度优先级（SCHED_IDLE + nice 19），业务要 CPU 立刻让出；内存进程每 30 秒检查一次，业务内存涨上来就释放，内存紧张时它最先被 OOM 杀掉。
- **网络**：限速约 8 Mbps，硬上限 10 Mbps；数据直接丢弃，不写硬盘；13 个长期稳定的下载源随机轮换，失败自动换下一个。下载是入站流量，OCI 不计费。
- **安全**：所有保活服务以 `nobody` 身份运行。
- **长期运行**：systemd 管理，开机自启、崩溃自动重启；只依赖 bash、coreutils、curl、python3（仅 ARM）、systemd。

## 安装

在 OCI 实例上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/lowprofileusername/oci-keepalive/main/oci-keepalive.sh -o oci-keepalive.sh
sudo bash oci-keepalive.sh install
```

自定义目标（可选，单位百分比）：

```bash
sudo CPU_TARGET=30 MEM_TARGET=30 bash oci-keepalive.sh install
```

`CPU_TARGET` 允许 5–80，`MEM_TARGET` 允许 5–60。改了机型或 CPU 核数后，重新执行一次 `install`。

## 查看状态

```bash
sudo bash oci-keepalive.sh status
```

会显示：各服务状态、当前 CPU/内存占用、下次网络任务时间、最近 3 次网络任务结果（`OK` / `FAIL` / `WARN`）、Oracle Cloud Agent 是否在运行。

## 确认真的达标

安装满 7 天后，到 OCI 控制台 → 计算实例 → **Metrics**，时间范围选 7 天：

- **CPU Utilization**，统计方式选 P95：应 ≥ 20%（两种机型）
- **Memory Utilization**：应 ≥ 20%（仅 ARM）

E2.1.Micro 是可突发机型（基线 1/8 OCPU），控制台数值如果偏低，把 `CPU_TARGET` 调高后重新 `install`。

监控数据依赖 **Oracle Cloud Agent** 的 Compute Instance Monitoring 插件，请保持启用。

## 网络配置

配置文件 `/etc/default/oci-keepalive`（shell 语法），改完不用重启，下次定时任务自动生效：

- `NET_BYTES`：每次下载字节数，默认 20000000（20MB）
- `NET_RATE`：限速，单位**字节/秒**，默认 `1M`（≈ 8 Mbps），超过 10 Mbps 会被强制压到 10 Mbps
- `NET_URLS`：下载源列表，空格或换行分隔

如果 `status` 里最近结果出现 `WARN`（所有源都失败），换几个可用的大文件地址到 `NET_URLS`。重新 `install` 不会覆盖你改过的配置，新版默认值会写到 `/etc/default/oci-keepalive.new`。

## 卸载

```bash
sudo bash oci-keepalive.sh uninstall
```

配置文件会保留，不需要的话手动删除：`sudo rm -f /etc/default/oci-keepalive /etc/default/oci-keepalive.new`

## 注意

- 这只针对"闲置回收"。账号层面的问题（违反服务条款、试用相关等）不在范围内。
- Oracle 改过多次阈值（10% → 15% → 20%），建议偶尔看一下官方文档，必要时调高 `CPU_TARGET`。
- 升级到 Pay As You Go 账户也常被认为能避免闲置回收，但官方文档未明确说明。
