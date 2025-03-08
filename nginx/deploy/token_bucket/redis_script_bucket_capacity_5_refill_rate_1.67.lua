local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Token bucket parameters
local bucket_capacity = 5 -- Maximum tokens in the bucket
local refill_rate = 5 / 3 -- Tokens generated per second
local requested_tokens = 1 -- Number of tokens required per request

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

-- Lua script for rate limiting
local rate_limit_script = [[
    local tokens_key = KEYS[1]
    local last_access_key = KEYS[2]
    local bucket_capacity = tonumber(ARGV[1])
    local refill_rate = tonumber(ARGV[2])
    local requested_tokens = tonumber(ARGV[3])
    local ttl = tonumber(ARGV[4])

    local redis_time = redis.call("TIME")
    local now = tonumber(redis_time[1]) * 1000000 + tonumber(redis_time[2]) -- Current timestamp in microseconds
    
    -- This code internally scales the request rate, bucket capacity, and requested tokens by a factor of 1000000.
    -- This scaling is done to facilitate operations in microseconds, providing finer granularity and precision
    -- in rate limiting calculations.
    local values = redis.call("mget", tokens_key, last_access_key)
    local last_token_count = tonumber(values[1]) or bucket_capacity * 1000000
    local last_access_time = tonumber(values[2]) or now
    
    -- Calculate the number of tokens to be added due to the elapsed time since the last access
    local elapsed_time_us = math.max(0, now - last_access_time)
    local tokens_to_add = elapsed_time_us * refill_rate
    local new_token_count = math.floor(math.min(bucket_capacity * 1000000, last_token_count + tokens_to_add))

    -- Check if there are enough tokens for the request
    if new_token_count >= requested_tokens * 1000000 then
        -- Deduct tokens and update Redis state
        new_token_count = new_token_count - requested_tokens * 1000000

        redis.call("set", tokens_key, new_token_count, "EX", ttl)
        redis.call("set", last_access_key, now, "EX", ttl)

        return 1
    else
        -- Not enough tokens, rate limit the request
        return -1
    end
]]

local function execute_rate_limit_script(red, tokens_key, last_access_key, requested_tokens, ttl)
    local sha, err = load_script_to_redis(red, "token_bucket_script_sha", rate_limit_script, false)
    if not sha then
        return nil, err
    end

    local result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, refill_rate, requested_tokens, ttl)

    if err and err:find("NOSCRIPT", 1, true) then
        -- Script not found in Redis, reload it
        sha, err = load_script_to_redis(red, "token_bucket_script_sha", rate_limit_script, true)
        if not sha then
            return nil, err
        end
        result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, refill_rate, requested_tokens, ttl)
    end

    if err then
        return nil, err
    end

    return result
end

-- Main rate limiting logic
local function check_rate_limit(red, token)
    -- Redis keys for token count and last access time
    local tokens_key = "rate_limit:" .. token .. ":tokens"
    local last_access_key = "rate_limit:" .. token .. ":last_access"

    -- Calculate TTL for the Redis keys
    local ttl = math.floor(bucket_capacity / refill_rate * 2)

    local result, err = execute_rate_limit_script(red, tokens_key, last_access_key, requested_tokens, ttl)
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

    local pcall_status, check_rate_limit_result, message = pcall(check_rate_limit, red, token)

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

    ngx.log(ngx.INFO, "Rate limit allowed for token: ", token)
end

main()
