#!/bin/sh
# Copyright (C) Juewuy
# WebDAV远程备份与同步功能
# 提供基于 curl 的 WebDAV 操作函数

[ -n "$__IS_LIB_WEBDAV_LOADED" ] && return
__IS_LIB_WEBDAV_LOADED=1

# =====================================================
# 配置变量（存储在 ShellCrash.cfg 中）
# webdav_url      — WebDAV 服务器地址
# webdav_user     — 用户名
# webdav_pass     — 密码
# =====================================================

# 统一 WebDAV HTTP 请求
# $1: HTTP 方法 (GET/PUT/MKCOL/PROPFIND/DELETE)
# $2: 完整 URL
# $3: 上传文件路径 (PUT 时使用)
# $4: 下载输出路径 (GET 时使用)
webdav_request() {
    local method="$1"
    local url="$2"
    local upload_file="$3"
    local output_file="$4"

    if ! ckcmd curl; then
        logger "WebDAV: 未检测到 curl，无法执行 WebDAV 操作！" 31
        return 1
    fi

    local curl_cmd="curl -s --connect-timeout 10 --max-time 60 -w '%{http_code}'"

    [ "$skip_cert" = "OFF" ] || curl_cmd="$curl_cmd -k"

    if [ -n "$webdav_user" ] && [ -n "$webdav_pass" ]; then
        curl_cmd="$curl_cmd -u '${webdav_user}:${webdav_pass}'"
    fi

    case "$method" in
        PUT)
            if [ -f "$upload_file" ]; then
                curl_cmd="$curl_cmd -T '${upload_file}'"
            else
                logger "WebDAV: 上传文件不存在 - $upload_file" 31
                return 1
            fi
            ;;
        GET)
            if [ -n "$output_file" ]; then
                curl_cmd="$curl_cmd -o '${output_file}'"
            else
                curl_cmd="$curl_cmd -o /dev/null"
            fi
            ;;
        MKCOL)
            curl_cmd="$curl_cmd -X MKCOL"
            ;;
        PROPFIND)
            curl_cmd="$curl_cmd -X PROPFIND -H 'Depth: 1'"
            ;;
        DELETE)
            curl_cmd="$curl_cmd -X DELETE"
            ;;
        *)
            logger "WebDAV: 不支持的 HTTP 方法 - $method" 31
            return 1
            ;;
    esac

    local resp
    resp=$(eval "$curl_cmd '$url' 2>/dev/null")
    local ret=$?

    local http_code
    http_code=$(echo "$resp" | tail -c 4 | tr -d '\n\r')

    case "$http_code" in
        2[0-9][0-9]) return 0 ;;
        3[0-9][0-9]) return 0 ;;
        401|403)
            logger "WebDAV: 认证失败，请检查用户名和密码 (HTTP $http_code)！" 31
            return 1
            ;;
        5[0-9][0-9])
            logger "WebDAV: 服务器错误 (HTTP $http_code)，请检查服务器状态！" 31
            return 1
            ;;
        *)
            if [ "$ret" = 0 ]; then
                [ "$method" = "PROPFIND" ] && return 0
                return 0
            fi
            [ "$method" = "MKCOL" ] && return 0
            logger "WebDAV: 请求失败 (HTTP $http_code)" 33
            return 1
            ;;
    esac
}

webdav_test() {
    local url="${webdav_url}"
    url="${url%/}/"

    logger "WebDAV: 正在测试连接 $url ..." 36
    if webdav_request PROPFIND "$url"; then
        logger "WebDAV: 连接测试成功！" 32
        return 0
    else
        logger "WebDAV: 连接测试失败，请检查配置！" 31
        return 1
    fi
}

webdav_ensure_dir() {
    local dir="$1"
    dir="${dir%/}/"
    webdav_request MKCOL "$dir" >/dev/null 2>&1
    return 0
}

webdav_upload_file() {
    local local_file="$1"
    local remote_base="${2:-${webdav_url}}"
    remote_base="${remote_base%/}/"

    [ ! -f "$local_file" ] && {
        logger "WebDAV: 本地文件不存在 - $local_file" 31
        return 1
    }

    local filename="${local_file##*/}"
    local remote_url="${remote_base}${filename}"

    webdav_ensure_dir "$remote_base"

    logger "WebDAV: 正在上传 $filename ..." 36
    if webdav_request PUT "$remote_url" "$local_file"; then
        logger "WebDAV: 上传 $filename 成功！" 32
        return 0
    else
        logger "WebDAV: 上传 $filename 失败！" 31
        return 1
    fi
}

webdav_download_file() {
    local remote_url="$1"
    local local_file="$2"
    local fname="${remote_url##*/}"

    logger "WebDAV: 正在下载 $fname ..." 36
    if webdav_request GET "$remote_url" "" "$local_file" && [ -s "$local_file" ]; then
        logger "WebDAV: 下载 $fname 成功！" 32
        return 0
    else
        logger "WebDAV: 下载 $fname 失败！" 31
        rm -f "$local_file" 2>/dev/null
        return 1
    fi
}

