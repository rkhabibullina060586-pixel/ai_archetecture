-- =============================================================================
-- Предиктивное обслуживание оборудования
-- Промежуточная аттестация — Хабибуллина Р.А.
--
-- База данных  : manufacturing (PostgreSQL)
-- Представление: vw_predictive_maintenance
--
-- Назначение:
--   Сворачивает поток IoT-телеметрии (> 2,29 млн измерений) в часовые окна
--   по каждой машине и размечает целевую переменную failure_next_24h —
--   произойдёт ли отказ оборудования в ближайшие 24 часа.
--
-- Одна строка результата = одна машина + один час наблюдения.
--
-- Запуск:
--   psql -h localhost -U postgres -d manufacturing -f vw_predictive_maintenance.sql
-- =============================================================================

CREATE OR REPLACE VIEW vw_predictive_maintenance AS

-- ЭТАП 1. Агрегация телеметрии по машине и часу.
-- Конструкция AGG(...) FILTER (WHERE ...) разворачивает "длинный" формат
-- (одно измерение = одна строка) в "широкий" (один час = одна строка со всеми
-- показателями) за один проход по таблице.
WITH hourly_sensor_data AS (
    SELECT
        s.machine_id,
        date_trunc('hour', sr.recorded_at) AS observation_hour,

        -- ТЕМПЕРАТУРА: уровень, пик и нестабильность
        AVG(sr.numeric_value)    FILTER (WHERE st.type_code = 'TEMPERATURE') AS mean_temperature,
        MAX(sr.numeric_value)    FILTER (WHERE st.type_code = 'TEMPERATURE') AS max_temperature,
        STDDEV(sr.numeric_value) FILTER (WHERE st.type_code = 'TEMPERATURE') AS std_temperature,

        -- ВИБРАЦИЯ: индикатор состояния механики
        AVG(sr.numeric_value)    FILTER (WHERE st.type_code = 'VIBRATION')   AS mean_vibration,
        MAX(sr.numeric_value)    FILTER (WHERE st.type_code = 'VIBRATION')   AS max_vibration,
        STDDEV(sr.numeric_value) FILTER (WHERE st.type_code = 'VIBRATION')   AS std_vibration,

        -- ЭНЕРГОПОТРЕБЛЕНИЕ: косвенный признак роста нагрузки и трения
        AVG(sr.numeric_value)    FILTER (WHERE st.type_code = 'POWER')       AS mean_power,
        MAX(sr.numeric_value)    FILTER (WHERE st.type_code = 'POWER')       AS max_power,
        STDDEV(sr.numeric_value) FILTER (WHERE st.type_code = 'POWER')       AS std_power

    FROM sensor_readings sr
    JOIN sensors      s  ON sr.sensor_id     = s.sensor_id
    JOIN sensor_types st ON s.sensor_type_id = st.sensor_type_id

    -- ОЧИСТКА НЕКОРРЕКТНЫХ ДАННЫХ:
    -- исключаем измерения, которые сама база помечает как отсутствующие,
    -- чтобы модель не обучалась на заведомо недостоверных значениях
    WHERE sr.quality_status <> 'MISSING'

    GROUP BY
        s.machine_id,
        date_trunc('hour', sr.recorded_at)
),

-- ЭТАП 2. Все аварийные остановки оборудования с моментом их возникновения.
failure_events AS (
    SELECT
        me.machine_id,
        me.started_at AS failure_time
    FROM machine_events me
    JOIN machine_event_types met
        ON me.event_type_id = met.event_type_id
    WHERE met.event_code = 'BREAKDOWN'
)

-- ЭТАП 3. Разметка целевой переменной.
-- Окно строго в БУДУЩЕМ относительно момента наблюдения
-- (failure_time > observation_hour) — это защищает от утечки целевой
-- переменной: модель не видит данных, снятых уже во время аварии.
SELECT
    h.machine_id,
    h.observation_hour,

    h.mean_temperature,
    h.max_temperature,
    h.std_temperature,

    h.mean_vibration,
    h.max_vibration,
    h.std_vibration,

    h.mean_power,
    h.max_power,
    h.std_power,

    CASE
        WHEN EXISTS (
            SELECT 1
            FROM failure_events f
            WHERE f.machine_id   = h.machine_id
              AND f.failure_time > h.observation_hour
              AND f.failure_time <= h.observation_hour + INTERVAL '24 hours'
        )
        THEN 1
        ELSE 0
    END AS failure_next_24h

FROM hourly_sensor_data h;


-- =============================================================================
-- ПРОВЕРОЧНЫЕ ЗАПРОСЫ (раскомментировать при необходимости)
-- =============================================================================

-- Объём полученного аналитического датасета
-- SELECT COUNT(*)                   AS observations,
--        COUNT(DISTINCT machine_id) AS machines,
--        MIN(observation_hour)      AS period_start,
--        MAX(observation_hour)      AS period_end
-- FROM vw_predictive_maintenance;

-- Баланс целевой переменной
-- SELECT failure_next_24h,
--        COUNT(*) AS cnt,
--        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS share_pct
-- FROM vw_predictive_maintenance
-- GROUP BY failure_next_24h
-- ORDER BY failure_next_24h;

-- Сравнение средних показателей в разрезе классов
-- SELECT failure_next_24h,
--        ROUND(AVG(mean_temperature)::numeric, 2) AS avg_temperature,
--        ROUND(AVG(mean_vibration)::numeric, 3)   AS avg_vibration,
--        ROUND(AVG(std_temperature)::numeric, 3)  AS avg_std_temperature
-- FROM vw_predictive_maintenance
-- GROUP BY failure_next_24h;

-- Доля пропусков по признакам (не все машины оснащены всеми типами сенсоров)
-- SELECT
--     ROUND(100.0 * COUNT(*) FILTER (WHERE mean_temperature IS NULL) / COUNT(*), 2) AS temp_missing_pct,
--     ROUND(100.0 * COUNT(*) FILTER (WHERE mean_vibration   IS NULL) / COUNT(*), 2) AS vibr_missing_pct,
--     ROUND(100.0 * COUNT(*) FILTER (WHERE mean_power       IS NULL) / COUNT(*), 2) AS power_missing_pct
-- FROM vw_predictive_maintenance;
