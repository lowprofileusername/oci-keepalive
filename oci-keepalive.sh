#!/usr/bin/env bash
# oci-keepalive.sh — 防止 Oracle Cloud Always Free 实例被判定为"闲置"而回收
#
# 官方闲置判定（7 天内以下条件【同时】成立才算闲置）：
#   - CPU 使用率 95 分位 < 20%
#   - 网络使用率 < 20%
#   - 内存使用率 < 20%（仅 A1/ARM 机型）
# 只要打破其中任意一条就不算闲置。本脚本：
#   AMD (x86_64, E2.1.Micro)：CPU 保底 ~25%（不占内存，1GB 太小，且 AMD 不考核内存）
#   ARM (aarch64, A1.Flex)  ：CPU 保底 ~25% + 内存保底 ~30%（双保险）
#   网络（两种机型都有）：每 ~60 分钟下载约 20MB，留下稳定的流量痕迹。
#     数据经管道直接丢弃，不写硬盘、不占空间。
#     限速 ~8 Mbps，硬上限 10 Mbps（服务器 50 Mbps，留足给业务），每次约 20 秒。
#     下载属于入站流量，OCI 不计费、不占 10TB 出站额度；每月约 15GB。
#     不追求 20%（不需要：判定要求条件同时成立，CPU 已经打破）。
#     13 个下载源（kernel.org 及各大学镜像的旧版内核包、Debian/Ubuntu 文件列表，多年不变），
#     每次随机顺序尝试，失败自动换下一个；源地址写在 /etc/default/oci-keepalive，失效了改这里即可，无需重装。
# 保活进程使用 SCHED_IDLE + nice 19，你的业务一旦需要 CPU 会立刻让出；
# 内存进程每 30 秒检查一次，业务内存涨上来就释放；OOM 优先级最高，内存紧张时它先被杀。
# 三个保活服务都以 nobody 身份运行，不需要也不持有 root 权限。
# 只依赖 bash/sh、coreutils、curl、python3（仅 ARM）、systemd，系统升级后照常工作。
#
# 用法（root）：
#   sudo bash oci-keepalive.sh install      # 安装并开机自启（改了机型/核数后重跑一次）
#   sudo bash oci-keepalive.sh status       # 查看状态、当前占用、最近一次网络任务结果
#   sudo bash oci-keepalive.sh uninstall    # 卸载
# 可选环境变量：CPU_TARGET=25（允许 5–80）  MEM_TARGET=30（允许 5–60），单位百分比

set -euo pipefail

CPU_TARGET="${CPU_TARGET:-25}"
MEM_TARGET="${MEM_TARGET:-30}"
LIB_DIR=/usr/local/lib/oci-keepalive
UNIT_DIR=/etc/systemd/system
CONF=/etc/default/oci-keepalive
ARCH="$(uname -m)"
NCPU="$(nproc)"

# 服务公共的降权与隔离设置（systemd 先设好调度/OOM 优先级再降权，降权后照样生效）
HARDEN="User=nobody
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "请用 root 运行（sudo）"; exit 1; }; }

# 校验百分比参数：必须是 lo–hi 之间的整数
check_pct() {
  local name="$1" val="$2" lo="$3" hi="$4"
  # 不允许前导 0：bash 会把 025 当八进制
  case "$val" in ''|*[!0-9]*|0*) echo "$name 必须是不带前导 0 的整数，当前：$val"; exit 1 ;; esac
  if [ "$val" -lt "$lo" ] || [ "$val" -gt "$hi" ]; then
    echo "$name 必须在 $lo–$hi 之间，当前：$val"; exit 1
  fi
}

write_cpu_worker() {
  # 单独成文件，避免在 systemd ExecStart 里转义 $
  cat > "$LIB_DIR/cpu.sh" <<'SH'
#!/bin/sh
# 每个 vCPU 一个空转进程，总占用由 systemd CPUQuota 限制
for _ in $(seq "$(nproc)"); do
  ( while :; do :; done ) &
done
wait
SH
  chmod 755 "$LIB_DIR/cpu.sh"
}

