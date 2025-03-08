CREATE DATABASE IF NOT EXISTS gcra_db;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
USE gcra_db;

CREATE TABLE user (
    user_token VARCHAR(255) PRIMARY KEY
);

CREATE TABLE gcra (
    user_token VARCHAR(255) PRIMARY KEY,
    last_tat BIGINT NOT NULL -- Theoretical Arrival Time (TAT) in microseconds
);

DELIMITER //

CREATE PROCEDURE check_rate_limit(
    IN p_user_token VARCHAR(255),
    IN p_emission_interval BIGINT,  -- Emission interval in microseconds
    IN p_delay_tolerance BIGINT,    -- Delay tolerance in microseconds
    OUT p_result INT
)
BEGIN
    DECLARE v_last_tat BIGINT;
    DECLARE v_current_time BIGINT;
    DECLARE v_allow_at BIGINT;
    DECLARE v_new_tat BIGINT;

    -- Ensure user exists
    INSERT IGNORE INTO user (user_token) VALUES (p_user_token);

    -- Start transaction to handle concurrency
    START TRANSACTION;

    -- Lock the user record for concurrency control
    SELECT 1 INTO @lock_dummy FROM user WHERE user_token = p_user_token FOR UPDATE;

    procedure_block: BEGIN
        -- Lock the user record for update
        SELECT last_tat
        INTO v_last_tat
        FROM gcra
        WHERE user_token = p_user_token;

        -- Get the current time in microseconds
        SET v_current_time = UNIX_TIMESTAMP(NOW(6)) * 1000000;

        -- If no existing record, initialize
        IF v_last_tat IS NULL THEN
            SET v_last_tat = v_current_time + p_emission_interval;
            INSERT INTO gcra (user_token, last_tat)
            VALUES (p_user_token, v_last_tat)
            ON DUPLICATE KEY UPDATE last_tat = v_last_tat;

            SET p_result = 1;
            LEAVE procedure_block;
        END IF;

        -- Compute the allowed arrival time
        SET v_allow_at = v_last_tat - p_delay_tolerance;

        -- Check if the request is allowed
        IF v_current_time >= v_allow_at THEN
            -- Request allowed, update TAT
            SET v_new_tat = GREATEST(v_current_time, v_last_tat) + p_emission_interval;

            -- Update bucket state
            UPDATE gcra
            SET last_tat = v_new_tat
            WHERE user_token = p_user_token;

            SET p_result = 1;
        ELSE
            -- Request denied
            SET p_result = -1;
        END IF;
    END procedure_block;

    COMMIT;
END; //

DELIMITER ;
