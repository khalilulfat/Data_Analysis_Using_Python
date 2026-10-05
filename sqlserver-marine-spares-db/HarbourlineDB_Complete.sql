/* =====================================================================================
   HarbourlineDB  -  Marine Spares Distribution (fictional company, invented data)
   -------------------------------------------------------------------------------------
   ONE FILE: structure + views + procedures + data + demo + diagram.
   SQL Server 2017 or later. Open in SSMS and press F5. Re-runnable (drops & recreates).

   Design: 10 tables, every hierarchy is exactly TWO levels deep
       Warehouse     -> StorageBin       (where stock is kept)
       ProductGroup  -> Product          (what is sold)
       SalesOrder    -> SalesOrderLine   (what was ordered)
     plus Supplier, Customer, StockLevel (Product x Bin) and StockMovement (ledger).

   STEP 1  Database, 10 tables, keys, constraints, indexes
   STEP 2  7 views
   STEP 3  7 stored procedures
   STEP 4  Data
   STEP 5  Live demo, showcase queries, database diagram (at the end of the file)
   ===================================================================================== */

/* =====================================================================================
   STEP 1 of 5 : DATABASE, TABLES, RELATIONSHIPS, INDEXES
   ===================================================================================== */
USE master;
GO
IF DB_ID(N'HarbourlineDB') IS NOT NULL
BEGIN
    ALTER DATABASE HarbourlineDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE HarbourlineDB;
END;
GO
CREATE DATABASE HarbourlineDB;
GO
USE HarbourlineDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
CREATE SCHEMA Spares;
GO

/* ---------- 1. Warehouse (level 1 of the storage structure) ---------- */
CREATE TABLE Spares.Warehouse
(
    WarehouseId    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Warehouse PRIMARY KEY,
    WarehouseCode  varchar(10)  NOT NULL CONSTRAINT UQ_Warehouse_Code UNIQUE,
    WarehouseName  nvarchar(80) NOT NULL,
    City           nvarchar(60) NOT NULL,
    IsActive       bit NOT NULL CONSTRAINT DF_Warehouse_Active DEFAULT (1)
);

/* ---------- 2. StorageBin (level 2: every bin belongs to one warehouse) ---------- */
CREATE TABLE Spares.StorageBin
(
    BinId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_StorageBin PRIMARY KEY,
    WarehouseId  int NOT NULL CONSTRAINT FK_Bin_Warehouse REFERENCES Spares.Warehouse(WarehouseId),
    BinCode      varchar(20) NOT NULL CONSTRAINT UQ_Bin_Code UNIQUE,
    BinType      varchar(10) NOT NULL CONSTRAINT CK_Bin_Type CHECK (BinType IN ('SHELF','PALLET','SECURE')),
    MaxWeightKg  decimal(9,2) NOT NULL CONSTRAINT CK_Bin_MaxWeight CHECK (MaxWeightKg > 0),
    IsActive     bit NOT NULL CONSTRAINT DF_Bin_Active DEFAULT (1)
);

/* ---------- 3. ProductGroup (level 1 of the catalogue) ---------- */
CREATE TABLE Spares.ProductGroup
(
    GroupId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProductGroup PRIMARY KEY,
    GroupCode   varchar(10)  NOT NULL CONSTRAINT UQ_Group_Code UNIQUE,
    GroupName   nvarchar(80) NOT NULL,
    NeedsSecureStorage bit NOT NULL CONSTRAINT DF_Group_Secure DEFAULT (0)   -- e.g. pyrotechnics, beacons
);

/* ---------- 4. Supplier ---------- */
CREATE TABLE Spares.Supplier
(
    SupplierId    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Supplier PRIMARY KEY,
    SupplierCode  varchar(10)   NOT NULL CONSTRAINT UQ_Supplier_Code UNIQUE,
    SupplierName  nvarchar(100) NOT NULL,
    CountryCode   char(2)       NOT NULL,
    LeadTimeDays  smallint      NOT NULL CONSTRAINT CK_Supplier_Lead CHECK (LeadTimeDays BETWEEN 0 AND 180)
);

/* ---------- 5. Product (level 2: every product belongs to one group) ---------- */
CREATE TABLE Spares.Product
(
    ProductId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Product PRIMARY KEY,
    PartNumber    varchar(20)   NOT NULL CONSTRAINT UQ_Product_Part UNIQUE,
    ProductName   nvarchar(100) NOT NULL,
    GroupId       int NOT NULL CONSTRAINT FK_Product_Group    REFERENCES Spares.ProductGroup(GroupId),
    SupplierId    int NOT NULL CONSTRAINT FK_Product_Supplier REFERENCES Spares.Supplier(SupplierId),
    UnitWeightKg  decimal(8,3)  NOT NULL CONSTRAINT CK_Product_Weight CHECK (UnitWeightKg > 0),
    UnitCost      decimal(10,2) NOT NULL CONSTRAINT CK_Product_Cost   CHECK (UnitCost >= 0),
    ListPrice     decimal(10,2) NOT NULL,
    ReorderLevel  int NOT NULL CONSTRAINT DF_Product_ROL DEFAULT (0),
    ReorderQty    int NOT NULL CONSTRAINT DF_Product_ROQ DEFAULT (0),
    IsActive      bit NOT NULL CONSTRAINT DF_Product_Active DEFAULT (1),
    CONSTRAINT CK_Product_Price   CHECK (ListPrice >= UnitCost),
    CONSTRAINT CK_Product_Reorder CHECK (ReorderLevel >= 0 AND ReorderQty >= 0)
);

/* ---------- 6. StockLevel (many-to-many: Product x StorageBin) ---------- */
CREATE TABLE Spares.StockLevel
(
    ProductId      int NOT NULL CONSTRAINT FK_Stock_Product REFERENCES Spares.Product(ProductId),
    BinId          int NOT NULL CONSTRAINT FK_Stock_Bin     REFERENCES Spares.StorageBin(BinId),
    QtyOnHand      int NOT NULL CONSTRAINT CK_Stock_Qty CHECK (QtyOnHand >= 0),
    LastMovedAt    datetime2(0) NOT NULL CONSTRAINT DF_Stock_Moved DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_StockLevel PRIMARY KEY (ProductId, BinId)
);

/* ---------- 7. Customer ---------- */
CREATE TABLE Spares.Customer
(
    CustomerId    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Customer PRIMARY KEY,
    CustomerCode  varchar(10)   NOT NULL CONSTRAINT UQ_Customer_Code UNIQUE,
    CustomerName  nvarchar(100) NOT NULL,
    CustomerType  varchar(10)   NOT NULL CONSTRAINT CK_Customer_Type CHECK (CustomerType IN ('SHIPYARD','FLEET','CHANDLERY','MARINA')),
    City          nvarchar(60)  NOT NULL,
    CreditLimit   decimal(12,2) NOT NULL CONSTRAINT CK_Customer_Credit CHECK (CreditLimit >= 0),
    DiscountPct   decimal(5,2)  NOT NULL CONSTRAINT DF_Customer_Disc DEFAULT (0)
                      CONSTRAINT CK_Customer_Disc CHECK (DiscountPct BETWEEN 0 AND 40),
    IsActive      bit NOT NULL CONSTRAINT DF_Customer_Active DEFAULT (1)
);

/* ---------- 8. SalesOrder (level 1 of the order document) ---------- */
CREATE TABLE Spares.SalesOrder
(
    OrderId       int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SalesOrder PRIMARY KEY,
    OrderNumber   varchar(15) NOT NULL CONSTRAINT UQ_Order_Number UNIQUE,
    CustomerId    int NOT NULL CONSTRAINT FK_Order_Customer  REFERENCES Spares.Customer(CustomerId),
    WarehouseId   int NOT NULL CONSTRAINT FK_Order_Warehouse REFERENCES Spares.Warehouse(WarehouseId),
    OrderDate     datetime2(0) NOT NULL CONSTRAINT DF_Order_Date DEFAULT (SYSDATETIME()),
    RequiredDate  date NOT NULL,
    Status        varchar(10) NOT NULL CONSTRAINT DF_Order_Status DEFAULT ('OPEN')
                      CONSTRAINT CK_Order_Status CHECK (Status IN ('OPEN','SHIPPED','CANCELLED')),
    ShippedAt     datetime2(0) NULL,
    Carrier       nvarchar(40) NULL,
    CONSTRAINT CK_Order_Shipped CHECK ((Status = 'SHIPPED' AND ShippedAt IS NOT NULL AND Carrier IS NOT NULL)
                                    OR (Status <> 'SHIPPED' AND ShippedAt IS NULL))
);

/* ---------- 9. SalesOrderLine (level 2: lines belong to one order) ---------- */
CREATE TABLE Spares.SalesOrderLine
(
    OrderLineId  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SalesOrderLine PRIMARY KEY,
    OrderId      int NOT NULL CONSTRAINT FK_Line_Order REFERENCES Spares.SalesOrder(OrderId) ON DELETE CASCADE,
    LineNumber   smallint NOT NULL,
    ProductId    int NOT NULL CONSTRAINT FK_Line_Product REFERENCES Spares.Product(ProductId),
    Quantity     int NOT NULL CONSTRAINT CK_Line_Qty CHECK (Quantity > 0),
    UnitPrice    decimal(10,2) NOT NULL,
    DiscountPct  decimal(5,2)  NOT NULL CONSTRAINT DF_Line_Disc DEFAULT (0),
    LineTotal    AS CAST(Quantity * UnitPrice * (1 - DiscountPct / 100) AS decimal(12,2)),
    CONSTRAINT UQ_Line_Number  UNIQUE (OrderId, LineNumber),
    CONSTRAINT UQ_Line_Product UNIQUE (OrderId, ProductId)
);

