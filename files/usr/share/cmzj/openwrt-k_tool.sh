#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2023-2024 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: MIT

trap 'rm -rf "$TMPDIR"' EXIT
TMPDIR=$(mktemp -d) || exit 1
cmd=$1
arg=$2


main() {
    check
    case "${cmd}" in
        update)
            check_curl
            case "${arg}" in
                rules)
                    update_rule
                    ;;
                packages)
                    update_package
                    ;;
                firmware)
                    update_firmware
                    ;;
                tool)
                    update_tool
                    ;;
                *)
                 echo "不支持的参数 $arg"            
            esac
            ;;
        info)
            show_info
            ;;
        help)
            usage
            ;;
        --help)
            usage
            ;;
        *)
        echo "不支持的命令 $cmd"
        usage
    esac
}

check() {
    if [ "$(grep -c "^ID_LIKE=\"lede openwrt\"$" /etc/os-release)" -eq '0' ];then
        echo "不支持非openwrt类系统"
        exit 1
    fi
}

show_info() {
    echo "固件系统："$(sed -n  "/^NAME=\"/p" /etc/os-release | sed -e "s/NAME=\"//g" -e "s/\"//g" )
    echo "固件版本："$(sed -n  "/^DISTRIB_RELEASE=\'/p" /etc/openwrt_release|sed -e "s/DISTRIB_RELEASE='//g" -e "s/'//g" )
    echo "固件架构："$(sed -n  "/^DISTRIB_ARCH=\'/p" /etc/openwrt_release|sed -e "s/DISTRIB_ARCH='//g" -e "s/'//g" )
    if  [ -e "/etc/openwrt-k_info" ]; then
        echo "固件编译者："$(sed -n  "/^COMPILER=\"/p" /etc/openwrt-k_info | sed -e "s/COMPILER=\"//g" -e "s/\"//g" )
        echo "固件编译仓库地址："$(sed -n  "/REPOSITORY_URL=\"/p" /etc/openwrt-k_info | sed -e "s/REPOSITORY_URL=\"//g" -e "s/\"//g" )
        echo "固件编译时间：UTC+8 "$(sed -n  "/^COMPILE_START_TIME=\"/p" /etc/openwrt-k_info | sed -e "s/COMPILE_START_TIME=\"//g" -e "s/\"/时/g" -e "s/-/日/" -e "s/\./月/g" -e "s/月/年/" )
    elif [ "$(grep -c "Compiled by" /etc/openwrt_release)" -ne '0' ];then
        echo "固件编译者："$(sed -n  "/Compiled by /p" /etc/openwrt_release|sed -e "s/.*Compiled by //g" -e "s/'//g" )
    fi
}

check_curl(){
	which curl && return || 未找到curl
    echo "错误:未检测到依赖的包curl"
    exit 1
}

check_github(){
    echo "检测与github的连通性"
    echo "github.com"
    curl -o /dev/null --connect-timeout 5 -s -w %{time_namelookup}---%{time_connect}---%{time_starttransfer}---%{time_total}---%{speed_download}"\n" github.com || github_check_failed
    echo "api.github.com"
    curl -o /dev/null --connect-timeout 5 -s -w %{time_namelookup}---%{time_connect}---%{time_starttransfer}---%{time_total}---%{speed_download}"\n" api.github.com || github_check_failed
    echo "objects.githubusercontent.com"
    curl -o /dev/null --connect-timeout 5 -s -w %{time_namelookup}---%{time_connect}---%{time_starttransfer}---%{time_total}---%{speed_download}"\n" objects.githubusercontent.com || github_check_failed
}

github_check_failed(){
    echo github测试失败
    exit 1
}

# APK package names and versions both contain hyphens. Use the machine-readable
# manifest output rather than splitting apk list's human-readable package names.
detect_package_manager() {
    if command -v apk >/dev/null 2>&1; then
        PACKAGE_MANAGER=apk
    elif command -v opkg >/dev/null 2>&1; then
        PACKAGE_MANAGER=opkg
    else
        echo "错误：未找到 apk 或 opkg" >&2
        return 1
    fi
}

