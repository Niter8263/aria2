#!/usr/bin/env bash
#
# Copyright (c) 2017 Toyo
# Copyright (c) 2018-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/aria2.sh
# Description: Aria2 One-click installation management script
# System Required: CentOS/Debian/Ubuntu
# Version: 2.7.4
#

sh_ver="2.7.4"
export PATH=~/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin
aria2_conf_dir="/root/.aria2c"
download_path="/root/downloads"
aria2_conf="${aria2_conf_dir}/aria2.conf"
aria2_log="${aria2_conf_dir}/aria2.log"
aria2c="/usr/local/bin/aria2c"
Crontab_file="/usr/bin/crontab"
# RPC 端口允许的来源网段。
# Aria2 的 RPC 接口若暴露在公网且密钥泄漏，任何人都能添加任务、读写下载目录。
# 默认仅放行内网网段，如需从公网访问请把来源改为你的固定 IP，并考虑套 Nginx 反代 + HTTPS。
rpc_allow_source="192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 127.0.0.1/8"

# ==================== GitHub 代理设置 ====================
# 公共 GitHub 代理会不定期失效，因此这里配置成“可改 + 自动多线路回退”。
# 优先级：你配置的代理 → 备用代理列表 → 直连 GitHub。
# 需要更换时请使用菜单 14「设置 GitHub 代理」，不要直接改这里的值（改脚本可能不生效）。
# 默认选 gh-proxy.com：实测下载二进制比 ghproxy.net 快约 6 倍，且支持 api.github.com（可查版本号）。
gh_proxy="https://gh-proxy.com/"
# 备用代理，脚本会按顺序依次尝试。留空表示只用上面配置的代理和直连。
gh_proxy_fallback="https://ghfast.top/ https://ghproxy.net/"
# 已知限制：ghproxy.net 不代理 api.github.com，因此版本查询会自动跳过它；
#          jsDelivr 只能取仓库文件，取不到 releases 里的二进制，故不用于二进制下载。
# 项目仓库（所有文件与发布都从这里获取）
gh_repo="Niter8263/aria2"
gh_branch="main"
gh_api_mirror="https://gh-api.p3terx.com"
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Green_background_prefix="\033[42;37m"
Red_background_prefix="\033[41;37m"
Font_color_suffix="\033[0m"
Info="[${Green_font_prefix}信息${Font_color_suffix}]"
Error="[${Red_font_prefix}错误${Font_color_suffix}]"
Tip="[${Green_font_prefix}注意${Font_color_suffix}]"