/* ---------- 10. StockMovement (audit ledger of every stock change) ---------- */
CREATE TABLE Spares.StockMovement
(
    MovementId    bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_StockMovement PRIMARY KEY,
    MovementType  varchar(10) NOT NULL CONSTRAINT CK_Move_Type CHECK (MovementType IN ('OPENING','RECEIPT','TRANSFER','ISSUE','ADJUST')),
    ProductId     int NOT NULL CONSTRAINT FK_Move_Product  REFERENCES Spares.Product(ProductId),
    FromBinId     int NULL     CONSTRAINT FK_Move_FromBin  REFERENCES Spares.StorageBin(BinId),
    ToBinId       int NULL     CONSTRAINT FK_Move_ToBin    REFERENCES Spares.StorageBin(BinId),
    Quantity      int NOT NULL CONSTRAINT CK_Move_Qty CHECK (Quantity > 0),
    SupplierId    int NULL     CONSTRAINT FK_Move_Supplier REFERENCES Spares.Supplier(SupplierId),
    OrderId       int NULL     CONSTRAINT FK_Move_Order    REFERENCES Spares.SalesOrder(OrderId),
    MovedAt       datetime2(0) NOT NULL CONSTRAINT DF_Move_At DEFAULT (SYSDATETIME()),
    Notes         nvarchar(200) NULL,
    CONSTRAINT CK_Move_Direction CHECK (
        (MovementType IN ('OPENING','RECEIPT') AND FromBinId IS NULL     AND ToBinId IS NOT NULL) OR
        (MovementType = 'ISSUE'                AND FromBinId IS NOT NULL AND ToBinId IS NULL)     OR
        (MovementType = 'TRANSFER'             AND FromBinId IS NOT NULL AND ToBinId IS NOT NULL AND FromBinId <> ToBinId) OR
        (MovementType = 'ADJUST'               AND (FromBinId IS NULL OR ToBinId IS NULL)
                                               AND NOT (FromBinId IS NULL AND ToBinId IS NULL)))
);
GO

CREATE SEQUENCE Spares.seq_OrderNo AS int START WITH 50001 INCREMENT BY 1;
GO

/* ---------- Indexes on foreign keys and common filters ---------- */
CREATE INDEX IX_Bin_Warehouse     ON Spares.StorageBin (WarehouseId) INCLUDE (BinCode, BinType);
CREATE INDEX IX_Product_Group     ON Spares.Product (GroupId) INCLUDE (PartNumber, ProductName);
CREATE INDEX IX_Product_Supplier  ON Spares.Product (SupplierId);
CREATE INDEX IX_Stock_Bin         ON Spares.StockLevel (BinId) INCLUDE (QtyOnHand);
CREATE INDEX IX_Order_Customer    ON Spares.SalesOrder (CustomerId, OrderDate);
CREATE INDEX IX_Order_Open        ON Spares.SalesOrder (WarehouseId) INCLUDE (CustomerId) WHERE Status = 'OPEN';
CREATE INDEX IX_Line_Product      ON Spares.SalesOrderLine (ProductId) INCLUDE (Quantity);
CREATE INDEX IX_Move_ProductDate  ON Spares.StockMovement (ProductId, MovedAt);
CREATE INDEX IX_Move_Order        ON Spares.StockMovement (OrderId) WHERE OrderId IS NOT NULL;
GO
PRINT 'Step 1 complete: 10 tables, 1 sequence, indexes.';
GO

/* =====================================================================================
   STEP 2 of 5 : VIEWS
     Spares.vw_WarehouseBinTree   two-level tree: warehouse totals, then each bin
     Spares.vw_BinContents        bin-level stock detail with weight load
     Spares.vw_ProductCatalogue   two-level catalogue: group > product, margin, stock
     Spares.vw_StockByWarehouse   on hand, committed to open orders, available
     Spares.vw_ReorderList        products below reorder level, suggested quantity
     Spares.vw_OrderSummary       order header + line totals, late-shipment flag
     Spares.vw_SalesByGroup       90-day sales with group subtotals (ROLLUP)
   ===================================================================================== */
USE HarbourlineDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* Two-level tree in one result: level 1 = warehouse (with totals), level 2 = its bins.
   ORDER BY SortKey to display the tree. */
CREATE OR ALTER VIEW Spares.vw_WarehouseBinTree
AS
SELECT
    w.WarehouseCode,
    1                                                   AS TreeLevel,
    'WAREHOUSE'                                         AS NodeType,
    w.WarehouseCode                                     AS NodeCode,
    w.WarehouseName + N' (' + w.City + N')'             AS DisplayName,
    (SELECT COUNT(*) FROM Spares.StorageBin b WHERE b.WarehouseId = w.WarehouseId) AS BinCount,
    COALESCE(st.Products, 0)                            AS DistinctProducts,
    COALESCE(st.Units, 0)                               AS UnitsOnHand,
    CAST(COALESCE(st.LoadKg, 0) AS decimal(12,2))       AS LoadKg,
    cap.CapacityKg,
    CAST(100.0 * COALESCE(st.LoadKg, 0) / NULLIF(cap.CapacityKg, 0) AS decimal(5,1)) AS UtilisationPct,
    CAST(COALESCE(st.StockValue, 0) AS decimal(12,2))   AS StockValue,
    CAST(w.WarehouseCode AS varchar(40))                AS SortKey
FROM Spares.Warehouse w
OUTER APPLY (SELECT COUNT(DISTINCT s.ProductId)       AS Products,
                    SUM(s.QtyOnHand)                  AS Units,
                    SUM(s.QtyOnHand * p.UnitWeightKg) AS LoadKg,
                    SUM(s.QtyOnHand * p.UnitCost)     AS StockValue
               FROM Spares.StorageBin b
               JOIN Spares.StockLevel s ON s.BinId = b.BinId AND s.QtyOnHand > 0
               JOIN Spares.Product p    ON p.ProductId = s.ProductId
              WHERE b.WarehouseId = w.WarehouseId) st
OUTER APPLY (SELECT CAST(SUM(b.MaxWeightKg) AS decimal(12,2)) AS CapacityKg
               FROM Spares.StorageBin b
              WHERE b.WarehouseId = w.WarehouseId) cap

UNION ALL

SELECT
    w.WarehouseCode,
    2,
    'BIN',
    b.BinCode,
    N'    ' + b.BinCode + N' - ' + LOWER(b.BinType),
    NULL,
    COALESCE(st.Products, 0),
    COALESCE(st.Units, 0),
    CAST(COALESCE(st.LoadKg, 0) AS decimal(12,2)),
    CAST(b.MaxWeightKg AS decimal(12,2)),
    CAST(100.0 * COALESCE(st.LoadKg, 0) / b.MaxWeightKg AS decimal(5,1)),
    CAST(COALESCE(st.StockValue, 0) AS decimal(12,2)),
    CAST(CONCAT(w.WarehouseCode, '|', b.BinCode) AS varchar(40))
FROM Spares.StorageBin b
JOIN Spares.Warehouse w ON w.WarehouseId = b.WarehouseId
OUTER APPLY (SELECT COUNT(*)                          AS Products,
                    SUM(s.QtyOnHand)                  AS Units,
                    SUM(s.QtyOnHand * p.UnitWeightKg) AS LoadKg,
                    SUM(s.QtyOnHand * p.UnitCost)     AS StockValue
               FROM Spares.StockLevel s
               JOIN Spares.Product p ON p.ProductId = s.ProductId
              WHERE s.BinId = b.BinId AND s.QtyOnHand > 0) st;
GO

CREATE OR ALTER VIEW Spares.vw_BinContents
AS
SELECT
    w.WarehouseCode,
    b.BinCode,
    b.BinType,
    g.GroupCode,
    p.PartNumber,
    p.ProductName,
    s.QtyOnHand,
    CAST(s.QtyOnHand * p.UnitWeightKg AS decimal(10,2)) AS LoadKg,
    CAST(s.QtyOnHand * p.UnitCost     AS decimal(12,2)) AS StockValue,
    s.LastMovedAt
FROM Spares.StockLevel s
JOIN Spares.StorageBin b   ON b.BinId = s.BinId
JOIN Spares.Warehouse w    ON w.WarehouseId = b.WarehouseId
JOIN Spares.Product p      ON p.ProductId = s.ProductId
JOIN Spares.ProductGroup g ON g.GroupId = p.GroupId
WHERE s.QtyOnHand > 0;
GO

CREATE OR ALTER VIEW Spares.vw_ProductCatalogue
AS
SELECT
    g.GroupCode,
    g.GroupName,
    p.PartNumber,
    p.ProductName,
    s.SupplierName,
    s.LeadTimeDays,
    p.UnitCost,
    p.ListPrice,
    CAST(100.0 * (p.ListPrice - p.UnitCost) / NULLIF(p.ListPrice, 0) AS decimal(5,1)) AS MarginPct,
    COALESCE(st.TotalOnHand, 0) AS TotalOnHand,
    p.ReorderLevel,
    g.NeedsSecureStorage,
    p.IsActive
