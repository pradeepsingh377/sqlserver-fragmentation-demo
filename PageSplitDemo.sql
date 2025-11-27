/********************************************************************************************
    SQL Server Page Split & Fragmentation Demo
    ----------------------------------------------------------
    This script demonstrates:
    1. How a page split happens
    2. How to capture BEFORE and AFTER physical row locations
    3. How to see which rows were kicked to a new page
    4. How index rebuild fixes fragmentation

    Author: Pradeep
********************************************************************************************/

SET NOCOUNT ON;
GO

/********************************************************************************************
    1. Drop + Create Test Table
********************************************************************************************/

IF OBJECT_ID('dbo.SampleData') IS NOT NULL
    DROP TABLE dbo.SampleData;
GO

CREATE TABLE dbo.SampleData (
    ID INT IDENTITY(1,1) PRIMARY KEY,
    IntColumn1 INT,
    IntColumn2 INT,
    VarcharColumn1 VARCHAR(500),
    VarcharColumn2 VARCHAR(500),
    DecimalColumn DECIMAL(18, 2)
);
GO

/********************************************************************************************
    2. Insert Sample Rows (100 rows)
********************************************************************************************/

DECLARE @n INT = 100, @i INT = 1;

WHILE @i <= @n
BEGIN
    INSERT INTO dbo.SampleData (
        IntColumn1,
        IntColumn2,
        VarcharColumn1,
        VarcharColumn2,
        DecimalColumn
    )
    VALUES (
        CAST(RAND() * 1000 AS INT),
        CAST(RAND() * 50 AS INT),
        'Row ' + CAST(@i AS VARCHAR(10)) + ' Data A: ' + CAST(NEWID() AS VARCHAR(36)),
        'Info B-' + CAST(CHECKSUM(NEWID()) AS VARCHAR(10)),
        CAST(RAND() * 5000 AS DECIMAL(18,2))
    );

    SET @i += 1;
END;
GO

/********************************************************************************************
    Helper: Function-style query to capture File/Page/Slot information
********************************************************************************************/
-- We'll reuse this snippet multiple times to capture row locations

-- Template:
-- SELECT File_ID, Page_ID, Slot_ID, Extent_ID, ID INTO #Temp FROM ( sys.fn_PhysLocFormatter ) t

/********************************************************************************************
    3. Capture BEFORE SPLIT physical layout
********************************************************************************************/

IF OBJECT_ID('tempdb..#BeforeSplit') IS NOT NULL DROP TABLE #BeforeSplit;

SELECT  
    File_ID    = CAST(PARSENAME(loc, 3) AS INT),
    Page_ID    = CAST(PARSENAME(loc, 2) AS INT),
    Slot_ID    = CAST(PARSENAME(loc, 1) AS INT),
    Extent_ID  = CAST(PARSENAME(loc, 2) AS INT) / 8,
    ID,
    IntColumn1,
    IntColumn2
INTO #BeforeSplit
FROM (
    SELECT t.*,
           REPLACE(REPLACE(REPLACE(sys.fn_PhysLocFormatter(%%physloc%%), '(', ''), ')', ''), ':', '.') AS loc
    FROM dbo.SampleData t
) t
ORDER BY Page_ID, Slot_ID;

PRINT 'Captured BEFORE SPLIT page layout';
GO

/********************************************************************************************
    4. Force a PAGE SPLIT by updating row ID = 10 with a 500-byte payload
********************************************************************************************/

UPDATE dbo.SampleData
SET VarcharColumn1 =
(
    SELECT TOP 1 
        LEFT(
            (
                SELECT CHAR(32 + ABS(CHECKSUM(NEWID())) % 95)
                FROM master..spt_values
                FOR XML PATH(''), TYPE
            ).value('.', 'varchar(max)')
        , 500)
)
WHERE ID = 10;

PRINT 'Page split triggered via update of row ID = 10';
GO

/********************************************************************************************
    5. Capture AFTER SPLIT physical layout
********************************************************************************************/

