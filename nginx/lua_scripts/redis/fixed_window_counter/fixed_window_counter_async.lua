local redis = require "resty.redis"
local resty_lock = require "resty.lock"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Fixed window parameters
local rate_limit = 100 -- Max requests allowed in the window
local window_size = 60 -- Time window size in seconds
local batch_percent = 0.5 -- Percentage of remaining requests to allow in a batch

-- Helper function to initialize shared dictionary
local function init_shared_dict()
    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
        return nil, "Failed to access shared dictionary"
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
        return nil, "Failed to connect to Redis: " .. err
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
local function acquire_lock(key)
    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(key, {
        timeout = 10
    }) -- 10 seconds timeout
    if not elapsed then
        return nil, "Failed to acquire lock: " .. err
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

-- Helper function to calculate TTL in the current window
local function calculate_window_ttl()
    local current_time = ngx.now()
    local window_start = math.floor(current_time / window_size) * window_size
    local ttl = window_size - (current_time - window_start)
    return math.max(1, math.ceil(ttl)) -- Ensure TTL is at least 1 second
end

-- Helper function to fetch batch quota from Redis
local function fetch_batch_quota(red, redis_key)
    local count, err = red:get(redis_key)
    if err then
        return nil, "Failed to GET from Redis: " .. err
    end

    count = tonumber(count) or 0
    local remaining = rate_limit - count

    if remaining <= 0 then
        return 0
    end

    local batch_size = math.ceil(remaining * batch_percent)

    return batch_size
end

-- Helper function to update Redis with the exhausted batch count
local function update_redis_with_batch(red, redis_key, batch_quota, ttl)
    local new_count, err = red:incrby(redis_key, batch_quota)
    if err then
        return nil, "Failed to INCRBY in Redis: " .. err
    end

    -- Set expiration if this is the first batch
    if new_count == batch_quota then
        red:expire(redis_key, ttl)
    end

    return true
end

-- Helper function to set batch quota and used count in shared dictionary
local function set_batch_quota_and_used(shared_dict, key, batch_size, used, ttl)
    local ok, err = shared_dict:set(key .. ":batch", batch_size, ttl)
    if not ok then
        return nil, "Failed to set batch quota in shared memory: " .. err
    end

    ok, err = shared_dict:set(key .. ":used", used, ttl)
    if not ok then
        return nil, "Failed to set used count in shared memory: " .. err
    end

    return true
end

-- Main rate limiting logic
local function check_rate_limit(red, shared_dict, token)
    -- Get the current timestamp and round it down to the nearest minute
    local current_time = ngx.now()
    local window_start = math.floor(current_time / window_size) * window_size

    -- Construct the Redis key using the token and the window start time
    local redis_key = string.format("rate_limit:%s:%d", token, window_start)

    -- Calculate TTL for the current window
    local ttl = calculate_window_ttl()

    -- Get current batch settings from shared dictionary
    local batch_quota = shared_dict:get(redis_key .. ":batch") or 0
    local batch_used = shared_dict:get(redis_key .. ":used") or 0

    -- Initialize batch quota if not already set
    if batch_quota == 0 then
        local batch_size, err = fetch_batch_quota(red, redis_key)
        if not batch_size then
            return nil, err
        end

        if batch_size > 0 then
            local success, err = set_batch_quota_and_used(shared_dict, redis_key, batch_size, 0, ttl)
            if not success then
                return nil, err
            end

            batch_quota = batch_size
        else
            -- No remaining requests in window
            return true, "rejected"
        end
    end

    -- Check if request is allowed within current batch
    if batch_quota > batch_used then
        local new_used, err = shared_dict:incr(redis_key .. ":used", 1, 0)
        if err then
            return nil, "Failed to increment used count: " .. err
        end

        if new_used == batch_quota then
            -- Update Redis with the exhausted batch on the last allowed request
            local success, err = update_redis_with_batch(red, redis_key, batch_quota, ttl)
            if not success then
                return nil, err
            end
            -- Reset used count in shared dictionary using set_batch_quota_and_used
            local success, err = set_batch_quota_and_used(shared_dict, redis_key, 0, 0, ttl)
            if not success then
                return nil, err
            end
        end
        return true, "allowed" -- Request is allowed within batch quota
    else
        return true, "rejected" -- Batch quota exceeded, reject request
    end
end

-- Main function to initialize Redis and handle rate limiting
local function main()
    local token, err = get_request_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local shared_dict, err = init_shared_dict()
    if not shared_dict then
        ngx.log(ngx.ERR, "Failed to initialize shared dictionary: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local red, err = init_redis()
    if not red then
        ngx.log(ngx.ERR, "Failed to initialize Redis: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Get the current timestamp and round it down to the nearest minute
    local current_time = ngx.now()
    local window_start = math.floor(current_time / window_size) * window_size
    local redis_key = string.format("rate_limit:%s:%d", token, window_start)

    local lock, err = acquire_lock(redis_key)
    if not lock then
        ngx.log(ngx.ERR, "Failed to acquire lock: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Rate limit the request
    local pcall_status, rate_limit_result, message = pcall(check_rate_limit, red, shared_dict, token)

    local ok, err = release_lock(lock)
    if not ok then
        ngx.log(ngx.ERR, "Failed to release lock: ", err)
    end

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

-- Run the rate limiter
main()
