local redis = require "resty.redis"
local resty_lock = require "resty.lock"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Rate limiting parameters
local rate_limit = 100 -- requests per time window
local window_size = 60 -- 60 second window
local batch_percent = 0.5 -- 50% of remaining quota
local rate_limit_script = -- Redis script to fetch current request count within window
[[ 
    local key = KEYS[1]
    local window_start = tonumber(ARGV[1])
    local rate_limit = tonumber(ARGV[2])

    -- Remove expired entries
    redis.call("ZREMRANGEBYSCORE", key, 0, window_start)

    -- Get the count of remaining members
    local count = redis.call("ZCARD", key)

    return count
]]

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

-- Function to update Redis with the exhausted batch
local function update_redis_with_exhausted_batch(red, shared_dict, redis_key)
    -- Prepare batch ZADD arguments
    local zadd_args = {}
    local list_key = redis_key .. ":timestamps"
    local timestamps_len = shared_dict:llen(list_key)

    for i = 1, timestamps_len do
        local ts, err = shared_dict:lpop(list_key)
        if ts then
            -- Add the timestamp twice: once as score and once as member
            table.insert(zadd_args, ts)
            table.insert(zadd_args, ts)
        else
            return false, "Failed to pop timestamp from shared dict: " .. (err or "unknown error")
        end
    end

    -- Only execute ZADD if there are timestamps to process
    if #zadd_args > 0 then
        local ok, err = red:zadd(redis_key, unpack(zadd_args))
        if not ok then
            return false, "Failed to update Redis with exhausted batch: " .. err
        end
    end

    return true
end

-- Main rate limiting logic
local function check_rate_limit(red, shared_dict, token)
    local redis_key = "rate_limit:" .. token

    -- Get current batch quota and timestamps length
    local batch_quota = shared_dict:get(redis_key .. ":batch")
    local timestamps_len = shared_dict:llen(redis_key .. ":timestamps")

    -- If no batch quota exists or it's exhausted, fetch a new one
    if not batch_quota or batch_quota == 0 then
        -- Calculate window start time
        local current_time = ngx.now() * 1000
        local window_start = current_time - window_size * 1000

        -- Load the script to Redis
        local sha, err = load_script_to_redis(red, "sliding_window_logs_async_sha", rate_limit_script, false)
        if not sha then
            return nil, "Failed to load script: " .. err
        end

        -- Execute the script
        local result, err = red:evalsha(sha, 1, redis_key, window_start, rate_limit)

        if err and err:find("NOSCRIPT", 1, true) then
            -- Script not found in Redis, reload it
            sha, err = load_script_to_redis(red, "sliding_window_logs_async_sha", rate_limit_script, true)
            if not sha then
                return nil, err
            end
            result, err = red:evalsha(sha, 1, redis_key, window_start, rate_limit)
        end

        if err then
            return nil, err
        end

        -- Calculate remaining requests and batch quota
        local count = tonumber(result)
        local remaining = math.max(0, rate_limit - count)

        if remaining == 0 then
            return true, "rejected" -- No more requests allowed in this window
        end

        -- Set new batch quota
        batch_quota = math.ceil(remaining * batch_percent)
        local ok, err = shared_dict:set(redis_key .. ":batch", batch_quota, window_size)
        if not ok then
            return nil, "Failed to set batch quota in shared memory: " .. err
        end
    end

    -- Add current timestamp to the batch
    local current_time = ngx.now() * 1000
    local length, err = shared_dict:rpush(redis_key .. ":timestamps", current_time)
    if not length then
        return nil, "Failed to update timestamps in shared memory: " .. err
    end

    -- Decrement the batch quota
    local new_quota, err = shared_dict:incr(redis_key .. ":batch", -1, 0)
    if err then
        return nil, "Failed to decrement batch quota: " .. err
    end

    -- If batch is exhausted, update Redis with all timestamps
    if new_quota == 0 then
        if length > 0 then
            local success, err = update_redis_with_exhausted_batch(red, shared_dict, redis_key)
            if not success then
                return nil, err
            end
        end
    end

    return true, "allowed"
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