FROM Spares.Product p
JOIN Spares.ProductGroup g ON g.GroupId = p.GroupId
JOIN Spares.Supplier s     ON s.SupplierId = p.SupplierId
OUTER APPLY (SELECT SUM(sl.QtyOnHand) AS TotalOnHand
               FROM Spares.StockLevel sl
              WHERE sl.ProductId = p.ProductId) st;
GO

/* Available = on hand in the warehouse minus quantity on OPEN orders from that warehouse */
CREATE OR ALTER VIEW Spares.vw_StockByWarehouse
AS
WITH OnHand AS
(
    SELECT s.ProductId, b.WarehouseId, SUM(s.QtyOnHand) AS QtyOnHand
    FROM Spares.StockLevel s
    JOIN Spares.StorageBin b ON b.BinId = s.BinId
    GROUP BY s.ProductId, b.WarehouseId
),
Committed AS
(
    SELECT l.ProductId, o.WarehouseId, SUM(l.Quantity) AS QtyCommitted
    FROM Spares.SalesOrderLine l
    JOIN Spares.SalesOrder o ON o.OrderId = l.OrderId
    WHERE o.Status = 'OPEN'
    GROUP BY l.ProductId, o.WarehouseId
)
SELECT
    w.WarehouseCode,
    p.PartNumber,
    p.ProductName,
    COALESCE(oh.QtyOnHand, 0)                                   AS QtyOnHand,
    COALESCE(c.QtyCommitted, 0)                                 AS QtyCommitted,
    COALESCE(oh.QtyOnHand, 0) - COALESCE(c.QtyCommitted, 0)     AS QtyAvailable,
    p.ProductId,
    w.WarehouseId
FROM OnHand oh
FULL OUTER JOIN Committed c ON c.ProductId = oh.ProductId AND c.WarehouseId = oh.WarehouseId
JOIN Spares.Product p   ON p.ProductId   = COALESCE(oh.ProductId, c.ProductId)
JOIN Spares.Warehouse w ON w.WarehouseId = COALESCE(oh.WarehouseId, c.WarehouseId);
GO

CREATE OR ALTER VIEW Spares.vw_ReorderList
AS
WITH Network AS
(
    SELECT ProductId, SUM(QtyOnHand) AS QtyOnHand, SUM(QtyCommitted) AS QtyCommitted, SUM(QtyAvailable) AS QtyAvailable
    FROM Spares.vw_StockByWarehouse
    GROUP BY ProductId
)
SELECT
    g.GroupName,
    p.PartNumber,
    p.ProductName,
    COALESCE(n.QtyOnHand, 0)     AS QtyOnHand,
    COALESCE(n.QtyCommitted, 0)  AS QtyCommitted,
    COALESCE(n.QtyAvailable, 0)  AS QtyAvailable,
    p.ReorderLevel,
    CASE WHEN p.ReorderLevel - COALESCE(n.QtyAvailable, 0) > p.ReorderQty
         THEN p.ReorderLevel - COALESCE(n.QtyAvailable, 0)
         ELSE p.ReorderQty END   AS SuggestedOrderQty,
    s.SupplierName,
    s.LeadTimeDays,
    CASE WHEN COALESCE(n.QtyAvailable, 0) <= 0 THEN 'OUT OF STOCK'
         WHEN COALESCE(n.QtyAvailable, 0) < p.ReorderLevel / 2.0 THEN 'CRITICAL'
         ELSE 'LOW' END          AS Urgency
FROM Spares.Product p
JOIN Spares.ProductGroup g ON g.GroupId = p.GroupId
JOIN Spares.Supplier s     ON s.SupplierId = p.SupplierId
LEFT JOIN Network n        ON n.ProductId = p.ProductId
WHERE p.IsActive = 1
  AND COALESCE(n.QtyAvailable, 0) < p.ReorderLevel;
GO

CREATE OR ALTER VIEW Spares.vw_OrderSummary
AS
SELECT
    o.OrderNumber,
    c.CustomerCode,
    c.CustomerName,
    c.CustomerType,
    w.WarehouseCode,
    o.OrderDate,
    o.RequiredDate,
    o.Status,
    o.ShippedAt,
    o.Carrier,
    COUNT(l.OrderLineId)                         AS LineCount,
    COALESCE(SUM(l.Quantity), 0)                 AS Units,
    CAST(COALESCE(SUM(l.LineTotal), 0) AS decimal(12,2)) AS OrderValue,
    CASE WHEN o.Status = 'SHIPPED' AND CAST(o.ShippedAt AS date) > o.RequiredDate THEN 1
         WHEN o.Status = 'OPEN'    AND CAST(SYSDATETIME() AS date) > o.RequiredDate THEN 1
         ELSE 0 END                              AS IsLate,
    CASE WHEN o.Status = 'SHIPPED' THEN DATEDIFF(day, o.RequiredDate, CAST(o.ShippedAt AS date))
         WHEN o.Status = 'OPEN'    THEN DATEDIFF(day, o.RequiredDate, CAST(SYSDATETIME() AS date))
         END                                     AS DaysVsRequired      -- positive = late
FROM Spares.SalesOrder o
JOIN Spares.Customer c  ON c.CustomerId  = o.CustomerId
JOIN Spares.Warehouse w ON w.WarehouseId = o.WarehouseId
LEFT JOIN Spares.SalesOrderLine l ON l.OrderId = o.OrderId
GROUP BY o.OrderNumber, c.CustomerCode, c.CustomerName, c.CustomerType, w.WarehouseCode,
         o.OrderDate, o.RequiredDate, o.Status, o.ShippedAt, o.Carrier;
GO

/* ROLLUP gives level-1 subtotals (group) and level-2 detail (product) plus a grand total */
CREATE OR ALTER VIEW Spares.vw_SalesByGroup
AS
SELECT
    CASE WHEN GROUPING(g.GroupName) = 1   THEN N'** GRAND TOTAL **'
         ELSE g.GroupName END                                   AS GroupName,
    CASE WHEN GROUPING(g.GroupName) = 1   THEN NULL
         WHEN GROUPING(p.PartNumber) = 1  THEN N'-- group subtotal --'
         ELSE p.PartNumber END                                  AS PartNumber,
    GROUPING(g.GroupName) + GROUPING(p.PartNumber)              AS RollupLevel,  -- 0 detail, 1 group, 2 total
    SUM(l.Quantity)                                             AS UnitsSold,
    CAST(SUM(l.LineTotal) AS decimal(12,2))                     AS Revenue,
    CAST(SUM(l.LineTotal - l.Quantity * p.UnitCost) AS decimal(12,2)) AS GrossProfit
FROM Spares.SalesOrderLine l
JOIN Spares.SalesOrder o   ON o.OrderId = l.OrderId
JOIN Spares.Product p      ON p.ProductId = l.ProductId
JOIN Spares.ProductGroup g ON g.GroupId = p.GroupId
WHERE o.Status = 'SHIPPED'
  AND o.ShippedAt >= DATEADD(day, -90, SYSDATETIME())
GROUP BY ROLLUP (g.GroupName, p.PartNumber);
GO
PRINT 'Step 2 complete: 7 views.';
GO

/* =====================================================================================
   STEP 3 of 5 : STORED PROCEDURES
     Spares.usp_ReceiveStock      goods-in with secure-storage and bin weight rules
     Spares.usp_TransferStock     bin-to-bin or warehouse-to-warehouse move
     Spares.usp_CreateOrder       order header with generated order number
     Spares.usp_AddOrderLine      order line with availability and credit-limit checks
     Spares.usp_ShipOrder         set-based bin picking, stock issue, ledger, status
     Spares.usp_CancelOrder       cancel an open order (releases committed stock)
     Spares.usp_WarehouseReport   two-level report for one warehouse
   Every write procedure: XACT_ABORT + TRY/CATCH + THROW, and writes the ledger.
   ===================================================================================== */
