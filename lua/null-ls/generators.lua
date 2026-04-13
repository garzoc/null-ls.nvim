local client = require("null-ls.client")
local log = require("null-ls.logger")
local methods = require("null-ls.methods")

local M = {}

local progress_token = 0

--- Resume a coroutine on the next event loop tick via vim.schedule.
local function schedule_resume(co)
    vim.schedule(function()
        coroutine.resume(co)
    end)
end

--- Run an async generator function (params, callback) synchronously inside a coroutine.
--- Yields the coroutine until the callback fires, then returns (ok, results).
local function call_async(fn, params)
    local co = coroutine.running()
    local ok, results
    fn(params, function(res)
        ok, results = true, res
        -- resume on the event loop so we're back on the main thread
        schedule_resume(co)
    end)
    coroutine.yield()
    return ok, results
end

M.run = function(generators, params, opts, callback)
    local all_results = {}
    local safe_callback = function()
        if not callback then
            return
        end

        callback(all_results)
    end

    log:trace("running generators for method " .. params.method)

    if vim.tbl_isempty(generators) then
        log:debug("no generators available")
        safe_callback()
        return
    end

    local current_progress_token = nil
    if params.method ~= methods.internal.COMPLETION then
        -- progress messages for completion lead to too
        -- much noise in the tests.
        progress_token = progress_token + 1
        current_progress_token = progress_token
    end

    local copy_params = function(to_copy)
        if #generators < 2 then
            return to_copy
        end
        return vim.deepcopy(to_copy)
    end

    -- Build a task function for each generator. When generator.async is true the
    -- function must run inside a coroutine so it can yield while waiting for the
    -- callback.
    local run_generator = function(i, generator)
        local copied_params = copy_params(opts.make_params and opts.make_params() or params)
        copied_params.source_id = generator.source_id

        local runtime_condition = generator.opts and generator.opts.runtime_condition
        if runtime_condition and not runtime_condition(copied_params) then
            return
        end

        if current_progress_token then
            client.send_progress_notification(current_progress_token, {
                kind = "report",
                message = generator.opts and generator.opts.name,
                percentage = math.floor((i - 1) / #generators * 100),
            })
        end

        local ok, results
        if generator.async then
            ok, results = call_async(generator.fn, copied_params)
        else
            ok, results = pcall(generator.fn, copied_params)
        end

        -- yield to the event loop (replaces a.util.scheduler + coroutine.yield)
        local co = coroutine.running()
        if co then
            schedule_resume(co)
            coroutine.yield()
        end

        -- filter results with the filter option
        local filter = generator.opts and generator.opts.filter
        if filter and results then
            results = vim.tbl_filter(filter, results)
        end

        if results then
            if results._generator_err then
                ok = false
                results = results._generator_err
            end

            if results._should_deregister and generator.source_id then
                results = nil
                vim.schedule(function()
                    require("null-ls.sources").deregister({ id = generator.source_id })
                end)
            end
        end

        if not ok then
            log:warn("failed to run generator: " .. results)
            generator._failed = true
            return
        end

        results = results or {}
        local postprocess, after_each = opts.postprocess, opts.after_each
        for _, result in ipairs(results) do
            if postprocess then
                postprocess(result, copied_params, generator)
            end
            table.insert(all_results, result)
        end

        if after_each then
            after_each(results, copied_params, generator)
        end
    end

    -- Main coroutine that orchestrates all generators.
    local main = coroutine.create(function()
        if current_progress_token then
            client.send_progress_notification(current_progress_token, {
                kind = "begin",
                title = require("null-ls.methods").internal[params.method]:lower(),
                percentage = 0,
            })
        end

        if opts.sequential then
            for i, generator in ipairs(generators) do
                run_generator(i, generator)
            end
        else
            -- Run all generators concurrently: each in its own coroutine.
            -- Track completion with a counter and resume main when all done.
            local remaining = #generators
            local main_co = coroutine.running()

            for i, generator in ipairs(generators) do
                local co = coroutine.create(function()
                    run_generator(i, generator)
                    remaining = remaining - 1
                    if remaining == 0 then
                        schedule_resume(main_co)
                    end
                end)
                coroutine.resume(co)
            end

            if remaining > 0 then
                coroutine.yield()
            end
        end

        if current_progress_token then
            client.send_progress_notification(current_progress_token, {
                kind = "end",
                percentage = 100,
            })
        end
        safe_callback()
    end)

    coroutine.resume(main)
end

M.run_sequentially = function(generators, make_params, opts, callback)
    M.run(generators, make_params(), {
        sequential = true,
        postprocess = opts.postprocess,
        after_each = opts.after_each,
        make_params = make_params,
    }, callback)
end

M.run_registered = function(opts)
    local filetype, method, params, postprocess, callback, after_each =
        opts.filetype, opts.method, opts.params, opts.postprocess, opts.callback, opts.after_each
    local generators = M.get_available(filetype, method)

    M.run(generators, params, { postprocess = postprocess, after_each = after_each }, callback)
end

M.run_registered_sequentially = function(opts)
    local filetype, method, make_params, postprocess, callback, after_each, after_all =
        opts.filetype, opts.method, opts.make_params, opts.postprocess, opts.callback, opts.after_each, opts.after_all
    local generators = M.get_available(filetype, method)

    M.run_sequentially(
        generators,
        make_params,
        { postprocess = postprocess, after_each = after_each, after_all = after_all },
        callback
    )
end

M.get_available = function(filetype, method)
    local available = {}
    for _, source in ipairs(require("null-ls.sources").get_available(filetype, method)) do
        table.insert(available, source.generator)
    end
    return available
end

M.can_run = function(filetype, method)
    return #M.get_available(filetype, method) > 0
end

return M
