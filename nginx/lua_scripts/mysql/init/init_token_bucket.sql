CREATE DATABASE IF NOT EXISTS token_bucket_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
USE token_bucket_db;

CREATE TABLE user (
    user_token VARCHAR(255) PRIMARY KEY
);

CREATE TABLE token_bucket (
    user_token VARCHAR(255) PRIMARY KEY,
    last_access_time BIGINT NOT NULL, -- Microsecond timestamp
    tokens_available BIGINT NOT NULL
);

DELIMITER //

CREATE PROCEDURE check_rate_limit(
    IN p_user_token VARCHAR(255), 
    IN p_bucket_capacity INT, 
    IN p_refill_rate DECIMAL(10,6), 
    IN p_tokens_requested INT,
    OUT p_result INT
)
BEGIN
    DECLARE v_last_access_time BIGINT;
    DECLARE v_tokens_available BIGINT;
    DECLARE v_current_time BIGINT;
    DECLARE v_elapsed_time BIGINT;
    DECLARE v_tokens_to_add BIGINT;
    DECLARE v_new_token_count BIGINT;
    DECLARE v_final_token_count BIGINT;

    INSERT IGNORE INTO user (user_token) VALUES (p_user_token);

    -- Start transaction to handle concurrency
    START TRANSACTION;

    procedure_block: BEGIN
        -- Lock the user record
        SELECT 1 INTO @lock_dummy FROM user WHERE user_token = p_user_token FOR UPDATE;
        
        SELECT last_access_time, tokens_available
        INTO v_last_access_time, v_tokens_available
        FROM token_bucket
        WHERE user_token = p_user_token;

        -- Get the current timestamp in microseconds
        SET v_current_time = UNIX_TIMESTAMP(NOW(6)) * 1000000;

        -- If user record does not exist, initialize it
        IF v_tokens_available IS NULL THEN
            SET v_tokens_available = (p_bucket_capacity - p_tokens_requested) * 1000000;
            SET v_last_access_time = v_current_time;

            INSERT INTO token_bucket (user_token, last_access_time, tokens_available)
            VALUES (p_user_token, v_last_access_time, v_tokens_available)
            ON DUPLICATE KEY UPDATE last_access_time = v_last_access_time, tokens_available = v_tokens_available;

            SET p_result = 1;
            LEAVE procedure_block;
        END IF;

        -- Compute elapsed time in microseconds
        SET v_elapsed_time = GREATEST(0, v_current_time - v_last_access_time);

        -- Compute how many tokens to add based on elapsed time
        SET v_tokens_to_add = FLOOR(v_elapsed_time * p_refill_rate);

        -- Update token count but do not exceed capacity
        SET v_new_token_count = LEAST(p_bucket_capacity * 1000000, v_tokens_available + v_tokens_to_add);

        -- Check if enough tokens are available for the request
        IF v_new_token_count >= p_tokens_requested * 1000000 THEN
            SET v_final_token_count = v_new_token_count - (p_tokens_requested * 1000000);

            -- Update token count and last access time
            UPDATE token_bucket 
            SET tokens_available = v_final_token_count,
                last_access_time = v_current_time
            WHERE user_token = p_user_token;

            SET p_result = 1;
        ELSE
            -- Not enough tokens
            SET p_result = -1;
        END IF;
    END procedure_block;

    COMMIT;
END; //

DELIMITER ;
