#!/bin/bash

# ========================================
# 全局配置
# ========================================
CURRENT_VERSION="1.2.0"
UPDATE_URL="https://raw.githubusercontent.com/qq1055506789/realm/main/realm.sh"
VERSION_CHECK_URL="https://raw.githubusercontent.com/qq1055506789/realm/main/version.txt"
REALM_DIR="/root/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
LOG_FILE="/var/log/realm_manager.log"
BACKUP_DIR="$REALM_DIR/backups"

# ========================================
# 颜色定义
# ========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========================================
# 初始化检查
# ========================================
init_check() {
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}✖ 必须使用root权限运行本脚本${NC}"
        exit 1
    fi

    # 检查必要命令
    local REQUIRED_CMDS=(curl wget tar systemctl)
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            install_package "$cmd"
        fi
    done

    # 创建必要目录
    mkdir -p "$REALM_DIR" "$BACKUP_DIR"
    chmod 700 "$REALM_DIR"
    
    # 检查日志目录权限
    if [[ ! -w $(dirname "$LOG_FILE") ]]; then
        echo -e "${RED}✖ 日志目录不可写，请检查权限${NC}"
        exit 1
    fi

    # 初始化日志文件
    touch "$LOG_FILE" || {
        echo -e "${RED}✖ 无法创建日志文件${NC}"
        exit 1
    }
    chmod 600 "$LOG_FILE"

    log "INFO" "脚本启动 v$CURRENT_VERSION"
    check_connectivity || exit 1
}

# ========================================
# 安装依赖包
# ========================================
install_package() {
    local pkg=$1
    log "WARN" "正在安装 $pkg..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y "$pkg"
    elif command -v yum &> /dev/null; then
        yum install -y "$pkg"
    elif command -v dnf &> /dev/null; then
        dnf install -y "$pkg"
    else
        log "ERROR" "无法识别包管理器，请手动安装 $pkg"
        echo -e "${RED}✖ 无法安装 $pkg，请手动安装${NC}"
        exit 1
    fi
}

# ========================================
# 网络连接检查
# ========================================
check_connectivity() {
    if ! curl -s --connect-timeout 5 https://github.com > /dev/null; then
        log "ERROR" "网络连接检查失败"
        echo -e "${RED}✖ 网络连接检查失败，请检查网络设置${NC}"
        return 1
    fi
    return 0
}

# ========================================
# 日志系统
# ========================================
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO") color="$BLUE" ;;
        "WARN") color="$YELLOW" ;;
        "ERROR") color="$RED" ;;
        *) color="$NC" ;;
    esac
    
    echo -e "[$timestamp] [$level] $msg" >> "$LOG_FILE"
    echo -e "${color}[$timestamp] [$level]${NC} $msg"
}

# ========================================
# 版本比较函数
# ========================================
version_compare() {
    if [[ "$1" == "$2" ]]; then
        return 0  # 版本相同
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1  # 当前版本更高
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2  # 远程版本更高
        fi
    done
    return 0
}

# ========================================
# 自动更新模块
# ========================================
check_update() {
    echo -e "\n${BLUE}▶ 正在检查更新...${NC}"
    log "INFO" "开始检查更新"
    
    # 获取远程版本
    remote_version=$(curl -sL $VERSION_CHECK_URL 2>> "$LOG_FILE" | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    if [[ -z "$remote_version" ]]; then
        log "ERROR" "版本检查失败：无法获取远程版本"
        echo -e "${RED}✖ 无法获取远程版本信息，请检查网络连接${NC}"
        return 1
    fi
    
    # 验证版本号格式
    if ! [[ "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "ERROR" "版本检查失败：无效的远程版本号 '$remote_version'"
        echo -e "${RED}✖ 远程版本号格式错误${NC}"
        return 1
    fi

    # 版本比较
    version_compare "$CURRENT_VERSION" "$remote_version"
    case $? in
        0)
            echo -e "${GREEN}✓ 当前已是最新版本 v${CURRENT_VERSION}${NC}"
            log "INFO" "当前已是最新版本"
            return 1
            ;;
        1)
            echo -e "${YELLOW}⚠ 本地版本 v${CURRENT_VERSION} 比远程版本 v${remote_version} 更高${NC}"
            log "WARN" "本地版本高于远程版本"
            return 1
            ;;
        2)
            echo -e "${YELLOW}▶ 发现新版本 v${remote_version}${NC}"
            log "INFO" "发现新版本 v$remote_version"
            return 0
            ;;
    esac
}