USE HarbourlineDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE Spares.usp_ReceiveStock
    @PartNumber    varchar(20),
    @BinCode       varchar(20),
    @Quantity      int,
    @SupplierCode  varchar(10)   = NULL,     -- NULL = product's usual supplier
    @Notes         nvarchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProductId int, @UnitWeight decimal(8,3), @NeedsSecure bit, @DefaultSupplier int,
            @SupplierId int, @BinId int, @BinType varchar(10), @MaxWeight decimal(9,2),
            @CurrentLoad decimal(12,3), @Msg nvarchar(400);

    IF @Quantity <= 0 THROW 50001, 'Quantity must be greater than zero.', 1;

    SELECT @ProductId = p.ProductId, @UnitWeight = p.UnitWeightKg,
           @NeedsSecure = g.NeedsSecureStorage, @DefaultSupplier = p.SupplierId
      FROM Spares.Product p
      JOIN Spares.ProductGroup g ON g.GroupId = p.GroupId
     WHERE p.PartNumber = @PartNumber AND p.IsActive = 1;
    IF @ProductId IS NULL THROW 50002, 'Part number not found or inactive.', 1;

    SELECT @BinId = BinId, @BinType = BinType, @MaxWeight = MaxWeightKg
      FROM Spares.StorageBin WHERE BinCode = @BinCode AND IsActive = 1;
    IF @BinId IS NULL THROW 50003, 'Bin not found or inactive.', 1;

    IF @NeedsSecure = 1 AND @BinType <> 'SECURE'
        THROW 50004, 'This product group must be stored in a SECURE bin.', 1;

    IF @SupplierCode IS NULL
        SET @SupplierId = @DefaultSupplier;
    ELSE
    BEGIN
        SELECT @SupplierId = SupplierId FROM Spares.Supplier WHERE SupplierCode = @SupplierCode;
        IF @SupplierId IS NULL THROW 50005, 'Supplier not found.', 1;
    END;

    BEGIN TRY
        BEGIN TRAN;

        -- weight check inside the transaction, with locks, so two receipts cannot overload a bin
        SELECT @CurrentLoad = COALESCE(SUM(s.QtyOnHand * p.UnitWeightKg), 0)
          FROM Spares.StockLevel s WITH (UPDLOCK, HOLDLOCK)
          JOIN Spares.Product p ON p.ProductId = s.ProductId
         WHERE s.BinId = @BinId;

        IF @CurrentLoad + @Quantity * @UnitWeight > @MaxWeight
        BEGIN
            SET @Msg = CONCAT(N'Bin ', @BinCode, N' would hold ', CAST(@CurrentLoad + @Quantity * @UnitWeight AS decimal(10,1)),
                              N' kg, above its limit of ', @MaxWeight, N' kg.');
            THROW 50006, @Msg, 1;
        END;

        UPDATE Spares.StockLevel
           SET QtyOnHand = QtyOnHand + @Quantity, LastMovedAt = SYSDATETIME()
         WHERE ProductId = @ProductId AND BinId = @BinId;

        IF @@ROWCOUNT = 0
            INSERT Spares.StockLevel (ProductId, BinId, QtyOnHand) VALUES (@ProductId, @BinId, @Quantity);

        INSERT Spares.StockMovement (MovementType, ProductId, FromBinId, ToBinId, Quantity, SupplierId, Notes)
        VALUES ('RECEIPT', @ProductId, NULL, @BinId, @Quantity, @SupplierId, COALESCE(@Notes, N'Goods received'));

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE Spares.usp_TransferStock
    @PartNumber   varchar(20),
    @FromBinCode  varchar(20),
    @ToBinCode    varchar(20),
    @Quantity     int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProductId int, @UnitWeight decimal(8,3), @NeedsSecure bit,
            @FromBinId int, @FromWh int, @ToBinId int, @ToWh int, @ToType varchar(10), @ToMax decimal(9,2),
            @ToLoad decimal(12,3), @WhAvailable int, @Msg nvarchar(400);

    IF @Quantity <= 0 THROW 50010, 'Quantity must be greater than zero.', 1;

    SELECT @ProductId = p.ProductId, @UnitWeight = p.UnitWeightKg, @NeedsSecure = g.NeedsSecureStorage
      FROM Spares.Product p JOIN Spares.ProductGroup g ON g.GroupId = p.GroupId
     WHERE p.PartNumber = @PartNumber;
    IF @ProductId IS NULL THROW 50011, 'Part number not found.', 1;

    SELECT @FromBinId = BinId, @FromWh = WarehouseId FROM Spares.StorageBin WHERE BinCode = @FromBinCode;
    SELECT @ToBinId = BinId, @ToWh = WarehouseId, @ToType = BinType, @ToMax = MaxWeightKg
      FROM Spares.StorageBin WHERE BinCode = @ToBinCode AND IsActive = 1;

    IF @FromBinId IS NULL OR @ToBinId IS NULL THROW 50012, 'Source or destination bin not found.', 1;
    IF @FromBinId = @ToBinId                  THROW 50013, 'Source and destination are the same bin.', 1;
    IF @NeedsSecure = 1 AND @ToType <> 'SECURE'
        THROW 50014, 'This product group must be stored in a SECURE bin.', 1;

    BEGIN TRY
        BEGIN TRAN;

        -- moving stock OUT of a warehouse must not take stock already promised to open orders there
        IF @FromWh <> @ToWh
        BEGIN
            SELECT @WhAvailable = COALESCE(SUM(QtyAvailable), 0)
              FROM Spares.vw_StockByWarehouse
             WHERE ProductId = @ProductId AND WarehouseId = @FromWh;
            IF @WhAvailable < @Quantity
                THROW 50015, 'Not enough uncommitted stock in the source warehouse for an inter-warehouse transfer.', 1;
        END;

        SELECT @ToLoad = COALESCE(SUM(s.QtyOnHand * p.UnitWeightKg), 0)
          FROM Spares.StockLevel s WITH (UPDLOCK, HOLDLOCK)
          JOIN Spares.Product p ON p.ProductId = s.ProductId
         WHERE s.BinId = @ToBinId;

        IF @ToLoad + @Quantity * @UnitWeight > @ToMax
        BEGIN
            SET @Msg = CONCAT(N'Destination bin ', @ToBinCode, N' would exceed its ', @ToMax, N' kg limit.');
            THROW 50016, @Msg, 1;
        END;

        UPDATE Spares.StockLevel
           SET QtyOnHand = QtyOnHand - @Quantity, LastMovedAt = SYSDATETIME()
         WHERE ProductId = @ProductId AND BinId = @FromBinId AND QtyOnHand >= @Quantity;
        IF @@ROWCOUNT = 0 THROW 50017, 'Not enough stock in the source bin.', 1;

        UPDATE Spares.StockLevel
           SET QtyOnHand = QtyOnHand + @Quantity, LastMovedAt = SYSDATETIME()
         WHERE ProductId = @ProductId AND BinId = @ToBinId;
        IF @@ROWCOUNT = 0
            INSERT Spares.StockLevel (ProductId, BinId, QtyOnHand) VALUES (@ProductId, @ToBinId, @Quantity);

        INSERT Spares.StockMovement (MovementType, ProductId, FromBinId, ToBinId, Quantity, Notes)
        VALUES ('TRANSFER', @ProductId, @FromBinId, @ToBinId, @Quantity, CONCAT(N'Move ', @FromBinCode, N' -> ', @ToBinCode));

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE Spares.usp_CreateOrder
    @CustomerCode   varchar(10),
    @WarehouseCode  varchar(10),
    @RequiredDate   date        = NULL,       -- default: 3 days from today
    @OrderNumber    varchar(15) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @CustomerId int, @WarehouseId int, @Seq int;

    SELECT @CustomerId = CustomerId FROM Spares.Customer WHERE CustomerCode = @CustomerCode AND IsActive = 1;
    IF @CustomerId IS NULL THROW 50020, 'Customer not found or inactive.', 1;

    SELECT @WarehouseId = WarehouseId FROM Spares.Warehouse WHERE WarehouseCode = @WarehouseCode AND IsActive = 1;
    IF @WarehouseId IS NULL THROW 50021, 'Warehouse not found or inactive.', 1;

    IF @RequiredDate < CAST(SYSDATETIME() AS date) THROW 50022, 'Required date cannot be in the past.', 1;

    SET @Seq = NEXT VALUE FOR Spares.seq_OrderNo;
    SET @OrderNumber = CONCAT('HL-', @Seq);

    INSERT Spares.SalesOrder (OrderNumber, CustomerId, WarehouseId, RequiredDate)
    VALUES (@OrderNumber, @CustomerId, @WarehouseId,
            COALESCE(@RequiredDate, DATEADD(day, 3, CAST(SYSDATETIME() AS date))));
END;
GO

CREATE OR ALTER PROCEDURE Spares.usp_AddOrderLine
    @OrderNumber  varchar(15),
    @PartNumber   varchar(20),
    @Quantity     int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OrderId int, @Status varchar(10), @WarehouseId int, @CustomerId int,
            @ProductId int, @ListPrice decimal(10,2), @Discount decimal(5,2), @CreditLimit decimal(12,2),
            @Available int, @OpenValue decimal(14,2), @LineValue decimal(14,2), @Msg nvarchar(400);

    IF @Quantity <= 0 THROW 50030, 'Quantity must be greater than zero.', 1;

    SELECT @ProductId = ProductId, @ListPrice = ListPrice
      FROM Spares.Product WHERE PartNumber = @PartNumber AND IsActive = 1;
    IF @ProductId IS NULL THROW 50031, 'Part number not found or inactive.', 1;

    BEGIN TRY
        BEGIN TRAN;

        -- lock the order header so concurrent line additions are serialised
        SELECT @OrderId = o.OrderId, @Status = o.Status, @WarehouseId = o.WarehouseId, @CustomerId = o.CustomerId,
               @Discount = c.DiscountPct, @CreditLimit = c.CreditLimit
          FROM Spares.SalesOrder o WITH (UPDLOCK, HOLDLOCK)
          JOIN Spares.Customer c ON c.CustomerId = o.CustomerId
         WHERE o.OrderNumber = @OrderNumber;

        IF @OrderId IS NULL   THROW 50032, 'Order not found.', 1;
        IF @Status <> 'OPEN'  THROW 50033, 'Lines can only be added to OPEN orders.', 1;
        IF EXISTS (SELECT 1 FROM Spares.SalesOrderLine WHERE OrderId = @OrderId AND ProductId = @ProductId)
            THROW 50034, 'This part is already on the order.', 1;

        -- availability at the order's warehouse after other open orders
        SELECT @Available = COALESCE(SUM(QtyAvailable), 0)
          FROM Spares.vw_StockByWarehouse
         WHERE ProductId = @ProductId AND WarehouseId = @WarehouseId;

        IF @Available < @Quantity
        BEGIN
            SET @Msg = CONCAT(N'Only ', @Available, N' x ', @PartNumber, N' available at this warehouse; ', @Quantity, N' requested.');
            THROW 50035, @Msg, 1;
        END;

        -- credit limit across ALL of the customer's open orders
        SELECT @OpenValue = COALESCE(SUM(l.LineTotal), 0)
          FROM Spares.SalesOrder o
          JOIN Spares.SalesOrderLine l ON l.OrderId = o.OrderId
         WHERE o.CustomerId = @CustomerId AND o.Status = 'OPEN';

        SET @LineValue = @Quantity * @ListPrice * (1 - @Discount / 100);

        IF @OpenValue + @LineValue > @CreditLimit
        BEGIN
            SET @Msg = CONCAT(N'Credit limit ', @CreditLimit, N' exceeded: open orders ', @OpenValue,
                              N' + this line ', CAST(@LineValue AS decimal(12,2)), N'.');
            THROW 50036, @Msg, 1;
        END;

        INSERT Spares.SalesOrderLine (OrderId, LineNumber, ProductId, Quantity, UnitPrice, DiscountPct)
        SELECT @OrderId, COALESCE(MAX(LineNumber), 0) + 1, @ProductId, @Quantity, @ListPrice, @Discount
          FROM Spares.SalesOrderLine
         WHERE OrderId = @OrderId;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* Picks every line from the order's warehouse in one set-based statement.
   Running total per product: smallest bins are emptied first to free up locations. */