check_root() {
    [[ $EUID != 0 ]] && echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。" && exit 1
}
#检查系统
check_sys() {
    # 优先读取 /etc/os-release：Ubuntu 24.04+ 的 /etc/issue 常为空，
    # 仅靠 /etc/issue 判断会漏判发行版，导致后续安装依赖走错分支。
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID}${ID_LIKE}" in
        *debian*|*ubuntu*) release="debian" ;;
        *centos*|*rhel*|*fedora*) release="centos" ;;
        esac
    fi
    if [[ -z ${release} ]]; then
        if [[ -f /etc/redhat-release ]]; then
            release="centos"
        elif cat /etc/issue 2>/dev/null | grep -q -E -i "debian"; then
            release="debian"
        elif cat /etc/issue 2>/dev/null | grep -q -E -i "ubuntu"; then
            release="ubuntu"
        elif cat /etc/issue 2>/dev/null | grep -q -E -i "centos|red hat|redhat"; then
            release="centos"
        elif cat /proc/version | grep -q -E -i "debian|ubuntu"; then
            release="debian"
        elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
            release="centos"
        fi
    fi
    [[ -z ${release} ]] && echo -e "${Error} 无法识别当前系统发行版，请手动检查 !" && exit 1
    ARCH=$(uname -m)
    [ $(command -v dpkg) ] && dpkgARCH=$(dpkg --print-architecture | awk -F- '{ print $NF }')
}
check_installed_status() {
    [[ ! -e ${aria2c} ]] && echo -e "${Error} Aria2 没有安装，请检查 !" && exit 1
    [[ ! -e ${aria2_conf} ]] && echo -e "${Error} Aria2 配置文件不存在，请检查 !" && [[ $1 != "un" ]] && exit 1
}
check_crontab_installed_status() {
    if [[ ! -e ${Crontab_file} ]]; then
        echo -e "${Error} Crontab 没有安装，开始安装..."
        if [[ ${release} == "centos" ]]; then
            yum install crond -y
        else
            apt-get install cron -y
        fi
        if [[ ! -e ${Crontab_file} ]]; then
            echo -e "${Error} Crontab 安装失败，请检查！" && exit 1
        else
            echo -e "${Info} Crontab 安装成功！"
        fi
    fi
}
check_pid() {
    # 用 pgrep 精确匹配进程名，避免 ps -ef | grep 把路径中含 "aria2c" 的无关进程也算进来。
    # pgrep 不存在时回退到原来的匹配方式。
    if command -v pgrep >/dev/null 2>&1; then
        PID=$(pgrep -x aria2c 2>/dev/null)
    else
        PID=$(ps -ef | grep "[a]ria2c" | grep -v "aria2.sh" | grep -v "init.d" | grep -v "service" | awk '{print $2}')
    fi
}
check_new_ver() {
    # 版本号与下载地址必须来自同一个仓库：回退源若换成别的项目，
    # 会拿到它的版本号却去本仓库下载，必然 404。因此回退只换代理，不换仓库。
    # 注意：ghproxy.net 不代理 api.github.com（实测会返回错误页），
    # 因此 API 查询跳过它，只走“你配置的代理（若非 ghproxy 系）→ gh-proxy 系备用 → 直连”。
    local api="https://api.github.com/repos/${gh_repo}/releases/latest"
    local -a urls=()
    # 用户配置的代理：仅当它能代理 API（即不是 ghproxy.net 系）时才纳入
    if [[ -n ${gh_proxy} && ${gh_proxy} != *"ghproxy.net"* ]]; then
        urls+=("${gh_proxy}${api}")
    fi
    local p
    for p in ${gh_proxy_fallback}; do
        [[ ${p} == *"ghproxy.net"* ]] && continue
        urls+=("${p}${api}")
    done
    urls+=("${gh_api_mirror}/repos/${gh_repo}/releases/latest")
    urls+=("${api}")
    aria2_new_ver=""
    local u out
    for u in "${urls[@]}"; do
        echo -e "${Info} 获取最新版本号: ${u}"
        out=$(wget -t2 -T5 -qO- "${u}" 2>/dev/null) &&
            aria2_new_ver=$(echo "${out}" | grep -o '"tag_name": ".*"' | head -n 1 | cut -d'"' -f4)
        [[ -n ${aria2_new_ver} ]] && break
    done
    if [[ -z ${aria2_new_ver} ]]; then
        echo -e "${Error} Aria2 最新版本获取失败，请手动获取最新版本号[ https://github.com/${gh_repo}/releases ]"
        read -e -p "请输入版本号:" aria2_new_ver
        [[ -z "${aria2_new_ver}" ]] && echo "取消..." && exit 1
    fi
}
check_ver_comparison() {
    read -e -p "是否更新(会中断当前下载任务) ? [Y/n] :" yn
    [[ -z "${yn}" ]] && yn="y"
    if [[ $yn == [Yy] ]]; then
        check_pid
        [[ ! -z $PID ]] && kill -9 ${PID}
        check_sys
        Download_aria2 "update"
        Start_aria2
    fi
}
# ==================== 多线路下载 ====================
# 仓库内文件的原始地址（所有非 releases 文件都从这里取）
gh_raw_url() {
    echo "https://raw.githubusercontent.com/${gh_repo}/${gh_branch}/$1"
}
# 生成候选下载地址：你配置的代理 → 备用代理列表 → 直连。
# 公共代理随时可能失效，所以不写死单条线路，而是逐个尝试。
# 用法：mapfile -t urls < <(build_urls "https://raw.githubusercontent.com/...")
build_urls() {
    local raw=$1 p
    [[ -n ${gh_proxy} ]] && echo "${gh_proxy}${raw}"
    for p in ${gh_proxy_fallback}; do
        [[ ${p} == "${gh_proxy}" ]] && continue
        echo "${p}${raw}"
    done
    echo "${raw}"
}
# 下载到指定路径，依次尝试各线路。参数：<目标路径> <原始URL> [额外wget参数]
# 用于临时文件或全新目标；若目标是已存在的重要文件，请用 dl_install。
# 注意：不要给 wget 加 2>/dev/null —— 进度条是输出到 stderr 的，重定向掉就看不到任何下载反馈。
dl_fetch() {
    local dest=$1 raw=$2
    shift 2
    local -a urls=()
    mapfile -t urls < <(build_urls "${raw}")
    local u n=0 total=${#urls[@]}
    for u in "${urls[@]}"; do
        n=$((n + 1))
        echo -e "${Info} 下载（第 ${n}/${total} 条线路）: ${u}"
        # --connect-timeout 10：代理不通时快速失败，避免卡在连接阶段
        if wget -t2 -T15 --connect-timeout=10 "$@" -O "${dest}" "${u}"; then
            [[ -s ${dest} ]] && return 0
        fi
        [[ ${n} -lt ${total} ]] && echo -e "${Tip} 该线路失败，自动尝试下一条..."
    done
    return 1
}
# 下载并安装到目标路径，失败时保留原有文件不被破坏。
# 先下到临时文件、确认非空后再替换，避免 wget -O 失败时截断目标。
dl_install() {
    local dest=$1 raw=$2
    shift 2
    local tmp
    tmp="$(mktemp)" || return 1
    if dl_fetch "${tmp}" "${raw}" "$@" && [[ -s ${tmp} ]]; then
        mv -f "${tmp}" "${dest}"
        return 0
    fi
    rm -f "${tmp}"
    return 1
}
Download_aria2() {
    update_dl=$1
    if [[ $ARCH == i*86 || $dpkgARCH == i*86 ]]; then
        ARCH="i386"
    elif [[ $ARCH == "x86_64" || $dpkgARCH == "amd64" ]]; then
        ARCH="amd64"
    elif [[ $ARCH == "aarch64" || $dpkgARCH == "arm64" ]]; then
        ARCH="arm64"
    elif [[ $ARCH == "armv7l" || $dpkgARCH == "armhf" ]]; then
        ARCH="armhf"
    else
        echo -e "${Error} 不支持此 CPU 架构。"
        exit 1
    fi
    # 删除旧版二进制文件。逐个文件处理，避免 rm 失败时 which 仍有输出导致死循环。
    local old_aria2c
    while [[ -n $(command -v aria2c) ]]; do
        old_aria2c=$(command -v aria2c)
        echo -e "${Info} 删除旧版 Aria2 二进制文件：${old_aria2c} ..."
        if ! rm -vf "${old_aria2c}"; then
            echo -e "${Error} 无法删除 ${old_aria2c}，请手动处理后重试 !"
            exit 1
        fi
    done
    local bin_url="https://github.com/${gh_repo}/releases/download/${aria2_new_ver}/aria2-${aria2_new_ver%_*}-static-linux-${ARCH}.tar.gz"
    echo -e "${Info} 正在下载 Aria2 主程序（约 4.5MB，${ARCH} 架构），速度取决于所用代理..."
    # 先下到临时文件再解压：直接管道进 tar 时若下载失败，
    # tar 会拿到错误页并解出空文件，报错信息也会被掩盖。
    local tmp_tar
    tmp_tar="$(mktemp)" || exit 1
    if ! dl_fetch "${tmp_tar}" "${bin_url}"; then
        rm -f "${tmp_tar}"
        echo -e "${Error} Aria2 主程序下载失败（所有线路均不可用）!"
        echo -e "${Tip} 可用菜单 14「设置 GitHub 代理」更换代理后重试。"
        exit 1
    fi
    if ! tar -xzf "${tmp_tar}"; then
        rm -f "${tmp_tar}"
        echo -e "${Error} Aria2 压缩包解压失败，代理可能返回了异常内容 !"
        echo -e "${Tip} 可更换代理后重试：菜单 14「设置 GitHub 代理」"
        exit 1
    fi
    rm -f "${tmp_tar}"
    [[ ! -s "aria2c" ]] && echo -e "${Error} Aria2 下载失败 !" && exit 1
    [[ ${update_dl} = "update" ]] && rm -f "${aria2c}"
    mv -f aria2c "${aria2c}"
    [[ ! -e ${aria2c} ]] && echo -e "${Error} Aria2 主程序安装失败！" && exit 1
    chmod +x ${aria2c}
    echo -e "${Info} Aria2 主程序安装完成！"
}
# 下载单个配置文件（仅 aria2.conf / script.conf / rclone.env）。
# refresh 模式（重置配置）需要拿到上游版本，因此不能用 wget -N：
# 它在“本地文件比远端新”时返回 304 跳过下载，会让重置静默失效。
# 但也不能先删后下——网络不通时会直接把可用配置删没了，
# 所以统一先下到临时文件、确认非空后再替换。
Download_profile() {
    local mode=$1 PROFILE=$2 tmp
    tmp="$(mktemp)" || return 1
    if [[ ${mode} = "refresh" ]]; then
        # 重置：必须拿到远端最新版本，不能用 wget -N（本地较新时会 304 跳过）
        if dl_fetch "${tmp}" "$(gh_raw_url "${PROFILE}")"; then
            [[ -s "${tmp}" ]] && mv -f "${tmp}" "${PROFILE}" && return 0
        fi
    else
        # 常规安装：先拷一份当前内容到临时文件，让 wget -N 能基于它做增量判断
        cp -f "${PROFILE}" "${tmp}" 2>/dev/null
        if dl_fetch "${tmp}" "$(gh_raw_url "${PROFILE}")" -N; then
            [[ -s "${tmp}" ]] && mv -f "${tmp}" "${PROFILE}" && return 0
        fi
    fi
    rm -f "${tmp}"
    return 1
}
# 下载附加功能脚本（core/*.sh 等）。
# 这些文件包含本项目的本地修复，不能被上游版本覆盖，因此：
#   已存在 → 一律跳过，只做安装时缺失补齐；
#   不存在 → 从本仓库下载。
# 需要同步上游更新时，请手动替换并重新应用本地修改。
Install_script_file() {
    local PROFILE=$1
    [[ -s "${PROFILE}" ]] && return 0
    dl_install "${PROFILE}" "$(gh_raw_url "${PROFILE}")"
}
Download_aria2_conf() {
    local mode=$1
    # 配置文件：重置时会被覆盖
    CONF_LIST="aria2.conf script.conf rclone.env"
    # 功能脚本与数据文件：始终保留本地版本，仅在缺失时补齐
    SCRIPT_LIST="core clean.sh delete.sh move.sh upload.sh LICENSE dht.dat dht6.dat"
    mkdir -p "${aria2_conf_dir}" && cd "${aria2_conf_dir}"
    # 失败清理时只删本次真正需要下载的东西，不能整目录 rm -rf：
    # 目录里可能已有本地修改过的功能脚本，误删会直接丢失本地修复。
    local need_download=""
    for PROFILE in ${CONF_LIST} ${SCRIPT_LIST}; do
        [[ -s "${PROFILE}" ]] || need_download="${need_download} ${PROFILE}"
    done
    for PROFILE in ${CONF_LIST}; do
        # 用返回码判断：refresh 模式下载失败时旧文件仍在磁盘上，
        # 若用“文件是否存在”判断会把失败误判为成功，导致静默没刷新。
        Download_profile "${mode}" "${PROFILE}" || {
            echo -e "${Error} '${PROFILE}' 下载失败！原有文件保持不变，本次操作已中止。"
            [[ ${mode} != "refresh" ]] && for f in ${need_download}; do rm -vf "${f}"; done
            exit 1
        }
    done
    for PROFILE in ${SCRIPT_LIST}; do
        if [[ -s "${PROFILE}" ]]; then
            echo -e "${Info} '${PROFILE}' 已存在，保留本地版本（不做覆盖）。"
            continue
        fi
        Install_script_file "${PROFILE}"
        [[ ! -s "${PROFILE}" ]] && {
            echo -e "${Error} '${PROFILE}' 下载失败！清理本次新下载的文件（原有文件不会删除）..."
            for f in ${need_download}; do rm -vf "${f}"; done
            exit 1
        }
    done
    sed -i "s@^\(dir=\).*@\1${download_path}@" ${aria2_conf}
    sed -i "s@/root/.aria2/@${aria2_conf_dir}/@" ${aria2_conf_dir}/*.conf
    sed -i "s@^\(rpc-secret=\).*@\1$(date +%s%N | md5sum | head -c 20)@" ${aria2_conf}
    sed -i "s@^#\(retry-on-.*=\).*@\1true@" ${aria2_conf}
    sed -i "s@^\(max-connection-per-server=\).*@\132@" ${aria2_conf}
    touch aria2.session
    chmod +x *.sh
    # 配置文件中含明文 RPC 密钥，收紧权限避免其它用户读取
    chmod 600 "${aria2_conf}" 2>/dev/null
    echo -e "${Info} Aria2 完美配置下载完成！"
}
Service_aria2() {
    local svc_name
    if [[ ${release} = "centos" ]]; then
        svc_name="aria2_centos"
    else
        svc_name="aria2_debian"
    fi
    dl_install /etc/init.d/aria2 "$(gh_raw_url "service/${svc_name}")"
    [[ ! -s /etc/init.d/aria2 ]] && {
        echo -e "${Error} Aria2服务 管理脚本下载失败 !"
        echo -e "${Tip} 可用菜单 14「设置 GitHub 代理」更换代理后重试。"
        exit 1
    }
    chmod +x /etc/init.d/aria2
    if [[ ${release} = "centos" ]]; then
        chkconfig --add aria2
        chkconfig aria2 on
    else
        update-rc.d -f aria2 defaults
    fi
    dl_install /etc/init.d/aria2c "$(gh_raw_url "service/aria2c")"
    echo -e "${Info} Aria2服务 管理脚本下载完成 !"
}
Installation_dependency() {
    if [[ ${release} = "centos" ]]; then
        # 仅刷新元数据，不做全系统升级（yum update 可能升级内核/关键组件，影响生产环境）
        yum makecache
        yum install -y wget curl nano ca-certificates findutils jq tar gzip dpkg
    else
        apt-get update
        apt-get install -y wget curl nano ca-certificates findutils jq tar gzip dpkg
    fi
}
Install_aria2() {
    check_root
    [[ -e ${aria2c} ]] && echo -e "${Error} Aria2 已安装，请检查 !" && exit 1
    check_sys
    echo -e "${Info} 开始安装/配置 依赖..."
    Installation_dependency
    echo -e "${Info} 开始下载/安装 主程序..."
    check_new_ver
    Download_aria2
    echo -e "${Info} 开始下载/安装 Aria2 完美配置..."
    Download_aria2_conf
    echo -e "${Info} 开始下载/安装 服务脚本(init)..."
    Service_aria2
    Read_config
    aria2_RPC_port=${aria2_port}
    echo -e "${Info} 开始设置 iptables 防火墙..."
    Set_iptables
    echo -e "${Info} 开始添加 iptables 防火墙规则..."
    Add_iptables
    echo -e "${Info} 开始保存 iptables 防火墙规则..."
    Save_iptables
    echo -e "${Info} 开始创建 下载目录..."
    mkdir -p ${download_path}
    echo -e "${Info} 开启Tracker自动更新中..."
    crontab_update_start
    Update_bt_tracker
    echo -e "${Info} 所有步骤 安装完毕，开始启动..."
    Start_aria2
}

# 检测开机自启是否已开启。
# 通过 /etc/rc?.d/ 下的启动软链接判断，CentOS(chkconfig) 与 Debian/Ubuntu(update-rc.d)
# 管理的都是同一套 SysV 软链接，因此无需区分发行版。
# 注意：不能用 `ls /etc/rc?.d/S*aria2 /etc/rc.d/rc?.d/S*aria2` 这种多 glob 写法——
# 在 Debian/Ubuntu 上 /etc/rc.d/rc?.d 不存在，该 glob 无法展开会成为字面量，
# ls 因它报错返回非 0，导致软链接明明存在也被误判为“未开启”。
check_autostart_status() {
    [[ -n "$(find /etc/rc?.d /etc/rc.d/rc?.d -maxdepth 1 -name 'S*aria2' -print -quit 2>/dev/null)" ]]
}

Start_auto() {
    check_installed_status
    check_sys
    if check_autostart_status; then
        echo
        echo -e " 是否关闭 ${Red_font_prefix}开机自启${Font_color_suffix} 功能？[y/N] \c"
        read -e Start_auto_ny
        [[ -z "${Start_auto_ny}" ]] && Start_auto_ny="n"
        if [[ ${Start_auto_ny} == [Yy] ]]; then
            echo
            Start_auto_stop
        fi
    else
        echo
        echo -e " 是否开启 ${Red_font_prefix}开机自启${Font_color_suffix} 功能？[y/N] \c"
        read -e Start_auto_ny
        [[ -z "${Start_auto_ny}" ]] && Start_auto_ny="n"
        if [[ ${Start_auto_ny} == [Yy] ]]; then
            echo
            Start_auto_open
        fi
    fi
}

Start_auto_open() {
    echo -e "${Info} 添加开机自启服务..."
    local out rc
    if [[ ${release} = "centos" ]]; then
        out=$(chkconfig aria2 on 2>&1); rc=$?
    else
        out=$(update-rc.d aria2 defaults 2>&1); rc=$?
    fi
    # 不能无条件报成功：命令失败时要如实提示并显示原始报错，
    # 否则界面显示“已开启”而实际没设置，重启后不会自动启动。
    if [[ ${rc} -eq 0 ]] && check_autostart_status; then
        echo -e "${Info} 打开自启服务成功..."
        /etc/init.d/aria2 start
        # 显式返回：自启配置已成功，不因后续 start 的结果影响本次操作的成败判定
        return 0
    else
        echo -e "${Error} 设置开机自启失败！"
        [[ -n ${out} ]] && echo -e "      命令返回: ${out}"
        [[ ! -e /etc/init.d/aria2 ]] && echo -e "      原因: /etc/init.d/aria2 不存在，请先执行菜单 1 安装"
        [[ ! -x /etc/init.d/aria2 && -e /etc/init.d/aria2 ]] && echo -e "      原因: /etc/init.d/aria2 没有执行权限（chmod +x）"
        echo -e "${Tip} 可手动执行以下命令排查："
        [[ ${release} = "centos" ]] && echo -e "      chkconfig aria2 on" || echo -e "      update-rc.d aria2 defaults"
        return 1
    fi
}
Start_auto_stop() {
    echo -e "${Info} 删除开机自启服务..."
    if [[ ${release} = "centos" ]]; then
        chkconfig aria2 off
    else
        update-rc.d -f aria2 remove
    fi
    if check_autostart_status; then
        echo -e "${Error} 取消自启服务失败，仍有自启软链接残留："
        find /etc/rc?.d /etc/rc.d/rc?.d -maxdepth 1 -name 'S*aria2' 2>/dev/null | sed 's/^/      /'
        return 1
    else
        echo -e "${Info} 取消自启服务成功..."
    fi
}

Start_aria2() {
    check_installed_status
    check_pid
    [[ ! -z ${PID} ]] && echo -e "${Error} Aria2 正在运行，请检查 !" && exit 1
    /etc/init.d/aria2 start
}
Stop_aria2() {
    check_installed_status
    check_pid
    [[ -z ${PID} ]] && echo -e "${Error} Aria2 没有运行，请检查 !" && exit 1
    /etc/init.d/aria2 stop
}
Restart_aria2() {
    check_installed_status
    check_pid
    [[ ! -z ${PID} ]] && /etc/init.d/aria2 stop
    /etc/init.d/aria2 start
}
Set_aria2() {
    check_installed_status
    echo -e "
 ${Green_font_prefix}1.${Font_color_suffix} 修改 Aria2 RPC 密钥
 ${Green_font_prefix}2.${Font_color_suffix} 修改 Aria2 RPC 端口
 ${Green_font_prefix}3.${Font_color_suffix} 修改 Aria2 下载目录
 ${Green_font_prefix}4.${Font_color_suffix} 修改 Aria2 密钥 + 端口 + 下载目录
 ${Green_font_prefix}5.${Font_color_suffix} 手动 打开配置文件修改
 ————————————
 ${Green_font_prefix}0.${Font_color_suffix} 重置/更新 Aria2 完美配置
"
    read -e -p " 请输入数字 [0-5]:" aria2_modify
    if [[ ${aria2_modify} == "1" ]]; then
        Set_aria2_RPC_passwd
    elif [[ ${aria2_modify} == "2" ]]; then
        Set_aria2_RPC_port
    elif [[ ${aria2_modify} == "3" ]]; then
        Set_aria2_RPC_dir
    elif [[ ${aria2_modify} == "4" ]]; then
        Set_aria2_RPC_passwd_port_dir
    elif [[ ${aria2_modify} == "5" ]]; then
        Set_aria2_vim_conf
    elif [[ ${aria2_modify} == "0" ]]; then
        Reset_aria2_conf
    else
        echo
        echo -e " ${Error} 请输入正确的数字"
        exit 1
    fi
}
Set_aria2_RPC_passwd() {
    read_123=$1
    if [[ ${read_123} != "1" ]]; then
        Read_config
    fi
    if [[ -z "${aria2_passwd}" ]]; then
        aria2_passwd_1="空(没有检测到配置，可能手动删除或注释了)"
    else
        aria2_passwd_1=${aria2_passwd}
    fi
    echo -e "
 ${Tip} Aria2 RPC 密钥不要包含等号(=)和井号(#)，留空为随机生成。

 当前 RPC 密钥为: ${Green_font_prefix}${aria2_passwd_1}${Font_color_suffix}
"
    read -e -p " 请输入新的 RPC 密钥: " aria2_RPC_passwd
    echo
    [[ -z "${aria2_RPC_passwd}" ]] && aria2_RPC_passwd=$(date +%s%N | md5sum | head -c 20)
    if [[ "${aria2_passwd}" != "${aria2_RPC_passwd}" ]]; then
        if [[ -z "${aria2_passwd}" ]]; then
            echo -e "\nrpc-secret=${aria2_RPC_passwd}" >>${aria2_conf}
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} RPC 密钥修改成功！新密钥为：${Green_font_prefix}${aria2_RPC_passwd}${Font_color_suffix}(配置文件中缺少相关选项参数，已自动加入配置文件底部)"
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} RPC 密钥修改失败！旧密钥为：${Green_font_prefix}${aria2_passwd}${Font_color_suffix}"
            fi
        else
            sed -i 's/^rpc-secret='${aria2_passwd}'/rpc-secret='${aria2_RPC_passwd}'/g' ${aria2_conf}
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} RPC 密钥修改成功！新密钥为：${Green_font_prefix}${aria2_RPC_passwd}${Font_color_suffix}"
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} RPC 密钥修改失败！旧密钥为：${Green_font_prefix}${aria2_passwd}${Font_color_suffix}"
            fi
        fi
    else
        echo -e "${Error} 与旧配置一致，无需修改..."
    fi
}
Set_aria2_RPC_port() {
    read_123=$1
    if [[ ${read_123} != "1" ]]; then
        Read_config
    fi
    if [[ -z "${aria2_port}" ]]; then
        aria2_port_1="空(没有检测到配置，可能手动删除或注释了)"
    else
        aria2_port_1=${aria2_port}
    fi
    echo -e "
 当前 RPC 端口为: ${Green_font_prefix}${aria2_port_1}${Font_color_suffix}
"
    read -e -p " 请输入新的 RPC 端口(默认: 6800): " aria2_RPC_port
    echo
    [[ -z "${aria2_RPC_port}" ]] && aria2_RPC_port="6800"
    if [[ "${aria2_port}" != "${aria2_RPC_port}" ]]; then
        if [[ -z "${aria2_port}" ]]; then
            echo -e "\nrpc-listen-port=${aria2_RPC_port}" >>${aria2_conf}
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} RPC 端口修改成功！新端口为：${Green_font_prefix}${aria2_RPC_port}${Font_color_suffix}(配置文件中缺少相关选项参数，已自动加入配置文件底部)"
                Del_iptables
                Add_iptables
                Save_iptables
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} RPC 端口修改失败！旧端口为：${Green_font_prefix}${aria2_port}${Font_color_suffix}"
            fi
        else
            sed -i 's/^rpc-listen-port='${aria2_port}'/rpc-listen-port='${aria2_RPC_port}'/g' ${aria2_conf}
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} RPC 端口修改成功！新端口为：${Green_font_prefix}${aria2_RPC_port}${Font_color_suffix}"
                Del_iptables
                Add_iptables
                Save_iptables
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} RPC 端口修改失败！旧端口为：${Green_font_prefix}${aria2_port}${Font_color_suffix}"
            fi
        fi
    else
        echo -e "${Error} 与旧配置一致，无需修改..."
    fi
}
Set_aria2_RPC_dir() {
    read_123=$1
    if [[ ${read_123} != "1" ]]; then
        Read_config
    fi
    if [[ -z "${aria2_dir}" ]]; then
        aria2_dir_1="空(没有检测到配置，可能手动删除或注释了)"
    else
        aria2_dir_1=${aria2_dir}
    fi
    echo -e "
 当前下载目录为: ${Green_font_prefix}${aria2_dir_1}${Font_color_suffix}
"
    read -e -p " 请输入新的下载目录(默认: ${download_path}): " aria2_RPC_dir
    [[ -z "${aria2_RPC_dir}" ]] && aria2_RPC_dir="${download_path}"
    mkdir -p ${aria2_RPC_dir}
    echo
    if [[ "${aria2_dir}" != "${aria2_RPC_dir}" ]]; then
        if [[ -z "${aria2_dir}" ]]; then
            echo -e "\ndir=${aria2_RPC_dir}" >>${aria2_conf}
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} 下载目录修改成功！新位置为：${Green_font_prefix}${aria2_RPC_dir}${Font_color_suffix}(配置文件中缺少相关选项参数，已自动加入配置文件底部)"
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} 下载目录修改失败！旧位置为：${Green_font_prefix}${aria2_dir}${Font_color_suffix}"
            fi
        else
            # 附加功能脚本从 aria2.conf 的 dir= 读取下载目录，无需再改脚本内的变量
            aria2_RPC_dir_2=$(echo "${aria2_RPC_dir}" | sed 's/\//\\\//g')
            sed -i "s@^\(dir=\).*@\1${aria2_RPC_dir_2}@" ${aria2_conf}
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} 下载目录修改成功！新位置为：${Green_font_prefix}${aria2_RPC_dir}${Font_color_suffix}"
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} 下载目录修改失败！旧位置为：${Green_font_prefix}${aria2_dir}${Font_color_suffix}"
            fi
        fi
    else
        echo -e "${Error} 与旧配置一致，无需修改..."
    fi
}
Set_aria2_RPC_passwd_port_dir() {
    Read_config
    Set_aria2_RPC_passwd "1"
    Set_aria2_RPC_port "1"
    Set_aria2_RPC_dir "1"
    Restart_aria2
}
Set_aria2_vim_conf() {
    Read_config
    aria2_port_old=${aria2_port}
    aria2_dir_old=${aria2_dir}
    echo -e "
 配置文件位置：${Green_font_prefix}${aria2_conf}${Font_color_suffix}

 ${Tip} 手动修改配置文件须知：
 
 ${Green_font_prefix}1.${Font_color_suffix} 默认使用 nano 文本编辑器打开
 ${Green_font_prefix}2.${Font_color_suffix} 退出并保存文件：按 ${Green_font_prefix}Ctrl+X${Font_color_suffix} 组合键，输入 ${Green_font_prefix}y${Font_color_suffix} ，按 ${Green_font_prefix}Enter${Font_color_suffix} 键
 ${Green_font_prefix}3.${Font_color_suffix} 退出不保存文件：按 ${Green_font_prefix}Ctrl+X${Font_color_suffix} 组合键，输入 ${Green_font_prefix}n${Font_color_suffix}
 ${Green_font_prefix}4.${Font_color_suffix} nano 详细使用教程：${Green_font_prefix}https://p3terx.com/archives/linux-nano-tutorial.html${Font_color_suffix}
 ${Green_font_prefix}5.${Font_color_suffix} 配置文件有中文注释，若语言设置有问题会导致中文乱码
 "
    read -e -p "按任意键继续，按 Ctrl+C 组合键取消" var
    nano "${aria2_conf}"
    Read_config
    if [[ ${aria2_port_old} != ${aria2_port} ]]; then
        aria2_RPC_port=${aria2_port}
        aria2_port=${aria2_port_old}
        Del_iptables
        Add_iptables
        Save_iptables
    fi
    if [[ ${aria2_dir_old} != ${aria2_dir} ]]; then
        # 用户手动改了下载目录，确保目录存在即可（附加功能脚本自动跟随 aria2.conf）
        mkdir -p ${aria2_dir}
    fi
    Restart_aria2
}
Reset_aria2_conf() {
    Read_config
    aria2_port_old=${aria2_port}
    echo
    echo -e "${Tip} 此操作将重新下载 aria2.conf、script.conf、rclone.env 三个配置文件，其内容将恢复为上游默认值。"
    echo -e "${Tip} core、clean.sh、delete.sh、move.sh、upload.sh 等功能脚本会保留本地版本，不会被覆盖。"
    echo
    read -e -p "按任意键继续，按 Ctrl+C 组合键取消" var
    Download_aria2_conf refresh
    Read_config
    if [[ ${aria2_port_old} != ${aria2_port} ]]; then
        aria2_RPC_port=${aria2_port}
        aria2_port=${aria2_port_old}
        Del_iptables
        Add_iptables
        Save_iptables
    fi
    Restart_aria2
}
Read_config() {
    status_type=$1
    if [[ ! -e ${aria2_conf} ]]; then
        if [[ ${status_type} != "un" ]]; then
            echo -e "${Error} Aria2 配置文件不存在 !" && exit 1
        fi
    else
        conf_text=$(cat ${aria2_conf} | grep -v '#')
        aria2_dir=$(echo -e "${conf_text}" | grep "^dir=" | awk -F "=" '{print $NF}')
        aria2_port=$(echo -e "${conf_text}" | grep "^rpc-listen-port=" | awk -F "=" '{print $NF}')
        aria2_passwd=$(echo -e "${conf_text}" | grep "^rpc-secret=" | awk -F "=" '{print $NF}')
        aria2_bt_port=$(echo -e "${conf_text}" | grep "^listen-port=" | awk -F "=" '{print $NF}')
        aria2_dht_port=$(echo -e "${conf_text}" | grep "^dht-listen-port=" | awk -F "=" '{print $NF}')
        # 关键参数缺失时直接报错退出：否则空值会被拼进 iptables 命令导致语法错误，
        # 或让后续逻辑拿到空端口。仅在校验模式下容忍缺失（卸载流程会调用）。
        if [[ ${status_type} != "un" ]]; then
            local missing=""
            [[ -z ${aria2_dir} ]] && missing="${missing} dir"
            [[ -z ${aria2_port} ]] && missing="${missing} rpc-listen-port"
            [[ -z ${aria2_bt_port} ]] && missing="${missing} listen-port"
            [[ -z ${aria2_dht_port} ]] && missing="${missing} dht-listen-port"
            [[ -n ${missing} ]] && echo -e "${Error} 配置文件缺少必要参数:${missing}，请检查 ${aria2_conf} !" && exit 1
        fi
    fi
}
View_Aria2() {
    check_installed_status
    Read_config
    # 逐个服务尝试，取第一个“有内容”的结果。
    # 不能只用 || 串联：若某个服务返回空内容但退出码为 0，|| 不会触发，
    # 会把空值当成结果，导致地址被误显示为“检测失败”。
    IPV4=""
    local u out
    for u in api.ip.sb/ip ifconfig.io/ip www.trackip.net/ip ifconfig.me/ip ipinfo.io/ip; do
        out=$(wget -qO- -t1 -T3 -4 "https://${u}" 2>/dev/null | tr -d '\r\n')
        [[ -n ${out} ]] && { IPV4="${out}"; break; }
    done
    IPV6=""
    for u in api.ip.sb/ip ifconfig.io/ip www.trackip.net/ip ifconfig.me/ip ipinfo.io/ip; do
        out=$(wget -qO- -t1 -T3 -6 "https://${u}" 2>/dev/null | tr -d '\r\n')
        [[ -n ${out} ]] && { IPV6="${out}"; break; }
    done
    [[ -z "${IPV4}" ]] && IPV4="IPv4 地址检测失败"
    [[ -z "${IPV6}" ]] && IPV6="IPv6 地址检测失败"
    [[ -z "${aria2_dir}" ]] && aria2_dir="找不到配置参数"
    [[ -z "${aria2_port}" ]] && aria2_port="找不到配置参数"
    [[ -z "${aria2_passwd}" ]] && aria2_passwd="找不到配置参数(或无密钥)"
    if [[ -z "${IPV4}" || -z "${aria2_port}" ]]; then
        AriaNg_URL="null"
    else
        AriaNg_API="/#!/settings/rpc/set/ws/${IPV4}/${aria2_port}/jsonrpc/$(echo -n ${aria2_passwd} | base64)"
        AriaNg_URL="http://ariang.js.org${AriaNg_API}"
    fi
    clear
    echo -e "\nAria2 简单配置信息：\n
 IPv4 地址\t: ${Green_font_prefix}${IPV4}${Font_color_suffix}
 IPv6 地址\t: ${Green_font_prefix}${IPV6}${Font_color_suffix}
 RPC 端口\t: ${Green_font_prefix}${aria2_port}${Font_color_suffix}
 RPC 密钥\t: ${Green_font_prefix}${aria2_passwd}${Font_color_suffix}
 下载目录\t: ${Green_font_prefix}${aria2_dir}${Font_color_suffix}
 AriaNg 链接\t: ${Green_font_prefix}${AriaNg_URL}${Font_color_suffix}\n"
}
View_Log() {
    [[ ! -e ${aria2_log} ]] && echo -e "${Error} Aria2 日志文件不存在 !" && exit 1
    echo && echo -e "${Tip} 按 ${Red_font_prefix}Ctrl+C${Font_color_suffix} 终止查看日志" && echo -e "如果需要查看完整日志内容，请用 ${Red_font_prefix}cat ${aria2_log}${Font_color_suffix} 命令。" && echo
    tail -f ${aria2_log}
}
Clean_Log() {
    [[ ! -e ${aria2_log} ]] && echo -e "${Error} Aria2 日志文件不存在 !" && exit 1
    echo >${aria2_log}
    echo -e "${Info} Aria2 日志已清空 !"
}
crontab_update_status() {
    crontab -l | grep "tracker.sh"
}
Update_bt_tracker_cron() {
    check_installed_status
    check_crontab_installed_status
    if [[ -z $(crontab_update_status) ]]; then
        echo
        echo -e " 是否开启 ${Green_font_prefix}自动更新 BT-Tracker${Font_color_suffix} 功能？(可能会增强 BT 下载速率)[Y/n] \c"
        read -e crontab_update_status_ny
        [[ -z "${crontab_update_status_ny}" ]] && crontab_update_status_ny="y"
        if [[ ${crontab_update_status_ny} == [Yy] ]]; then
            crontab_update_start
        else
            echo && echo " 已取消..."
        fi
    else
        echo
        echo -e " 是否关闭 ${Red_font_prefix}自动更新 BT-Tracker${Font_color_suffix} 功能？[y/N] \c"
        read -e crontab_update_status_ny
        [[ -z "${crontab_update_status_ny}" ]] && crontab_update_status_ny="n"
        if [[ ${crontab_update_status_ny} == [Yy] ]]; then
            crontab_update_stop
        else
            echo && echo " 已取消..."
        fi
    fi
}
crontab_update_start() {
    crontab -l >"/tmp/crontab.bak"
    sed -i "/aria2.sh update-bt-tracker/d" "/tmp/crontab.bak"
    sed -i "/tracker.sh/d" "/tmp/crontab.bak"
    echo -e "\n0 0 * * * /bin/bash ${aria2_conf_dir}/tracker.sh ${aria2_conf} RPC 2>&1 | tee ${aria2_conf_dir}/tracker.log" >>"/tmp/crontab.bak"
    crontab "/tmp/crontab.bak"
    rm -f "/tmp/crontab.bak"
    if [[ -z $(crontab_update_status) ]]; then
        echo && echo -e "${Error} 自动更新 BT-Tracker 开启失败 !" && exit 1
    else
        Update_bt_tracker
        echo && echo -e "${Info} 自动更新 BT-Tracker 开启成功 !"
    fi
}
crontab_update_stop() {
    crontab -l >"/tmp/crontab.bak"
    sed -i "/aria2.sh update-bt-tracker/d" "/tmp/crontab.bak"
    sed -i "/tracker.sh/d" "/tmp/crontab.bak"
    crontab "/tmp/crontab.bak"
    rm -f "/tmp/crontab.bak"
    if [[ -n $(crontab_update_status) ]]; then
        echo && echo -e "${Error} 自动更新 BT-Tracker 关闭失败 !" && exit 1
    else
        echo && echo -e "${Info} 自动更新 BT-Tracker 关闭成功 !"
    fi
}
Update_bt_tracker() {
    check_installed_status
    check_pid
    # 先下载到临时文件再执行：避免下载中断时执行到半截脚本，同时便于排查问题。
    local tracker_tmp="/tmp/aria2-tracker.sh"
    local tracker_opts=""
    if ! dl_fetch "${tracker_tmp}" "$(gh_raw_url tracker.sh)"; then
        rm -f "${tracker_tmp}"
        echo -e "${Error} tracker.sh 下载失败（所有线路均不可用）!"
        echo -e "${Tip} 可用菜单 14「设置 GitHub 代理」更换代理后重试。"
        exit 1
    fi
    # Aria2 正在运行时通过 RPC 热更新，无需重启
    [[ -n $PID ]] && tracker_opts="RPC"
    bash "${tracker_tmp}" "${aria2_conf}" ${tracker_opts}
    rm -f "${tracker_tmp}"
}
Update_aria2() {
    check_installed_status
    check_new_ver
    check_ver_comparison
}
Uninstall_aria2() {
    check_installed_status "un"
    echo "确定要卸载 Aria2 ? (y/N)"
    echo
    read -e -p "(默认: n):" unyn
    [[ -z ${unyn} ]] && unyn="n"
    if [[ ${unyn} == [Yy] ]]; then
        crontab -l >"/tmp/crontab.bak"
        sed -i "/aria2.sh/d" "/tmp/crontab.bak"
        sed -i "/tracker.sh/d" "/tmp/crontab.bak"
        crontab "/tmp/crontab.bak"
        rm -f "/tmp/crontab.bak"
        check_pid
        [[ ! -z $PID ]] && kill -9 ${PID}
        Read_config "un"
        Del_iptables
        Save_iptables
        rm -rf "${aria2c}"
        rm -rf "${aria2_conf_dir}"
        if [[ ${release} = "centos" ]]; then
            chkconfig --del aria2
        else
            update-rc.d -f aria2 remove
        fi
        rm -rf "/etc/init.d/aria2"
        echo && echo "Aria2 卸载完成 !" && echo
    else
        echo && echo "卸载已取消..." && echo
    fi
}
Add_iptables() {
    # RPC 端口仅对内网来源放行；BT/DHT 端口需要外部连通，保持全网放行。
    for source in ${rpc_allow_source}; do
        iptables -I INPUT -m state --state NEW -m tcp -p tcp -s ${source} --dport ${aria2_RPC_port} -j ACCEPT
    done
    iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport ${aria2_bt_port} -j ACCEPT
    iptables -I INPUT -m state --state NEW -m udp -p udp --dport ${aria2_dht_port} -j ACCEPT
}
Del_iptables() {
    for source in ${rpc_allow_source}; do
        iptables -D INPUT -m state --state NEW -m tcp -p tcp -s ${source} --dport ${aria2_port} -j ACCEPT 2>/dev/null
    done
    iptables -D INPUT -m state --state NEW -m tcp -p tcp --dport ${aria2_bt_port} -j ACCEPT 2>/dev/null
    iptables -D INPUT -m state --state NEW -m udp -p udp --dport ${aria2_dht_port} -j ACCEPT 2>/dev/null
    return 0
}
Save_iptables() {
    if [[ ${release} == "centos" ]]; then
        service iptables save
    else
        iptables-save >/etc/iptables.up.rules
    fi
}
Set_iptables() {
    if [[ ${release} == "centos" ]]; then
        service iptables save
        chkconfig --level 2345 iptables on
    else
        iptables-save >/etc/iptables.up.rules
        echo -e '#!/bin/bash\n/sbin/iptables-restore < /etc/iptables.up.rules' >/etc/network/if-pre-up.d/iptables
        chmod +x /etc/network/if-pre-up.d/iptables
    fi
}
Update_Shell() {
    # 更新源指向本项目仓库。原先指向 P3TERX/aria2.sh，会把增强版覆盖成上游原版，
    # 导致菜单里依赖 Niter 增强功能的选项失效。
    local raw shell_tmp="/tmp/aria2.sh.new"
    raw=$(gh_raw_url aria2.sh)
    sh_new_ver=$(wget -qO- -t1 -T5 "${gh_proxy}${raw}" 2>/dev/null |
        grep 'sh_ver="' | awk -F "=" '{print $NF}' | sed 's/\"//g' | head -1)
    [[ -z ${sh_new_ver} ]] && sh_new_ver=$(wget -qO- -t1 -T5 "https://raw.githubusercontent.com/${gh_repo}/${gh_branch}/aria2.sh" 2>/dev/null |
        grep 'sh_ver="' | awk -F "=" '{print $NF}' | sed 's/\"//g' | head -1)
    [[ -z ${sh_new_ver} ]] && echo -e "${Error} 无法获取最新版本号，更新已取消 !" && exit 1
    if [[ ${sh_new_ver} == ${sh_ver} ]]; then
        echo -e "${Info} 当前已是最新版本 [ ${sh_ver} ]，无需更新。"
        exit 0
    fi
    # 先下载到临时文件并校验完整性，确认无误后再覆盖，避免下载中断把可用脚本写坏。
    # 注意这里不能用 wget -N：本地脚本较新时会返回 304 跳过下载，导致更新实际不生效。
    if ! dl_install "${shell_tmp}" "${raw}"; then
        echo -e "${Error} 脚本下载失败或内容异常，更新已取消 !"
        rm -f "${shell_tmp}"
        exit 1
    fi
    if ! head -n 1 "${shell_tmp}" | grep -q '^#!/usr/bin/env bash'; then
        echo -e "${Error} 下载内容异常（非有效脚本），更新已取消 !"
        rm -f "${shell_tmp}"
        exit 1
    fi
    check_sys
    if [[ -e "/etc/init.d/aria2" ]]; then
        rm -rf /etc/init.d/aria2
        Service_aria2
        Restart_aria2
    fi
    if [[ -n $(crontab_update_status) ]]; then
        crontab_update_stop
    fi
    chmod +x "${shell_tmp}" && mv -f "${shell_tmp}" aria2.sh
    echo -e "${Info} 脚本已更新为最新版本 [ ${sh_new_ver} ] !"
    # 重新下载的脚本需要重新注册服务，否则 update-rc.d/chkconfig 记录会失效
    Service_aria2
    Restart_aria2
    exit 0
}
# ==================== 代理设置 ====================
# 把新的代理地址持久化写回本脚本顶部的 gh_proxy 变量，下次运行依然生效。
save_gh_proxy() {
    local new=$1 self
    self=$(readlink -f "$0")
    [[ -f ${self} ]] || self="aria2.sh"
    if ! grep -q '^gh_proxy=' "${self}"; then
        echo -e "${Error} 未找到可修改的 gh_proxy 配置行，请手动编辑 ${self}"
        return 1
    fi
    # 用 | 作分隔符，避免代理地址中的 / 需要转义
    sed -i "s|^gh_proxy=.*|gh_proxy=\"${new}\"|" "${self}"
    if grep -q "^gh_proxy=\"${new}\"" "${self}"; then
        echo -e "${Info} 新代理已保存：${Green_font_prefix}${new:-（空，表示不使用代理）}${Font_color_suffix}"
        echo -e "${Tip} 下次运行脚本时生效。"
        return 0
    fi
    echo -e "${Error} 保存失败，请手动编辑 ${self} 中的 gh_proxy"
    return 1
}
# 测试代理连通性：分别验证 raw 文件与 api（版本查询）两类地址
test_gh_proxy() {
    local proxy=$1 raw api code
    raw="$(gh_raw_url aria2.sh)"
    api="https://api.github.com/repos/${gh_repo}/releases/latest"
    if [[ -z ${proxy} ]]; then
        echo -e "${Info} 未配置代理，测试直连 GitHub ..."
        raw="$(gh_raw_url aria2.sh)"
        api="https://api.github.com/repos/${gh_repo}/releases/latest"
    else
        raw="${proxy}${raw}"
        api="${proxy}${api}"
    fi
    code=$(wget -qO- -t1 -T8 "${raw}" 2>/dev/null | head -c 40)
    if [[ -n ${code} ]]; then
        echo -e "  raw 文件下载: ${Green_font_prefix}可用${Font_color_suffix}"
    else
        echo -e "  raw 文件下载: ${Red_font_prefix}不可用${Font_color_suffix}"
    fi
    local ver
    ver=$(wget -qO- -t1 -T8 "${api}" 2>/dev/null | grep -o '"tag_name": ".*"' | head -n 1 | cut -d'"' -f4)
    if [[ -n ${ver} ]]; then
        echo -e "  版本查询(API): ${Green_font_prefix}可用${Font_color_suffix}（最新版本 ${ver}）"
    else
        echo -e "  版本查询(API): ${Red_font_prefix}不可用${Font_color_suffix}（该代理可能不转发 api.github.com，如 ghproxy.net）"
    fi
}
Set_gh_proxy() {
    while :; do
        echo -e "
 当前 GitHub 代理 : ${Green_font_prefix}${gh_proxy:-（未配置，直连）}${Font_color_suffix}
 备用代理列表     : ${Green_font_prefix}${gh_proxy_fallback:-（无）}${Font_color_suffix}

 ${Tip} 代理需以 http(s):// 开头、以 / 结尾，脚本会拼成 <代理>https://github.com/...
      实测可用的公共代理：https://ghproxy.net/  https://gh-proxy.com/  https://ghfast.top/
      注意 ghproxy.net 不转发 api.github.com，版本查询时会自动跳过它。
"
        echo -e " ${Green_font_prefix}1.${Font_color_suffix} 设置新代理"
        echo -e " ${Green_font_prefix}2.${Font_color_suffix} 测试当前代理连通性"
        echo -e " ${Green_font_prefix}0.${Font_color_suffix} 返回"
        # read 失败（EOF，例如非交互执行）时退出，避免循环空转
        read -e -p " 请输入数字 [0-2]:" proxy_num || return 0
        case "${proxy_num}" in
        1)
            echo
            read -e -p " 请输入代理地址（留空表示不使用代理，直连）: " new_proxy
            # 规范化：非空时补全缺少的协议头与结尾斜杠
            if [[ -n ${new_proxy} ]]; then
                [[ ${new_proxy} != http*://* ]] && new_proxy="https://${new_proxy}"
                [[ ${new_proxy} != */ ]] && new_proxy="${new_proxy}/"
            fi
            if [[ -n ${new_proxy} && -n ${gh_proxy} && ${new_proxy} == "${gh_proxy}" ]]; then
                echo -e "${Error} 与当前代理一致，无需修改。"
                continue
            fi
            echo
            read -e -p " 是否先测试该代理的连通性？[Y/n] :" test_yn
            [[ -z ${test_yn} ]] && test_yn="y"
            if [[ ${test_yn} == [Yy] ]]; then
                echo
                test_gh_proxy "${new_proxy}"
                echo
                read -e -p " 是否仍然保存该代理？[Y/n] :" save_yn
                [[ -z ${save_yn} ]] && save_yn="y"
                if [[ ${save_yn} != [Yy] ]]; then
                    echo && echo " 已取消保存..."
                    continue
                fi
            fi
            save_gh_proxy "${new_proxy}" && gh_proxy="${new_proxy}"
            ;;
        2)
            echo
            test_gh_proxy "${gh_proxy}"
            echo
            read -e -p " 按回车键返回" var
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${Error} 请输入正确的数字"
            ;;
        esac
    done
}