perform_update() {
    echo -e "${BLUE}▶ 开始更新...${NC}"
    log "INFO" "开始执行更新"
    
    # 创建临时文件
    local temp_file=$(mktemp)
    
    # 下载新版本
    if ! curl -sL $UPDATE_URL -o "$temp_file"; then
        log "ERROR" "更新失败：下载脚本失败"
        echo -e "${RED}✖ 下载更新失败，请检查网络${NC}"
        rm -f "$temp_file"
        return 1
    fi
    
    # 验证下载内容
    if ! grep -q "CURRENT_VERSION" "$temp_file"; then
        log "ERROR" "更新失败：下载文件无效"
        echo -e "${RED}✖ 下载文件校验失败${NC}"
        rm -f "$temp_file"
        return 1
    fi
    
    # 备份当前脚本
    local backup_file="$BACKUP_DIR/realm.sh.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$0" "$backup_file"
    log "INFO" "已备份当前脚本到 $backup_file"
    
    # 替换脚本
    chmod +x "$temp_file"
    if ! mv -f "$temp_file" "$0"; then
        log "ERROR" "更新失败：替换脚本失败"
        echo -e "${RED}✖ 更新失败，请手动操作${NC}"
        return 1
    fi
    
    log "INFO" "更新完成，重启脚本"
    echo -e "${GREEN}✓ 更新成功，重新启动脚本...${NC}"
    
    # 传递参数跳过更新检查
    exec "$0" "--no-update" "$@"
}

# ========================================
# 配置管理
# ========================================
backup_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/config.toml.bak.$timestamp"
    cp "$CONFIG_FILE" "$backup_file"
    log "INFO" "配置文件已备份到 $backup_file"
    echo -e "${GREEN}✓ 配置文件已备份${NC}"
}

init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
        chmod 600 "$CONFIG_FILE"
        log "INFO" "初始化配置文件"
    fi
}

