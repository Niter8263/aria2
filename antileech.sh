#!/usr/bin/env bash
#
# aria2 anti-leech
# 轮询 aria2.getPeers，按 peerId 前缀识别迅雷 / QQ旋风 等客户端，
# 把对应 IP 加入 ipset 临时封禁（默认 1 小时自动过期）。
#
# 依赖: curl jq ipset iptables
# 说明: aria2 没有 ban peer 的 RPC，只能识别后从系统层封 IP。
#       封的是 IP 不是客户端，共享 IP 可能误伤，请自行评估。
#
# 可用环境变量:
#   ARIA2_CONF      aria2 配置文件，默认 /root/.aria2c/aria2.conf
#   IPSET_NAME      ipset 集合名，默认 aria2_leech
#   BLOCK_TIMEOUT   封禁秒数，默认 3600
#   POLL_INTERVAL   轮询间隔秒数，默认 10
#   BLOCK_SEEDERS   1=连做种者一起封（不推荐），默认 0
#   BLOCK_OUTPUT    1=同时阻断出站，默认 0（只阻断入站）
#   LEECH_PREFIXES  要封的 peerId 前缀，默认 "-XL -SD -QD -TX -QQ"
#
set -u

ARIA2_CONF="${ARIA2_CONF:-/root/.aria2c/aria2.conf}"
IPSET_NAME="${IPSET_NAME:-aria2_leech}"
BLOCK_TIMEOUT="${BLOCK_TIMEOUT:-3600}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
BLOCK_SEEDERS="${BLOCK_SEEDERS:-0}"
BLOCK_OUTPUT="${BLOCK_OUTPUT:-0}"
# 规则插入的链：裸机用 INPUT；aria2 在 Docker 里用 DOCKER-USER（需 host 网络或端口映射）
IPT_CHAIN="${IPT_CHAIN:-INPUT}"
LEECH_PREFIXES="${LEECH_PREFIXES:--XL -SD -QD -TX -QQ}"
RPC_TIMEOUT="${RPC_TIMEOUT:-5}"
# 1=只打印“本应封禁”的 IP，不创建 ipset / 不写 iptables，用于验证匹配逻辑
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

cleanup() {
    [[ ${DRY_RUN} == 1 ]] && return 0
    iptables -D "${IPT_CHAIN}" -m set --match-set "${IPSET_NAME}" src -j DROP 2>/dev/null
    if [[ ${BLOCK_OUTPUT} == 1 ]]; then
        iptables -D OUTPUT -m set --match-set "${IPSET_NAME}" dst -j DROP 2>/dev/null
    fi
    ipset destroy "${IPSET_NAME}" 2>/dev/null
}
trap cleanup EXIT
# 收到 TERM/INT 时先清理再退出；只写 trap cleanup 会把信号吞掉，进程继续跑
trap 'cleanup; exit 0' INT TERM

if [[ ${DRY_RUN} == 1 ]]; then
    log "DRY_RUN=1: 只打印匹配结果，不创建 ipset / 不写 iptables"
else
    # hash:ip 带 timeout，加入集合的 IP 到期自动移除
    ipset create "${IPSET_NAME}" hash:ip timeout "${BLOCK_TIMEOUT}" -exist 2>/dev/null ||
        die "创建 ipset 失败（内核未加载 ip_set？）"

    if ! iptables -C "${IPT_CHAIN}" -m set --match-set "${IPSET_NAME}" src -j DROP 2>/dev/null; then
        iptables -I "${IPT_CHAIN}" 1 -m set --match-set "${IPSET_NAME}" src -j DROP ||
            die "写入 iptables 规则失败"
    fi
    if [[ ${BLOCK_OUTPUT} == 1 ]]; then
        if ! iptables -C OUTPUT -m set --match-set "${IPSET_NAME}" dst -j DROP 2>/dev/null; then
            iptables -I OUTPUT 1 -m set --match-set "${IPSET_NAME}" dst -j DROP 2>/dev/null
        fi
    fi
fi

log "started: set=${IPSET_NAME} timeout=${BLOCK_TIMEOUT}s poll=${POLL_INTERVAL}s prefixes='${LEECH_PREFIXES}'"

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
        jq -r '.result[]? | [.peerId, .ip, (.seeder|tostring), (.uploadSpeed|tostring)] | @tsv' 2>/dev/null
}

block_ip() {
    local ip=$1 reason=$2
    # 只处理 IPv4；IPv6 需要单独的 inet6 集合，这里不做
    [[ ${ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 0
    if [[ ${DRY_RUN} == 1 ]]; then
        [[ -n ${DRY_SEEN[${ip}]:-} ]] && return 0
        DRY_SEEN[${ip}]=1
        log "would block ${ip} (${reason})"
        return 0
    fi
    ipset test "${IPSET_NAME}" "${ip}" >/dev/null 2>&1 && return 0
    if ipset add "${IPSET_NAME}" "${ip}" timeout "${BLOCK_TIMEOUT}" -exist 2>/dev/null; then
        log "block ${ip} (${reason}) ${BLOCK_TIMEOUT}s"
    fi
}

while true; do
    mapfile -t gids < <(tell_active)
    for gid in "${gids[@]}"; do
        while IFS=$'\t' read -r pid ip seeder up; do
            [[ -z ${pid:-} || -z ${ip:-} ]] && continue
            pid_lc=${pid,,}
            matched=""
            for p in ${LEECH_PREFIXES}; do
                if [[ ${pid_lc} == "${p,,}"* ]]; then matched=${p}; break; fi
            done
            [[ -z ${matched} ]] && continue
            # 默认放行做种者：迅雷偶尔也会上传，做种的对我们有利
            [[ ${BLOCK_SEEDERS} == 0 && ${seeder} == "true" ]] && continue
            block_ip "${ip}" "peerId=${pid:0:8}"
        done < <(get_peers "${gid}")
    done
    # 放到后台再 wait：收到 TERM 时能立即打断 sleep 执行清理，
    # 否则要等 sleep 跑完（最多 POLL_INTERVAL 秒）才处理信号。
    sleep "${POLL_INTERVAL}" &
    wait $!
done