echo && echo -e " Aria2 一键安装管理脚本 增强版 ${Red_font_prefix}[v${sh_ver}]${Font_color_suffix} by \033[1;35mNiter\033[0m

 ${Green_font_prefix} 0.${Font_color_suffix} 升级脚本
 ———————————————————————
 ${Green_font_prefix} 1.${Font_color_suffix} 安装 Aria2
 ${Green_font_prefix} 2.${Font_color_suffix} 更新 Aria2
 ${Green_font_prefix} 3.${Font_color_suffix} 卸载 Aria2
 ———————————————————————
 ${Green_font_prefix} 4.${Font_color_suffix} 启动 Aria2
 ${Green_font_prefix} 5.${Font_color_suffix} 停止 Aria2
 ${Green_font_prefix} 6.${Font_color_suffix} 重启 Aria2
 ———————————————————————
 ${Green_font_prefix} 7.${Font_color_suffix} 修改 配置
 ${Green_font_prefix} 8.${Font_color_suffix} 查看 配置
 ${Green_font_prefix} 9.${Font_color_suffix} 查看 日志
 ${Green_font_prefix}10.${Font_color_suffix} 清空 日志
 ———————————————————————
 ${Green_font_prefix}11.${Font_color_suffix} 手动更新 BT-Tracker
 ${Green_font_prefix}12.${Font_color_suffix} 自动更新 BT-Tracker
 ———————————————————————
 ${Green_font_prefix}13.${Font_color_suffix} 开机自启服务
 ———————————————————————
 ${Green_font_prefix}14.${Font_color_suffix} 设置 GitHub 代理
 ———————————————————————   " && echo
