#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN='\033[0m'

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")
PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove" "yum -y remove")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove")

[[ $EUID -ne 0 ]] && red "注意：请在root用户下运行脚本" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i"
    if [[ -n $SYS ]]; then
        break
    fi
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        if [[ -n $SYSTEM ]]; then
            break
        fi
    fi
done

[[ -z $SYSTEM ]] && red "不支持当前VPS系统, 请使用主流的操作系统" && exit 1

back2menu() {
    echo ""
    green "所选命令操作执行完成"
    read -rp "请输入“y”退出, 或按任意键回到主菜单：" back2menuInput
    case "$back2menuInput" in
        y) exit 1 ;;
        *) menu ;;
    esac
}

install_base(){
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl
    if [[ $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_INSTALL[int]} cronie
        systemctl start crond
        systemctl enable crond
    else
        ${PACKAGE_INSTALL[int]} cron
        systemctl start cron
        systemctl enable cron
    fi
}

install_acme(){
    install_base
    read -rp "请输入注册邮箱 (例: admin@gmail.com, 或留空自动生成一个gmail邮箱): " acmeEmail
    if [[ -z $acmeEmail ]]; then
        autoEmail=$(date +%s%N | md5sum | cut -c 1-16)
        acmeEmail=$autoEmail@gmail.com
        yellow "已取消设置邮箱, 使用自动生成的gmail邮箱: $acmeEmail"
    fi
    curl https://get.acme.sh | sh -s email=$acmeEmail
    source ~/.bashrc
    bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    if [[ -n $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
        green "Acme.sh证书申请脚本安装成功!"
    else
        red "抱歉, Acme.sh证书申请脚本安装失败"
        green "建议如下："
        yellow "1. 检查VPS的网络环境"
        yellow "2. 脚本可能跟不上时代, 建议截图发布到GitHub Issues询问"
    fi
    back2menu
}

check_80(){
    # 感谢Wulabing前辈提供的检查80端口思路
    # Source: https://github.com/wulabing/Xray_onekey
    
    if [[ -z $(type -P lsof) ]]; then
        if [[ ! $SYSTEM == "CentOS" ]]; then
            ${PACKAGE_UPDATE[int]}
        fi
        ${PACKAGE_INSTALL[int]} lsof
    fi
    
    yellow "正在检测80端口是否占用..."
    sleep 1
    
    if [[  $(lsof -i:"80" | grep -i -c "listen") -eq 0 ]]; then
        green "检测到目前80端口未被占用"
        sleep 1
    else
        red "检测到目前80端口被其他程序被占用，以下为占用程序信息"
        lsof -i:"80"
        read -rp "如需结束占用进程请按Y，按其他键则退出 [Y/N]: " yn
        if [[ $yn =~ "Y"|"y" ]]; then
            lsof -i:"80" | awk '{print $2}' | grep -v "PID" | xargs kill -9
            sleep 1
        else
            exit 1
        fi
    fi
}

acme_standalone(){
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && red "未安装acme.sh, 无法执行操作" && exit 1
    check_80
    WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
        wg-quick down wgcf >/dev/null 2>&1
        systemctl stop warp-go >/dev/null 2>&1
    fi
    
    ipv4=$(curl -s4m8 ip.p3terx.com -k | sed -n 1p)
    ipv6=$(curl -s6m8 ip.p3terx.com -k | sed -n 1p)
    
    echo ""
    yellow "在使用80端口申请模式时, 请先将您的域名解析至你的VPS的真实IP地址, 否则会导致证书申请失败"
    echo ""
    if [[ -n $ipv4 && -n $ipv6 ]]; then
        echo -e "VPS的真实IPv4地址为: ${GREEN} $ipv4 ${PLAIN}"
        echo -e "VPS的真实IPv6地址为: ${GREEN} $ipv6 ${PLAIN}"
    elif [[ -n $ipv4 && -z $ipv6 ]]; then
        echo -e "VPS的真实IPv4地址为: ${GREEN} $ipv4 ${PLAIN}"
    elif [[ -z $ipv4 && -n $ipv6 ]]; then
        echo -e "VPS的真实IPv6地址为: ${GREEN} $ipv6 ${PLAIN}"
    fi
    echo ""
    read -rp "请输入解析完成的域名: " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1
    green "已输入的域名：$domain" && sleep 1
    domainIP=$(curl -sm8 ipget.net/?ip="${domain}")
    
    if [[ $domainIP == $ipv6 ]]; then
        bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --listen-v6 --insecure
    fi
    if [[ $domainIP == $ipv4 ]]; then
        bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --insecure
    fi
    
    if [[ -n $(echo $domainIP | grep nginx) ]]; then
        if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
            wg-quick up wgcf >/dev/null 2>&1
        fi
        if [[ -a "/opt/warp-go/warp-go" ]]; then
            systemctl start warp-go 
        fi
        yellow "域名解析失败, 请检查域名是否正确填写或等待解析完成再执行脚本"
        exit 1
    elif [[ -n $(echo $domainIP | grep ":") || -n $(echo $domainIP | grep ".") ]]; then
        if [[ $domainIP != $ipv4 ]] && [[ $domainIP != $ipv6 ]]; then
            if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
                wg-quick up wgcf >/dev/null 2>&1
            fi
            if [[ -a "/opt/warp-go/warp-go" ]]; then
                systemctl start warp-go 
            fi
            green "域名 ${domain} 目前解析的IP: ($domainIP)"
            red "当前域名解析的IP与当前VPS使用的真实IP不匹配"
            green "建议如下："
            yellow "1. 请确保CloudFlare小云朵为关闭状态(仅限DNS), 其他域名解析或CDN网站设置同理"
            yellow "2. 请检查DNS解析设置的IP是否为VPS的真实IP"
            yellow "3. 脚本可能跟不上时代, 建议截图发布到GitHub Issues、GitLab Issues、论坛或TG群询问"
            exit 1
        fi
    fi
    
    bash ~/.acme.sh/acme.sh --install-cert -d ${domain} --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
    checktls
}

acme_cfapiTLD(){
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && red "未安装Acme.sh, 无法执行操作" && exit 1
    ipv4=$(curl -s4m8 ip.p3terx.com -k | sed -n 1p)
    ipv6=$(curl -s6m8 ip.p3terx.com -k | sed -n 1p)
    read -rp "请输入需要申请证书的域名: " domain
    if [[ $(echo ${domain:0-2}) =~ cf|ga|gq|ml|tk ]]; then
        red "检测为Freenom免费域名, 由于CloudFlare API不支持, 故无法使用本模式申请!"
        back2menu
    fi
    read -rp "请输入CloudFlare Global API Key: " GAK
    [[ -z $GAK ]] && red "未输入CloudFlare Global API Key, 无法执行操作!" && exit 1
    export CF_Key="$GAK"
    read -rp "请输入CloudFlare的登录邮箱: " CFemail
    [[ -z $domain ]] && red "未输入CloudFlare的登录邮箱, 无法执行操作!" && exit 1
    export CF_Email="$CFemail"
    if [[ -z $ipv4 ]]; then
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" -k ec-256 --listen-v6 --insecure
    else
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" -k ec-256 --insecure
    fi
    bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
    checktls
}

acme_cfapiNTLD(){
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && red "未安装acme.sh, 无法执行操作" && exit 1
    ipv4=$(curl -s4m8 ip.p3terx.com -k | sed -n 1p)
    ipv6=$(curl -s6m8 ip.p3terx.com -k | sed -n 1p)
    read -rp "请输入需要申请证书的泛域名 (输入格式：example.com): " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1
    if [[ $(echo ${domain:0-2}) =~ cf|ga|gq|ml|tk ]]; then
        red "检测为Freenom免费域名, 由于CloudFlare API不支持, 故无法使用本模式申请!"
        back2menu
    fi
    read -rp "请输入CloudFlare Global API Key: " GAK
    [[ -z $GAK ]] && red "未输入CloudFlare Global API Key, 无法执行操作！" && exit 1
    export CF_Key="$GAK"
    read -rp "请输入CloudFlare的登录邮箱: " CFemail
    [[ -z $domain ]] && red "未输入CloudFlare的登录邮箱, 无法执行操作!" && exit 1
    export CF_Email="$CFemail"
    if [[ -z $ipv4 ]]; then
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "*.${domain}" -d "${domain}" -k ec-256 --listen-v6 --insecure
    else
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "*.${domain}" -d "${domain}" -k ec-256 --insecure
    fi
    bash ~/.acme.sh/acme.sh --install-cert -d "*.${domain}" --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
    checktls
}

checktls() {
    if [[ -f /root/cert.crt && -f /root/private.key ]]; then
        if [[ -s /root/cert.crt && -s /root/private.key ]]; then
            if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
                wg-quick up wgcf >/dev/null 2>&1
            fi
            if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
                wg-quick up wgcf >/dev/null 2>&1
            fi
            if [[ -a "/opt/warp-go/warp-go" ]]; then
                systemctl start warp-go 
            fi
            echo $domain > /root/ca.log
            sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
            echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab
            green "证书申请成功! 脚本申请到的证书 (cert.crt) 和私钥 (private.key) 文件已保存到 /root 文件夹下"
            yellow "证书crt文件路径如下: /root/cert.crt"
            yellow "私钥key文件路径如下: /root/private.key"
            back2menu
        else
            if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
                wg-quick up wgcf >/dev/null 2>&1
            fi
            if [[ -a "/opt/warp-go/warp-go" ]]; then
                systemctl start warp-go 
            fi
            red "很抱歉，证书申请失败"
            green "建议如下: "
            yellow "1. 自行检测防火墙是否打开, 如使用80端口申请模式时, 请关闭防火墙或放行80端口"
            yellow "2. 同一域名多次申请可能会触发Let's Encrypt官方风控, 请尝试使用脚本菜单的9选项更换证书颁发机构, 再重试申请证书, 或更换域名、或等待7天后再尝试执行脚本"
            yellow "3. 脚本可能跟不上时代, 建议截图发布到GitHub Issues询问"
            back2menu
        fi
    fi
}

view_cert(){
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装acme.sh, 无法执行操作!" && exit 1
    bash ~/.acme.sh/acme.sh --list
    back2menu
}

revoke_cert() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装acme.sh, 无法执行操作!" && exit 1
    bash ~/.acme.sh/acme.sh --list
    read -rp "请输入要撤销的域名证书 (复制Main_Domain下显示的域名): " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作!" && exit 1
    if [[ -n $(bash ~/.acme.sh/acme.sh --list | grep $domain) ]]; then
        bash ~/.acme.sh/acme.sh --revoke -d ${domain} --ecc
        bash ~/.acme.sh/acme.sh --remove -d ${domain} --ecc
        rm -rf ~/.acme.sh/${domain}_ecc
        rm -f /root/cert.crt /root/private.key
        green "撤销${domain}的域名证书成功"
        back2menu
    else
        red "未找到${domain}的域名证书, 请自行检查!"
        back2menu
    fi
}

renew_cert() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装acme.sh, 无法执行操作!" && exit 1
    bash ~/.acme.sh/acme.sh --list
    read -rp "请输入要续期的域名证书 (复制Main_Domain下显示的域名): " domain
    [[ -z $domain ]] && red "未输入域名, 无法执行操作!" && exit 1
    if [[ -n $(bash ~/.acme.sh/acme.sh --list | grep $domain) ]]; then
        bash ~/.acme.sh/acme.sh --renew -d ${domain} --force --ecc
        checktls
        back2menu
    else
        red "未找到${domain}的域名证书，请再次检查域名输入正确"
        back2menu
    fi
}

switch_provider(){
    yellow "请选择证书提供商, 默认通过 Letsencrypt.org 来申请证书 "
    yellow "如果证书申请失败, 例如一天内通过 Letsencrypt.org 申请次数过多, 可选 BuyPass.com 或 ZeroSSL.com 来申请."
    echo -e " ${GREEN}1.${PLAIN} Letsencrypt.org"
    echo -e " ${GREEN}2.${PLAIN} BuyPass.com"
    echo -e " ${GREEN}3.${PLAIN} ZeroSSL.com"
    read -rp "请选择证书提供商 [1-3，默认1]: " provider
    case $provider in
        2) bash ~/.acme.sh/acme.sh --set-default-ca --server buypass && green "切换证书提供商为 BuyPass.com 成功！" ;;
        3) bash ~/.acme.sh/acme.sh --set-default-ca --server zerossl && green "切换证书提供商为 ZeroSSL.com 成功！" ;;
        *) bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt && green "切换证书提供商为 Letsencrypt.org 成功！" ;;
    esac
    back2menu
}