write_net_conf() {
  # 已存在且被你改过就不覆盖，新默认值写到 $CONF.new 供参考
  # 临时文件建在同目录：mv 是原子操作，且 SELinux 标签正确
  local tmp; tmp="$(mktemp "${CONF}.XXXXXX")"; chmod 644 "$tmp"
  cat > "$tmp" <<'CONF'
# oci-keepalive 网络保活配置（shell 语法，由 net.sh 直接读取；改完无需重启，下次定时任务自动生效）
# 每次下载的字节数（默认 20MB）
NET_BYTES=20000000
# 限速，单位是"字节/秒"（注意不是 bit）：1M = 1 MB/s ≈ 8 Mbps
# 脚本内部硬上限 10 Mbps（1250000 字节/秒），写再大也不会超过
NET_RATE=1M
# 下载源，空格/换行分隔，每次随机顺序尝试，任一成功即可。
# 13 个源分属 10 多个机构，每个源平均每天只分到约 40MB，任何一家都不会在意。
# 选的都是长期不变的文件（旧版内核包、软件源文件列表）；某个失效了删掉或换成别的大文件地址即可。
NET_URLS="
https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz
https://mirrors.edge.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz
https://mirrors.kernel.org/debian/ls-lR.gz
https://ftp.debian.org/debian/ls-lR.gz
https://archive.ubuntu.com/ubuntu/ls-lR.gz
https://ports.ubuntu.com/ubuntu-ports/ls-lR.gz
https://mirrors.ocf.berkeley.edu/debian/ls-lR.gz
https://mirror.csclub.uwaterloo.ca/debian/ls-lR.gz
https://mirrors.mit.edu/debian/ls-lR.gz
https://mirrors.mit.edu/kernel/linux/kernel/v6.x/linux-6.6.tar.xz
https://mirror.math.princeton.edu/pub/kernel/linux/kernel/v6.x/linux-6.6.tar.xz
https://ftp.jaist.ac.jp/pub/Linux/kernel.org/linux/kernel/v6.x/linux-6.6.tar.xz
https://ftp.riken.jp/Linux/kernel.org/linux/kernel/v6.x/linux-6.6.tar.xz
"
CONF
  if [ ! -f "$CONF" ]; then
    mv "$tmp" "$CONF"
  elif cmp -s "$tmp" "$CONF"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$CONF.new"
    echo "提示：$CONF 已存在（保留你的设置），新版默认配置写在 $CONF.new，可对比后自行合并"
  fi
  chmod 644 "$CONF"
  command -v restorecon >/dev/null && restorecon -q "$CONF" "$CONF.new" 2>/dev/null || true
}

write_net_worker() {
  cat > "$LIB_DIR/net.sh" <<'SH'
#!/bin/sh
# 下载一段数据并丢弃，留下网络流量痕迹。任一源成功即结束；全部失败只记日志，不报错。
NET_BYTES=20000000
NET_RATE=1M
NET_URLS=
# 配置是 shell 语法（支持多行 NET_URLS），由这里直接读取，不经 systemd EnvironmentFile
CONF=/etc/default/oci-keepalive
[ -r "$CONF" ] && . "$CONF"
[ -n "${NET_URLS:-}" ] || { echo "WARN NET_URLS 为空，请检查 $CONF"; exit 0; }

# 去掉前导 0（否则 $(( )) 会按八进制解析，08/09 直接报错）
strip0() { v=$1; while :; do case "$v" in 0?*) v=${v#0} ;; *) break ;; esac; done; printf '%s' "$v"; }

# 每次下载字节数：必须是正整数，否则用默认值
case "$NET_BYTES" in ''|*[!0-9]*) NET_BYTES=20000000 ;; esac
NET_BYTES=$(strip0 "$NET_BYTES"); [ "$NET_BYTES" -gt 0 ] || NET_BYTES=20000000

# 限速换算成字节/秒，并硬性封顶 10 Mbps = 1250000 字节/秒（服务器只有 50 Mbps）
# 任何写错的值（含 0：curl 里 0 表示不限速）都按上限处理
MAX_RATE=1250000
num=${NET_RATE%[kKmM]}
case "$num" in ''|*[!0-9]*) num= ;; *) num=$(strip0 "$num") ;; esac
if [ -z "$num" ]; then
  RATE=$MAX_RATE
else
  case "$NET_RATE" in
    *[kK]) RATE=$(( num * 1024 )) ;;
    *[mM]) RATE=$(( num * 1024 * 1024 )) ;;
    *)     RATE=$num ;;
  esac
fi
if [ "$RATE" -le 0 ] || [ "$RATE" -gt "$MAX_RATE" ]; then RATE=$MAX_RATE; fi

# 至少拿到这么多才算成功（防止把错误页当成功）
MIN=1000000; [ "$NET_BYTES" -lt "$MIN" ] && MIN="$NET_BYTES"
for url in $(printf '%s\n' $NET_URLS | shuf); do
  # -f：404 等错误不输出内容
  # head 截断：服务器不支持分段下载时也只取 NET_BYTES，不会把整个文件拖下来
  # 单个源最多 120 秒（20MB 按 1MB/s 约 20 秒），13 个源全试完也不超过服务的 1 小时超时
  n=$(curl -fsL --connect-timeout 20 --max-time 120 --limit-rate "$RATE" \
        -A "oci-keepalive/1.0" -r "0-$((NET_BYTES - 1))" "$url" 2>/dev/null \
      | head -c "$NET_BYTES" | wc -c)
  if [ "${n:-0}" -ge "$MIN" ]; then
    echo "OK $n bytes <- $url"
    exit 0
  fi
  echo "FAIL $url"