IF OBJECT_ID('tempdb..#AfterSplit') IS NOT NULL DROP TABLE #AfterSplit;

SELECT  
    File_ID    = CAST(PARSENAME(loc, 3) AS INT),
    Page_ID    = CAST(PARSENAME(loc, 2) AS INT),
    Slot_ID    = CAST(PARSENAME(loc, 1) AS INT),
    Extent_ID  = CAST(PARSENAME(loc, 2) AS INT) / 8,
    ID,
    IntColumn1,
    IntColumn2
INTO #AfterSplit
FROM (
    SELECT t.*,
           REPLACE(REPLACE(REPLACE(sys.fn_PhysLocFormatter(%%physloc%%), '(', ''), ')', ''), ':', '.') AS loc
    FROM dbo.SampleData t
) t
ORDER BY Page_ID, Slot_ID;

PRINT 'Captured AFTER SPLIT page layout';
GO

/********************************************************************************************
    6. Show EXACT CHANGES caused by the page split (rows that moved)
********************************************************************************************/

PRINT '===== ROWS THAT MOVED DURING PAGE SPLIT =====';

SELECT 
    b.ID,
    Before_Page   = b.Page_ID,
    After_Page    = a.Page_ID,
    Before_Slot   = b.Slot_ID,
    After_Slot    = a.Slot_ID,
    Before_Extent = b.Extent_ID,
    After_Extent  = a.Extent_ID
FROM #BeforeSplit b
JOIN #AfterSplit a ON b.ID = a.ID
WHERE b.Page_ID <> a.Page_ID
   OR b.Slot_ID <> a.Slot_ID
   OR b.Extent_ID <> a.Extent_ID
ORDER BY a.Page_ID, a.Slot_ID;
GO

/********************************************************************************************
    7. Rebuild Clustered Index (fix fragmentation)
********************************************************************************************/

DECLARE @IndexName SYSNAME;
SELECT @IndexName = name
FROM sys.indexes
WHERE object_id = OBJECT_ID('dbo.SampleData')
  AND is_primary_key = 1;

DECLARE @sql NVARCHAR(MAX) =
    N'ALTER INDEX [' + @IndexName + N'] ON dbo.SampleData REBUILD;';
EXEC (@sql);

PRINT 'Clustered index rebuilt - fragmentation removed';
GO

/********************************************************************************************
    8. Capture FINAL layout after rebuild (pages should be contiguous)
********************************************************************************************/

IF OBJECT_ID('tempdb..#AfterRebuild') IS NOT NULL DROP TABLE #AfterRebuild;

SELECT  
    File_ID    = CAST(PARSENAME(loc, 3) AS INT),
    Page_ID    = CAST(PARSENAME(loc, 2) AS INT),
    Slot_ID    = CAST(PARSENAME(loc, 1) AS INT),
    Extent_ID  = CAST(PARSENAME(loc, 2) AS INT) / 8,
    ID
INTO #AfterRebuild
FROM (
    SELECT t.*,
           REPLACE(REPLACE(REPLACE(sys.fn_PhysLocFormatter(%%physloc%%), '(', ''), ')', ''), ':', '.') AS loc
    FROM dbo.SampleData t
) t
ORDER BY Page_ID, Slot_ID;

PRINT 'Captured layout AFTER REBUILD';
GO

/********************************************************************************************
    9. Show final comparison (Before → After → After Rebuild)
********************************************************************************************/

PRINT '===== FINAL PAGE ALIGNMENT AFTER REBUILD =====';

SELECT 
    b.ID,
    Before_Page    = b.Page_ID,
    After_Page     = s.Page_ID,
    Rebuilt_Page   = r.Page_ID,
    Before_Extent  = b.Extent_ID,
    After_Extent   = s.Extent_ID,
    Rebuilt_Extent = r.Extent_ID
FROM #BeforeSplit b
JOIN #AfterSplit s   ON b.ID = s.ID
JOIN #AfterRebuild r ON b.ID = r.ID
ORDER BY r.Page_ID, r.Slot_ID;
GO
