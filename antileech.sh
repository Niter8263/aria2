#!/usr/bin/env bash
#
# aria2 anti-leech
# 轮询 aria2.getPeers，按 peerId 前缀识别迅雷 / QQ旋风 等客户端，
# 把对应 IP 加入 ipset 临时封禁（默认 1 小时自动过期）。
#
# 依赖: curl jq ipset iptables
# 说明: aria2 没有 ban peer 的 RPC，只能识别后从系统层封 IP。
#       注意 aria2.getPeers 返回的 peerId 是百分号编码的（%2DXL0300 => -XL0300），
#       脚本会先解码再比对前缀，否则永远匹配不上。
#
# 关于封禁粒度（BLOCK_MODE）：
#   ip      按来源 IP 整段拦截。只有能看到真实对端 IP 时才有意义。
#   ipport  按来源 IP + 源端口拦截，只断掉那一 条 peer 连接。
#           适用于对端源地址被网关 / NAT / 端口转发改写过的环境：
#           此时所有 peer 都显示成同一个地址，按 IP 封会把正常 peer 一起打死。
#           注意：源端口是 NAT 会话的映射端口，对方重连会换端口，只能止损。
#           想根治需要让端口转发保留真实源 IP（只做 DNAT，不要叠加 SNAT/MASQUERADE）。
#
# 可用环境变量:
#   ARIA2_CONF      aria2 配置文件，默认 /root/.aria2c/aria2.conf
#   IPSET_NAME      ipset 集合名，默认 aria2_leech
#   BLOCK_TIMEOUT   封禁秒数，默认 3600
#   POLL_INTERVAL   轮询间隔秒数，默认 10
#   BLOCK_MODE      封禁粒度 ip / ipport，默认 ip
#   EXCLUDE_IPS     永不封禁的地址，逗号或空格分隔，默认空
#                   源地址被改写的环境建议把网关填进来，避免误封后失去远程访问
#   BLOCK_SEEDERS   1=连做种者一起封（不推荐），默认 0
#   MIN_DOWNLOAD_SPEED
#                   该 peer 给我方的下载速度 >= 此值（字节/秒）时不封，默认 1024
#                   迅雷等客户端经常同时在给我传数据，一刀切会把有用的源一起封掉。
#                   设 0 关闭该保护（只看 peerId 前缀，行为与旧版一致）
#   BLOCK_OUTPUT    1=同时阻断出站，默认 0（只阻断入站）
#   LEECH_PREFIXES  要封的 peerId 前缀，默认 "-XL -SD -QD -TX -QQ"
#
# 只下不上判定（RATIO_GUARD，默认关闭）：
#   不看客户端名，按"我方上传给它 / 它下载给我"的累计比例识别纯吸血。
#   只在我们确实还在下载的任务上评估；任务已完成（我们自己就是做种者）时跳过，
#   否则所有 peer 都会因为不需要回传而命中。
#   RATIO_WINDOW        观察窗口秒数，默认 600（10 分钟）
#   RATIO_MIN_UPLOAD    窗口内我方至少给它传了这么多字节才判定，默认 104857600（100MB）
#   RATIO_MIN_IN_PERCENT 它给我的不足我给它的百分之几就判为吸血，默认 5
#   注意：多个 peer 共用一个出口 IP（CGNAT/机房）时状态会合并计算，
#   与 iptables 按 IP 封禁的粒度一致，但可能连带影响同出口的正常 peer。
#
set -u

