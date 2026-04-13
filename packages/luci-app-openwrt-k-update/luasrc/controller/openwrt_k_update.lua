module("luci.controller.openwrt_k_update", package.seeall)

local fs = require "nixio.fs"
local http = require "luci.http"
local jsonc = require "luci.jsonc"
local sys = require "luci.sys"
local util = require "luci.util"

local INFO_FILE = "/etc/openwrt-k_info"
local RELEASE_FILE = "/etc/openwrt_release"
local STATUS_FILE = "/tmp/openwrt-k-update.state"
local LOG_FILE = "/tmp/openwrt-k-update.log"
local CACHE_FILE = "/tmp/openwrt-k-update.latest.json"
local IMAGE_DIR = "/tmp/openwrt-k-update"
local IMAGE_PATH = IMAGE_DIR .. "/firmware.bin"
local RUNNER = "/usr/libexec/openwrt-k-online-update"


function index()
    if not fs.access(INFO_FILE) then
        return
    end

    local page = entry({"admin", "system", "openwrt-k-update"}, template("openwrt_k_update/index"), _("在线更新"), 92)
    page.dependent = true

    entry({"admin", "system", "openwrt-k-update", "status"}, call("action_status")).leaf = true
    entry({"admin", "system", "openwrt-k-update", "check"}, call("action_check")).leaf = true
    entry({"admin", "system", "openwrt-k-update", "upgrade"}, call("action_upgrade")).leaf = true
end


local function write_json(data)
    http.prepare_content("application/json")
    http.write(jsonc.stringify(data) or "{}")
end


local function read_lines(path)
    local content = fs.readfile(path)
    if not content then
        return {}
    end

    local lines = {}
    for line in content:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    return lines
end


local function parse_kv_file(path)
    local values = {}
    for _, line in ipairs(read_lines(path)) do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key then
            value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
            values[key] = value
        end
    end
    return values
end


local function shell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", [['"'"']]) .. "'"
end


local function exec_json(url)
    local body = sys.exec("curl -fsSL --connect-timeout 10 --retry 2 " .. shell_quote(url) .. " 2>/dev/null")
    if not body or body == "" then
        return nil, "无法连接 GitHub Releases API"
    end

    local data = jsonc.parse(body)
    if not data then
        return nil, "GitHub 返回数据解析失败"
    end

    return data
end


local function format_bytes(size)
    local units = {"B", "KiB", "MiB", "GiB"}
    local value = tonumber(size or 0) or 0
    local idx = 1
    while value >= 1024 and idx < #units do
        value = value / 1024
        idx = idx + 1
    end
    if idx == 1 then
        return string.format("%d %s", value, units[idx])
    end
    return string.format("%.1f %s", value, units[idx])
end


local function detect_rootfs_type()
    local romfs = util.trim(sys.exec([[awk '$2=="/rom"{print $3; exit}' /proc/mounts 2>/dev/null]]))
    if romfs ~= "" then
        return romfs
    end

    local rootfs = util.trim(sys.exec([[awk '$2=="/"{print $3; exit}' /proc/mounts 2>/dev/null]]))
    if rootfs ~= "" then
        return rootfs
    end

    return "unknown"
end


local function detect_boot_mode()
    if fs.access("/sys/firmware/efi") then
        return "efi"
    end
    return "bios"
end


local function repository_path(repository_url)
    if not repository_url then
        return nil
    end
    return repository_url:match("github%.com/([^/]+/[^/]+)/?$")
end


local function current_info()
    local release = parse_kv_file(RELEASE_FILE)
    local info = parse_kv_file(INFO_FILE)
    local os_release = parse_kv_file("/etc/os-release")

    return {
        system = os_release.NAME,
        release = release.DISTRIB_RELEASE,
        revision = release.DISTRIB_REVISION,
        architecture = release.DISTRIB_ARCH,
        target = release.DISTRIB_TARGET,
        compiler = info.COMPILER,
        repository_url = info.REPOSITORY_URL,
        repository = repository_path(info.REPOSITORY_URL),
        tag_suffix = info.TAG_SUFFIX,
        compile_start_time = info.COMPILE_START_TIME,
        rootfs_type = detect_rootfs_type(),
        boot_mode = detect_boot_mode(),
        temp_free = util.trim(sys.exec([[df -k /tmp | awk 'NR==2 {print $4 " KiB"}']]))
    }