CREATE OR ALTER PROCEDURE Spares.usp_ShipOrder
    @OrderNumber  varchar(15),
    @Carrier      nvarchar(40)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OrderId int, @Status varchar(10), @WarehouseId int, @Now datetime2(0) = SYSDATETIME();
    DECLARE @Pick TABLE (ProductId int NOT NULL, BinId int NOT NULL, Qty int NOT NULL, PRIMARY KEY (ProductId, BinId));

    IF NULLIF(LTRIM(@Carrier), N'') IS NULL THROW 50040, 'Carrier is required.', 1;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @OrderId = OrderId, @Status = Status, @WarehouseId = WarehouseId
          FROM Spares.SalesOrder WITH (UPDLOCK, HOLDLOCK)
         WHERE OrderNumber = @OrderNumber;

        IF @OrderId IS NULL  THROW 50041, 'Order not found.', 1;
        IF @Status <> 'OPEN' THROW 50042, 'Only OPEN orders can be shipped.', 1;
        IF NOT EXISTS (SELECT 1 FROM Spares.SalesOrderLine WHERE OrderId = @OrderId)
            THROW 50043, 'Order has no lines.', 1;

        -- all-or-nothing: every line must be fully available in the warehouse
        IF EXISTS (SELECT 1
                     FROM Spares.SalesOrderLine l
                    WHERE l.OrderId = @OrderId
                      AND l.Quantity > (SELECT COALESCE(SUM(s.QtyOnHand), 0)
                                          FROM Spares.StockLevel s
                                          JOIN Spares.StorageBin b ON b.BinId = s.BinId
                                         WHERE s.ProductId = l.ProductId AND b.WarehouseId = @WarehouseId))
            THROW 50044, 'Insufficient stock in the warehouse to ship every line.', 1;

        WITH Src AS
        (
            SELECT  l.ProductId,
                    l.Quantity AS Needed,
                    s.BinId,
                    s.QtyOnHand,
                    SUM(s.QtyOnHand) OVER (PARTITION BY l.ProductId
                                           ORDER BY s.QtyOnHand, b.BinCode
                                           ROWS UNBOUNDED PRECEDING) AS Cum
              FROM Spares.SalesOrderLine l
              JOIN Spares.StockLevel s WITH (UPDLOCK, HOLDLOCK) ON s.ProductId = l.ProductId
              JOIN Spares.StorageBin b ON b.BinId = s.BinId
             WHERE l.OrderId = @OrderId
               AND b.WarehouseId = @WarehouseId
               AND s.QtyOnHand > 0
        )
        INSERT @Pick (ProductId, BinId, Qty)
        SELECT ProductId, BinId,
               CASE WHEN Cum <= Needed THEN QtyOnHand ELSE Needed - (Cum - QtyOnHand) END
          FROM Src
         WHERE Cum - QtyOnHand < Needed;

        UPDATE s
           SET s.QtyOnHand = s.QtyOnHand - p.Qty, s.LastMovedAt = @Now
          FROM Spares.StockLevel s
          JOIN @Pick p ON p.ProductId = s.ProductId AND p.BinId = s.BinId;

        INSERT Spares.StockMovement (MovementType, ProductId, FromBinId, ToBinId, Quantity, OrderId, MovedAt, Notes)
        SELECT 'ISSUE', ProductId, BinId, NULL, Qty, @OrderId, @Now, CONCAT(N'Shipped on ', @OrderNumber, N' via ', @Carrier)
          FROM @Pick;

        UPDATE Spares.SalesOrder
           SET Status = 'SHIPPED', ShippedAt = @Now, Carrier = @Carrier
         WHERE OrderId = @OrderId;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;

    -- pick list returned to the caller
    SELECT @OrderNumber AS OrderNumber, b.BinCode, pr.PartNumber, pr.ProductName, p.Qty AS QtyPicked
      FROM @Pick p
      JOIN Spares.StorageBin b ON b.BinId = p.BinId
      JOIN Spares.Product pr   ON pr.ProductId = p.ProductId
     ORDER BY b.BinCode, pr.PartNumber;
END;
GO

CREATE OR ALTER PROCEDURE Spares.usp_CancelOrder
    @OrderNumber  varchar(15)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE Spares.SalesOrder SET Status = 'CANCELLED'
     WHERE OrderNumber = @OrderNumber AND Status = 'OPEN';

    IF @@ROWCOUNT = 0 THROW 50050, 'Order not found or not OPEN.', 1;
END;
GO

CREATE OR ALTER PROCEDURE Spares.usp_WarehouseReport
    @WarehouseCode  varchar(10)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM Spares.Warehouse WHERE WarehouseCode = @WarehouseCode)
        THROW 50060, 'Warehouse not found.', 1;

    -- Result 1: the warehouse and its bins (two-level tree)
    SELECT TreeLevel, DisplayName, DistinctProducts, UnitsOnHand, LoadKg, CapacityKg, UtilisationPct, StockValue
      FROM Spares.vw_WarehouseBinTree
     WHERE WarehouseCode = @WarehouseCode
     ORDER BY SortKey;

    -- Result 2: open orders waiting to ship from this warehouse
    SELECT OrderNumber, CustomerName, RequiredDate, LineCount, Units, OrderValue, IsLate
      FROM Spares.vw_OrderSummary
     WHERE WarehouseCode = @WarehouseCode AND Status = 'OPEN'
     ORDER BY RequiredDate;
END;
GO
PRINT 'Step 3 complete: 7 stored procedures.';
GO

/* =====================================================================================
   STEP 4 of 5 : DATA  (all invented; dates relative to the day the script runs)
   ===================================================================================== */
USE HarbourlineDB;
GO
SET NOCOUNT ON;
GO

/* ---------- Level 1: warehouses ---------- */
INSERT INTO Spares.Warehouse (WarehouseCode, WarehouseName, City)
VALUES ('SOU', N'Southampton Dock Store',   N'Southampton'),
       ('ABZ', N'Aberdeen Offshore Store',  N'Aberdeen'),
       ('FAL', N'Falmouth Marina Store',    N'Falmouth');

/* ---------- Level 2: bins generated per warehouse ----------
   Row A = shelves, row B = pallet racking, last bin of each store = SECURE cage. */
WITH n AS (SELECT TOP (8) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int) AS n FROM sys.all_objects)
INSERT INTO Spares.StorageBin (WarehouseId, BinCode, BinType, MaxWeightKg)
SELECT  w.WarehouseId,
        CONCAT(w.WarehouseCode, '-', CASE WHEN n.n <= 4 THEN 'A' ELSE 'B' END, RIGHT(CONCAT('0', (n.n - 1) % 4 + 1), 2)),
        t.BinType,
        CASE t.BinType WHEN 'SHELF' THEN 150 WHEN 'PALLET' THEN 1000 ELSE 300 END
FROM Spares.Warehouse w
JOIN (VALUES ('SOU', 8), ('ABZ', 6), ('FAL', 4)) c(WarehouseCode, BinCount) ON c.WarehouseCode = w.WarehouseCode
JOIN n ON n.n <= c.BinCount
CROSS APPLY (SELECT CASE WHEN n.n = c.BinCount THEN 'SECURE'
                         WHEN n.n <= 4         THEN 'SHELF'
                         ELSE 'PALLET' END AS BinType) t;

/* ---------- Level 1: product groups ---------- */
INSERT INTO Spares.ProductGroup (GroupCode, GroupName, NeedsSecureStorage)
VALUES ('ENG', N'Engine Parts',          0),
       ('FIL', N'Filters',               0),
       ('ELE', N'Electrical',            0),
       ('PMP', N'Pumps & Impellers',     0),
       ('SAF', N'Safety & Pyrotechnics', 0),
       ('BCN', N'Distress Beacons',      1),
       ('DCK', N'Deck Hardware',         0);