# === 高级操作 ===

webdav_backup_configs() {
    local remote_base="${webdav_url}"
    remote_base="${remote_base%/}/configs/"

    local BACK_TAR="$TMPDIR/ShellCrash_configs_backup.tar.gz"

    logger "WebDAV: 正在打包 configs/ 目录 ..." 36
    if ! tar -zcf "$BACK_TAR" -C "$CRASHDIR/configs/" . 2>/dev/null; then
        logger "WebDAV: configs/ 目录打包失败！" 31
        return 1
    fi

    local timestamp=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo "unknown")
    local remote_file="${remote_base}ShellCrash_configs_${timestamp}.tar.gz"
    local latest_file="${remote_base}ShellCrash_configs_latest.tar.gz"

    webdav_ensure_dir "$remote_base"

    if webdav_upload_file "$BACK_TAR" "$remote_base"; then
        webdav_request PUT "$latest_file" "$BACK_TAR" >/dev/null 2>&1
        rm -f "$BACK_TAR"
        logger "WebDAV: 配置备份完成！文件: ShellCrash_configs_${timestamp}.tar.gz" 32
        return 0
    fi

    rm -f "$BACK_TAR"
    return 1
}

webdav_backup_config_file() {
    local remote_base="${webdav_url}"
    remote_base="${remote_base%/}/configs/"

    webdav_ensure_dir "$remote_base"

    local config_file
    if echo "$crashcore" | grep -q 'singbox'; then
        config_file="$CRASHDIR/jsons/config.json"
    else
        config_file="$CRASHDIR/yamls/config.yaml"
    fi

    if [ ! -f "$config_file" ]; then
        logger "WebDAV: 内核配置文件不存在 - $config_file" 33
        return 1
    fi

    webdav_upload_file "$config_file" "$remote_base"
    return $?
}

webdav_restore_configs() {
    local remote_base="${webdav_url}"
    remote_base="${remote_base%/}/configs/"

    logger "WebDAV: 正在获取远程备份列表 ..." 36

    local resp
    resp=$(webdav_request PROPFIND "$remote_base" 2>/dev/null) || {
        logger "WebDAV: 无法获取远程备份列表！" 31
        return 1
    }

    local latest_file
    latest_file=$(echo "$resp" | grep -o 'href="[^"]*\.tar\.gz"' | \
        sed 's/href="//;s/"//' | \
        sed 's|.*/||' | \
        sort -r | head -1)

    [ -z "$latest_file" ] && {
        logger "WebDAV: 远程未找到备份文件 (*.tar.gz)！" 31
        return 1
    }

    local remote_url="${remote_base}${latest_file}"
    local BACK_TAR="$TMPDIR/ShellCrash_configs_restore.tar.gz"

    webdav_download_file "$remote_url" "$BACK_TAR" || return 1

    local backup_current="$TMPDIR/configs_pre_restore.tar.gz"
    mkdir -p "$CRASHDIR/configs"
    tar -zcf "$backup_current" -C "$CRASHDIR/configs/" . 2>/dev/null

    rm -rf "$CRASHDIR/configs/"*
    if tar -zxf "$BACK_TAR" -C "$CRASHDIR/configs/" 2>/dev/null; then
        rm -f "$BACK_TAR"
        logger "WebDAV: 配置恢复成功！(旧配置已备份到 $backup_current)" 32
        return 0
    else
        logger "WebDAV: 配置恢复失败！正在还原旧配置 ..." 31
        rm -rf "$CRASHDIR/configs/"*
        tar -zxf "$backup_current" -C "$CRASHDIR/configs/" 2>/dev/null
        rm -f "$BACK_TAR" "$backup_current"
        return 1
    fi
}

webdav_restore_config_file() {
    local remote_base="${webdav_url}"
    remote_base="${remote_base%/}/configs/"

    local config_name
    local config_path
    if echo "$crashcore" | grep -q 'singbox'; then
        config_name="config.json"
        config_path="$CRASHDIR/jsons/config.json"
    else
        config_name="config.yaml"
        config_path="$CRASHDIR/yamls/config.yaml"
    fi

    local remote_url="${remote_base}${config_name}"
    local tmp_file="$TMPDIR/webdav_${config_name}"

    webdav_download_file "$remote_url" "$tmp_file" || return 1

    mkdir -p "${config_path%/*}"
    [ -f "$config_path" ] && cp -f "$config_path" "${config_path}.bak" 2>/dev/null

    mv -f "$tmp_file" "$config_path"
    logger "WebDAV: ${config_name} 已恢复！旧文件已备份为 ${config_name}.bak" 32
    return 0
}

webdav_auto_backup() {
    logger "WebDAV: 开始自动备份 ..." 36
    webdav_backup_config_file
    webdav_backup_configs
    logger "WebDAV: 自动备份完成！" 32
    return 0
}
