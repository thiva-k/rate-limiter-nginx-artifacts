local redis = require "resty.redis"
local resty_lock = require "resty.lock"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second timeout
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- Sliding window parameters
local window_size = 60 -- Total window size in seconds
local request_limit = 100 -- Max requests allowed in the window
local sub_window_count = 5 -- Number of subwindows
local sub_window_size = window_size / sub_window_count -- Size of each subwindow
local batch_percent = 0.5 -- Percentage of remaining quota to allocate for batch

-- Helper function to initialize shared dictionary
local function init_shared_dict()
    local shared_dict = ngx.shared.rate_limit_dict
    if not shared_dict then
        return nil, "Failed to initialize shared dictionary"
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

-- Get the current window and timestamp
local function get_current_window()
    local now = ngx.now()
    local current_window = math.floor(now / sub_window_size) * sub_window_size
    return current_window, now
end

-- Redis script to fetch current total counts
local fetch_counts_script = [[
local key_prefix = KEYS[1]
local current_window = tonumber(ARGV[1])
local sub_window_count = tonumber(ARGV[2])
local sub_window_size = tonumber(ARGV[3])
local now = tonumber(ARGV[4])

local total = 0

for i = 0, sub_window_count do
    local window_key = key_prefix .. ":" .. (current_window - i*sub_window_size)
    local count = redis.call('get', window_key)
    count = count and tonumber(count) or 0
    
    if i == sub_window_count then
        local elapsed_in_window = now % sub_window_size
        local weight = (sub_window_size - elapsed_in_window) / sub_window_size
        total = total + (count * weight)
    else
        total = total + count
    end
end

return total
]]

-- Redis script to update counts
local update_counts_script = [[
local key_prefix = KEYS[1]
local current_window = tonumber(ARGV[1])
local sub_window_size = tonumber(ARGV[2])
local updates = cjson.decode(ARGV[3])

for window_offset, count in pairs(updates) do
    local window_key = key_prefix .. ":" .. (current_window - window_offset * sub_window_size)
    if tonumber(count) > 0 then
        redis.call('incrby', window_key, count)
        redis.call('expire', window_key, 3600) -- Added expiration for safety
    end
end

return true
]]

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

-- Function to calculate and fetch batch quota with integrated fetch_window_total
local function fetch_batch_quota(red, key_prefix, current_window, now)
    -- Integrated fetch_window_total logic
    local sha, err = load_script_to_redis(red, "fetch_counts_script_sha", fetch_counts_script, false)
    if not sha then
        return 0, err
    end
    
    local total, err = red:evalsha(
        sha,
        1, -- number of keys
        key_prefix, -- KEYS[1]
        current_window, -- ARGV[1]
        sub_window_count, -- ARGV[2]
        sub_window_size, -- ARGV[3]
        now -- ARGV[4]
    )
    
    if err and err:find("NOSCRIPT", 1, true) then
        -- Script not found in Redis, reload it
        sha, err = load_script_to_redis(red, "fetch_counts_script_sha", fetch_counts_script, true)
        if not sha then
            return 0, err
        end
        total, err = red:evalsha(sha, 1, key_prefix, current_window, sub_window_count, sub_window_size, now)
    end
    
    if err then
        return 0, "Failed to execute fetch_counts script: " .. err
    end
    
    -- Calculate batch quota from the total
    local remaining = math.max(0, request_limit - total)
    return math.ceil(remaining * batch_percent)
end

-- Update Redis with accumulated counts using Lua script
local function update_redis_counts(red, key_prefix, shared_dict, current_window)
    local updates = {}
    
    -- Collect all non-zero counts
    for i = 0, sub_window_count do
        local window_key = key_prefix .. ":" .. (current_window - i * sub_window_size)
        local local_count = shared_dict:get(window_key .. ":local") or 0
        if local_count > 0 then
            updates[tostring(i)] = local_count
            shared_dict:set(window_key .. ":local", 0)
        end
    end
    
    -- Only make the Redis call if we have updates
    if next(updates) then
        local cjson = require "cjson"
        
        local sha, err = load_script_to_redis(red, "update_counts_script_sha", update_counts_script, false)
        if not sha then
            return nil, err
        end
        
        local ok, err = red:evalsha(
            sha,
            1, -- number of keys
            key_prefix, -- KEYS[1]
            current_window, -- ARGV[1]
            sub_window_size, -- ARGV[2]
            cjson.encode(updates) -- ARGV[3]
        )
        
        if err and err:find("NOSCRIPT", 1, true) then
            -- Script not found in Redis, reload it
            sha, err = load_script_to_redis(red, "update_counts_script_sha", update_counts_script, true)
            if not sha then
                return nil, err
            end
            ok, err = red:evalsha(sha, 1, key_prefix, current_window, sub_window_size, cjson.encode(updates))
        end
        
        if err then
            return nil, "Failed to execute update_counts script: " .. err
        end
    end
    
    return true
end

-- Main rate limiting logic (with process_batch_quota integrated)
local function rate_limit(red, shared_dict, token)
    local current_window, now = get_current_window()
    local key_prefix = "rate_limit:" .. token
    
    -- Integrated process_batch_quota logic
    local batch_key = key_prefix .. ":batch"
    local batch_quota = shared_dict:get(batch_key)
    
    if not batch_quota or batch_quota <= 0 then
        local new_quota, err = fetch_batch_quota(red, key_prefix, current_window, now)
        if err then
            return nil, err
        end
        if new_quota > 0 then
            shared_dict:set(batch_key, new_quota, window_size)
            batch_quota = new_quota
        else
            batch_quota = 0
        end
    end
    
    if batch_quota <= 0 then
        return true, "rejected"
    end

    -- Increment local counter for current subwindow
    local window_key = key_prefix .. ":" .. current_window
    local local_key = window_key .. ":local"
    local new_count = shared_dict:incr(local_key, 1, 0)
    
    -- Decrement batch quota
    local remaining_quota = shared_dict:incr(key_prefix .. ":batch", -1, 0)
    
    -- If batch is exhausted, update Redis
    if remaining_quota <= 0 then
        local ok, err = update_redis_counts(red, key_prefix, shared_dict, current_window)
        if not ok then
            return nil, err
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
    local pcall_status, rate_limit_result, message = pcall(rate_limit, red, shared_dict, token)

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