INSERT INTO Spares.Supplier (SupplierCode, SupplierName, CountryCode, LeadTimeDays)
VALUES ('SUP-KVD', N'Kvadrant Marine AS',          'NO', 14),
       ('SUP-BRL', N'Brightwell Lubrication Ltd',  'GB',  4),
       ('SUP-TDL', N'Tidal Electrics BV',          'NL',  9),
       ('SUP-OCP', N'Ocean Pump Works GmbH',       'DE', 12),
       ('SUP-SVR', N'Solent Safety Supplies',      'GB',  3);

/* ---------- Level 2: products ---------- */
INSERT INTO Spares.Product (PartNumber, ProductName, GroupId, SupplierId, UnitWeightKg, UnitCost, ListPrice, ReorderLevel, ReorderQty)
SELECT v.Part, v.Name, g.GroupId, s.SupplierId, v.Wt, v.Cost, v.Price, v.Rol, v.Roq
FROM (VALUES
    ('HL-ENG-1001', N'Raw Water Pump Seal Kit',                'ENG', 'SUP-KVD', 0.400,  18.50,  42.00, 20,  50),
    ('HL-ENG-1002', N'Exhaust Elbow Gasket 120 mm',            'ENG', 'SUP-KVD', 0.200,   6.20,  15.90, 30,  80),
    ('HL-ENG-1003', N'Injector Nozzle Assembly',               'ENG', 'SUP-KVD', 0.600,  74.00, 165.00, 10,  24),
    ('HL-ENG-1004', N'Heat Exchanger Zinc Anode Pack (6)',     'ENG', 'SUP-KVD', 0.900,   9.80,  24.50, 40, 100),
    ('HL-FIL-2001', N'Fuel Water Separator Element 10 micron', 'FIL', 'SUP-BRL', 0.500,  11.40,  27.00, 60, 150),
    ('HL-FIL-2002', N'Lube Oil Filter Spin-On LF-90',          'FIL', 'SUP-BRL', 0.700,   8.90,  21.50, 60, 150),
    ('HL-FIL-2003', N'Air Intake Silencer Element',            'FIL', 'SUP-BRL', 1.100,  23.00,  54.00, 15,  40),
    ('HL-ELE-3001', N'Alternator 24V 110A Marine',             'ELE', 'SUP-TDL', 7.500, 215.00, 449.00,  4,   8),
    ('HL-ELE-3002', N'Battery Isolator Switch 300A',           'ELE', 'SUP-TDL', 0.800,  28.00,  64.00, 12,  30),
    ('HL-ELE-3003', N'LED Masthead Navigation Light',          'ELE', 'SUP-TDL', 0.600,  46.00,  99.00, 10,  25),
    ('HL-ELE-3004', N'Tinned Cable 6 mm2 (50 m reel)',         'ELE', 'SUP-TDL', 3.200,  52.00, 119.00,  8,  20),
    ('HL-PMP-4001', N'Flexible Impeller 65 mm Neoprene',       'PMP', 'SUP-OCP', 0.300,  14.20,  34.00, 30,  80),
    ('HL-PMP-4002', N'Submersible Bilge Pump 2000 GPH',        'PMP', 'SUP-OCP', 1.800,  61.00, 139.00,  8,  20),
    ('HL-PMP-4003', N'Deck Wash Pump 24V',                     'PMP', 'SUP-OCP', 4.600, 148.00, 319.00,  3,   6),
    ('HL-SAF-5001', N'Lifejacket 275N Auto with Harness',      'SAF', 'SUP-SVR', 1.400,  62.00, 135.00, 20,  40),
    ('HL-SAF-5003', N'Offshore Flare Pack (12)',               'SAF', 'SUP-SVR', 2.200,  84.00, 179.00,  6,  12),
    ('HL-BCN-5101', N'EPIRB Cat II with GPS',                  'BCN', 'SUP-SVR', 0.900, 238.00, 489.00,  3,   6),
    ('HL-BCN-5102', N'Personal Locator Beacon AIS',            'BCN', 'SUP-SVR', 0.300, 152.00, 299.00,  4,   8),
    ('HL-DCK-6001', N'Stainless Mooring Cleat 250 mm',         'DCK', 'SUP-KVD', 1.200,  19.00,  46.00, 15,  40),
    ('HL-DCK-6002', N'Galvanised Anchor Shackle 16 mm',        'DCK', 'SUP-KVD', 0.500,   4.30,  11.50, 40, 100),
    ('HL-DCK-6003', N'Cylinder Fender 200 x 800 mm',           'DCK', 'SUP-SVR', 3.000,  26.00,  59.00, 12,  30)
) v(Part, Name, GroupCode, SupplierCode, Wt, Cost, Price, Rol, Roq)
JOIN Spares.ProductGroup g ON g.GroupCode    = v.GroupCode
JOIN Spares.Supplier s     ON s.SupplierCode = v.SupplierCode;

/* ---------- Opening stock (beacons only in SECURE bins) ---------- */
INSERT INTO Spares.StockLevel (ProductId, BinId, QtyOnHand, LastMovedAt)
SELECT p.ProductId, b.BinId, v.Qty, DATEADD(day, -60, SYSDATETIME())
FROM (VALUES
    ('SOU-A01', 'HL-ENG-1001',  34), ('SOU-A01', 'HL-ENG-1002',  60),
    ('SOU-A02', 'HL-ENG-1003',   8), ('SOU-A02', 'HL-ENG-1004',  85),
    ('SOU-A03', 'HL-FIL-2001', 140), ('SOU-A03', 'HL-FIL-2002',  45),
    ('SOU-A04', 'HL-ELE-3002',   9), ('SOU-A04', 'HL-ELE-3003',   7),
    ('SOU-B01', 'HL-ELE-3001',   5), ('SOU-B01', 'HL-PMP-4003',   2),
    ('SOU-B02', 'HL-ELE-3004',   9), ('SOU-B02', 'HL-PMP-4002',  11),
    ('SOU-B03', 'HL-DCK-6003',  24), ('SOU-B03', 'HL-SAF-5001',  30),
    ('SOU-B03', 'HL-SAF-5003',   5),
    ('SOU-B04', 'HL-BCN-5101',   4), ('SOU-B04', 'HL-BCN-5102',   6),
    ('ABZ-A01', 'HL-FIL-2001',  90), ('ABZ-A01', 'HL-FIL-2002',  38),
    ('ABZ-A02', 'HL-FIL-2003',  22), ('ABZ-A02', 'HL-ENG-1001',  16),
    ('ABZ-A03', 'HL-PMP-4001',  55), ('ABZ-A03', 'HL-ENG-1004',  30),
    ('ABZ-A04', 'HL-DCK-6001',  25), ('ABZ-A04', 'HL-DCK-6002', 120),
    ('ABZ-B01', 'HL-ELE-3001',   3), ('ABZ-B01', 'HL-PMP-4002',   6),
    ('ABZ-B01', 'HL-SAF-5003',   4),
    ('ABZ-B02', 'HL-BCN-5101',   2),
    ('FAL-A01', 'HL-DCK-6002',  60), ('FAL-A01', 'HL-DCK-6001',  10),
    ('FAL-A02', 'HL-PMP-4001',  18), ('FAL-A02', 'HL-ENG-1002',  14),
    ('FAL-A03', 'HL-SAF-5001',  12), ('FAL-A03', 'HL-ELE-3003',   6),
    ('FAL-A04', 'HL-BCN-5102',   3)
) v(BinCode, Part, Qty)
JOIN Spares.StorageBin b ON b.BinCode   = v.BinCode
JOIN Spares.Product p    ON p.PartNumber = v.Part;

-- every opening balance is recorded in the ledger
INSERT INTO Spares.StockMovement (MovementType, ProductId, FromBinId, ToBinId, Quantity, MovedAt, Notes)
SELECT 'OPENING', ProductId, NULL, BinId, QtyOnHand, LastMovedAt, N'Opening balance'
FROM Spares.StockLevel;

/* ---------- Customers (discount by trade type) ---------- */
INSERT INTO Spares.Customer (CustomerCode, CustomerName, CustomerType, City, CreditLimit, DiscountPct)
VALUES ('CU-SOLY', N'Solent Yacht Yard Ltd',        'SHIPYARD',  N'Southampton', 40000,  7.5),
       ('CU-NSEA', N'North Sea Crew Transfers',     'FLEET',     N'Aberdeen',    60000, 10.0),
       ('CU-ITCH', N'Itchen Ferry Chandlery',       'CHANDLERY', N'Southampton',  8000, 15.0),
       ('CU-PNDN', N'Pendennis Point Marina',       'MARINA',    N'Falmouth',    12000,  5.0),
       ('CU-GRAM', N'Grampian Survey Vessels',      'FLEET',     N'Peterhead',   50000, 10.0),
       ('CU-HMBL', N'Hamble Riverside Boatworks',   'SHIPYARD',  N'Hamble',      25000,  7.5),
       ('CU-CARR', N'Carrick Roads Chandlers',      'CHANDLERY', N'Falmouth',     6000, 15.0),
       ('CU-ORKN', N'Orkney Island Ferries Co-op',  'FLEET',     N'Kirkwall',    30000, 10.0);

/* ---------- Order history: 10 shipped orders in the last 90 days ----------
   RequiredDate = order date + 3 days; ShipDays > 3 means it shipped late. */