# ========================================
# 核心功能模块
# ========================================
deploy_realm() {
    log "INFO" "开始安装Realm"
    echo -e "${BLUE}▶ 正在安装Realm...${NC}"
    
    # 检查架构
    case $(uname -m) in
        x86_64) ARCH="x86_64" ;;
        aarch64) ARCH="aarch64" ;;
        *) 
            echo -e "${RED}✖ 不支持的架构: $(uname -m)${NC}"
            log "ERROR" "不支持的架构: $(uname -m)"
            read -rp "按回车键继续..." dummy
            return 1
            ;;
    esac

    mkdir -p "$REALM_DIR"
    cd "$REALM_DIR" || return 1

    # 获取最新版本号
    echo -e "${BLUE}▶ 正在检测最新版本...${NC}"
    LATEST_VERSION=$(curl -sL https://github.com/zhboner/realm/releases | grep -oE '/zhboner/realm/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d'/' -f6 | tr -d 'v')
    
    # 版本号验证
    if [[ -z "$LATEST_VERSION" || ! "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "WARN" "版本检测失败，使用备用版本2.7.0"
        LATEST_VERSION="2.7.0"
        echo -e "${YELLOW}⚠ 无法获取最新版本，使用备用版本 v${LATEST_VERSION}${NC}"
    else
        echo -e "${GREEN}✓ 检测到最新版本 v${LATEST_VERSION}${NC}"
    fi

    # 下载最新版本
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v${LATEST_VERSION}/realm-${ARCH}-unknown-linux-gnu.tar.gz"
    echo -e "${BLUE}▶ 正在下载 Realm v${LATEST_VERSION}...${NC}"
    if ! wget --show-progress -qO realm.tar.gz "$DOWNLOAD_URL"; then
        log "ERROR" "安装失败：下载错误"
        echo -e "${RED}✖ 文件下载失败，请检查：${NC}"
        echo -e "1. 网络连接状态"
        echo -e "2. GitHub访问权限"
        echo -e "3. 手动验证下载地址: $DOWNLOAD_URL"
        read -rp "按回车键继续..." dummy
        return 1
    fi

    # 解压安装
    tar -xzf realm.tar.gz
    chmod +x realm
    rm realm.tar.gz

    # 初始化配置文件
    init_config

    # 创建服务文件
    echo -e "${BLUE}▶ 创建系统服务...${NC}"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$REALM_DIR/realm -c $CONFIG_FILE
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log "INFO" "安装成功"
    echo -e "${GREEN}✔ 安装完成！${NC}"
    read -rp "按回车键返回主菜单..." dummy
}

# 查看转发规则
show_rules() {
    echo -e "                   ${YELLOW}当前 Realm 转发规则${NC}                   "
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}${YELLOW}"
    printf "%-5s| %-30s| %-40s| %-20s\n" "序号" "   本地地址:端口 " "   目标地址:端口 " "备注"
    echo -e "${NC}${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
    
    local IFS=$'\n'
    local lines=($(grep -n '^\[\[endpoints\]\]' "$CONFIG_FILE"))
    
    if [ ${#lines[@]} -eq 0 ]; then
        echo -e "没有发现任何转发规则。"
    else
        local index=1
        for line in "${lines[@]}"; do
            local line_number=$(echo "$line" | cut -d ':' -f 1)
            local remark=$(sed -n "$((line_number + 1))p" "$CONFIG_FILE" | grep "^# 备注:" | cut -d ':' -f 2 | sed 's/^[[:space:]]*//')
            local listen_info=$(sed -n "$((line_number + 2))p" "$CONFIG_FILE" | cut -d '"' -f 2)
            local remote_info=$(sed -n "$((line_number + 3))p" "$CONFIG_FILE" | cut -d '"' -f 2)

            printf "%-4s| %-24s| %-34s| %-20s\n" " $index" "$listen_info" "$remote_info" "$remark"
            echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
            ((index++))
        done
    fi

    read -rp "按回车键返回主菜单..." dummy
}

# 添加转发规则
add_rule() {
    log "INFO" "开始添加转发规则"
    while : ; do
        echo -e "\n${BLUE}▶ 添加新规则（输入 q 退出）${NC}"
        
        # 获取输入
        read -rp "本地监听端口 (1-65535): " local_port
        [ "$local_port" = "q" ] && break
        
        if ! validate_port "$local_port"; then
            echo -e "${RED}✖ 无效的端口号！${NC}"
            continue
        fi
        
        read -rp "目标服务器IP或域名: " remote_ip
        if ! validate_ip_or_domain "$remote_ip"; then
            echo -e "${RED}✖ 无效的IP地址或域名！${NC}"
            continue
        fi
        
        read -rp "目标端口 (1-65535): " remote_port
        if ! validate_port "$remote_port"; then
            echo -e "${RED}✖ 无效的端口号！${NC}"
            continue
        fi
        
        read -rp "规则备注: " remark

        # 监听模式选择
        echo -e "\n${YELLOW}请选择监听模式：${NC}"
        echo "1) 双栈监听 [::]:${local_port} (默认)"
        echo "2) 仅IPv4监听 0.0.0.0:${local_port}"
        echo "3) 自定义监听地址"
        read -rp "请输入选项 [1-3] (默认1): " ip_choice
        ip_choice=${ip_choice:-1}

        case $ip_choice in
            1)
                listen_addr="[::]:$local_port"
                desc="双栈监听"
                ;;
            2)
                listen_addr="0.0.0.0:$local_port"
                desc="仅IPv4"
                ;;
            3)
                while : ; do
                    read -rp "请输入完整监听地址(格式如 0.0.0.0:80 或 [::]:443): " listen_addr
                    if ! validate_listen_addr "$listen_addr"; then
                        echo -e "${RED}✖ 格式错误！示例: 0.0.0.0:80 或 [::]:443${NC}"
                        continue
                    fi
                    break
                done
                desc="自定义监听"
                ;;
            *)
                echo -e "${RED}无效选择，使用默认值！${NC}"
                listen_addr="[::]:$local_port"
                desc="双栈监听"
                ;;
        esac

        # 确认添加
        echo -e "\n${YELLOW}即将添加以下规则：${NC}"
        echo -e "监听地址: $listen_addr"
        echo -e "目标地址: $remote_ip:$remote_port"
        echo -e "备注: $remark"
        
        read -rp "确认添加？(y/n): " confirm
        [[ "$confirm" != "y" ]] && continue

        # 备份配置
        backup_config

        # 写入配置文件
        cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
