CREATE DATABASE IF NOT EXISTS sliding_window_counter_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
USE sliding_window_counter_db;

-- Table to store request counts for each sub-window
CREATE TABLE IF NOT EXISTS sliding_window_counter (
    user_token VARCHAR(255) NOT NULL,
    window_start INT NOT NULL, -- Timestamp rounded down to the start of the sub-window
    count INT DEFAULT 0, -- Request count for that sub-window
    PRIMARY KEY (user_token, window_start)
);

CREATE TABLE IF NOT EXISTS user (
    user_token VARCHAR(255) PRIMARY KEY
);

DELIMITER //

CREATE PROCEDURE check_rate_limit(
    IN p_user_token VARCHAR(255),
    IN p_window_size INT,
    IN p_request_limit INT,
    IN p_sub_window_count INT,
    OUT p_result INT
)
BEGIN
    DECLARE v_current_time INT;
    DECLARE v_sub_window_size INT;
    DECLARE v_current_window_key INT;
    DECLARE v_elapsed_time INT;
    DECLARE v_total_requests INT;
    DECLARE v_count INT;
    DECLARE v_iterator INT DEFAULT 1;
    DECLARE v_previous_window_key INT;

    -- Get current timestamp in seconds (rounded down to the nearest second)
    SET v_current_time = UNIX_TIMESTAMP(CURRENT_TIMESTAMP);
    SET v_sub_window_size = p_window_size / p_sub_window_count;
    SET v_current_window_key = FLOOR(v_current_time / v_sub_window_size) * v_sub_window_size;
    SET v_elapsed_time = v_current_time % v_sub_window_size;
    SET v_total_requests = 0;

    INSERT IGNORE INTO user (user_token) VALUES (p_user_token);

    START TRANSACTION;

    SELECT 1 INTO @lock_dummy FROM user WHERE user_token = p_user_token FOR UPDATE;

    -- Count the requests in the current sub-window
    SELECT COALESCE(sum(count), 0) INTO v_count 
    FROM sliding_window_counter 
    WHERE user_token = p_user_token 
    AND window_start = v_current_window_key;

    SET v_total_requests = v_total_requests + v_count;

    -- Add the requests from previous sub-windows, with a weight applied to the oldest window
    WHILE v_iterator <= p_sub_window_count DO
        SET v_previous_window_key = v_current_window_key - (v_iterator * v_sub_window_size);

        -- Get the request count for the previous sub-window
        SELECT COALESCE(sum(count), 0) INTO v_count 
        FROM sliding_window_counter 
        WHERE user_token = p_user_token 
        AND window_start = v_previous_window_key;

        -- Apply weight for the oldest window
        IF v_iterator = p_sub_window_count THEN
            SET v_total_requests = v_total_requests + ((v_sub_window_size - v_elapsed_time) / v_sub_window_size) * v_count;
        ELSE
            SET v_total_requests = v_total_requests + v_count;
        END IF;

        SET v_iterator = v_iterator + 1;
    END WHILE;

    -- Check if the total requests exceed the limit
    IF v_total_requests + 1 > p_request_limit THEN
        SET p_result = -1;
    ELSE
        -- Increment the count for the current sub-window
        INSERT INTO sliding_window_counter (user_token, window_start, count)
        VALUES (p_user_token, v_current_window_key, 1)
        ON DUPLICATE KEY UPDATE count = count + 1;

        SET p_result = 1;
    END IF;

    COMMIT;
END //

DELIMITER ;