list_installed_packages() {
    case "$PACKAGE_MANAGER" in
        apk)
            package_list=$(apk list --installed --manifest) || return 1
            printf '%s\n' "$package_list" | awk 'NF == 2 { print $1 " - " $2 }'
            ;;
        opkg)
            opkg list-installed
            ;;
        *) return 1 ;;
    esac
}

package_installed() {
    case "$PACKAGE_MANAGER" in
        apk) apk info --exists "$1" >/dev/null 2>&1 ;;
        opkg)
            package_status=$(opkg status "$1" 2>/dev/null) || return 1
            printf '%s\n' "$package_status" | grep -q '^Status: .* installed$'
            ;;
        *) return 1 ;;
    esac
}

package_version_is_newer() {
    case "$PACKAGE_MANAGER" in
        apk) [ "$(apk version --test "$1" "$2")" = '<' ] ;;
        opkg) opkg compare-versions "$1" lt "$2" ;;
        *) return 1 ;;
    esac
}

find_package_updates() {
    awk -F ' - ' '
        NR == FNR { if (NF == 2) installed[$1] = $2; next }
        NF == 2 && ($1 in installed) && installed[$1] != $2 &&
            $1 != "kernel" && $1 !~ /^kmod-/ {
            print $1, installed[$1], $2
        }
    ' "$1" "$2" | while read -r package_name installed_version available_version; do
        if package_version_is_newer "$installed_version" "$available_version"; then
            printf '%s - %s\n' "$package_name" "$available_version"
        fi
    done
}