done
echo "WARN 所有下载源都失败了，请检查网络或更新 /etc/default/oci-keepalive 里的 NET_URLS"
exit 0
SH
  chmod 755 "$LIB_DIR/net.sh"
}

write_mem_worker() {
  cat > "$LIB_DIR/mem.py" <<'PY'
#!/usr/bin/env python3
# 让"已用内存"保持在 MEM_TARGET% 左右：业务少时补足，业务涨上来时自动释放。
import os, time
TARGET = float(os.environ.get("MEM_TARGET", "30")) / 100
CHUNK = 64 * 1024 * 1024
PAGE = os.sysconf("SC_PAGE_SIZE")        # ARM 上可能是 64K 页
INTERVAL = 30
held = []

def meminfo():
    d = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            d[k] = int(v.split()[0]) * 1024
    return d["MemTotal"], d["MemAvailable"]

def touch(b):
    # 每页写一个字节：确保真正占用物理内存，并减少被换出
    b[::PAGE] = b"\x01" * len(range(0, len(b), PAGE))

while True:
    total, avail = meminfo()
    used, want = total - avail, TARGET * total
    if used < want - CHUNK:                       # 不够 → 补
        for _ in range(int((want - used) // CHUNK)):
            b = bytearray(CHUNK); touch(b); held.append(b)
    elif used > want + 2 * CHUNK and held:        # 业务涨了 → 让
        n = min(len(held), int((used - want) // CHUNK) - 1)
        if n > 0:
            del held[:n]
    for b in held:
        touch(b)
    time.sleep(INTERVAL)
PY
  chmod 755 "$LIB_DIR/mem.py"
}

install() {
  need_root
  check_pct CPU_TARGET "$CPU_TARGET" 5 80
  check_pct MEM_TARGET "$MEM_TARGET" 5 60
  mkdir -p "$LIB_DIR"

  # CPU：CPUQuota 以单核为 100%，OCI 指标按全部 vCPU 平均，所以乘以核数
  write_cpu_worker
  local quota=$(( NCPU * CPU_TARGET ))
  cat > "$UNIT_DIR/oci-keepalive-cpu.service" <<EOF
[Unit]
Description=OCI Always Free keepalive (CPU ~${CPU_TARGET}% of ${NCPU} vCPU)
After=network.target

[Service]
Type=simple
ExecStart=${LIB_DIR}/cpu.sh
CPUQuota=${quota}%
CPUSchedulingPolicy=idle
Nice=19
IOSchedulingClass=idle
${HARDEN}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  # 网络：oneshot 服务 + 定时器，开机 5 分钟后首跑，之后每 60 分钟（随机抖动 0–15 分钟）
  command -v curl >/dev/null || { echo "需要 curl：apt install -y curl 或 dnf install -y curl"; exit 1; }
  write_net_conf
  write_net_worker
  cat > "$UNIT_DIR/oci-keepalive-net.service" <<EOF
[Unit]
Description=OCI Always Free keepalive (network trace)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${LIB_DIR}/net.sh
Nice=19
IOSchedulingClass=idle
${HARDEN}
TimeoutStartSec=1h
EOF
  cat > "$UNIT_DIR/oci-keepalive-net.timer" <<EOF
[Unit]
Description=Run OCI keepalive network trace every ~60 min

[Timer]
OnBootSec=5min
OnUnitActiveSec=60min
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
EOF

  local units="oci-keepalive-cpu.service oci-keepalive-net.timer"

  if [ "$ARCH" = "aarch64" ]; then
    command -v python3 >/dev/null || { echo "需要 python3：apt install -y python3 或 dnf install -y python3"; exit 1; }
    write_mem_worker
    local total_mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
    local cap_mb=$(( total_mb * (MEM_TARGET + 5) / 100 ))
    # 内存上限：cgroup v2 用 MemoryMax（并禁止它的内存进 swap，保证计入真实已用），
    # cgroup v1（如 Oracle Linux 8 默认）只认 MemoryLimit
    local mem_limit
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
      mem_limit="MemoryMax=${cap_mb}M
MemorySwapMax=0"
    else
      mem_limit="MemoryLimit=${cap_mb}M"
    fi
    cat > "$UNIT_DIR/oci-keepalive-mem.service" <<EOF
[Unit]
Description=OCI Always Free keepalive (memory ~${MEM_TARGET}%)
After=network.target

[Service]
Type=simple
Environment=MEM_TARGET=${MEM_TARGET}
ExecStart=/usr/bin/env python3 ${LIB_DIR}/mem.py
${mem_limit}
OOMScoreAdjust=1000
CPUSchedulingPolicy=idle
Nice=19
${HARDEN}
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    units="$units oci-keepalive-mem.service"
  else
    # 从 ARM 换到 AMD 等情况：清掉不需要的内存服务
    systemctl disable --now oci-keepalive-mem.service 2>/dev/null || true
    rm -f "$UNIT_DIR/oci-keepalive-mem.service" "$LIB_DIR/mem.py"
  fi

  systemctl daemon-reload
  # restart 而不是只 start：重复 install 时让新配置立即生效
  systemctl enable $units
  systemctl restart $units
  echo "已安装：$units  （架构 $ARCH，vCPU $NCPU，CPU 目标 ${CPU_TARGET}%$( [ "$ARCH" = aarch64 ] && echo "，内存目标 ${MEM_TARGET}%")）"
  check_agent
}

check_agent() {
  # 只做提示，不影响安装和运行。
  # OCI 控制台里的 CPU/内存指标（oci_computeagent）由 Oracle Cloud Agent 上报；
  # 没有 Agent（例如自己重装的系统）时，Oracle 能直接看到的只有 VNIC 网络流量（oci_vcn）。
  # 先存进变量再匹配：避免 pipefail 下 grep -q 提前退出导致 SIGPIPE 误判
  local units_list
  units_list="$(systemctl list-units --type=service --state=active --no-legend 2>/dev/null || true)"
  if systemctl is-active --quiet oracle-cloud-agent 2>/dev/null \
     || [[ "$units_list" == *snap.oracle-cloud-agent* ]]; then
    echo "Oracle Cloud Agent：运行中（控制台可看到 CPU/内存指标）"
  else
    echo "Oracle Cloud Agent：未安装（不影响本脚本运行）"
    echo "  注意：控制台不会有 CPU/内存指标，只有网络流量指标；Oracle 在没有 CPU 数据时如何判定闲置，官方未说明。"
  fi
}

status() {
  systemctl --no-pager --lines=0 status oci-keepalive-cpu.service 2>/dev/null || echo "CPU 保活未安装或未运行"
  if [ "$ARCH" = "aarch64" ]; then
    systemctl --no-pager --lines=0 status oci-keepalive-mem.service 2>/dev/null || echo "内存保活未安装或未运行"
  fi
  # 核数变了（改过机型）但没重装，配额就不对了
  if grep -q "of ${NCPU} vCPU" "$UNIT_DIR/oci-keepalive-cpu.service" 2>/dev/null; then :; \
  elif [ -f "$UNIT_DIR/oci-keepalive-cpu.service" ]; then
    echo "⚠ vCPU 数已变为 ${NCPU}，CPU 配额是旧的，请重新执行 install"
  fi
  echo "---- 当前占用（取 5 秒平均）----"
  read -r _ a b c d e f g _ < /proc/stat; t1=$((a+b+c+d+e+f+g)); i1=$((d+e))
  sleep 5
  read -r _ a b c d e f g _ < /proc/stat; t2=$((a+b+c+d+e+f+g)); i2=$((d+e))
  echo "CPU：$(( 100 * ( (t2-t1) - (i2-i1) ) / (t2-t1) ))%"
  awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "内存：%d%%（%d / %d MB）\n",(t-a)*100/t,(t-a)/1024,t/1024}' /proc/meminfo
  echo "---- 网络保活 ----"
  if systemctl is-enabled --quiet oci-keepalive-net.timer 2>/dev/null; then
    local timers; timers="$(systemctl list-timers --all --no-pager oci-keepalive-net.timer 2>/dev/null || true)"
    printf '%s\n' "$timers" | sed -n '1,2p'
    echo "最近 3 次结果："
    # 多取一些日志再过滤，避免连续 FAIL 和 systemd 自身日志把 OK 挤掉
    local logs; logs="$(journalctl -u oci-keepalive-net.service --no-pager -o short -n 500 2>/dev/null || true)"
    printf '%s\n' "$logs" | grep -E 'OK |FAIL |WARN ' | tail -n 3 || echo "（还没有运行记录）"
  else
    echo "网络保活未安装"
  fi
  check_agent
}

uninstall() {
  need_root
  systemctl disable --now oci-keepalive-cpu.service oci-keepalive-mem.service oci-keepalive-net.timer 2>/dev/null || true
  rm -f "$UNIT_DIR"/oci-keepalive-{cpu,mem,net}.service "$UNIT_DIR/oci-keepalive-net.timer"
  rm -rf "$LIB_DIR"
  systemctl daemon-reload
  if [ -f "$CONF" ]; then
    echo "已卸载服务。配置文件 $CONF 已保留（你可能改过下载源），不需要的话手动删除：rm -f $CONF $CONF.new"
  else
    echo "已卸载"
  fi
}

case "${1:-}" in
  install)   install ;;
  status)    status ;;
  uninstall) uninstall ;;
  *) echo "用法：sudo bash $0 install|status|uninstall"; exit 1 ;;
esac
