-- Create the rate limit table
CREATE DATABASE IF NOT EXISTS fixed_window_counter_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
USE fixed_window_counter_db;

-- Table to track rate limits per token
CREATE TABLE IF NOT EXISTS fixed_window_counter (
    user_token VARCHAR(255) NOT NULL,
    window_start BIGINT UNSIGNED NOT NULL,
    request_count INT UNSIGNED NOT NULL,
    PRIMARY KEY (user_token, window_start)
);

CREATE TABLE user (
    user_token VARCHAR(255) PRIMARY KEY
);

DELIMITER //

CREATE PROCEDURE check_rate_limit(
    IN p_user_token VARCHAR(255),
    IN p_window_size INT,
    IN p_rate_limit INT,
    OUT p_result INT
)
BEGIN
    DECLARE v_current_time BIGINT UNSIGNED;
    DECLARE v_window_start BIGINT UNSIGNED;
    DECLARE v_current_count INT UNSIGNED DEFAULT 0;

    SET v_current_time = UNIX_TIMESTAMP();

    -- Calculate window start time
    SET v_window_start = FLOOR(v_current_time / p_window_size) * p_window_size;

    INSERT IGNORE INTO user (user_token) VALUES (p_user_token);

    START TRANSACTION;

    SELECT 1 INTO @lock_dummy FROM user WHERE user_token = p_user_token FOR UPDATE;

    -- Check if an entry exists for the current window
    SELECT IFNULL(request_count, 0) 
    INTO v_current_count
    FROM fixed_window_counter
    WHERE user_token = p_user_token AND window_start = v_window_start;

    IF v_current_count = 0 THEN
        INSERT INTO fixed_window_counter (user_token, window_start, request_count)
        VALUES (p_user_token, v_window_start, 1);
        SET p_result = 1;
    ELSE
        IF v_current_count + 1 > p_rate_limit THEN
            SET p_result = -1;
        ELSE
            UPDATE fixed_window_counter
            SET request_count = request_count + 1
            WHERE user_token = p_user_token AND window_start = v_window_start;
            SET p_result = 1;
        END IF;
    END IF;

    COMMIT;
END //

DELIMITER ;