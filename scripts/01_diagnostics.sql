-- ============================================================================
-- Script Name : 01_diagnostics.sql
-- Description : Production-grade diagnostic queries for identifying top missing
--               indexes, high-IO statements, and index fragmentation in
--               SQL Server and Azure SQL Database.
-- Author      : Agam Sandhu
-- ============================================================================
-- ----------------------------------------------------------------------------
-- 1. IDENTIFY TOP MISSING INDEXES
-- Finds missing indexes based on user impact (avg user impact * user seeks)
-- ----------------------------------------------------------------------------
SELECT TOP 20
   CAST(mid.user_seeks * mid.avg_user_impact AS BIGINT) AS [Impact_Score],
   mig.index_group_handle,
   mid.index_handle,
   CONCAT(mid.statement, '') AS [Table_Name],
   mid.equality_columns AS [Equality_Columns],
   mid.inequality_columns AS [Inequality_Columns],
   mid.included_columns AS [Included_Columns],
   mid.user_seeks AS [User_Seeks],
   mid.avg_user_impact AS [Avg_User_Impact_Percent]
FROM sys.dm_db_missing_index_group_stats AS migs
INNER JOIN sys.dm_db_missing_index_groups AS mig
   ON migs.group_handle = mig.index_group_handle
INNER JOIN sys.dm_db_missing_index_details AS mid
   ON mig.index_handle = mid.index_handle
ORDER BY Impact_Score DESC;

-- ----------------------------------------------------------------------------
-- 2. IDENTIFY TOP 10 HIGH-IO / CPU EXPENSIVE QUERIES
-- Analyzes execution plans in the plan cache for highest cumulative Logical Reads
-- ----------------------------------------------------------------------------
SELECT TOP 10
   qs.total_logical_reads AS [Total_Logical_Reads],
   qs.execution_count AS [Execution_Count],
   qs.total_logical_reads / qs.execution_count AS [Avg_Logical_Reads],
   qs.total_worker_time / 1000 AS [Total_CPU_Time_ms],
   qs.total_elapsed_time / 1000 AS [Total_Elapsed_Time_ms],
   SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
       ((CASE qs.statement_end_offset
           WHEN -1 THEN DATALENGTH(st.text)
           ELSE qs.statement_end_offset
         END - qs.statement_start_offset) / 2) + 1) AS [Query_Text],
   qp.query_plan AS [Execution_Plan]
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
ORDER BY qs.total_logical_reads DESC;

-- ----------------------------------------------------------------------------
-- 3. CHECK INDEX FRAGMENTATION
-- Identifies indexes with over 15% fragmentation needing REORGANIZE or REBUILD
-- ----------------------------------------------------------------------------
SELECT
   dbschemas.name AS [Schema_Name],
   dbtables.name AS [Table_Name],
   dbindexes.name AS [Index_Name],
   indexstats.avg_fragmentation_in_percent AS [Fragmentation_Percent],
   indexstats.page_count AS [Page_Count],
   CASE
       WHEN indexstats.avg_fragmentation_in_percent > 30 THEN 'ALTER INDEX REBUILD'
       WHEN indexstats.avg_fragmentation_in_percent BETWEEN 15 AND 30 THEN 'ALTER INDEX REORGANIZE'
       ELSE 'OPTIMAL'
   END AS [Recommended_Action]
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS indexstats
INNER JOIN sys.tables AS dbtables
   ON indexstats.object_id = dbtables.object_id
INNER JOIN sys.schemas AS dbschemas
   ON dbtables.schema_id = dbschemas.schema_id
INNER JOIN sys.indexes AS dbindexes
   ON indexstats.object_id = dbindexes.object_id
   AND indexstats.index_id = dbindexes.index_id
WHERE indexstats.avg_fragmentation_in_percent > 15
 AND indexstats.page_count > 1000
ORDER BY indexstats.avg_fragmentation_in_percent DESC;
