local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Sliding window parameters
local window_size = 60 -- Total window size in seconds
local request_limit = 100 -- Max requests allowed in the window
local sub_window_count = 5 -- Number of subwindows
local rate_limit_script = [[
    local key_prefix = KEYS[1]
    local window_size = tonumber(ARGV[1])
    local request_limit = tonumber(ARGV[2])
    local sub_window_count = tonumber(ARGV[3])
    
    local redis_time = redis.call("TIME")
    local now = tonumber(redis_time[1])
    local sub_window_size = window_size / sub_window_count
    local current_window_key = math.floor(now / sub_window_size) * sub_window_size
    local elapsed_time = now % sub_window_size
    
    local current_key = key_prefix .. ":" .. current_window_key
    local current_count = tonumber(redis.call("GET", current_key) or 0)
    
    local total_requests = current_count
    
    for i = 1, sub_window_count do
        local previous_window_key = current_window_key - (i * sub_window_size)
        local previous_key = key_prefix .. ":" .. previous_window_key
        local previous_count = tonumber(redis.call("GET", previous_key) or 0)
        
        if i == sub_window_count then
            total_requests = total_requests + ((sub_window_size - elapsed_time) / sub_window_size) * previous_count
        else
            total_requests = total_requests + previous_count
        end
    end
    
    if total_requests + 1 > request_limit then
        return -1
    end
    
    redis.call("INCR", current_key)
    redis.call("EXPIRE", current_key, window_size)
    
    return 1
]]

-- Helper function to initialize Redis connection
local function init_redis()
    local red, err = redis:new()
    if not red then
        return nil, err
    end
    red:set_timeout(redis_timeout)
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        return nil, err
    end
    return red
end

-- Helper function to close Redis connection
local function close_redis(red)
    local ok, err = red:set_keepalive(max_idle_timeout, pool_size)
    if not ok then
        return nil, err
    end
    return true
end

-- Helper function to get URL token
local function get_request_token()
    local token = ngx.var.arg_token
    if not token then
        return nil, "Token not provided"
    end
    return token
end

-- Load the Lua script into Redis if not already cached
local function load_script_to_redis(red, key, script, reload)

    local function load_new_script()
        local new_sha, err = red:script("LOAD", script)
        if not new_sha then
            return nil, err
        end
        ngx.shared.my_cache:set(key, new_sha)
        return new_sha
    end

    if reload then
        ngx.shared.my_cache:delete(key)
        return load_new_script()
    end

    local sha = ngx.shared.my_cache:get(key)
    if not sha then
        sha = load_new_script()
    end

    return sha
end

local function execute_rate_limit_script(red, key_prefix)
    local sha, err = load_script_to_redis(red, "sliding_window_counter_script_sha", rate_limit_script, false)
    if not sha then
        return nil, err
    end

    local result, err = red:evalsha(sha, 1, key_prefix, window_size, request_limit, sub_window_count)

    if err and err:find("NOSCRIPT", 1, true) then
        sha, err = load_script_to_redis(red, "sliding_window_counter_script_sha", rate_limit_script, true)
        if not sha then
            return nil, err
        end
        result, err = red:evalsha(sha, 1, key_prefix, window_size, request_limit, sub_window_count)
    end

    if err then
        return nil, err
    end

    return result
end

-- Main rate limiting logic
local function check_rate_limit(red, token)
    local key_prefix = "rate_limit:" .. token
    local result, err = execute_rate_limit_script(red, key_prefix)

    if not result then
        return nil, "Failed to run rate limiting script: " .. err
    end

    if result == 1 then
        return true, "allowed"
    else
        return true, "rejected"
    end
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    local token, err = get_request_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local pcall_status, rate_limit_result, message = pcall(check_rate_limit, red, token)

    local ok, err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", err)
    end

    if not pcall_status then
        ngx.log(ngx.ERR, rate_limit_result)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if not rate_limit_result then
        ngx.log(ngx.ERR, "Failed to rate limit: ", message)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if message == "rejected" then
        ngx.log(ngx.INFO, "Rate limit exceeded for token: ", token)
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end

    ngx.log(ngx.INFO, "Rate limit allowed for token: ", token)
end

-- Run the main function
main()
