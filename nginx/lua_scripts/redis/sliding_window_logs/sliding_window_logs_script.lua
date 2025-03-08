local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Sliding Window Logs parameters
local rate_limit = 100 -- Maximum requests per window
local window_size = 60 -- Window size in seconds
local rate_limit_script = [[
    local key = KEYS[1]
    local window = tonumber(ARGV[1])
    local limit = tonumber(ARGV[2])

    local time = redis.call("TIME")
    local now = tonumber(time[1]) * 1000000 + tonumber(time[2]) -- Current timestamp in microseconds

    redis.call("ZREMRANGEBYSCORE", key, 0, now - window * 1000000)
    local count = redis.call("ZCARD", key)
    
    if count < limit then
        redis.call("ZADD", key, now, now)
        redis.call("EXPIRE", key, window)
        return 1
    else
        return -1
    end
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

local function execute_rate_limit_script(red, key)
    local sha, err = load_script_to_redis(red, "sliding_window_logs_script_sha", rate_limit_script, false)
    if not sha then
        return nil, err
    end

    local result, err = red:evalsha(sha, 1, key, window_size, rate_limit)

    if err and err:find("NOSCRIPT", 1, true) then
        sha, err = load_script_to_redis(red, true)
        if not sha then
            return nil, err
        end
        result, err = red:evalsha(sha, 1, key, window_size, rate_limit)
    end

    if err then
        return nil, err
    end

    return result
end

-- Main rate limiting logic
local function check_rate_limit(red, token)
    local key = "rate_limit:" .. token
    local result, err = execute_rate_limit_script(red, key)
    if not result then
        return nil, "Failed to run rate limiting script" .. err
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
