local c = require("null-ls.config")
local u = require("null-ls.utils")

local default_notify_opts = {
    title = "null-ls",
}

local log = {}

local level_order = { trace = 0, debug = 1, info = 2, warn = 3, error = 4 }

--- Adds a log entry to the logfile
---@param msg any
---@param level string [same as vim.log.log_levels]
function log:add_entry(msg, level)
    local cfg = c.get()

    if not self.__notify_fmt then
        self.__notify_fmt = function(m)
            return string.format(cfg.notify_format, m)
        end
    end

    local min_level = cfg.log_level or "warn"
    if min_level == "off" then
        return
    end
    if cfg.debug then
        min_level = "trace"
    end

    if (level_order[level] or 0) < (level_order[min_level] or 0) then
        return
    end

    local logpath = self:get_path()
    local fp = io.open(logpath, "a")
    if not fp then
        return
    end
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    fp:write(string.format("[%-5s %s] %s\n", level:upper(), timestamp, tostring(msg)))
    fp:close()
end

---Retrieves the path of the logfile
---@return string path of the logfile
function log:get_path()
    return u.path.join(vim.fn.stdpath("cache"), "null-ls.log")
end

---Add a log entry at TRACE level
---@param msg any
function log:trace(msg)
    self:add_entry(msg, "trace")
end

---Add a log entry at DEBUG level
---@param msg any
function log:debug(msg)
    self:add_entry(msg, "debug")
end

---Add a log entry at INFO level
---@param msg any
function log:info(msg)
    self:add_entry(msg, "info")
end

---Add a log entry at WARN level
---@param msg any
function log:warn(msg)
    self:add_entry(msg, "warn")
    vim.notify(self.__notify_fmt(msg), vim.log.levels.WARN, default_notify_opts)
end

---Add a log entry at ERROR level
---@param msg any
function log:error(msg)
    self:add_entry(msg, "error")
    vim.notify(self.__notify_fmt(msg), vim.log.levels.ERROR, default_notify_opts)
end

setmetatable({}, log)
return log