DROP TABLE IF EXISTS #Hist;
CREATE TABLE #Hist (OrderNumber varchar(15) PRIMARY KEY, CustomerCode varchar(10), WarehouseCode varchar(10),
                    DaysAgo int, ShipDays int, Carrier nvarchar(40));
INSERT INTO #Hist VALUES
    ('HL-40001', 'CU-SOLY', 'SOU', 80, 1, N'Solent Freight'),
    ('HL-40002', 'CU-NSEA', 'ABZ', 74, 1, N'Granite City Haulage'),
    ('HL-40003', 'CU-ITCH', 'SOU', 66, 4, N'Solent Freight'),
    ('HL-40004', 'CU-PNDN', 'FAL', 59, 1, N'Kernow Couriers'),
    ('HL-40005', 'CU-GRAM', 'ABZ', 51, 2, N'Granite City Haulage'),
    ('HL-40006', 'CU-HMBL', 'SOU', 43, 1, N'Solent Freight'),
    ('HL-40007', 'CU-CARR', 'FAL', 35, 5, N'Kernow Couriers'),
    ('HL-40008', 'CU-ORKN', 'ABZ', 27, 1, N'Northlink Freight'),
    ('HL-40009', 'CU-NSEA', 'ABZ', 15, 1, N'Granite City Haulage'),
    ('HL-40010', 'CU-SOLY', 'SOU',  8, 2, N'Solent Freight');

INSERT INTO Spares.SalesOrder (OrderNumber, CustomerId, WarehouseId, OrderDate, RequiredDate, Status, ShippedAt, Carrier)
SELECT h.OrderNumber, c.CustomerId, w.WarehouseId, d.OrderDate,
       DATEADD(day, 3, CAST(d.OrderDate AS date)),
       'SHIPPED',
       DATEADD(day, h.ShipDays, DATEADD(hour, 5, d.OrderDate)),
       h.Carrier
FROM #Hist h
JOIN Spares.Customer c  ON c.CustomerCode  = h.CustomerCode
JOIN Spares.Warehouse w ON w.WarehouseCode = h.WarehouseCode
CROSS APPLY (SELECT DATEADD(hour, 10, CAST(DATEADD(day, -h.DaysAgo, CAST(SYSDATETIME() AS date)) AS datetime2(0))) AS OrderDate) d;

INSERT INTO Spares.SalesOrderLine (OrderId, LineNumber, ProductId, Quantity, UnitPrice, DiscountPct)
SELECT o.OrderId, v.LineNumber, p.ProductId, v.Qty, p.ListPrice, c.DiscountPct
FROM (VALUES
    ('HL-40001', 1, 'HL-ENG-1001',  6), ('HL-40001', 2, 'HL-ENG-1004', 12), ('HL-40001', 3, 'HL-FIL-2001', 10),
    ('HL-40002', 1, 'HL-FIL-2001', 24), ('HL-40002', 2, 'HL-FIL-2002', 24), ('HL-40002', 3, 'HL-PMP-4001',  8),
    ('HL-40003', 1, 'HL-DCK-6002', 30), ('HL-40003', 2, 'HL-DCK-6001',  6), ('HL-40003', 3, 'HL-SAF-5001',  4),
    ('HL-40004', 1, 'HL-DCK-6003',  8), ('HL-40004', 2, 'HL-PMP-4002',  2),
    ('HL-40005', 1, 'HL-ELE-3001',  1), ('HL-40005', 2, 'HL-FIL-2003',  6), ('HL-40005', 3, 'HL-ENG-1003',  2),
    ('HL-40006', 1, 'HL-ELE-3004',  2), ('HL-40006', 2, 'HL-ELE-3002',  4), ('HL-40006', 3, 'HL-ENG-1002', 10),
    ('HL-40007', 1, 'HL-SAF-5003',  2), ('HL-40007', 2, 'HL-SAF-5001',  3),
    ('HL-40008', 1, 'HL-BCN-5101',  1), ('HL-40008', 2, 'HL-PMP-4001',  6), ('HL-40008', 3, 'HL-FIL-2002', 12),
    ('HL-40009', 1, 'HL-FIL-2001', 30), ('HL-40009', 2, 'HL-FIL-2002', 30), ('HL-40009', 3, 'HL-ENG-1004', 10),
    ('HL-40010', 1, 'HL-PMP-4003',  1), ('HL-40010', 2, 'HL-ELE-3003',  3), ('HL-40010', 3, 'HL-ENG-1001',  4)
) v(OrderNumber, LineNumber, Part, Qty)
JOIN Spares.SalesOrder o ON o.OrderNumber = v.OrderNumber
JOIN Spares.Customer c   ON c.CustomerId  = o.CustomerId
JOIN Spares.Product p    ON p.PartNumber  = v.Part;

DROP TABLE #Hist;
GO

SELECT 'Warehouse' AS TableName, COUNT(*) AS RowsLoaded FROM Spares.Warehouse
UNION ALL SELECT 'StorageBin',     COUNT(*) FROM Spares.StorageBin
UNION ALL SELECT 'ProductGroup',   COUNT(*) FROM Spares.ProductGroup
UNION ALL SELECT 'Supplier',       COUNT(*) FROM Spares.Supplier
UNION ALL SELECT 'Product',        COUNT(*) FROM Spares.Product
UNION ALL SELECT 'StockLevel',     COUNT(*) FROM Spares.StockLevel
UNION ALL SELECT 'Customer',       COUNT(*) FROM Spares.Customer
UNION ALL SELECT 'SalesOrder',     COUNT(*) FROM Spares.SalesOrder
UNION ALL SELECT 'SalesOrderLine', COUNT(*) FROM Spares.SalesOrderLine
UNION ALL SELECT 'StockMovement',  COUNT(*) FROM Spares.StockMovement;
GO
PRINT 'Step 4 complete: data loaded.';
GO

/* =====================================================================================
   STEP 5 of 5 : LIVE DEMO, SHOWCASE QUERIES, DATABASE DIAGRAM
   Watch the "Messages" tab for the narration; result grids follow.
   ===================================================================================== */
USE HarbourlineDB;
GO
SET NOCOUNT ON;
GO

/* ---------- PART A: a working day, executed only through the procedures ---------- */
DECLARE @Ord1 varchar(15), @Ord2 varchar(15), @Ord3 varchar(15), @Ord4 varchar(15);

PRINT 'A1  Goods in';
EXEC Spares.usp_ReceiveStock @PartNumber = 'HL-ENG-1003', @BinCode = 'SOU-A02', @Quantity = 20, @Notes = N'Kvadrant delivery note KV-88412';
EXEC Spares.usp_ReceiveStock @PartNumber = 'HL-PMP-4003', @BinCode = 'SOU-B01', @Quantity = 6;
PRINT '    20 injector assemblies and 6 deck wash pumps received at Southampton';

PRINT 'A2  Rule check: overload a 150 kg shelf with 60 cable reels (192 kg)';
BEGIN TRY
    EXEC Spares.usp_ReceiveStock @PartNumber = 'HL-ELE-3004', @BinCode = 'SOU-A04', @Quantity = 60;
    PRINT '    !! unexpected: accepted';
