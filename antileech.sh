#!/usr/bin/env bash
#
# aria2 anti-leech
# 轮询 aria2.getPeers，按 peerId 前缀识别迅雷 / QQ旋风 等客户端，
# 把对应 IP 加入 ipset 临时封禁（默认 1 小时自动过期）。
#
# 依赖: curl jq ipset iptables
# 说明: aria2 没有 ban peer 的 RPC，只能识别后从系统层封 IP。
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
#   BLOCK_OUTPUT    1=同时阻断出站，默认 0（只阻断入站）
#   LEECH_PREFIXES  要封的 peerId 前缀，默认 "-XL -SD -QD -TX -QQ"
#
set -u

ARIA2_CONF="${ARIA2_CONF:-/root/.aria2c/aria2.conf}"
IPSET_NAME="${IPSET_NAME:-aria2_leech}"
BLOCK_TIMEOUT="${BLOCK_TIMEOUT:-3600}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
BLOCK_MODE="${BLOCK_MODE:-ip}"
EXCLUDE_IPS="${EXCLUDE_IPS:-}"
BLOCK_SEEDERS="${BLOCK_SEEDERS:-0}"
BLOCK_OUTPUT="${BLOCK_OUTPUT:-0}"
# 规则插入的链：裸机用 INPUT；aria2 在 Docker 里用 DOCKER-USER（需 host 网络或端口映射）
IPT_CHAIN="${IPT_CHAIN:-INPUT}"
LEECH_PREFIXES="${LEECH_PREFIXES:--XL -SD -QD -TX -QQ}"
RPC_TIMEOUT="${RPC_TIMEOUT:-5}"
# 1=只打印“本应封禁”的目标，不创建 ipset / 不写 iptables，用于验证匹配逻辑
DRY_RUN="${DRY_RUN:-0}"
declare -A DRY_SEEN=()

log() { echo "$(date '+%F %T') $*"; }
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

log "started: set=${IPSET_NAME} type=${set_type} mode=${BLOCK_MODE} timeout=${BLOCK_TIMEOUT}s poll=${POLL_INTERVAL}s prefixes='${LEECH_PREFIXES}'"
[[ -n ${EXCLUDE_IPS} ]] && log "exclude: ${EXCLUDE_IPS}"

rpc_call() {
    curl -s --max-time "${RPC_TIMEOUT}" -H 'Content-Type: application/json' -d "$1" \
        "http://127.0.0.1:${rpc_port}/jsonrpc"
}

tell_active() {
    local payload
    payload=$(jq -cn --arg s "token:${rpc_secret}" \
        '{jsonrpc:"2.0",id:"antileech",method:"aria2.tellActive",params:[$s]}')
    rpc_call "${payload}" | jq -r '.result[]?.gid // empty' 2>/dev/null
}

get_peers() {
    local gid=$1 payload
    payload=$(jq -cn --arg s "token:${rpc_secret}" --arg g "${gid}" \
        '{jsonrpc:"2.0",id:"antileech",method:"aria2.getPeers",params:[$s,$g]}')
    rpc_call "${payload}" |
        jq -r '.result[]? | [.peerId, .ip, (.port|tostring), (.seeder|tostring), (.uploadSpeed|tostring)] | @tsv' 2>/dev/null
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

while true; do
    mapfile -t gids < <(tell_active)
    for gid in "${gids[@]}"; do
        while IFS=$'\t' read -r pid ip port seeder up; do
            [[ -z ${pid:-} || -z ${ip:-} ]] && continue
            pid_lc=${pid,,}
            matched=""
            for p in ${LEECH_PREFIXES}; do
                if [[ ${pid_lc} == "${p,,}"* ]]; then matched=${p}; break; fi
            done
            [[ -z ${matched} ]] && continue
            # 默认放行做种者：迅雷偶尔也会上传，做种的对我们有利
            [[ ${BLOCK_SEEDERS} == 0 && ${seeder} == "true" ]] && continue
            block_peer "${ip}" "${port}" "peerId=${pid:0:8}"
        done < <(get_peers "${gid}")
    done
    # 放到后台再 wait：收到 TERM 时能立即打断 sleep 执行清理，
    # 否则要等 sleep 跑完（最多 POLL_INTERVAL 秒）才处理信号。
    sleep "${POLL_INTERVAL}" &
    wait $!
done