# 备注: $remark
listen = "$listen_addr"
remote = "$remote_ip:$remote_port"
EOF

        # 检查IPv6配置
        if [[ "$listen_addr" == *"["*"]"* ]] && ! grep -q "ipv6_only = false" "$CONFIG_FILE"; then
            sed -i '/^\[network\]/a ipv6_only = false' "$CONFIG_FILE"
            log "INFO" "已添加ipv6_only = false配置"
        fi

        # 重启服务
        if ! service_control restart; then
            echo -e "${RED}✖ 服务重启失败，请检查配置${NC}"
            log "ERROR" "服务重启失败"
            read -rp "按回车键继续..." dummy
            return 1
        fi

        log "INFO" "规则已添加: $listen_addr → $remote_ip:$remote_port"
        echo -e "${GREEN}✔ 添加成功！${NC}"
        
        read -rp "继续添加？(y/n): " cont
        [[ "$cont" != "y" ]] && break
    done
}

# 删除转发规则
delete_rule() {
    log "INFO" "开始删除转发规则"
    show_rules
    
    local IFS=$'\n'
    local rules=($(grep -n '^\[\[endpoints\]\]' "$CONFIG_FILE"))
    
    if [ ${#rules[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        read -rp "按回车键继续..." dummy
        return
    fi

    echo "请输入要删除的转发规则序号，直接按回车返回主菜单。"
    read -p "选择: " choice
    
    if [ -z "$choice" ]; then
        echo "返回主菜单。"
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#rules[@]} )); then
        echo -e "${RED}无效选择，请输入有效序号${NC}"
        read -rp "按回车键继续..." dummy
        return
    fi

    # 显示要删除的规则详情
    local selected_line=${rules[$((choice-1))]}
    local start_line=$(echo "$selected_line" | cut -d ':' -f 1)
    local remark=$(sed -n "$((start_line + 1))p" "$CONFIG_FILE" | grep "^# 备注:" | cut -d ':' -f 2)
    local listen_info=$(sed -n "$((start_line + 2))p" "$CONFIG_FILE" | cut -d '"' -f 2)
    local remote_info=$(sed -n "$((start_line + 3))p" "$CONFIG_FILE" | cut -d '"' -f 2)

    echo -e "\n${YELLOW}即将删除以下规则：${NC}"
    echo -e "监听地址: $listen_info"
    echo -e "目标地址: $remote_info"
    echo -e "备注: $remark"
    
    read -rp "确认删除？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    # 备份配置
    backup_config

    # 计算删除范围 ([[endpoints]]块共5行)
    local end_line=$((start_line + 4))

    # 执行删除
    sed -i "${start_line},${end_line}d" "$CONFIG_FILE"
    sed -i '/^$/d' "$CONFIG_FILE"  # 清理空行

    # 重启服务
    if ! service_control restart; then
        echo -e "${RED}✖ 服务重启失败，请检查配置${NC}"
        log "ERROR" "服务重启失败"
        read -rp "按回车键继续..." dummy
        return 1
    fi

    log "INFO" "已删除规则: $listen_info → $remote_info"
    echo -e "${GREEN}✔ 规则删除成功${NC}"
    read -rp "按回车键继续..." dummy
}

# 服务控制
service_control() {
    case $1 in
        start)
            log "INFO" "启动服务"
            if ! sudo systemctl unmask realm.service; then
                log "ERROR" "取消服务屏蔽失败"
                return 1
            fi
            if ! sudo systemctl daemon-reload; then
                log "ERROR" "服务重载失败"
                return 1
            fi
            if ! sudo systemctl restart realm.service; then
                log "ERROR" "服务启动失败"
                return 1
            fi
            if ! sudo systemctl enable --now realm.service; then
                log "ERROR" "服务启用失败"
                return 1
            fi
            log "INFO" "服务已启动"
            echo -e "${GREEN}✔ 服务已启动${NC}"
            return 0
            ;;
        stop)
            log "INFO" "停止服务"
            if ! sudo systemctl stop realm.service; then
                log "ERROR" "服务停止失败"
                return 1
            fi
            log "INFO" "服务已停止"
            echo -e "${YELLOW}⚠ 服务已停止${NC}"
            return 0
            ;;
        restart)
            log "INFO" "重启服务"
            if ! sudo systemctl unmask realm.service; then
                log "ERROR" "取消服务屏蔽失败"
                return 1
            fi
            if ! sudo systemctl daemon-reload; then
                log "ERROR" "服务重载失败"
                return 1
            fi
            if ! sudo systemctl restart realm.service; then
                log "ERROR" "服务重启失败"
                return 1
            fi
            log "INFO" "服务已重启"
            echo -e "${GREEN}✔ 服务已重启${NC}"
            return 0
            ;;
        status)
            if systemctl is-active --quiet realm.service; then
                echo -e "${GREEN}● 服务运行中${NC}"
                return 0
            else
                echo -e "${RED}● 服务未运行${NC}"
                return 1
            fi
            ;;
    esac
}