ARIA2_CONF="${ARIA2_CONF:-/root/.aria2c/aria2.conf}"
IPSET_NAME="${IPSET_NAME:-aria2_leech}"
BLOCK_TIMEOUT="${BLOCK_TIMEOUT:-3600}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
BLOCK_MODE="${BLOCK_MODE:-ip}"
EXCLUDE_IPS="${EXCLUDE_IPS:-}"
BLOCK_SEEDERS="${BLOCK_SEEDERS:-0}"
# peer 正在给我方传数据时（下载速度达到该值）不封，0 表示不启用该保护
MIN_DOWNLOAD_SPEED="${MIN_DOWNLOAD_SPEED:-1024}"
BLOCK_OUTPUT="${BLOCK_OUTPUT:-0}"
# 规则插入的链：裸机用 INPUT；aria2 在 Docker 里用 DOCKER-USER（需 host 网络或端口映射）
IPT_CHAIN="${IPT_CHAIN:-INPUT}"
LEECH_PREFIXES="${LEECH_PREFIXES:--XL -SD -QD -TX -QQ}"
# 只下不上判定：0=关闭，1=启用
RATIO_GUARD="${RATIO_GUARD:-0}"
RATIO_WINDOW="${RATIO_WINDOW:-600}"
RATIO_MIN_UPLOAD="${RATIO_MIN_UPLOAD:-104857600}"
RATIO_MIN_IN_PERCENT="${RATIO_MIN_IN_PERCENT:-5}"
RPC_TIMEOUT="${RPC_TIMEOUT:-5}"
# 1=只打印“本应封禁”的目标，不创建 ipset / 不写 iptables，用于验证匹配逻辑
DRY_RUN="${DRY_RUN:-0}"
declare -A DRY_SEEN=()
declare -A SKIP_SEEN=()

