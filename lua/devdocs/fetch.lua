--- Fetch: the one place that runs curl. Downloads go to `<dest>.part` and
--- are renamed on success so a half file never looks complete. file:// URLs
--- work too, which is how tests and local mirrors avoid the network.
local M = {}

--- @class DevDocsFetchResult
--- @field ok boolean
--- @field status integer HTTP status (0 for file:// and transport failures)
--- @field err string|nil

--- @param bin string
--- @return boolean
function M.available(bin)
  return vim.fn.executable(bin) == 1
end

--- @param url string
--- @param dest string
--- @param opts { curl?: string, retries?: integer, timeout?: integer }|nil
--- @param cb fun(res: DevDocsFetchResult)
--- @return vim.SystemObj|nil
function M.download(url, dest, opts, cb)
  opts = opts or {}
  local curl = opts.curl or "curl"
  if not M.available(curl) then
    cb { ok = false, status = 0, err = ("%s is not installed"):format(curl) }
    return nil
  end
  vim.fn.mkdir(vim.fs.dirname(dest), "p")
  local part = dest .. ".part"
  local cmd = {
    curl,
    "--silent",
    "--show-error",
    "--location",
    "--fail",
    "--retry",
    tostring(opts.retries or 3),
    "--retry-delay",
    "2",
    "--max-time",
    tostring(opts.timeout or 600),
    "--write-out",
    "%{http_code}",
    "--output",
    part,
    url,
  }
  return vim.system(cmd, { text = true }, function(res)
    local status = tonumber(res.stdout and res.stdout:match "(%d%d%d)%s*$") or 0
    if res.code ~= 0 then
      os.remove(part)
      local msg = vim.trim(res.stderr or "")
      if msg == "" then
        msg = ("curl exited %d"):format(res.code)
      end
      cb { ok = false, status = status, err = msg }
      return
    end
    local ok, err = vim.uv.fs_rename(part, dest)
    if not ok then
      os.remove(part)
      cb { ok = false, status = status, err = tostring(err) }
      return
    end
    cb { ok = true, status = status }
  end)
end

--- Extract a .tar.gz into `dir` (created). Uses the system tar; bsdtar and
--- GNU tar both accept these flags.
--- @param archive string
--- @param dir string
--- @param opts { tar?: string }|nil
--- @param cb fun(ok: boolean, err: string|nil)
function M.untar(archive, dir, opts, cb)
  local tar = (opts or {}).tar or "tar"
  if not M.available(tar) then
    cb(false, ("%s is not installed"):format(tar))
    return
  end
  vim.fn.mkdir(dir, "p")
  vim.system({ tar, "-xzf", archive, "-C", dir }, { text = true }, function(res)
    if res.code ~= 0 then
      cb(false, vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or ("tar exited %d"):format(res.code))
      return
    end
    cb(true)
  end)
end

return M