select_package_entries() {
    awk -F ' - ' -v manager="$PACKAGE_MANAGER" '
        NR == FNR { if (NF == 2) versions[$1] = $2; next }
        {
            entry = $0
            if (entry ~ /^\// || entry ~ /(^|\/)\.\.(\/|$)/) next
            basename = entry
            sub(/^.*\//, "", basename)
            for (name in versions) {
                if ((manager == "apk" && basename == name "-" versions[name] ".apk") ||
                    (manager == "opkg" && index(basename, name "_" versions[name] "_") == 1 && basename ~ /\.ipk$/)) {
                    print entry
                    break
                }
            }
        }
    ' "$1" "$2"
}

install_local_packages() {
    case "$PACKAGE_MANAGER" in
        apk)
            set -- "$1"/*.apk
            [ -f "$1" ] || return 1
            # Keep signature verification enabled. A release signed by another
            # build key must be installed through a full firmware upgrade.
            apk add --upgrade "$@"
            ;;
        opkg)
            set -- "$1"/*.ipk
            [ -f "$1" ] || return 1
            opkg install "$@"
            ;;
        *) return 1 ;;
    esac
}

update_rule(){
    detect_package_manager || exit 1
    check_github
    if ! type base64;then
        echo "错误:未检测到依赖的包base64" 
        exit 1
    fi
    if ! type sed;then
        echo "错误:未检测到依赖的包sed" 
        exit 1
    fi
    if package_installed aria2; then
        echo "开始更新aria2 BT Tracker" 
        export bt_tracker="$(curl -s -L --retry 3 --connect-timeout 20 https://github.com/XIU2/TrackersListCollection/raw/master/all_aria2.txt || curl  -s -L --retry 3 https://cf.trackerslist.com/all_aria2.txt)"
        if [ -z $bt_tracker ];then
            download_failed
        fi
        uci set aria2.main.bt_tracker=$bt_tracker
        uci commit aria2
        /etc/init.d/aria2 restart
        echo "更新aria2 BT Tracker完成" 
    else
        echo "未检测到aria2，跳过更新aria2 BT Tracker" 
    fi
    if package_installed luci-app-adguardhome && package_installed smartdns; then
        echo "开始更新adguardhome上游 DNS 服务器分流规则（/etc/AdGuardHome-dnslist(by cmzj).yaml)" 
        mkdir -p $TMPDIR/update/rule/adguardhome
        cd $TMPDIR/update/rule/adguardhome
        [[ -d $TMPDIR ]] && rm -rf $TMPDIR/update/rule/adguardhome/* || exit 1
        curl -s -L --retry 6 --connect-timeout 20 "https://raw.githubusercontent.com/hexsen929/OpenWrt-K/refs/heads/main/files/etc/AdGuardHome-dnslist(by%20cmzj).yaml" -o "AdGuardHomednslist" || download_failed
        cat ./AdGuardHomednslist > /etc/AdGuardHome-dnslist"(by cmzj)".yaml
        /etc/init.d/AdGuardHome restart
        echo "更新adguardhome上游 DNS 服务器分流规则（/etc/AdGuardHome-dnslist(by cmzj).yaml)完成"
    else
        echo "未检测到luci-app-adguardhome与smartdns或其中之一，跳过更新adguardhome上游 DNS 服务器分流规则" 
    fi
    if package_installed luci-app-openclash; then
        echo "开始更新openclash直连规则(by 沉默の金)与代理规则(by 沉默の金)"
        mkdir -p $TMPDIR/update/rule/openclash
        cd $TMPDIR/update/rule/openclash
        curl -s -L --retry 3 https://raw.githubusercontent.com/hexsen929/OpenWrt-K/main/files/etc/openclash/rule_provider/ProxyRule-chenmozhijin.yaml -o ProxyRule-chenmozhijin.yaml || download_failed
        curl -s -L --retry 3 https://raw.githubusercontent.com/hexsen929/OpenWrt-K/main/files/etc/openclash/rule_provider/DirectRule-chenmozhijin.yaml -o DirectRule-chenmozhijin.yaml || download_failed
        curl -s -L --retry 3 https://raw.githubusercontent.com/hexsen929/OpenWrt-K/main/files/etc/openclash/rule_provider/HKMOTWRule-chenmozhijin.yaml -o HKMOTWRule-chenmozhijin.yaml || download_failed
        if [ "$(pidof clash)" ] ;then
            echo "检测到clash启动，关闭openclash"
            /etc/init.d/openclash stop
            if [ "$(grep -c "^代理规则(by 沉默の金)" /usr/share/openclash/res/rule_providers.list)" -eq '0' ];then
                sed -i '1i 代理规则(by 沉默の金),沉默の金,classical,chenmozhijin/OpenWrt-K/main/files/etc/openclash/rule_provider/,ProxyRule-chenmozhijin.yaml' "/usr/share/openclash/res/rule_providers.list"
            fi
            if [ "$(grep -c "^直连规则(by 沉默の金)" /usr/share/openclash/res/rule_providers.list)" -eq '0' ];then
                sed -i '1i 直连规则(by 沉默の金),沉默の金,classical,chenmozhijin/OpenWrt-K/main/files/etc/openclash/rule_provider/,DirectRule-chenmozhijin.yaml' "/usr/share/openclash/res/rule_providers.list"
            fi
            if [ "$(grep -c "^港澳台规则(by 沉默の金)" /usr/share/openclash/res/rule_providers.list)" -eq '0' ];then
                sed -i '1i 港澳台规则(by 沉默の金),沉默の金,classical,chenmozhijin/OpenWrt-K/main/files/etc/openclash/rule_provider/,HKMOTWRule-chenmozhijin.yaml' "/usr/share/openclash/res/rule_providers.list"
            fi
            rm -rf /etc/openclash/rule_provider/ProxyRule-chenmozhijin.yaml /etc/openclash/rule_provider/DirectRule-chenmozhijin.yaml
            mv -f ProxyRule-chenmozhijin.yaml /etc/openclash/rule_provider/ProxyRule-chenmozhijin.yaml
            mv -f DirectRule-chenmozhijin.yaml /etc/openclash/rule_provider/DirectRule-chenmozhijin.yaml
            mv -f HKMOTWRule-chenmozhijin.yaml /etc/openclash/rule_provider/HKMOTWRule-chenmozhijin.yaml
            echo "重启openclash"
            /etc/init.d/openclash restart
        else
            if [ "$(grep -c "^代理规则(by 沉默の金)" /usr/share/openclash/res/rule_providers.list)" -eq '0' ];then
                sed -i '1i 代理规则(by 沉默の金),沉默の金,classical,chenmozhijin/OpenWrt-K/main/files/etc/openclash/rule_provider/,ProxyRule-chenmozhijin.yaml' "/usr/share/openclash/res/rule_providers.list"
            fi
            if [ "$(grep -c "^直连规则(by 沉默の金)" /usr/share/openclash/res/rule_providers.list)" -eq '0' ];then
                sed -i '1i 直连规则(by 沉默の金),沉默の金,classical,chenmozhijin/OpenWrt-K/main/files/etc/openclash/rule_provider/,DirectRule-chenmozhijin.yaml' "/usr/share/openclash/res/rule_providers.list"
            fi
            if [ "$(grep -c "^港澳台规则(by 沉默の金)" /usr/share/openclash/res/rule_providers.list)" -eq '0' ];then
                sed -i '1i 港澳台规则(by 沉默の金),沉默の金,classical,chenmozhijin/OpenWrt-K/main/files/etc/openclash/rule_provider/,HKMOTWRule-chenmozhijin.yaml' "/usr/share/openclash/res/rule_providers.list"
            fi
            rm -rf /etc/openclash/rule_provider/ProxyRule-chenmozhijin.yaml /etc/openclash/rule_provider/DirectRule-chenmozhijin.yaml
            mv -f ProxyRule-chenmozhijin.yaml /etc/openclash/rule_provider/ProxyRule-chenmozhijin.yaml
            mv -f DirectRule-chenmozhijin.yaml /etc/openclash/rule_provider/DirectRule-chenmozhijin.yaml
            mv -f HKMOTWRule-chenmozhijin.yaml /etc/openclash/rule_provider/HKMOTWRule-chenmozhijin.yaml
        fi
        echo "更新openclash规则集完成"
    else
        echo "未检测到luci-app-openclash，跳过更新openclash规则集"
    fi
}

download_failed() {
    echo "下载失败,请检查你的网络环境是否良好"
    exit 1
}

update_package() {
    detect_package_manager || exit 1
    if ! type sed;then
        echo "错误:未检测到依赖的包sed" 
        exit 1
    fi
    if ! type unzip;then
        echo "错误:未检测到依赖的包unzip" 
        exit 1
    fi    
    check_github
    mkdir -p $TMPDIR/update/package
    cd $TMPDIR/update/package
    [[ -d $TMPDIR ]] && rm -rf $TMPDIR/update/package/* || exit 1
    list_installed_packages > installed.list || {
        echo "错误：无法读取已安装软件包"
        exit 1
    }
    if  [ ! -e "/etc/openwrt-k_info" ]; then
        echo "错误：未找到openwrt-k_info"
        exit 1
    elif [ "$(grep -c "^REPOSITORY_URL=" /etc/openwrt-k_info)" -eq '0' ]; then
        echo "错误：未知的固件编译仓库地址"
        exit 1
    elif [ "$(grep -c "^TAG_SUFFIX=" /etc/openwrt-k_info)" -eq '0' ]; then
        echo "错误：未知的固件标签前缀"
        exit 1
    fi
    REPOSITORY_URL=$(sed -n  "/REPOSITORY_URL=\"/p" /etc/openwrt-k_info | sed -e "s/REPOSITORY_URL=\"//g" -e "s/\"//g")
    REPOSITORY=$(echo $REPOSITORY_URL|sed -e "s/https:\/\/github.com\///")
    TAG_SUFFIX=$(sed -n  "/TAG_SUFFIX=\"/p" /etc/openwrt-k_info | sed -e "s/TAG_SUFFIX=\"//g" -e "s/\"//g")
    latest_ver="$(curl -s https://api.github.com/repos/$REPOSITORY/releases 2>/dev/null | grep -E 'tag_name' | grep "$TAG_SUFFIX" | sed -e 's/    "tag_name": "//' -e 's/",//' | sed -n '1p')"
    FILE_NAME=$(curl -s "https://api.github.com/repos/$REPOSITORY/releases/tags/$latest_ver"| grep -E 'name'| grep -E '\.manifest'| sed -e 's/      "name": "//' -e 's/",//' | sed -n '1p')
    curl -L --retry 3 --connect-timeout 20 $REPOSITORY_URL/releases/download/${latest_ver}/$FILE_NAME -o package.list || download_failed
    find_package_updates installed.list package.list > update_package.list
    if [ ! -s update_package.list ]; then
        echo "没有可更新的包"
        exit 0
    fi
    echo "将更新以下包（内核与内核模块请通过固件升级更新）："
    cat update_package.list
    echo "这将下载releases中的package.zip请确保你有足够的空间与良好的网络"
    read -n1 -p "是否继续 [Y/N]?" answer
    case "$answer" in
    Y | y)
        echo "继续"
        ;;
    N | n)
        echo "你选择了退出"
        exit 0
        ;;

    *)
        echo "错误:未指定的选择"
        exit 1
        ;;
    esac
    read -n1 -p "下载到内存 [Y/N]?" answer
    case "$answer" in
    Y | y)
        echo "下载到内存"
        mkdir $TMPDIR/update/package/download
        DOWNLOAD_PATH=$TMPDIR/update/package/download/newpackage.zip
        ;;
    N | n)
        echo "下载到磁盘"
        mkdir -p /usr/share/cmzj/download
        DOWNLOAD_PATH=/usr/share/cmzj/download/newpackage.zip
        ;;

    *)
        echo "错误:未指定的选择"
        exit 1
        ;;
    esac
    [[ -d /usr/share/cmzj/download/ ]] && rm -rf /usr/share/cmzj/download/*
    curl -fL --retry 3 --connect-timeout 20 "$REPOSITORY_URL/releases/download/${latest_ver}/packages.zip" -o "$DOWNLOAD_PATH" || download_failed
    unzip -l "$DOWNLOAD_PATH" > archive.list || exit 1
    awk '$1 ~ /^[0-9]+$/ && $4 ~ /\.(apk|ipk)$/ { print $4 }' archive.list > newpackage.list
    select_package_entries update_package.list newpackage.list > selected.list
    if [ ! -s selected.list ]; then
        echo "归档中没有匹配的软件包，请通过固件升级更新"
        exit 1
    fi
    mkdir -p "$TMPDIR/update/package/install"
    while IFS= read -r entry; do
        unzip -p "$DOWNLOAD_PATH" "$entry" > "$TMPDIR/update/package/install/${entry##*/}" || exit 1
    done < selected.list
    rm -rf /usr/share/cmzj/download "$TMPDIR/update/package/download"
    if install_local_packages "$TMPDIR/update/package/install"; then
        echo "安装成功；归档未包含的软件包请通过固件升级更新"
    else
        echo "安装失败；若提示签名或依赖不匹配，请通过固件升级更新"
        exit 1
    fi
}

update_firmware() {
    echo "不支持的参数 $arg"
}

update_tool() {
    echo "这可能会导致工具与固件不兼容"
    read -n1 -p "是否继续 [Y/N]?" answer
    case "$answer" in
    Y | y)
        echo "继续"
        ;;
    N | n)
        echo "你选择了退出"
        exit 0
        ;;

    *)
        echo "错误:未指定的选择"
        exit 1
        ;;
    esac
    curl -fL --retry 3 --connect-timeout 20 https://raw.githubusercontent.com/hexsen929/OpenWrt-K/main/files/usr/share/cmzj/openwrt-k_tool.sh -o $TMPDIR/openwrt-k_tool.sh || download_failed
    chmod +x $TMPDIR/openwrt-k_tool.sh
    mv $TMPDIR/openwrt-k_tool.sh /usr/share/cmzj/openwrt-k_tool.sh && exit 0
}

usage() {
    echo "OpenWrt-K工具"
    echo "固件项目地址：https://github.com/hexsen929/OpenWrt-K"
    echo ""
    echo "Usage: openwrt-k <command> [<arguments>]"
    echo ""
    echo "Commands:"
    echo "update <packages|rules|tool>              更新包/规则/本工具"
    echo "info                                      打印固件信息"
}
main