if [[ -e ${aria2c} ]]; then
    check_pid
    if [[ ! -z "${PID}" ]]; then
        echo -e " Aria2 状态: ${Green_font_prefix}已安装${Font_color_suffix} | ${Green_font_prefix}已启动${Font_color_suffix}"
    else
        echo -e " Aria2 状态: ${Green_font_prefix}已安装${Font_color_suffix} | ${Red_font_prefix}未启动${Font_color_suffix}"
    fi
    if [[ -n $(crontab_update_status) ]]; then
        echo
        echo -e " 自动更新 BT-Tracker: ${Green_font_prefix}已开启${Font_color_suffix}"
    else
        echo
        echo -e " 自动更新 BT-Tracker: ${Red_font_prefix}未开启${Font_color_suffix}"
    fi
    if check_autostart_status; then
        echo
        echo -e " Aria2开机自启: ${Green_font_prefix}已开启${Font_color_suffix}"
    else
        echo
        echo -e " Aria2开机自启: ${Red_font_prefix}未开启${Font_color_suffix}"
    fi
else
    echo
    echo -e " Aria2 状态: ${Red_font_prefix}未安装${Font_color_suffix}"
fi
    echo
    echo -e " GitHub 代理: ${Green_font_prefix}${gh_proxy:-（未配置，直连）}${Font_color_suffix}"
    echo
read -e -p " 请输入数字 [0-14]:" num
case "$num" in
0)
    Update_Shell
    ;;
1)
    Install_aria2
    ;;
2)
    Update_aria2
    ;;
3)
    Uninstall_aria2
    ;;
4)
    Start_aria2
    ;;
5)
    Stop_aria2
    ;;
6)
    Restart_aria2
    ;;
7)
    Set_aria2
    ;;
8)
    View_Aria2
    ;;
9)
    View_Log
    ;;
10)
    Clean_Log
    ;;
11)
    Update_bt_tracker
    ;;
12)
    Update_bt_tracker_cron
    ;;
13)
    Start_auto
    ;;
14)
    Set_gh_proxy
    ;;
*)
    echo
    echo -e " ${Error} 请输入正确的数字"
    ;;
esac
