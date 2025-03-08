local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Leaky bucket parameters
local max_delay = 3000 -- 3 second,
local leak_rate = 5 / 3 -- Requests leaked per second

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

-- Function to load the script into Redis if not already cached
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

-- Lua script to implement leaky bucket algorithm
local rate_limit_script = [[
    local queue_key = KEYS[1]
    local bucket_capacity = tonumber(ARGV[1])
    local leak_rate = tonumber(ARGV[2])
    local ttl = tonumber(ARGV[3])

    local redis_time = redis.call("TIME")
    local now = tonumber(redis_time[1]) * 1000000 + tonumber(redis_time[2]) -- Convert to microseconds

    -- Get the head of the queue to check the last leak time
    local results = redis.call("zrevrange", queue_key, 0, 0, "WITHSCORES")
    local last_leak_time = now
    if #results > 0 then
        last_leak_time = tonumber(results[2])
    end

    -- remove old entries and get the current queue length
    redis.call("zremrangebyscore", queue_key, 0, now)
    local queue_length = tonumber(redis.call("zcard", queue_key)) or 0

    if queue_length + 1 <= bucket_capacity then
        local default_delay = math.floor(1 / leak_rate * 1000000)

        local delay = 0
        local time_diff = now - last_leak_time
        if time_diff ~= 0 then
            delay = math.max(0, default_delay - time_diff)
        end

        local leak_time = now + delay

        redis.call("zadd", queue_key, leak_time, leak_time)
        redis.call("expire", queue_key, ttl)

        return delay
    else
        return -1
    end
]]

-- Execute the leaky bucket logic atomically
local function execute_rate_limit_script(red, queue_key, bucket_capacity, ttl)
    local sha, err = load_script_to_redis(red, "leaky_bucket_script_sha", rate_limit_script, false)
    if not sha then
        return nil, "Failed to load script: " .. err
    end

    local result, err = red:evalsha(sha, 1, queue_key, bucket_capacity, leak_rate, ttl)

    if err then
        if err:find("NOSCRIPT", 1, true) then
            -- Script not found in Redis, reload it
            sha, err = load_script_to_redis(red, "leaky_bucket_script_sha", rate_limit_script, true)
            if not sha then
                return nil, err
            end
            result, err = red:evalsha(sha, 1, queue_key, bucket_capacity, leak_rate, ttl)
        end

        if err then
            return nil, err
        end
    end

    return result
end

-- Main function for rate limiting
local function check_rate_limit(red, token)
    -- Redis keys for token count and last access time
    local queue_key = "rate_limit:" .. token .. ":queue"

    -- Calculate bucket capacity based on max delay and leak rate
    local bucket_capacity = math.floor(max_delay / 1000 * leak_rate)

    -- Calculate TTL for the Redis keys
    local ttl = math.floor(bucket_capacity / leak_rate * 2)

    -- Execute leaky bucket logic
    local result, err = execute_rate_limit_script(red, queue_key, bucket_capacity, ttl)
    if not result then
        return nil, "Failed to run rate limiting script" .. err
    end

    -- Handle the result
    if result == -1 then
        return true, "rejected"
    else
        -- Nginx sleep supports second with milliseconds precision
        local delay = math.ceil(result / 1000) / 1000
        return true, "allowed", delay
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

    local pcall_status, check_rate_limit_result, message, delay = pcall(check_rate_limit, red, token)

    local ok, err = close_redis(red)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close Redis connection: ", err)
    end

    if not pcall_status then
        ngx.log(ngx.ERR, check_rate_limit_result)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if not check_rate_limit_result then
        ngx.log(ngx.ERR, "Failed to rate limit: ", message)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if message == "rejected" then
        ngx.log(ngx.INFO, "Rate limit exceeded for token: ", token)
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end

    ngx.sleep(delay)
    ngx.log(ngx.INFO, "Rate limit allowed for token: ", token)
end

-- Run the main function
main()