uninstall() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装Acme.sh, 卸载程序无法执行!" && exit 1
    ~/.acme.sh/acme.sh --uninstall
    sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
    rm -rf ~/.acme.sh
    green "Acme  一键申请证书脚本已彻底卸载!"
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#                   ${RED}Acme  证书一键申请脚本${PLAIN}                  #"
    echo -e "# ${GREEN}作者${PLAIN}: MisakaNo の 小破站                                  #"
    echo -e "# ${GREEN}博客${PLAIN}: https://blog.misaka.rest                            #"
    echo -e "# ${GREEN}GitHub 项目${PLAIN}: https://github.com/Misaka-blog               #"
    echo -e "# ${GREEN}Telegram 频道${PLAIN}: https://t.me/misakanocchannel              #"
    echo -e "# ${GREEN}Telegram 群组${PLAIN}: https://t.me/misakanoc                     #"
    echo -e "# ${GREEN}YouTube 频道${PLAIN}: https://www.youtube.com/@misaka-blog        #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 安装 Acme.sh 域名证书申请脚本"
    echo -e " ${GREEN}2.${PLAIN} ${RED}卸载 Acme.sh 域名证书申请脚本${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}3.${PLAIN} 申请单域名证书 ${YELLOW}(80端口申请)${PLAIN}"
    echo -e " ${GREEN}4.${PLAIN} 申请单域名证书 ${YELLOW}(CF API申请)${PLAIN} ${GREEN}(无需解析)${PLAIN} ${RED}(不支持freenom域名)${PLAIN}"
    echo -e " ${GREEN}5.${PLAIN} 申请泛域名证书 ${YELLOW}(CF API申请)${PLAIN} ${GREEN}(无需解析)${PLAIN} ${RED}(不支持freenom域名)${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}6.${PLAIN} 查看已申请的证书"
    echo -e " ${GREEN}7.${PLAIN} 撤销并删除已申请的证书"
    echo -e " ${GREEN}8.${PLAIN} 手动续期已申请的证书"
    echo -e " ${GREEN}9.${PLAIN} 切换证书颁发机构"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo ""
    read -rp "请输入选项 [0-9]: " NumberInput
    case "$NumberInput" in
        1) install_acme ;;
        2) uninstall ;;
        3) acme_standalone ;;
        4) acme_cfapiTLD ;;
        5) acme_cfapiNTLD ;;
        6) view_cert ;;
        7) revoke_cert ;;
        8) renew_cert ;;
        9) switch_provider ;;
        *) exit 1 ;;
    esac
}

menu
