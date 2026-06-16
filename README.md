# incuscheck

`incuscheck` 是一套面向 Incus 宿主机的交互式审查脚本，主要包括：

1. 定时记录容器/虚机的历史连接。
2. 按容器或全局视角审查当前运行进程。

## 主要功能和特性

- 支持一键安装/重装自动 IP 记录
- 按容器归类历史连接
- 支持来源/目标/CIDR/地区过滤
- 支持当前进程审查

### 快速开始

交互式菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/piphase/incuscheck/main/install.sh)
```

## 文件说明

- `incuscheck.sh`
  - 交互式主菜单。
- `conntrack-capture.sh`
  - 单次采集脚本，定时器实际调用它。
- `conntrack-report.sh`
  - 历史连接统计与筛选。
- `checklist.sh`
  - 进程审查脚本。
- `lib/common.sh`
  - 公共配置、GeoIP 检测、systemd 路径和公共函数。
- `incuscheck.conf.example`
  - 配置示例。

## 数据存储

历史连接按“每天一个 TSV 文件”保存：

- `history/YYYY-MM-DD.tsv`

每条记录字段包含：

- 采集时间
- 实例名
- 实例类型
- 入站/出站方向
- 协议
- 本地 IP/端口
- 远端 IP/端口
- 对端实例名
- 国家/地区代码
- 国家/地区名称
- 连接状态

GeoIP 查询结果会缓存在：

- `cache/geoip-cache.tsv`

## 安装后的系统位置

安装完成后，运行时文件默认会放到：

- 程序目录：`/opt/incuscheck`
- 配置目录：`/etc/incuscheck`
- 命令入口：`/usr/local/bin/incuscheck`
- 数据目录：`/var/lib/incuscheck`

对应的 `systemd` 单元：

- `incuscheck-capture.service`
- `incuscheck-capture.timer`

## 依赖

Linux 宿主机上至少需要：

- `bash`
- `incus`
- `conntrack`
- `python3`

可选依赖：

- `jq`
- `mmdblookup` 或 `geoiplookup`
- 对应的 GeoIP 数据库

说明：

- 安装流程会优先尝试自动安装缺失的关键依赖，包括 `jq`。
- 安装流程会尝试自动安装可用的 GeoIP 查询工具和数据库。
- `GeoIP` 不可用时，主功能仍可运行，只是地区过滤不可用。
- VM 要想看到实例内真实进程，需要实例内 `incus-agent` 正常工作。

## 本地使用

### 1. 启动交互菜单

```bash
./incuscheck.sh
```

### 2. 隐藏调试命令

手动执行一次采集：

```bash
./incuscheck.sh --run-once
```

直接看状态页：

```bash
./incuscheck.sh --debug-status
```

### 3. 独立查看历史连接

```bash
./conntrack-report.sh --group-by instance
./conntrack-report.sh --china-ingress --group-by src
./conntrack-report.sh --details --instance my-container --days 3
./conntrack-report.sh --country CN --direction ingress --group-by src
```

### 4. 独立进程审查

```bash
./checklist.sh
./checklist.sh host
./checklist.sh instances
./checklist.sh global
```

## 功能边界

- `conntrack` 是状态快照，不是全流量审计，极短连接可能会漏掉。
- 当前是“按天原始记录 + 查询时聚合”，还没有单独做日汇总压缩。
- 进程审查目前是当前视图，不保留进程历史。
- GeoIP 目前依赖宿主机已有数据库，没有内置下载器。