# 日志一律写 stderr：tell_active 的 stdout 会被 mapfile 当 gid 列表读走，
# 若告警写 stdout 会被当成 gid 吞掉。
log() { echo "$(date '+%F %T') $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

if [[ ${DRY_RUN} == 1 ]]; then
    for c in curl jq; do
        command -v "$c" >/dev/null 2>&1 || die "缺少依赖: $c"
    done
else
    for c in curl jq ipset iptables; do
        command -v "$c" >/dev/null 2>&1 || die "缺少依赖: $c"
    done
fi
[[ -r ${ARIA2_CONF} ]] || die "读不到配置文件: ${ARIA2_CONF}"

rpc_port=$(grep -E '^rpc-listen-port=' "${ARIA2_CONF}" 2>/dev/null | tail -1 | cut -d= -f2-)
rpc_secret=$(grep -E '^rpc-secret=' "${ARIA2_CONF}" 2>/dev/null | tail -1 | cut -d= -f2-)
rpc_port="${rpc_port:-6800}"

# 按封禁粒度决定 ipset 类型和 iptables 的匹配维度
if [[ ${BLOCK_MODE} == "ipport" ]]; then
    set_type="hash:ip,port"
    match_in="src,src"
    match_out="dst,dst"
else
    BLOCK_MODE="ip"
    set_type="hash:ip"
    match_in="src"
    match_out="dst"
fi

# 是否在排除名单里（逗号或空格分隔）
is_excluded() {
    local ip=$1 n
    [[ -z ${EXCLUDE_IPS//[[:space:]]/} ]] && return 1
    for n in ${EXCLUDE_IPS//,/ }; do
        [[ ${ip} == "${n}" ]] && return 0
    done
    return 1
}

cleanup() {
    [[ ${DRY_RUN} == 1 ]] && return 0
    # 两种匹配维度都删一次，避免切换 BLOCK_MODE 后残留旧规则
    iptables -D "${IPT_CHAIN}" -m set --match-set "${IPSET_NAME}" src -j DROP 2>/dev/null
    iptables -D "${IPT_CHAIN}" -m set --match-set "${IPSET_NAME}" src,src -j DROP 2>/dev/null
    if [[ ${BLOCK_OUTPUT} == 1 ]]; then
        iptables -D OUTPUT -m set --match-set "${IPSET_NAME}" dst -j DROP 2>/dev/null
        iptables -D OUTPUT -m set --match-set "${IPSET_NAME}" dst,dst -j DROP 2>/dev/null
    fi
    ipset destroy "${IPSET_NAME}" 2>/dev/null
}
trap cleanup EXIT
# 收到 TERM/INT 时先清理再退出；只写 trap cleanup 会把信号吞掉，进程继续跑
trap 'cleanup; exit 0' INT TERM

if [[ ${DRY_RUN} == 1 ]]; then
    log "DRY_RUN=1: 只打印匹配结果，不创建 ipset / 不写 iptables"
else
    # 切换粒度时旧的集合类型不兼容，必须先删规则再销毁重建
    iptables -D "${IPT_CHAIN}" -m set --match-set "${IPSET_NAME}" src -j DROP 2>/dev/null
    iptables -D "${IPT_CHAIN}" -m set --match-set "${IPSET_NAME}" src,src -j DROP 2>/dev/null
    if ipset list -n 2>/dev/null | grep -qxF "${IPSET_NAME}"; then
        cur_type=$(ipset list "${IPSET_NAME}" 2>/dev/null | awk '/^Type:/{print $2; exit}')
        [[ -n ${cur_type} && ${cur_type} != "${set_type}" ]] && ipset destroy "${IPSET_NAME}" 2>/dev/null
    fi
    # timeout 写在 create 上，加入集合的条目到期自动移除
    ipset create "${IPSET_NAME}" "${set_type}" timeout "${BLOCK_TIMEOUT}" -exist 2>/dev/null ||
        die "创建 ipset 失败（内核未加载 ip_set？）"

    if ! iptables -C "${IPT_CHAIN}" -m set --match-set "${IPSET_NAME}" "${match_in}" -j DROP 2>/dev/null; then
        iptables -I "${IPT_CHAIN}" 1 -m set --match-set "${IPSET_NAME}" "${match_in}" -j DROP ||
            die "写入 iptables 规则失败"
    fi
    if [[ ${BLOCK_OUTPUT} == 1 ]]; then
        if ! iptables -C OUTPUT -m set --match-set "${IPSET_NAME}" "${match_out}" -j DROP 2>/dev/null; then
            iptables -I OUTPUT 1 -m set --match-set "${IPSET_NAME}" "${match_out}" -j DROP 2>/dev/null
        fi
    fi
fi

log "started: set=${IPSET_NAME} type=${set_type} mode=${BLOCK_MODE} timeout=${BLOCK_TIMEOUT}s poll=${POLL_INTERVAL}s min-dl=${MIN_DOWNLOAD_SPEED}B/s prefixes='${LEECH_PREFIXES}'"
[[ -n ${EXCLUDE_IPS} ]] && log "exclude: ${EXCLUDE_IPS}"

rpc_call() {
    curl -s --max-time "${RPC_TIMEOUT}" -H 'Content-Type: application/json' -d "$1" \
        "http://127.0.0.1:${rpc_port}/jsonrpc"
}

# aria2.getPeers 返回的 peerId 是百分号编码的（例如 %2DXL0300... 实际是 -XL0300...）。
# 不解码直接拿编码后的串比前缀，永远匹配不上，防吸血会静默失效。
url_decode() {
    local s=$1 hex out=""
    while [[ ${s} == *%* ]]; do
        out+="${s%%\%*}"
        s="${s#*%}"
        hex="${s:0:2}"
        if [[ ${hex} =~ ^[0-9A-Fa-f]{2}$ ]]; then
            out+="$(printf "\\x${hex}")"
            s="${s:2}"
        else
            out+="%"
        fi
    done
    printf '%s' "${out}${s}"
}

# 同类告警只打一次，避免 RPC 故障时每 10 秒刷屏
last_rpc_err=""
log_once() {
    [[ $1 == "${last_rpc_err}" ]] && return 0
    last_rpc_err=$1
    log "WARN: $1"
}

ACTIVE_GIDS=()
declare -A ACTIVE_DOWNLOADING=()

# 取当前活动任务的 gid 列表，结果放进全局数组 ACTIVE_GIDS；
# 同时把"仍未下载完成"的任务记到 ACTIVE_DOWNLOADING，供只下不上判定使用。
# 不能写成 mapfile < <(tell_active)：进程替换会开子 shell，
# 告警去重用的 last_rpc_err 在子 shell 里改了带不回主循环，会每轮重复刷屏。
scan_active() {
    local payload raw err
    payload=$(jq -cn --arg s "token:${rpc_secret}" \
        '{jsonrpc:"2.0",id:"antileech",method:"aria2.tellActive",params:[$s]}')
    raw=$(rpc_call "${payload}")
    ACTIVE_GIDS=()
    ACTIVE_DOWNLOADING=()
    if [[ -z ${raw} ]]; then
        log_once "RPC 无响应（port=${rpc_port}），检查 aria2 是否运行、rpc-listen-port 是否正确"
        return 1
    fi
    err=$(printf '%s' "${raw}" | jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n ${err} ]]; then
        log_once "RPC 返回错误: ${err}（检查 rpc-secret 是否与 aria2.conf 一致）"
        return 1
    fi
    last_rpc_err=""
    local line
    mapfile -t ACTIVE_GIDS < <(printf '%s' "${raw}" | jq -r '.result[]?.gid // empty' 2>/dev/null)
    while IFS= read -r line; do
        [[ -n ${line} ]] && ACTIVE_DOWNLOADING[${line}]=1
    done < <(printf '%s' "${raw}" | jq -r '
        .result[]?
        | select(((.totalLength|tonumber) > 0) and ((.completedLength|tonumber) < (.totalLength|tonumber)))
        | .gid' 2>/dev/null)
    return 0
}

get_peers() {
    local gid=$1 payload
    payload=$(jq -cn --arg s "token:${rpc_secret}" --arg g "${gid}" \
        '{jsonrpc:"2.0",id:"antileech",method:"aria2.getPeers",params:[$s,$g]}')
    rpc_call "${payload}" |
        jq -r '.result[]? | [.peerId, .ip, (.port|tostring), (.seeder|tostring), (.uploadSpeed|tostring), (.downloadSpeed|tostring)] | @tsv' 2>/dev/null
}

# 生成 ipset 条目 key：ip 模式用 IP，ipport 模式用 "IP,tcp:PORT"
peer_key() {
    local ip=$1 port=$2
    if [[ ${BLOCK_MODE} == "ipport" ]]; then
        [[ ${port} =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || return 1
        printf '%s,tcp:%s' "${ip}" "${port}"
    else
        printf '%s' "${ip}"
    fi
}

block_peer() {
    local ip=$1 port=${2:-} reason=$3 key
    # 只处理 IPv4；IPv6 需要单独的 inet6 集合，这里不做
    [[ ${ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 0
    # 排除名单优先：网关 / NAT 出口被写进来时绝不封禁
    is_excluded "${ip}" && return 0
    key=$(peer_key "${ip}" "${port}") || return 0

    if [[ ${DRY_RUN} == 1 ]]; then
        [[ -n ${DRY_SEEN[${key}]:-} ]] && return 0
        DRY_SEEN[${key}]=1
        log "would block ${key} (${reason})"
        return 0
    fi
    ipset test "${IPSET_NAME}" "${key}" >/dev/null 2>&1 && return 0
    if ipset add "${IPSET_NAME}" "${key}" timeout "${BLOCK_TIMEOUT}" -exist 2>/dev/null; then
        log "block ${key} (${reason}) ${BLOCK_TIMEOUT}s"
    fi
}

# ==================== 只下不上判定 ====================
# getPeers 只提供瞬时速度，没有累计字节数，只能按轮询间隔把速度积分成流量。
# 状态按出口 IP 聚合：多个 peer 共用同一 IP（CGNAT/机房）时合并统计，
# 与 iptables 按 IP 封禁的粒度一致。
declare -A RG_IN=() RG_OUT=() RG_FIRST=() RG_LAST=() RG_PORT=()

RG_RESET() {
    unset "RG_IN[$1]" "RG_OUT[$1]" "RG_FIRST[$1]" "RG_LAST[$1]" "RG_PORT[$1]"
}

ratio_accum() {
    local ip=$1 port=$2 down=$3 up=$4 now=$5
    [[ ${ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 0
    [[ ${down} =~ ^[0-9]+$ ]] || down=0
    [[ ${up} =~ ^[0-9]+$ ]] || up=0
    [[ -z ${RG_FIRST[${ip}]:-} ]] && RG_FIRST[${ip}]=${now}
    RG_LAST[${ip}]=${now}
    [[ ${port} =~ ^[0-9]+$ ]] && RG_PORT[${ip}]=${port}
    RG_IN[${ip}]=$(( ${RG_IN[${ip}]:-0} + down * POLL_INTERVAL ))
    RG_OUT[${ip}]=$(( ${RG_OUT[${ip}]:-0} + up * POLL_INTERVAL ))
}

# 窗口到期且我方累计上传量达标时，按比例判定；返回 0 表示已封禁
ratio_eval() {
    local ip=$1 now=$2 first in out
    first=${RG_FIRST[${ip}]:-}
    [[ -z ${first} ]] && return 1
    (( now - first >= RATIO_WINDOW )) || return 1
    out=${RG_OUT[${ip}]:-0}
    # 传得太少不足以说明问题，继续累计，不判定
    (( out >= RATIO_MIN_UPLOAD )) || return 1
    in=${RG_IN[${ip}]:-0}
    if (( in * 100 < out * RATIO_MIN_IN_PERCENT )); then
        block_peer "${ip}" "${RG_PORT[${ip}]:-}" "ratio in=${in} out=${out} ${RATIO_WINDOW}s"
        RG_RESET "${ip}"
        return 0
    fi
    # 比例健康：结束本窗口重新累计，便于发现后转吸血的 peer
    RG_RESET "${ip}"
    return 1
}

# 清理长时间没出现的 peer，避免状态表无限增长
ratio_gc() {
    local ip now=$1
    for ip in "${!RG_LAST[@]}"; do
        (( now - RG_LAST[${ip}] > RATIO_WINDOW * 2 )) && RG_RESET "${ip}"
    done
}

while true; do
    scan_active
    now=$(date +%s)
    for gid in "${ACTIVE_GIDS[@]}"; do
        downloading=${ACTIVE_DOWNLOADING[${gid}]:-0}
        while IFS=$'\t' read -r pid ip port seeder up down; do
            [[ -z ${ip:-} ]] && continue
            # 只下不上判定：只在本任务还没下完时评估。
            # 自己已完成（做种中）时所有 peer 都不会回传，评估会把整个 swarm 封掉。
            if [[ ${RATIO_GUARD} == 1 && ${downloading} == 1 ]]; then
                ratio_accum "${ip}" "${port}" "${down:-0}" "${up:-0}" "${now}"
                ratio_eval "${ip}" "${now}" && continue
            fi
            [[ -z ${pid:-} ]] && continue
            pid_dec=$(url_decode "${pid}")
            pid_lc=${pid_dec,,}
            matched=""
            for p in ${LEECH_PREFIXES}; do
                if [[ ${pid_lc} == "${p,,}"* ]]; then matched=${p}; break; fi
            done
            [[ -z ${matched} ]] && continue
            # 默认放行做种者：迅雷偶尔也会上传，做种的对我们有利
            [[ ${BLOCK_SEEDERS} == 0 && ${seeder} == "true" ]] && continue
            # 正在给我方传数据的 peer 放行：它此刻是有用的源，不是纯吸血。
            # 迅雷常一边大量下载一边回传，只按 peerId 一刀切会误伤。
            if [[ ${MIN_DOWNLOAD_SPEED} =~ ^[0-9]+$ ]] && ((MIN_DOWNLOAD_SPEED > 0)) &&
                [[ ${down:-0} =~ ^[0-9]+$ ]] && ((down >= MIN_DOWNLOAD_SPEED)); then
                if [[ ${DRY_RUN} == 1 && -z ${SKIP_SEEN[${ip}:${port}]:-} ]]; then
                    SKIP_SEEN["${ip}:${port}"]=1
                    log "skip ${ip}:${port} (peerId=${pid_dec:0:8}) 对方回传 ${down} B/s"
                fi
                continue
            fi
            block_peer "${ip}" "${port}" "peerId=${pid_dec:0:8}"
        done < <(get_peers "${gid}")
    done
    [[ ${RATIO_GUARD} == 1 ]] && ratio_gc "${now}"
    # 放到后台再 wait：收到 TERM 时能立即打断 sleep 执行清理，
    # 否则要等 sleep 跑完（最多 POLL_INTERVAL 秒）才处理信号。
    sleep "${POLL_INTERVAL}" &
    wait $!
done
