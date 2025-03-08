CREATE DATABASE IF NOT EXISTS sliding_window_log_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
USE sliding_window_log_db;

-- Table to store request timestamps per token
CREATE TABLE IF NOT EXISTS sliding_window_log (
    user_token VARCHAR(255) NOT NULL,
    request_time TIMESTAMP(3) NOT NULL,
    PRIMARY KEY (user_token, request_time)
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
    DECLARE v_current_time TIMESTAMP(3);
    DECLARE v_request_count INT;

    -- Get current timestamp with millisecond precision
    SET v_current_time = CURRENT_TIMESTAMP(3);

    INSERT IGNORE INTO user (user_token) VALUES (p_user_token);

    START TRANSACTION;

    SELECT 1 INTO @lock_dummy FROM user WHERE user_token = p_user_token FOR UPDATE;

    -- Remove outdated requests outside the sliding window
    DELETE FROM sliding_window_log
    WHERE user_token = p_user_token 
    AND request_time < (v_current_time - INTERVAL p_window_size SECOND);

    -- Count the remaining requests within the current window
    SELECT COUNT(*)
    INTO v_request_count
    FROM sliding_window_log
    WHERE user_token = p_user_token;

    IF v_request_count < p_rate_limit THEN
        -- Log the current request
        INSERT INTO sliding_window_log (user_token, request_time)
        VALUES (p_user_token, v_current_time);
        SET p_result = 1;
    ELSE
        SET p_result = -1;
    END IF;

    COMMIT;
END //

DELIMITER ;
