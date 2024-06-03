local M = {}

function M.install_bundle_loader(bundlepath)
    if not myarchive then return end
    local function searchbundle(name)
        local bundlename = string.match(name, '^[^.]+')
        local filename = package.searchpath(bundlename, bundlepath)
        if not filename then return end

        local modulepath = string.gsub(name, '%.', '/') .. '.lua'
        local source = myarchive.get_archive_file(filename, modulepath)

        return load(source, name, 't'), filename
    end
    table.insert(package.searchers, searchbundle)
end

return M