END TRY
BEGIN CATCH
    PRINT CONCAT('    Rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

PRINT 'A3  Rule check: store a distress beacon on an open shelf';
BEGIN TRY
    EXEC Spares.usp_ReceiveStock @PartNumber = 'HL-BCN-5102', @BinCode = 'SOU-A01', @Quantity = 2;
    PRINT '    !! unexpected: accepted';
END TRY
BEGIN CATCH
    PRINT CONCAT('    Rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

PRINT 'A4  Inter-warehouse transfer: 20 fuel filters Southampton -> Falmouth';
EXEC Spares.usp_TransferStock @PartNumber = 'HL-FIL-2001', @FromBinCode = 'SOU-A03', @ToBinCode = 'FAL-A02', @Quantity = 20;

PRINT 'A5  Order 1 - North Sea Crew Transfers from Aberdeen, then shipped';
EXEC Spares.usp_CreateOrder @CustomerCode = 'CU-NSEA', @WarehouseCode = 'ABZ', @OrderNumber = @Ord1 OUTPUT;
EXEC Spares.usp_AddOrderLine @OrderNumber = @Ord1, @PartNumber = 'HL-FIL-2001', @Quantity = 40;
EXEC Spares.usp_AddOrderLine @OrderNumber = @Ord1, @PartNumber = 'HL-FIL-2002', @Quantity = 20;
EXEC Spares.usp_AddOrderLine @OrderNumber = @Ord1, @PartNumber = 'HL-PMP-4002', @Quantity = 4;
EXEC Spares.usp_ShipOrder    @OrderNumber = @Ord1, @Carrier = N'Granite City Haulage';
PRINT CONCAT('    ', @Ord1, ' shipped (pick list returned as a result grid)');

PRINT 'A6  Rule check: ship the same order twice';
BEGIN TRY
    EXEC Spares.usp_ShipOrder @OrderNumber = @Ord1, @Carrier = N'Granite City Haulage';
    PRINT '    !! unexpected: accepted';
END TRY
BEGIN CATCH
    PRINT CONCAT('    Rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

PRINT 'A7  Order 2 - Pendennis Point Marina from Falmouth (left OPEN)';
EXEC Spares.usp_CreateOrder @CustomerCode = 'CU-PNDN', @WarehouseCode = 'FAL', @OrderNumber = @Ord2 OUTPUT;
EXEC Spares.usp_AddOrderLine @OrderNumber = @Ord2, @PartNumber = 'HL-DCK-6002', @Quantity = 25;
EXEC Spares.usp_AddOrderLine @OrderNumber = @Ord2, @PartNumber = 'HL-SAF-5001', @Quantity = 2;
EXEC Spares.usp_AddOrderLine @OrderNumber = @Ord2, @PartNumber = 'HL-FIL-2001', @Quantity = 10;   -- uses transferred stock

PRINT 'A8  Rule check: order a part Falmouth does not stock';
BEGIN TRY
    EXEC Spares.usp_AddOrderLine @OrderNumber = @Ord2, @PartNumber = 'HL-PMP-4003', @Quantity = 1;
    PRINT '    !! unexpected: accepted';
END TRY
BEGIN CATCH
    PRINT CONCAT('    Rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

PRINT 'A9  Order 3 - Carrick Roads Chandlers (credit limit 6,000) from Southampton';
EXEC Spares.usp_CreateOrder @CustomerCode = 'CU-CARR', @WarehouseCode = 'SOU', @OrderNumber = @Ord3 OUTPUT;
EXEC Spares.usp_AddOrderLine @OrderNumber = @Ord3, @PartNumber = 'HL-SAF-5001', @Quantity = 30;
EXEC Spares.usp_AddOrderLine @OrderNumber = @Ord3, @PartNumber = 'HL-BCN-5101', @Quantity = 3;
BEGIN TRY
    EXEC Spares.usp_AddOrderLine @OrderNumber = @Ord3, @PartNumber = 'HL-ELE-3001', @Quantity = 5;
    PRINT '    !! unexpected: accepted';
END TRY
BEGIN CATCH
    PRINT CONCAT('    Third line rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

PRINT 'A10 Order 4 - created then cancelled (committed stock released)';
EXEC Spares.usp_CreateOrder @CustomerCode = 'CU-ITCH', @WarehouseCode = 'SOU', @OrderNumber = @Ord4 OUTPUT;
EXEC Spares.usp_AddOrderLine @OrderNumber = @Ord4, @PartNumber = 'HL-ENG-1001', @Quantity = 10;
EXEC Spares.usp_CancelOrder  @OrderNumber = @Ord4;
PRINT CONCAT('    ', @Ord4, ' cancelled');
GO

/* ---------- PART B: showcase queries ---------- */
PRINT 'B1  Two-level storage tree: warehouses and their bins';
SELECT TreeLevel, DisplayName, BinCount, DistinctProducts, UnitsOnHand, LoadKg, CapacityKg, UtilisationPct, StockValue
  FROM Spares.vw_WarehouseBinTree
 ORDER BY SortKey;

PRINT 'B2  Two-level catalogue: product groups and their products';
SELECT GroupName, PartNumber, ProductName, SupplierName, UnitCost, ListPrice, MarginPct, TotalOnHand, NeedsSecureStorage
  FROM Spares.vw_ProductCatalogue
 ORDER BY GroupCode, PartNumber;

PRINT 'B3  Stock by warehouse: on hand, committed to open orders, available';
SELECT WarehouseCode, PartNumber, ProductName, QtyOnHand, QtyCommitted, QtyAvailable
  FROM Spares.vw_StockByWarehouse
 ORDER BY WarehouseCode, PartNumber;

PRINT 'B4  Reorder list';
SELECT Urgency, GroupName, PartNumber, ProductName, QtyAvailable, ReorderLevel, SuggestedOrderQty, SupplierName, LeadTimeDays
  FROM Spares.vw_ReorderList
 ORDER BY CASE Urgency WHEN 'OUT OF STOCK' THEN 1 WHEN 'CRITICAL' THEN 2 ELSE 3 END, PartNumber;

PRINT 'B5  Order summary (header level with line totals)';
SELECT OrderNumber, CustomerName, WarehouseCode, Status, OrderDate, RequiredDate, ShippedAt, Carrier,
       LineCount, Units, OrderValue, IsLate, DaysVsRequired
  FROM Spares.vw_OrderSummary
 ORDER BY OrderDate DESC;

PRINT 'B6  90-day sales with group subtotals and grand total (ROLLUP)';
SELECT GroupName, PartNumber, RollupLevel, UnitsSold, Revenue, GrossProfit
  FROM Spares.vw_SalesByGroup
 ORDER BY CASE WHEN RollupLevel = 2 THEN 1 ELSE 0 END, GroupName, RollupLevel, PartNumber;

PRINT 'B7  Warehouse report procedure (two result sets)';
EXEC Spares.usp_WarehouseReport @WarehouseCode = 'SOU';

PRINT 'B8  Ledger reconciliation: stock rebuilt from movements must equal StockLevel';
WITH Net AS
(
    SELECT ProductId, BinId, SUM(Qty) AS LedgerQty
    FROM (SELECT ProductId, ToBinId   AS BinId,  Quantity AS Qty FROM Spares.StockMovement WHERE ToBinId   IS NOT NULL
          UNION ALL
          SELECT ProductId, FromBinId AS BinId, -Quantity AS Qty FROM Spares.StockMovement WHERE FromBinId IS NOT NULL) m
    GROUP BY ProductId, BinId
)
SELECT COUNT(*) AS StockRows,
       SUM(CASE WHEN COALESCE(n.LedgerQty, 0) =  s.QtyOnHand THEN 1 ELSE 0 END) AS Matching,
       SUM(CASE WHEN COALESCE(n.LedgerQty, 0) <> s.QtyOnHand THEN 1 ELSE 0 END) AS Mismatches
  FROM Spares.StockLevel s
  LEFT JOIN Net n ON n.ProductId = s.ProductId AND n.BinId = s.BinId;

PRINT 'B9  Latest stock movements';
SELECT TOP (12) m.MovementId, m.MovedAt, m.MovementType, p.PartNumber,
       fb.BinCode AS FromBin, tb.BinCode AS ToBin, m.Quantity, o.OrderNumber, m.Notes
  FROM Spares.StockMovement m
  JOIN Spares.Product p          ON p.ProductId = m.ProductId
  LEFT JOIN Spares.StorageBin fb ON fb.BinId    = m.FromBinId
  LEFT JOIN Spares.StorageBin tb ON tb.BinId    = m.ToBinId
  LEFT JOIN Spares.SalesOrder o  ON o.OrderId   = m.OrderId
 ORDER BY m.MovementId DESC;
GO

PRINT 'HarbourlineDB complete.';
GO

/* =====================================================================================
   DATABASE DIAGRAM
   -------------------------------------------------------------------------------------
   Option 1 - SSMS (native diagram):
     Object Explorer > HarbourlineDB > Database Diagrams > New Database Diagram
     > select all 10 tables > Add. Relationships are drawn from the foreign keys.

   Option 2 - Mermaid (paste into mermaid.live, GitHub or VS Code):

erDiagram
    Warehouse ||--o{ StorageBin : "contains (level 2)"
    ProductGroup ||--o{ Product : "groups (level 2)"
    SalesOrder ||--|{ SalesOrderLine : "has lines (level 2)"
    Supplier ||--o{ Product : "supplies"
    Product ||--o{ StockLevel : "stocked as"
    StorageBin ||--o{ StockLevel : "holds"
    Customer ||--o{ SalesOrder : "places"
    Warehouse ||--o{ SalesOrder : "ships"
    Product ||--o{ SalesOrderLine : "ordered as"
    Product ||--o{ StockMovement : "moved"
    StorageBin |o--o{ StockMovement : "from or to"
    Supplier |o--o{ StockMovement : "delivered"
    SalesOrder |o--o{ StockMovement : "issued for"

    Warehouse {
        int WarehouseId PK
        varchar WarehouseCode UK
        nvarchar WarehouseName
        nvarchar City
    }
    StorageBin {
        int BinId PK
        int WarehouseId FK
        varchar BinCode UK
        varchar BinType
        decimal MaxWeightKg
    }
    ProductGroup {
        int GroupId PK
        varchar GroupCode UK
        nvarchar GroupName
        bit NeedsSecureStorage
    }
    Supplier {
        int SupplierId PK
        varchar SupplierCode UK
        nvarchar SupplierName
        smallint LeadTimeDays
    }
    Product {
        int ProductId PK
        varchar PartNumber UK
        int GroupId FK
        int SupplierId FK
        decimal UnitCost
        decimal ListPrice
        int ReorderLevel
    }
    StockLevel {
        int ProductId PK, FK
        int BinId PK, FK
        int QtyOnHand
    }
    Customer {
        int CustomerId PK
        varchar CustomerCode UK
        varchar CustomerType
        decimal CreditLimit
        decimal DiscountPct
    }
    SalesOrder {
        int OrderId PK
        varchar OrderNumber UK
        int CustomerId FK
        int WarehouseId FK
        date RequiredDate
        varchar Status
    }
    SalesOrderLine {
        int OrderLineId PK
        int OrderId FK
        int ProductId FK
        int Quantity
        decimal LineTotal "computed"
    }
    StockMovement {
        bigint MovementId PK
        varchar MovementType
        int ProductId FK
        int FromBinId FK
        int ToBinId FK
        int SupplierId FK
        int OrderId FK
        int Quantity
    }

   ===================================================================================== */
