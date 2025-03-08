local redis = require "resty.redis"

-- Redis connection settings
local redis_host = "redis"
local redis_port = 6379
local redis_timeout = 1000 -- 1 second
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- GCRA parameters
local period = 60 -- Time window of 1 minute
local rate = 100 -- 100 requests per minute
local burst = 5 -- Allow burst of up to 2 requests

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

-- Function to get the rate limit Lua script
local rate_limit_script = [[
    local tat_key = KEYS[1]
    local emission_interval = tonumber(ARGV[1])
    local delay_tolerance = tonumber(ARGV[2])

    -- Get the current time from Redis
    local redis_time = redis.call("TIME")
    local current_time = tonumber(redis_time[1]) * 1000000 + tonumber(redis_time[2])

    -- Retrieve the last TAT
    local last_tat = redis.call("GET", tat_key)
    last_tat = tonumber(last_tat) or current_time

    -- Calculate the allowed arrival time
    local allow_at = last_tat - delay_tolerance

    -- Check if the request is allowed
    if current_time >= allow_at then
        -- Request allowed; calculate the new TAT
        local new_tat = math.max(current_time, last_tat) + emission_interval
        
        -- Calculate TTL based on the new TAT and the current time in seconds
        local ttl = math.ceil((new_tat - current_time + delay_tolerance) / 1000000)

        -- Store the updated TAT with calculated TTL
        redis.call("SET", tat_key, new_tat, "EX", ttl)

        -- Request allowed
        return 1
    else
        -- Request denied
        return -1  
    end
]]

-- Execute the GCRA logic atomically
local function execute_rate_limit_script(red, tat_key, emission_interval, delay_tolerance)
    local sha, err = load_script_to_redis(red, "gcra_script_sha", rate_limit_script, false)
    if not sha then
        return nil, "Failed to load script: " .. err
    end

    local results, err = red:evalsha(sha, 1, tat_key, emission_interval, delay_tolerance)

    if err and err:find("NOSCRIPT", 1, true) then
        -- Script not found in Redis, reload it
        sha, err = load_script_to_redis(red, "gcra_script_sha", rate_limit_script, true)
        if not sha then
            return nil, err
        end
        results, err = red:evalsha(sha, 1, tat_key, emission_interval, delay_tolerance)
    end

    if err then
        return nil, err
    end

    return results
end

-- Main GCRA rate limiting logic
local function check_rate_limit(red, token)
    -- Redis key for storing the user's TAT (Theoretical Arrival Time)
    local tat_key = "rate_limit:" .. token .. ":tat"

    -- Calculate the emission interval and delay tolerance in microseconds
    local emission_interval = math.ceil(period / rate * 1000000)
    local delay_tolerance = emission_interval * burst

    -- Execute GCRA logic
    local result, err = execute_rate_limit_script(red, tat_key, emission_interval, delay_tolerance)
    if err then
        return nil, err
    end

    -- Handle the result
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
    else
        ngx.log(ngx.INFO, "Rate limit allowed for token: ", token)
    end
end

-- Run the main function
main()