# 定时任务管理
manage_cron() {
    echo -e "\n${YELLOW}定时任务管理：${NC}"
    echo "1. 添加每日重启任务"
    echo "2. 删除所有任务"
    echo "3. 查看当前任务"
    read -rp "请选择: " choice

    case $choice in
        1)
            read -rp "输入每日重启时间 (0-23): " hour
            if [[ "$hour" =~ ^[0-9]+$ ]] && (( hour >= 0 && hour <= 23 )); then
                (crontab -l 2>/dev/null; echo "0 $hour * * * /usr/bin/systemctl restart realm") | crontab -
                log "INFO" "添加定时任务：每日 $hour 时重启"
                echo -e "${GREEN}✔ 定时任务已添加！${NC}"
            else
                echo -e "${RED}✖ 无效时间！${NC}"
            fi
            read -rp "按回车键继续..." dummy
            ;;
        2)
            crontab -l | grep -v "realm" | crontab -
            log "INFO" "清除定时任务"
            echo -e "${YELLOW}✔ 定时任务已清除！${NC}"
            read -rp "按回车键继续..." dummy
            ;;
        3)
            echo -e "\n${BLUE}当前定时任务：${NC}"
            crontab -l | grep --color=auto "realm"
            read -rp "按回车键继续..." dummy
            ;;
        *)
            echo -e "${RED}✖ 无效选择！${NC}"
            read -rp "按回车键继续..." dummy
            ;;
    esac
}

# 卸载功能
uninstall() {
    log "INFO" "开始卸载"
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
    
    read -rp "确认要完全卸载Realm？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    
    # 停止服务
    if systemctl is-active --quiet realm.service; then
        systemctl stop realm.service
    fi
    
    # 禁用服务
    if systemctl is-enabled --quiet realm.service; then
        systemctl disable realm.service
    fi
    
    # 删除文件和目录
    rm -f "$SERVICE_FILE"
    rm -rf "$REALM_DIR"
    systemctl daemon-reload
    
    # 清理定时任务
    crontab -l | grep -v "realm" | crontab -
    
    log "INFO" "卸载完成"
    echo -e "${GREEN}✔ 已完全卸载！${NC}"
    read -rp "按回车键退出..." dummy
    exit 0
}

