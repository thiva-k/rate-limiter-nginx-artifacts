local redis = require "resty.redis"
local resty_lock = require "resty.lock"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Token bucket parameters
local bucket_capacity = 5
local refill_rate = 5 / 3 -- tokens per second
local requested_tokens = 1 -- tokens required per request
local batch_percent = 0.5 -- 20% of remaining tokens for batch quota
local min_batch_quota = 1

-- Helper function to initialize shared dictionary
local function init_shared_dict()
    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
        return nil
    end

    return shared_dict
end

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

-- Helper function to acquire a lock
local function acquire_lock(token)
    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(token)
    if not elapsed then
        return nil, err
    end

    return lock
end

-- Helper function to release the lock
local function release_lock(lock)
    local ok, err = lock:unlock()
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

-- Redis script to reduce the batch quota and update the token bucket
local rate_limit_script = [[
    local tokens_key = KEYS[1]
    local last_access_key = KEYS[2]
    local bucket_capacity = tonumber(ARGV[1])
    local refill_rate = tonumber(ARGV[2])
    local requested_tokens = tonumber(ARGV[3])
    local ttl = tonumber(ARGV[4])

    local redis_time = redis.call("TIME")
    local now = tonumber(redis_time[1]) * 1000000 + tonumber(redis_time[2]) -- Convert to microseconds

    local values = redis.call("mget", tokens_key, last_access_key)
    local last_token_count = tonumber(values[1]) or bucket_capacity * 1000000
    local last_access_time = tonumber(values[2]) or now

    local elapsed_time_us = math.max(0, now - last_access_time)
    local tokens_to_add = elapsed_time_us * refill_rate
    local new_token_count = math.max(math.floor(math.min(bucket_capacity * 1000000, last_token_count + tokens_to_add - requested_tokens * 1000000)), 0)

    redis.call("set", tokens_key, new_token_count, "EX", ttl)
    redis.call("set", last_access_key, now, "EX", ttl)

    return new_token_count
]]

-- Execute the token bucket logic atomically
local function execute_rate_limit_script(red, tokens_key, last_access_key, batch_used, ttl)
    local sha, err = load_script_to_redis(red, "token_bucket_async_sha", rate_limit_script, false)
    if not sha then
        return nil, "Failed to load script: " .. err
    end

    local result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, refill_rate, batch_used, ttl)

    if err and err:find("NOSCRIPT", 1, true) then
        -- Script not found in Redis, reload it
        sha, err = load_script_to_redis(red, "token_bucket_async_sha", rate_limit_script, true)
        if not sha then
            return nil, err
        end
        result, err = red:evalsha(sha, 2, tokens_key, last_access_key, bucket_capacity, refill_rate, batch_used, ttl)
    end

    if err then
        return nil, err
    end

    return result
end

-- Function to set batch quota and batch used in shared dictionary
local function set_batch_quota_and_used(shared_dict, token, batch_quota, batch_used, ttl)
    local ok, err = shared_dict:set(token .. ":batch_quota", batch_quota, ttl)
    if not ok then
        return nil, "Failed to set batch_quota in shared_dict: " .. err
    end

    local ok, err = shared_dict:set(token .. ":batch_used", batch_used, ttl)
    if not ok then
        return nil, "Failed to set batch_used in shared_dict: " .. err
    end

    return true
end

-- Main rate limiting logic
local function check_rate_limit(red, shared_dict, token)
    -- Redis keys for token count and last access time
    local tokens_key = "rate_limit:" .. token .. ":tokens"
    local last_access_key = "rate_limit:" .. token .. ":last_access"

    -- Calculate TTL based on bucket capacity and refill rate
    local ttl = math.floor(bucket_capacity / refill_rate * 2)

    local batch_quota = shared_dict:get(token .. ":batch_quota") or 0
    local batch_used = shared_dict:get(token .. ":batch_used") or 0

    -- Initialize batch quota
    if batch_quota == 0 then
        -- Initially fetch remaining tokens to determine the current state of the token bucket
        -- without deducting any batch quota from Redis state.
        local remaining_tokens, err = execute_rate_limit_script(red, tokens_key, last_access_key, 0, ttl)
        if not remaining_tokens then
            return nil, err
        end

        -- Calculate the batch quota based on the remaining tokens
        remaining_tokens = remaining_tokens / 1000000
        if remaining_tokens < 1 then
            batch_quota = 0
        else
            batch_quota = math.max(min_batch_quota, math.floor(remaining_tokens * batch_percent))
        end

        local ok, err = set_batch_quota_and_used(shared_dict, token, batch_quota, 0, ttl)
        if not ok then
            return nil, err
        end
    end

    if batch_used < batch_quota then
        local batch_used, err = shared_dict:incr(token .. ":batch_used", 1)
        if not batch_used then
            return nil, "Failed to increment batch_used: " .. err
        end

        if batch_used == batch_quota then
            -- Batch quota exceeded, update redis with exhausted batch quota
            local remaining_tokens, err = execute_rate_limit_script(red, tokens_key, last_access_key, batch_used, ttl)
            if not remaining_tokens then
                return nil, err
            end

            -- Reset batch quota and batch used in shared dictionary
            local ok, err = set_batch_quota_and_used(shared_dict, token, 0, 0, ttl)
            if not ok then
                return nil, err
            end
        end

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

    local shared_dict = init_shared_dict()
    if not shared_dict then
        ngx.log(ngx.ERR, "Failed to initialize shared dictionary")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local lock, err = acquire_lock(token)
    if not lock then
        ngx.log(ngx.ERR, "Failed to acquire lock: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local pcall_status, check_rate_limit_result, message = pcall(check_rate_limit, red, shared_dict, token)

    local ok, err = release_lock(lock)
    if not ok then
        ngx.log(ngx.ERR, "Failed to release lock: ", err)
    end

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