end


local function is_upgrade_asset(name)
    local lower = (name or ""):lower()
    if lower == "" then
        return false
    end
    if lower == "packages.zip" or lower == "kmods.zip" or lower == "profiles.json" or lower == "sha256sums" then
        return false
    end
    if lower:match("%.manifest$") or lower:match("%.iso$") or lower:match("%.vmdk$") or lower:match("%.vmdk%.gz$") then
        return false
    end
    if lower:match("rootfs") or lower:match("kernel") or lower:match("initramfs") or lower:match("targz") or lower:match("factory") then
        return false
    end
    if lower:match("sysupgrade") then
        return true
    end
    if lower:match("%.img%.gz$") or lower:match("%.bin$") then
        return true
    end
    return false
end


local function choose_recommended_asset(info, assets)
    local suffixes = {}
    local rootfs = info.rootfs_type == "squashfs" and "squashfs" or (info.rootfs_type == "ext4" and "ext4" or nil)
    local efi_suffix = info.boot_mode == "efi" and "-efi" or ""

    if rootfs then
        suffixes[#suffixes + 1] = string.format("-%s-combined%s.img.gz", rootfs, efi_suffix)
        if efi_suffix ~= "" then
            suffixes[#suffixes + 1] = string.format("-%s-combined.img.gz", rootfs)
        end
    end

    suffixes[#suffixes + 1] = "-sysupgrade.bin"
    suffixes[#suffixes + 1] = ".img.gz"
    suffixes[#suffixes + 1] = ".bin"

    for _, suffix in ipairs(suffixes) do
        for _, asset in ipairs(assets) do
            if asset.name:sub(-#suffix) == suffix then
                return asset.name
            end
        end
    end

    return assets[1] and assets[1].name or nil
end


local function simplify_release(info, release)
    local assets = {}
    for _, asset in ipairs(release.assets or {}) do
        if is_upgrade_asset(asset.name) then
            assets[#assets + 1] = {
                name = asset.name,
                url = asset.browser_download_url,
                size = asset.size,
                size_human = format_bytes(asset.size),
                updated_at = asset.updated_at
            }
        end
    end

    local recommended_asset = choose_recommended_asset(info, assets)
    for _, asset in ipairs(assets) do
        asset.recommended = asset.name == recommended_asset
    end

    return {
        tag_name = release.tag_name,
        name = release.name,
        html_url = release.html_url,
        published_at = release.published_at,
        assets = assets,
        recommended_asset = recommended_asset
    }
end


local function save_release_cache(data)
    fs.writefile(CACHE_FILE, jsonc.stringify(data))
end


local function load_release_cache()
    local content = fs.readfile(CACHE_FILE)
    if not content or content == "" then
        return nil
    end
    return jsonc.parse(content)
end


local function latest_release(info)
    if not info.repository or not info.tag_suffix then
        return nil, "当前固件缺少 openwrt-k_info 仓库信息"
    end

    local releases, err = exec_json("https://api.github.com/repos/" .. info.repository .. "/releases?per_page=10")
    if not releases then
        return nil, err
    end
    if releases.message and not releases[1] then
        return nil, "GitHub API 返回错误: " .. tostring(releases.message)
    end

    for _, release in ipairs(releases) do
        if not release.draft and release.tag_name and release.tag_name:find(info.tag_suffix, 1, true) then
            local data = simplify_release(info, release)
            save_release_cache(data)
            return data
        end
    end

    return nil, "没有找到匹配当前架构的发布版本"
end


local function read_task_status()
    local data = parse_kv_file(STATUS_FILE)
    local log = util.trim(sys.exec("tail -n 50 " .. shell_quote(LOG_FILE) .. " 2>/dev/null"))
    local image_path = data.IMAGE_PATH or IMAGE_PATH
    local total_size = tonumber(data.TOTAL_SIZE or "0") or 0
    local downloaded_size = 0
    local progress = 0
    local image_stat = fs.stat(image_path)

    if image_stat and image_stat.type == "reg" then
        downloaded_size = tonumber(image_stat.size or 0) or 0
    end
    if total_size > 0 then
        progress = math.floor((downloaded_size * 10000) / total_size + 0.5) / 100
        if progress > 100 then
            progress = 100
        end
    elseif data.STATE == "validating" or data.STATE == "rebooting" then
        progress = 100
    end

    return {
        state = data.STATE or "idle",
        message = data.MESSAGE or "",
        release_tag = data.RELEASE_TAG or "",
        asset_name = data.ASSET_NAME or "",
        image_path = image_path,
        keep_settings = data.KEEP == "1",
        total_size = total_size,
        total_size_human = format_bytes(total_size),
        downloaded_size = downloaded_size,
        downloaded_size_human = format_bytes(downloaded_size),
        progress = progress,
        updated_at = data.UPDATED_AT or "",
        log = log
    }
end


local function selected_asset(release, asset_name)
    for _, asset in ipairs(release.assets or {}) do
        if asset.name == asset_name then
            return asset
        end
    end
    return nil
end


local function write_task_status(state, message, release_tag, asset_name, keep_settings, total_size)
    local content = table.concat({
        "STATE=" .. (state or "idle"),
        "MESSAGE=" .. (message or ""),
        "RELEASE_TAG=" .. (release_tag or ""),
        "ASSET_NAME=" .. (asset_name or ""),
        "IMAGE_PATH=" .. IMAGE_PATH,
        "KEEP=" .. (keep_settings and "1" or "0"),
        "TOTAL_SIZE=" .. tostring(total_size or 0),
        "UPDATED_AT=" .. os.date("%Y-%m-%d %H:%M:%S")
    }, "\n")
    fs.writefile(STATUS_FILE, content .. "\n")
end


function action_status()
    write_json({
        ok = true,
        current = current_info(),
        latest = load_release_cache(),
        task = read_task_status()
    })
end


function action_check()
    local info = current_info()
    local release, err = latest_release(info)
    if not release then
        write_json({
            ok = false,
            current = info,
            task = read_task_status(),
            error = err
        })
        return
    end

    write_json({
        ok = true,
        current = info,
        latest = release,
        task = read_task_status()
    })
end


function action_upgrade()
    local task = read_task_status()
    local info = current_info()
    local release, err = latest_release(info)
    local asset_name = http.formvalue("asset_name")
    local keep_settings = http.formvalue("keep_settings") ~= "0"

    if task.state == "downloading" or task.state == "validating" or task.state == "rebooting" then
        write_json({ok = false, error = "已有在线升级任务正在运行，请稍后再试"})
        return
    end

    if not fs.access(RUNNER) then
        write_json({ok = false, error = "升级后端脚本不存在，请确认软件包已正确安装"})
        return
    end

    if not release then
        write_json({ok = false, error = err})
        return
    end

    if #release.assets == 0 then
        write_json({ok = false, error = "当前发布未找到可用于在线升级的固件文件"})
        return
    end

    if not asset_name or asset_name == "" then
        asset_name = release.recommended_asset
    end

    local asset = selected_asset(release, asset_name)
    if not asset then
        write_json({ok = false, error = "未找到你选择的固件文件"})
        return
    end

    fs.remove(STATUS_FILE)
    fs.remove(LOG_FILE)
    fs.remove(IMAGE_PATH)
    sys.call("mkdir -p " .. shell_quote(IMAGE_DIR))
    write_task_status("downloading", "升级任务已创建，准备开始下载固件", release.tag_name, asset.name, keep_settings, asset.size)

    local command = string.format(
        "(%s %s %s %s %s %s %s %s %s) >/dev/null 2>&1 &",
        shell_quote(RUNNER),
        shell_quote(asset.url),
        shell_quote(IMAGE_PATH),
        shell_quote(STATUS_FILE),
        shell_quote(LOG_FILE),
        shell_quote(release.tag_name),
        shell_quote(asset.name),
        shell_quote(tostring(asset.size or 0)),
        keep_settings and "1" or "0"
    )

    local code = sys.call(command)
    if code ~= 0 then
        write_json({ok = false, error = "启动在线升级任务失败"})
        return
    end

    write_json({
        ok = true,
        message = "升级任务已启动，正在后台下载并校验固件",
        latest = release,
        task = read_task_status()
    })
end