# ========================================
# 验证函数
# ========================================
validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_ip_or_domain() {
    local input=$1
    # 允许IPv4
    if [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        IFS='.' read -ra ip_parts <<< "$input"
        for part in "${ip_parts[@]}"; do
            (( part >= 0 && part <= 255 )) || return 1
        done
        return 0
    fi
    # 允许域名（简单校验）
    [[ "$input" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && return 0
    return 1
}

validate_listen_addr() {
    local addr=$1
    [[ "$addr" =~ ^([0-9.]+|\[[:0-9a-fA-F]+\]):[0-9]+$ ]]
}

# ========================================
# 安装状态检测
# ========================================
check_installed() {
    if [[ -f "$REALM_DIR/realm" && -f "$SERVICE_FILE" ]]; then
        echo -e "${GREEN}已安装${NC}"
    else
        echo -e "${RED}未安装${NC}"
    fi
}

# ========================================
# 主界面
# ========================================
main_menu() {
    clear
    init_check

    # 处理跳过更新检查参数
    local skip_update=false
    if [[ "$1" == "--no-update" ]]; then
        skip_update=true
        shift
    fi

    # 首次运行检查更新
    if ! $skip_update; then
        check_update && perform_update "$@"
    fi

    while true; do
        echo -e "${YELLOW}▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂${NC}"
        echo -e "  "
        echo -e "                ${BLUE}Realm 高级管理脚本 v$CURRENT_VERSION${NC}"
        echo -e "        修改by：Lee    修改日期：2025/4/1"
        echo -e "        修改内容:1.基本重做了脚本"
        echo -e "                 2.新增了自动更新脚本"
        echo -e "                 3.realm支持检测最新版本"
        echo -e "    (1)安装前请先更新系统软件包，缺少命令可能无法安装"
        echo -e "    (2)如果启动失败请检查 /root/realm/config.toml下有无多余配置或者卸载后重新配置"
        echo -e "    (3)该脚本只在debian系统下测试，未做其他系统适配，安装命令有别，可能无法启动。如若遇到问题，请自行解决"
        echo -e "    仓库：https://github.com/qq1055506789/realm"
        echo -e "        删除该脚本 rm realm.sh"
        echo -e "        运行 wget -N https://raw.githubusercontent.com/qq1055506789/realm/refs/heads/main/realm.sh && chmod +x realm.sh && ./realm.sh"
        echo -e "${YELLOW}▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂${NC}"
        echo -e "  "
        echo -e "${YELLOW}服务状态：$(service_control status)${NC}"
        echo -e "${YELLOW}安装状态：$(check_installed)${NC}"
        echo -e "  "
        echo -e "${YELLOW}------------------${NC}"
        echo "1. 安装/更新 Realm"
        echo -e "${YELLOW}------------------${NC}"
        echo "2. 添加转发规则"
        echo "3. 查看转发规则"
        echo "4. 删除转发规则"
        echo -e "${YELLOW}------------------${NC}"
        echo "5. 启动服务"
        echo "6. 停止服务"
        echo "7. 重启服务"
        echo -e "${YELLOW}------------------${NC}"
        echo "8. 定时任务管理"
        echo "9. 查看日志"
        echo -e "${YELLOW}------------------${NC}"
        echo "10. 完全卸载"
        echo -e "${YELLOW}------------------${NC}"
        echo "0. 退出脚本"
        echo -e "${YELLOW}------------------${NC}"

        read -rp "请输入选项: " choice
        case $choice in
            1) deploy_realm ;;
            2) add_rule ;;
            3) show_rules ;;
            4) delete_rule ;;
            5) service_control start ;;
            6) service_control stop ;;
            7) service_control restart ;;
            8) manage_cron ;;
            9) 
                echo -e "\n${BLUE}最近日志：${NC}"
                tail -n 10 "$LOG_FILE" 
                read -rp "按回车键继续..." dummy
                ;;
            10) uninstall ;;
            0) 
                echo -e "${GREEN}再见！${NC}"
                exit 0 
                ;;
            *) 
                echo -e "${RED}无效选项！${NC}"
                read -rp "按回车键继续..." dummy
                ;;
        esac
        clear
    done
}

# ========================================
# 脚本入口
# ========================================
main_menu "$@"
