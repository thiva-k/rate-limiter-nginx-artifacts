CREATE DATABASE IF NOT EXISTS leaky_bucket_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
USE leaky_bucket_db;

CREATE TABLE user (
    user_token VARCHAR(255) PRIMARY KEY
);

CREATE TABLE leaky_bucket (
    user_token VARCHAR(255),
    leak_time BIGINT NOT NULL,
    PRIMARY KEY (user_token, leak_time)
);

DELIMITER //

CREATE PROCEDURE check_rate_limit(
    IN p_user_token VARCHAR(255), 
    IN p_bucket_capacity INT, 
    IN p_leak_rate DECIMAL(10,6),
    OUT p_delay BIGINT
)
BEGIN
    DECLARE v_current_time BIGINT;
    DECLARE v_last_leak_time BIGINT;
    DECLARE v_queue_length INT;
    DECLARE v_default_delay BIGINT;
    DECLARE v_time_diff BIGINT;
    DECLARE v_delay BIGINT DEFAULT 0;

    -- Ensure user exists
    INSERT IGNORE INTO user (user_token) VALUES (p_user_token);

    -- Start transaction to handle concurrency
    START TRANSACTION;

    -- Lock the user record for concurrency control
    SELECT 1 INTO @lock_dummy FROM user WHERE user_token = p_user_token FOR UPDATE;

    -- Get the current timestamp in microseconds
    SET v_current_time = UNIX_TIMESTAMP(NOW(6)) * 1000000;

    -- Get the most recent request timestamp
    SELECT COALESCE(MAX(leak_time), v_current_time) 
    INTO v_last_leak_time
    FROM leaky_bucket
    WHERE user_token = p_user_token;

    -- Remove leaked requests from the queue
    DELETE FROM leaky_bucket 
    WHERE user_token = p_user_token 
    AND leak_time < v_current_time;

    -- Get the updated queue length
    SELECT COUNT(*) INTO v_queue_length 
    FROM leaky_bucket 
    WHERE user_token = p_user_token;

    -- Check if the queue is within bucket capacity
    IF v_queue_length < p_bucket_capacity THEN
        -- Calculate the default leak delay in microseconds
        SET v_default_delay = FLOOR(1 / p_leak_rate * 1000000);
        
        -- Compute actual delay based on last request
        SET v_time_diff = v_current_time - v_last_leak_time;
        IF v_time_diff <> 0 THEN
            SET v_delay = GREATEST(0, v_default_delay - v_time_diff);
        END IF;

        -- Insert new request into the queue
        INSERT INTO leaky_bucket (user_token, leak_time)
        VALUES (p_user_token, v_current_time + v_delay);

        SET p_delay = v_delay;
    ELSE
        -- Request rejected due to queue capacity limit
        SET p_delay = -1;
    END IF;

    COMMIT;
END; //

DELIMITER ;