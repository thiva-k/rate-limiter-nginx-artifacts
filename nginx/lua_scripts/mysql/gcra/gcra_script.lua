local mysql = require "resty.mysql"

-- MySQL connection settings
local mysql_host = "mysql"
local mysql_port = 3306
local mysql_user = "root"
local mysql_password = "root"
local mysql_database = "gcra_db"
local mysql_timeout = 3000 -- 3 second
local max_idle_timeout = 10000 -- 10 seconds
local pool_size = 100 -- Maximum number of idle connections in the pool

-- GCRA parameters
local period = 60 -- Time window of 1 minute
local rate = 100 -- 100 requests per minute
local burst = 5 -- Allow burst of up to 2 requests

-- Helper function to initialize MySQL connection
local function init_mysql()
    local db, err = mysql:new()
    if not db then
        return nil, err
    end

    db:set_timeout(mysql_timeout)

    local ok, err, errcode, sqlstate = db:connect{
        host = mysql_host,
        port = mysql_port,
        user = mysql_user,
        password = mysql_password,
        database = mysql_database
    }
    if not ok then
        return nil, err
    end

    return db
end

-- Helper function to close MySQL connection
local function close_mysql(db)
    local ok, err = db:set_keepalive(max_idle_timeout, pool_size)
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

-- Main rate limiting logic using stored procedure
local function rate_limit(db, token)
    -- Calculate the emission interval and delay tolerance in microseconds
    local emission_interval = math.ceil(period / rate * 1000000)
    local delay_tolerance = emission_interval * burst

    local query = string.format([[
        CALL gcra_db.check_rate_limit(%s, %d, %d, @result)
    ]], ngx.quote_sql_str(token), emission_interval, delay_tolerance)

    local res, err = db:query(query)
    if not res then
        return nil, err
    end

    local res, err = db:query("SELECT @result")
    if not res then
        return nil, err
    end

    local result = tonumber(res[1]["@result"])

    if result == 1 then
        return true, "allowed"
    else
        return true, "rejected"
    end
end

-- Main function to handle rate limiting
local function main()
    local token, err = get_request_token()
    if not token then
        ngx.log(ngx.ERR, "Failed to get token: ", err)
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    local db, err = init_mysql()
    if not db then
        ngx.log(ngx.ERR, "Failed to initialize MySQL: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local pcall_status, rate_limit_result, message = pcall(rate_limit, db, token)

    local ok, err = close_mysql(db)
    if not ok then
        ngx.log(ngx.ERR, "Failed to close MySQL connection: ", err)
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
    else
        ngx.log(ngx.INFO, "Rate limit allowed for token: ", token)
    end
end

-- Run the main function
main()
