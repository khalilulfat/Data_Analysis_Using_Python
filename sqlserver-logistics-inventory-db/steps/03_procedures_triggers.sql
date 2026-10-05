/*
=====================================================================================
  VerdantStackDB  -  STEP 3 of 5 : Stored Procedures and Triggers
-------------------------------------------------------------------------------------
  Run after Step2_Functions_Views.sql

  Conventions used in every write procedure
    * SET XACT_ABORT ON + TRY/CATCH + THROW  -> all-or-nothing, original error re-raised
    * Validation BEFORE the transaction opens -> short lock duration
    * UPDLOCK/HOLDLOCK on rows that are read then written -> no lost updates / race conditions
    * Every stock change writes to the append-only ledger (Inventory.StockTransaction)
    * Custom error numbers 50000-50099, grouped by area

  PROCEDURES
    Org.usp_AddEmployee                     insert under a manager with GetDescendant
    Org.usp_MoveEmployeeSubtree             re-parent a whole reporting line with GetReparentedValue
    Inventory.usp_AddLocation               add a node to the warehouse tree, validating level order
    Inventory.usp_ReceivePurchaseOrderLine  goods-in: lot creation, putaway, ledger, PO status
    Inventory.usp_TransferStock             bin-to-bin move with temperature-zone rule
    Inventory.usp_RecordCycleCount          stock count with variance posting
    Inventory.usp_GetLocationSubtree        report: any branch of the tree with roll-ups
    Inventory.usp_GetKitRequirements        report: multi-level BOM explosion vs site stock
    Logistics.usp_CreateSalesOrder          order entry via table-valued parameter, group credit check
    Logistics.usp_AllocateSalesOrder        set-based FEFO allocation using running totals
    Logistics.usp_ShipSalesOrder            pack (pallet > cartons), dispatch, decrement stock, freight
    Logistics.usp_RecordTrackingEvent       carrier events drive shipment & order status
    Logistics.usp_CarrierScorecard          report: ranked carrier KPIs for a date range

  TRIGGERS
    Inventory.trg_StockTransaction_Immutable  ledger is append-only
    Inventory.trg_KitComponent_Validate       only kits have components; BOM cycles rejected
    Inventory.trg_Product_PriceAudit          cost / price changes to Core.AuditLog
    Logistics.trg_SalesOrder_StatusAudit      order status history to Core.AuditLog
=====================================================================================
*/
USE VerdantStackDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ===================================================================================
   ORG
   =================================================================================== */
CREATE OR ALTER PROCEDURE Org.usp_AddEmployee
    @ManagerEmployeeId  int,
    @FirstName          nvarchar(50),
    @LastName           nvarchar(50),
    @JobTitle           nvarchar(80),
    @DepartmentCode     varchar(10),
    @Email              varchar(120),
    @HomeSiteCode       varchar(30) = NULL,
    @HireDate           date        = NULL,
    @NewEmployeeId      int         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @MgrNode hierarchyid, @LastChild hierarchyid, @DeptId int, @SiteId int = NULL;

    SELECT @DeptId = DepartmentId FROM Org.Department WHERE DepartmentCode = @DepartmentCode;
    IF @DeptId IS NULL THROW 50080, 'Department not found.', 1;

    IF @HomeSiteCode IS NOT NULL
    BEGIN
        SELECT @SiteId = LocationId FROM Inventory.Location
         WHERE LocationCode = @HomeSiteCode AND LocationType = 'SITE';
        IF @SiteId IS NULL THROW 50081, 'Home site not found.', 1;
    END;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @MgrNode = OrgNode
          FROM Org.Employee WITH (UPDLOCK, HOLDLOCK)
         WHERE EmployeeId = @ManagerEmployeeId AND IsActive = 1;
        IF @MgrNode IS NULL THROW 50082, 'Manager not found or inactive.', 1;

        -- range lock on the manager's children prevents two inserts taking the same slot
        SELECT @LastChild = MAX(OrgNode)
          FROM Org.Employee WITH (UPDLOCK, HOLDLOCK)
         WHERE OrgNode.GetAncestor(1) = @MgrNode;

        INSERT Org.Employee (OrgNode, FirstName, LastName, JobTitle, DepartmentId, HomeSiteId, Email, HireDate)
        VALUES (@MgrNode.GetDescendant(@LastChild, NULL), @FirstName, @LastName, @JobTitle, @DeptId, @SiteId,
                @Email, COALESCE(@HireDate, CAST(SYSDATETIME() AS date)));

        SET @NewEmployeeId = SCOPE_IDENTITY();
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE Org.usp_MoveEmployeeSubtree
    @EmployeeId    int,
    @NewManagerId  int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OldNode hierarchyid, @NewParent hierarchyid, @NewNode hierarchyid, @LastChild hierarchyid;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @OldNode   = OrgNode FROM Org.Employee WITH (UPDLOCK, HOLDLOCK) WHERE EmployeeId = @EmployeeId;
        SELECT @NewParent = OrgNode FROM Org.Employee WITH (UPDLOCK, HOLDLOCK) WHERE EmployeeId = @NewManagerId;

        IF @OldNode IS NULL OR @NewParent IS NULL THROW 50083, 'Employee or new manager not found.', 1;
        IF @OldNode = hierarchyid::GetRoot()        THROW 50084, 'The head of the organisation cannot be moved.', 1;
        IF @NewParent.IsDescendantOf(@OldNode) = 1  THROW 50085, 'Cannot move an employee underneath their own reporting line.', 1;
        IF @OldNode.GetAncestor(1) = @NewParent      THROW 50086, 'Employee already reports to that manager.', 1;

        SELECT @LastChild = MAX(OrgNode)
          FROM Org.Employee WITH (UPDLOCK, HOLDLOCK)
         WHERE OrgNode.GetAncestor(1) = @NewParent;

        SET @NewNode = @NewParent.GetDescendant(@LastChild, NULL);

        -- one set-based statement moves the employee AND everyone beneath them
        UPDATE Org.Employee
           SET OrgNode = OrgNode.GetReparentedValue(@OldNode, @NewNode)
         WHERE OrgNode.IsDescendantOf(@OldNode) = 1;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;

    SELECT IndentedName, JobTitle, ManagerName, OrgPath
      FROM Org.vw_OrgChart
     WHERE OrgNode.IsDescendantOf(@NewNode) = 1
     ORDER BY OrgNode;
END;
GO

/* ===================================================================================
   INVENTORY - WRITE OPERATIONS
   =================================================================================== */
CREATE OR ALTER PROCEDURE Inventory.usp_AddLocation
    @ParentCode        varchar(30),
    @LocationCode      varchar(30),
    @LocationName      nvarchar(100),
    @LocationType      varchar(10),
    @TemperatureClass  varchar(8)    = NULL,
    @ZonePurpose       varchar(10)   = NULL,
    @CountryCode       char(2)       = NULL,
    @City              nvarchar(60)  = NULL,
    @MaxVolumeM3       decimal(9,3)  = NULL,
    @MaxWeightKg       decimal(10,2) = NULL,
    @NewLocationId     int           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ParentNode hierarchyid, @ParentType varchar(10), @LastChild hierarchyid;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @ParentNode = LocationNode, @ParentType = LocationType
          FROM Inventory.Location WITH (UPDLOCK, HOLDLOCK)
         WHERE LocationCode = @ParentCode AND IsActive = 1;
        IF @ParentNode IS NULL THROW 50010, 'Parent location not found or inactive.', 1;

        IF NOT EXISTS (SELECT 1
                         FROM (VALUES ('NETWORK','REGION'), ('REGION','SITE'), ('SITE','ZONE'),
                                      ('ZONE','AISLE'),    ('AISLE','BIN')) r(ParentType, ChildType)
                        WHERE r.ParentType = @ParentType AND r.ChildType = @LocationType)
            THROW 50011, 'Invalid hierarchy: the new location type must be the level directly below its parent.', 1;

        SELECT @LastChild = MAX(LocationNode)
          FROM Inventory.Location WITH (UPDLOCK, HOLDLOCK)
         WHERE LocationNode.GetAncestor(1) = @ParentNode;

        INSERT Inventory.Location (LocationNode, LocationCode, LocationName, LocationType, TemperatureClass,
                                   ZonePurpose, CountryCode, City, MaxVolumeM3, MaxWeightKg)
        VALUES (@ParentNode.GetDescendant(@LastChild, NULL), @LocationCode, @LocationName, @LocationType,
                @TemperatureClass, @ZonePurpose, @CountryCode, @City, @MaxVolumeM3, @MaxWeightKg);

        SET @NewLocationId = SCOPE_IDENTITY();
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE Inventory.usp_ReceivePurchaseOrderLine
    @PoNumber        varchar(20),
    @LineNumber      smallint,
    @QtyReceived     decimal(12,3),
    @BinCode         varchar(30),
    @LotNumber       varchar(30) = NULL,
    @ManufacturedOn  date        = NULL,
    @EmployeeId      int         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PoLineId int, @PurchaseOrderId int, @ProductId int, @Outstanding decimal(12,3),
            @UnitCost decimal(12,4), @PoStatus varchar(10), @ShipToSiteId int, @SupplierId int,
            @BinId int, @BinSiteId int, @DestTemp varchar(8), @DestPurpose varchar(10),
            @IsLotTracked bit, @ShelfLife smallint, @ProductTemp varchar(8), @LotId int = NULL,
            @Today date = CAST(SYSDATETIME() AS date);

    -- ---- validation -------------------------------------------------------------
    SELECT @PoLineId = pol.PoLineId, @PurchaseOrderId = po.PurchaseOrderId, @ProductId = pol.ProductId,
           @Outstanding = pol.QtyOrdered - pol.QtyReceived, @UnitCost = pol.UnitCost,
           @PoStatus = po.Status, @ShipToSiteId = po.ShipToSiteId, @SupplierId = po.SupplierId
      FROM Inventory.PurchaseOrder po
      JOIN Inventory.PurchaseOrderLine pol ON pol.PurchaseOrderId = po.PurchaseOrderId
     WHERE po.PoNumber = @PoNumber AND pol.LineNumber = @LineNumber;

    IF @PoLineId IS NULL                                   THROW 50001, 'Purchase order line not found.', 1;
    IF @PoStatus NOT IN ('SENT','PARTIAL')                 THROW 50002, 'Purchase order is not open for receiving.', 1;
    IF @QtyReceived <= 0 OR @QtyReceived > @Outstanding    THROW 50003, 'Receipt quantity must be positive and cannot exceed the outstanding quantity.', 1;

    SELECT @BinId = b.LocationId, @BinSiteId = ctx.SiteId, @DestTemp = ctx.TemperatureClass, @DestPurpose = ctx.ZonePurpose
      FROM Inventory.Location b
     CROSS APPLY Inventory.ufn_LocationContext(b.LocationId) ctx
     WHERE b.LocationCode = @BinCode AND b.LocationType = 'BIN' AND b.IsActive = 1;

    IF @BinId IS NULL               THROW 50004, 'Bin not found or inactive.', 1;
    IF @BinSiteId <> @ShipToSiteId  THROW 50006, 'Bin is not inside the purchase order ship-to site.', 1;

    SELECT @IsLotTracked = IsLotTracked, @ShelfLife = ShelfLifeDays, @ProductTemp = TemperatureClass
      FROM Inventory.Product WHERE ProductId = @ProductId;

    IF @DestPurpose = 'STORAGE' AND @DestTemp <> @ProductTemp
        THROW 50007, 'Bin temperature class does not match the product. Receive into staging or a matching zone.', 1;
    IF @IsLotTracked = 1 AND @LotNumber IS NULL
        THROW 50005, 'A lot number is required for this lot-tracked product.', 1;

    -- ---- transaction ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRAN;

        IF @IsLotTracked = 1
        BEGIN
            SELECT @LotId = LotId
              FROM Inventory.Lot WITH (UPDLOCK, HOLDLOCK)
             WHERE ProductId = @ProductId AND LotNumber = @LotNumber;

            IF @LotId IS NULL
            BEGIN
                INSERT Inventory.Lot (ProductId, LotNumber, SupplierId, ManufacturedOn, ExpiresOn, ReceivedOn)
                VALUES (@ProductId, @LotNumber, @SupplierId,
                        COALESCE(@ManufacturedOn, @Today),
                        CASE WHEN @ShelfLife IS NULL THEN NULL
                             ELSE DATEADD(day, @ShelfLife, COALESCE(@ManufacturedOn, @Today)) END,
                        @Today);
                SET @LotId = SCOPE_IDENTITY();
            END;
        END;

        -- upsert balance
        UPDATE Inventory.StockBalance WITH (HOLDLOCK)
           SET QtyOnHand = QtyOnHand + @QtyReceived, LastMovementAt = SYSDATETIME()
         WHERE ProductId = @ProductId AND LocationId = @BinId
           AND (LotId = @LotId OR (LotId IS NULL AND @LotId IS NULL));

        IF @@ROWCOUNT = 0
            INSERT Inventory.StockBalance (ProductId, LocationId, LotId, QtyOnHand, QtyAllocated, LastMovementAt)
            VALUES (@ProductId, @BinId, @LotId, @QtyReceived, 0, SYSDATETIME());

        INSERT Inventory.StockTransaction (TxnType, ProductId, LotId, FromLocationId, ToLocationId, Quantity,
                                           UnitCost, ReferenceType, ReferenceId, EmployeeId, Notes)
        VALUES ('RECEIPT', @ProductId, @LotId, NULL, @BinId, @QtyReceived, @UnitCost, 'PO', @PoLineId, @EmployeeId,
                CONCAT(N'Receipt against ', @PoNumber, N' line ', @LineNumber));

        UPDATE Inventory.PurchaseOrderLine
           SET QtyReceived = QtyReceived + @QtyReceived
         WHERE PoLineId = @PoLineId;

        UPDATE Inventory.PurchaseOrder
           SET Status = CASE WHEN EXISTS (SELECT 1 FROM Inventory.PurchaseOrderLine l
                                           WHERE l.PurchaseOrderId = @PurchaseOrderId
                                             AND l.QtyReceived < l.QtyOrdered)
                             THEN 'PARTIAL' ELSE 'RECEIVED' END
         WHERE PurchaseOrderId = @PurchaseOrderId;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE Inventory.usp_TransferStock
    @Sku          varchar(20),
    @FromBinCode  varchar(30),
    @ToBinCode    varchar(30),
    @Quantity     decimal(12,3),
    @LotNumber    varchar(30) = NULL,
    @EmployeeId   int         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProductId int, @IsLotTracked bit, @ProductTemp varchar(8), @StdCost decimal(12,4), @LotId int = NULL,
            @FromId int, @ToId int, @FromSite int, @ToSite int, @DestTemp varchar(8), @DestPurpose varchar(10);

    IF @Quantity <= 0 THROW 50016, 'Quantity must be positive.', 1;

    SELECT @ProductId = ProductId, @IsLotTracked = IsLotTracked, @ProductTemp = TemperatureClass, @StdCost = StandardCost
      FROM Inventory.Product WHERE Sku = @Sku;
    IF @ProductId IS NULL THROW 50012, 'SKU not found.', 1;

    IF @IsLotTracked = 1
    BEGIN
        SELECT @LotId = LotId FROM Inventory.Lot WHERE ProductId = @ProductId AND LotNumber = @LotNumber;
        IF @LotId IS NULL THROW 50013, 'A valid lot number is required for this lot-tracked SKU.', 1;
    END;

    SELECT @FromId = f.LocationId, @FromSite = fc.SiteId
      FROM Inventory.Location f
     CROSS APPLY Inventory.ufn_LocationContext(f.LocationId) fc
     WHERE f.LocationCode = @FromBinCode AND f.LocationType = 'BIN';

    SELECT @ToId = t.LocationId, @ToSite = tc.SiteId, @DestTemp = tc.TemperatureClass, @DestPurpose = tc.ZonePurpose
      FROM Inventory.Location t
     CROSS APPLY Inventory.ufn_LocationContext(t.LocationId) tc
     WHERE t.LocationCode = @ToBinCode AND t.LocationType = 'BIN' AND t.IsActive = 1;

    IF @FromId IS NULL OR @ToId IS NULL THROW 50014, 'Source or destination bin not found (or destination inactive).', 1;
    IF @FromId = @ToId                  THROW 50015, 'Source and destination bins are the same.', 1;
    IF @FromSite <> @ToSite             THROW 50017, 'Bin moves must stay inside one site. Use a transfer order between sites.', 1;
    IF @DestPurpose = 'STORAGE' AND @DestTemp <> @ProductTemp
        THROW 50018, 'Destination zone temperature class does not match the product requirement.', 1;

    BEGIN TRY
        BEGIN TRAN;

        -- decrement only if enough UNALLOCATED stock exists (atomic check-and-set)
        UPDATE Inventory.StockBalance
           SET QtyOnHand = QtyOnHand - @Quantity, LastMovementAt = SYSDATETIME()
         WHERE ProductId = @ProductId AND LocationId = @FromId
           AND (LotId = @LotId OR (LotId IS NULL AND @LotId IS NULL))
           AND QtyOnHand - QtyAllocated >= @Quantity;

        IF @@ROWCOUNT = 0 THROW 50019, 'Insufficient unallocated stock in the source bin.', 1;

        UPDATE Inventory.StockBalance WITH (HOLDLOCK)
           SET QtyOnHand = QtyOnHand + @Quantity, LastMovementAt = SYSDATETIME()
         WHERE ProductId = @ProductId AND LocationId = @ToId
           AND (LotId = @LotId OR (LotId IS NULL AND @LotId IS NULL));

        IF @@ROWCOUNT = 0
            INSERT Inventory.StockBalance (ProductId, LocationId, LotId, QtyOnHand, QtyAllocated, LastMovementAt)
            VALUES (@ProductId, @ToId, @LotId, @Quantity, 0, SYSDATETIME());

        INSERT Inventory.StockTransaction (TxnType, ProductId, LotId, FromLocationId, ToLocationId, Quantity,
                                           UnitCost, ReferenceType, EmployeeId, Notes)
        VALUES ('TRANSFER', @ProductId, @LotId, @FromId, @ToId, @Quantity, @StdCost, 'BINMOVE', @EmployeeId,
                CONCAT(N'Move ', @FromBinCode, N' -> ', @ToBinCode));

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE Inventory.usp_RecordCycleCount
    @Sku         varchar(20),
    @BinCode     varchar(30),
    @CountedQty  decimal(12,3),
    @LotNumber   varchar(30)   = NULL,
    @EmployeeId  int           = NULL,
    @Reason      nvarchar(150) = N'Cycle count'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProductId int, @IsLotTracked bit, @StdCost decimal(12,4), @LotId int = NULL, @BinId int,
            @BalanceId int, @OnHand decimal(12,3), @Allocated decimal(12,3), @Variance decimal(12,3);

    IF @CountedQty < 0 THROW 50020, 'Counted quantity cannot be negative.', 1;

    SELECT @ProductId = ProductId, @IsLotTracked = IsLotTracked, @StdCost = StandardCost
      FROM Inventory.Product WHERE Sku = @Sku;
    IF @ProductId IS NULL THROW 50021, 'SKU not found.', 1;

    SELECT @BinId = LocationId FROM Inventory.Location WHERE LocationCode = @BinCode AND LocationType = 'BIN';
    IF @BinId IS NULL THROW 50022, 'Bin not found.', 1;

    IF @IsLotTracked = 1
    BEGIN
        SELECT @LotId = LotId FROM Inventory.Lot WHERE ProductId = @ProductId AND LotNumber = @LotNumber;
        IF @LotId IS NULL THROW 50023, 'A valid lot number is required for this lot-tracked SKU.', 1;
    END;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @BalanceId = StockBalanceId, @OnHand = QtyOnHand, @Allocated = QtyAllocated
          FROM Inventory.StockBalance WITH (UPDLOCK, HOLDLOCK)
         WHERE ProductId = @ProductId AND LocationId = @BinId
           AND (LotId = @LotId OR (LotId IS NULL AND @LotId IS NULL));

        SET @OnHand    = COALESCE(@OnHand, 0);
        SET @Allocated = COALESCE(@Allocated, 0);

        IF @CountedQty < @Allocated
            THROW 50024, 'Counted quantity is below the quantity already allocated to orders. Resolve allocations first.', 1;

        SET @Variance = @CountedQty - @OnHand;

        IF @Variance <> 0
        BEGIN
            IF @BalanceId IS NULL
            BEGIN
                INSERT Inventory.StockBalance (ProductId, LocationId, LotId, QtyOnHand, QtyAllocated, LastMovementAt)
                VALUES (@ProductId, @BinId, @LotId, @CountedQty, 0, SYSDATETIME());
            END
            ELSE
            BEGIN
                UPDATE Inventory.StockBalance
                   SET QtyOnHand = @CountedQty, LastMovementAt = SYSDATETIME()
                 WHERE StockBalanceId = @BalanceId;
            END;

            INSERT Inventory.StockTransaction (TxnType, ProductId, LotId, FromLocationId, ToLocationId, Quantity,
                                               UnitCost, ReferenceType, EmployeeId, Notes)
            VALUES ('ADJUST', @ProductId, @LotId,
                    CASE WHEN @Variance < 0 THEN @BinId END,
                    CASE WHEN @Variance > 0 THEN @BinId END,
                    ABS(@Variance), @StdCost, 'COUNT', @EmployeeId,
                    CONCAT(@Reason, N': system ', @OnHand, N', counted ', @CountedQty));
        END;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;

    SELECT @Sku AS Sku, @BinCode AS BinCode, @LotNumber AS LotNumber,
           @OnHand AS SystemQty, @CountedQty AS CountedQty, @Variance AS Variance,
           CAST(@Variance * @StdCost AS decimal(12,2)) AS VarianceValue;
END;
GO

/* ===================================================================================
   INVENTORY - REPORTING
   =================================================================================== */
CREATE OR ALTER PROCEDURE Inventory.usp_GetLocationSubtree
    @LocationCode  varchar(30),
    @IncludeBins   bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Node hierarchyid;
    SELECT @Node = LocationNode FROM Inventory.Location WHERE LocationCode = @LocationCode;
    IF @Node IS NULL THROW 50025, 'Location not found.', 1;

    SELECT  r.IndentedName,
            r.LocationCode,
            r.LocationType,
            t.EffectiveTemperature,
            t.ZonePurpose,
            r.DistinctSkus,
            r.OccupiedBins,
            r.StockValue,
            r.OccupiedM3,
            r.CapacityM3,
            r.UtilisationPct
      FROM Inventory.vw_StockRollupByLocation r
      JOIN Inventory.vw_LocationTree t ON t.LocationId = r.LocationId
     WHERE r.LocationNode.IsDescendantOf(@Node) = 1
       AND (@IncludeBins = 1 OR r.LocationType <> 'BIN')
     ORDER BY r.LocationNode;
END;
GO

CREATE OR ALTER PROCEDURE Inventory.usp_GetKitRequirements
    @KitSku    varchar(20),
    @KitQty    int,
    @SiteCode  varchar(30)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @KitId int, @SiteNode hierarchyid;

    SELECT @KitId = ProductId FROM Inventory.Product WHERE Sku = @KitSku AND IsKit = 1;
    IF @KitId IS NULL THROW 50030, 'Kit SKU not found.', 1;
    IF @KitQty <= 0  THROW 50031, 'Kit quantity must be positive.', 1;

    SELECT @SiteNode = LocationNode FROM Inventory.Location WHERE LocationCode = @SiteCode AND LocationType = 'SITE';
    IF @SiteNode IS NULL THROW 50032, 'Site not found.', 1;

    -- Result 1: full multi-level structure
    SELECT  e.BomLevel,
            REPLICATE('    ', e.BomLevel - 1) + e.Sku AS IndentedSku,
            e.ProductName,
            e.IsKit,
            e.ExtendedQty
      FROM Inventory.ufn_ExplodeKit(@KitId, @KitQty) e
     ORDER BY e.BomPath;

    -- Result 2: raw (leaf) component requirement vs availability at the site
    WITH Leaf AS
    (
        SELECT ProductId, Sku, ProductName, SUM(ExtendedQty) AS QtyRequired
          FROM Inventory.ufn_ExplodeKit(@KitId, @KitQty)
         WHERE IsKit = 0
         GROUP BY ProductId, Sku, ProductName
    ),
    Avail AS
    (
        SELECT sb.ProductId, SUM(sb.QtyAvailable) AS QtyAvailable
          FROM Inventory.StockBalance sb
          JOIN Inventory.Location b ON b.LocationId = sb.LocationId
         WHERE b.LocationNode.IsDescendantOf(@SiteNode) = 1
         GROUP BY sb.ProductId
    )
    SELECT  l.Sku,
            l.ProductName,
            l.QtyRequired,
            COALESCE(a.QtyAvailable, 0) AS QtyAvailableAtSite,
            CASE WHEN COALESCE(a.QtyAvailable, 0) >= l.QtyRequired THEN 0
                 ELSE l.QtyRequired - COALESCE(a.QtyAvailable, 0) END AS Shortfall
      FROM Leaf l
      LEFT JOIN Avail a ON a.ProductId = l.ProductId
     ORDER BY Shortfall DESC, l.Sku;
END;
GO

/* ===================================================================================
   LOGISTICS
   =================================================================================== */
CREATE OR ALTER PROCEDURE Logistics.usp_CreateSalesOrder
    @CustomerCode          varchar(12),
    @FulfilSiteCode        varchar(30),
    @Lines                 Logistics.OrderLineList READONLY,
    @Priority              tinyint      = 2,
    @RequestedServiceCode  varchar(12)  = NULL,
    @PromisedDate          date         = NULL,
    @OrderedAt             datetime2(0) = NULL,     -- allows back-dated entry / migration
    @EmployeeId            int          = NULL,
    @OrderNumber           varchar(20)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @CustomerId int, @AddressId int, @SiteId int, @ServiceId int = NULL, @Transit tinyint = 2,
            @RootCustomerId int, @CreditLimit decimal(12,2), @Exposure decimal(14,2), @NewValue decimal(14,2),
            @Discount decimal(5,2), @SalesOrderId int, @Seq int, @Msg nvarchar(2048),
            @When datetime2(0) = COALESCE(@OrderedAt, SYSDATETIME());

    -- ---- validation -------------------------------------------------------------
    IF @OrderedAt > DATEADD(minute, 5, SYSDATETIME()) THROW 50039, 'Order date cannot be in the future.', 1;

    SELECT @CustomerId = CustomerId FROM Logistics.Customer WHERE CustomerCode = @CustomerCode AND IsActive = 1;
    IF @CustomerId IS NULL THROW 50040, 'Customer not found or inactive.', 1;

    SELECT @AddressId = AddressId FROM Logistics.CustomerAddress
     WHERE CustomerId = @CustomerId AND AddressType = 'DELIVERY' AND IsDefault = 1;
    IF @AddressId IS NULL THROW 50041, 'Customer has no default delivery address.', 1;

    SELECT @SiteId = LocationId FROM Inventory.Location
     WHERE LocationCode = @FulfilSiteCode AND LocationType = 'SITE' AND IsActive = 1;
    IF @SiteId IS NULL THROW 50042, 'Fulfilment site not found.', 1;

    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 50043, 'An order needs at least one line.', 1;
    IF EXISTS (SELECT 1 FROM @Lines l
                 LEFT JOIN Inventory.Product p ON p.Sku = l.Sku AND p.IsActive = 1
                WHERE p.ProductId IS NULL)
        THROW 50044, 'One or more SKUs are unknown or inactive.', 1;

    IF @RequestedServiceCode IS NOT NULL
    BEGIN
        SELECT @ServiceId = ServiceId, @Transit = TransitDaysTarget
          FROM Logistics.CarrierService WHERE ServiceCode = @RequestedServiceCode;
        IF @ServiceId IS NULL THROW 50045, 'Requested carrier service not found.', 1;
    END;

    -- ---- walk UP the account tree: group root + nearest defined discount ---------
    WITH Up AS
    (
        SELECT CustomerId, ParentCustomerId, DefaultDiscountPct, 0 AS Lvl
          FROM Logistics.Customer WHERE CustomerId = @CustomerId
        UNION ALL
        SELECT c.CustomerId, c.ParentCustomerId, c.DefaultDiscountPct, u.Lvl + 1
          FROM Logistics.Customer c
          JOIN Up u ON c.CustomerId = u.ParentCustomerId
    )
    SELECT @RootCustomerId = (SELECT CustomerId FROM Up WHERE ParentCustomerId IS NULL),
           @Discount       = COALESCE((SELECT TOP (1) DefaultDiscountPct FROM Up
                                        WHERE DefaultDiscountPct IS NOT NULL ORDER BY Lvl), 0);

    SELECT @CreditLimit = CreditLimit FROM Logistics.Customer WHERE CustomerId = @RootCustomerId;

    -- ---- walk DOWN from the root: open exposure of the whole group ---------------
    WITH Down AS
    (
        SELECT CustomerId FROM Logistics.Customer WHERE CustomerId = @RootCustomerId
        UNION ALL
        SELECT c.CustomerId FROM Logistics.Customer c JOIN Down d ON c.ParentCustomerId = d.CustomerId
    )
    SELECT @Exposure = COALESCE(SUM(sol.LineTotal), 0)
      FROM Down d
      JOIN Logistics.SalesOrder so      ON so.CustomerId = d.CustomerId
                                       AND so.Status IN ('NEW','PARTIAL','ALLOCATED','SHIPPED')
      JOIN Logistics.SalesOrderLine sol ON sol.SalesOrderId = so.SalesOrderId;

    SELECT @NewValue = SUM(CASE WHEN l.UnitPrice IS NOT NULL THEN l.Quantity * l.UnitPrice
                                ELSE l.Quantity * p.ListPrice * (1 - @Discount / 100) END)
      FROM @Lines l
      JOIN Inventory.Product p ON p.Sku = l.Sku;

    IF @CreditLimit IS NOT NULL AND @Exposure + @NewValue > @CreditLimit
    BEGIN
        SET @Msg = CONCAT(N'Group credit limit exceeded. Limit ', @CreditLimit,
                          N', open exposure ', @Exposure,
                          N', this order ', CAST(@NewValue AS decimal(14,2)), N'.');
        THROW 50046, @Msg, 1;
    END;

    -- ---- write ------------------------------------------------------------------
    BEGIN TRY
        BEGIN TRAN;

        SET @Seq = NEXT VALUE FOR Logistics.seq_SalesOrderNo;
        SET @OrderNumber = CONCAT('SO-', @Seq);

        INSERT Logistics.SalesOrder (OrderNumber, CustomerId, DeliveryAddressId, FulfilSiteId, RequestedServiceId,
                                     OrderedAt, PromisedDate, Priority, Status, CreatedBy)
        VALUES (@OrderNumber, @CustomerId, @AddressId, @SiteId, @ServiceId, @When,
                COALESCE(@PromisedDate, DATEADD(day, 1 + @Transit, CAST(@When AS date))),
                @Priority, 'NEW', @EmployeeId);

        SET @SalesOrderId = SCOPE_IDENTITY();

        INSERT Logistics.SalesOrderLine (SalesOrderId, LineNumber, ProductId, QtyOrdered, UnitPrice, DiscountPct)
        SELECT @SalesOrderId,
               ROW_NUMBER() OVER (ORDER BY l.Sku),
               p.ProductId,
               l.Quantity,
               COALESCE(l.UnitPrice, p.ListPrice),
               CASE WHEN l.UnitPrice IS NULL THEN @Discount ELSE 0 END
          FROM @Lines l
          JOIN Inventory.Product p ON p.Sku = l.Sku;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

-- Set-based FEFO allocation (First-Expiry-First-Out), no cursor:
-- a running total of available stock per order line decides how much each bin/lot gives.
CREATE OR ALTER PROCEDURE Logistics.usp_AllocateSalesOrder
    @OrderNumber  varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SalesOrderId int, @Status varchar(10), @SiteNode hierarchyid,
            @Today date = CAST(SYSDATETIME() AS date);

    DECLARE @Alloc TABLE (SoLineId int NOT NULL, StockBalanceId int NOT NULL, Quantity decimal(12,3) NOT NULL);

    SELECT @SalesOrderId = so.SalesOrderId, @Status = so.Status, @SiteNode = s.LocationNode
      FROM Logistics.SalesOrder so
      JOIN Inventory.Location s ON s.LocationId = so.FulfilSiteId
     WHERE so.OrderNumber = @OrderNumber;

    IF @SalesOrderId IS NULL            THROW 50050, 'Sales order not found.', 1;
    IF @Status NOT IN ('NEW','PARTIAL') THROW 50051, 'Only NEW or PARTIAL orders can be allocated.', 1;

    BEGIN TRY
        BEGIN TRAN;

        WITH Need AS
        (
            SELECT sol.SoLineId, sol.ProductId,
                   sol.QtyOrdered - sol.QtyAllocated - sol.QtyShipped AS QtyNeeded
              FROM Logistics.SalesOrderLine sol
             WHERE sol.SalesOrderId = @SalesOrderId
               AND sol.QtyOrdered - sol.QtyAllocated - sol.QtyShipped > 0
        ),
        Supply AS
        (
            SELECT  n.SoLineId,
                    n.QtyNeeded,
                    sb.StockBalanceId,
                    sb.QtyAvailable,
                    SUM(sb.QtyAvailable) OVER (
                        PARTITION BY n.SoLineId
                        ORDER BY CASE WHEN lt.ExpiresOn IS NULL THEN 1 ELSE 0 END,  -- dated lots first
                                 lt.ExpiresOn,                                      -- earliest expiry first
                                 b.LocationNode,                                    -- then walk order
                                 sb.StockBalanceId
                        ROWS UNBOUNDED PRECEDING) AS CumAvail
              FROM Need n
              JOIN Inventory.StockBalance sb WITH (UPDLOCK, HOLDLOCK) ON sb.ProductId = n.ProductId
              JOIN Inventory.Location b ON b.LocationId = sb.LocationId
              JOIN Inventory.Location z ON z.LocationType = 'ZONE'
                                       AND b.LocationNode.IsDescendantOf(z.LocationNode) = 1
              LEFT JOIN Inventory.Lot lt ON lt.LotId = sb.LotId
             WHERE b.LocationNode.IsDescendantOf(@SiteNode) = 1      -- only this site
               AND z.ZonePurpose = 'STORAGE'                          -- not dock/staging stock
               AND sb.QtyOnHand - sb.QtyAllocated > 0
               AND (lt.ExpiresOn IS NULL OR lt.ExpiresOn > @Today)    -- never allocate expired lots
        )
        INSERT @Alloc (SoLineId, StockBalanceId, Quantity)
        SELECT SoLineId,
               StockBalanceId,
               CASE WHEN CumAvail <= QtyNeeded THEN QtyAvailable
                    ELSE QtyNeeded - (CumAvail - QtyAvailable) END
          FROM Supply
         WHERE CumAvail - QtyAvailable < QtyNeeded;

        UPDATE sb
           SET sb.QtyAllocated = sb.QtyAllocated + a.Quantity
          FROM Inventory.StockBalance sb
          JOIN @Alloc a ON a.StockBalanceId = sb.StockBalanceId;

        INSERT Logistics.OrderAllocation (SoLineId, StockBalanceId, Quantity)
        SELECT SoLineId, StockBalanceId, Quantity FROM @Alloc;

        UPDATE sol
           SET sol.QtyAllocated = sol.QtyAllocated + x.Qty
          FROM Logistics.SalesOrderLine sol
          JOIN (SELECT SoLineId, SUM(Quantity) AS Qty FROM @Alloc GROUP BY SoLineId) x
            ON x.SoLineId = sol.SoLineId;

        UPDATE Logistics.SalesOrder
           SET Status = CASE
                 WHEN NOT EXISTS (SELECT 1 FROM Logistics.SalesOrderLine l
                                   WHERE l.SalesOrderId = @SalesOrderId
                                     AND l.QtyAllocated + l.QtyShipped < l.QtyOrdered) THEN 'ALLOCATED'
                 WHEN EXISTS     (SELECT 1 FROM Logistics.SalesOrderLine l
                                   WHERE l.SalesOrderId = @SalesOrderId
                                     AND (l.QtyAllocated > 0 OR l.QtyShipped > 0))      THEN 'PARTIAL'
                 ELSE 'NEW' END
         WHERE SalesOrderId = @SalesOrderId;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;

    -- Result 1: pick list in warehouse walk order
    SELECT PickSequence, OrderNumber, ZoneCode, BinCode, LineNumber, Sku, LotNumber, ExpiresOn, Quantity
      FROM Logistics.vw_OpenPickList
     WHERE OrderNumber = @OrderNumber
     ORDER BY PickSequence;

    -- Result 2: line coverage
    SELECT sol.LineNumber, p.Sku, sol.QtyOrdered, sol.QtyAllocated, sol.QtyShipped,
           sol.QtyOrdered - sol.QtyAllocated - sol.QtyShipped AS QtyShort
      FROM Logistics.SalesOrderLine sol
      JOIN Inventory.Product p ON p.ProductId = sol.ProductId
     WHERE sol.SalesOrderId = @SalesOrderId
     ORDER BY sol.LineNumber;
END;
GO

-- Packs and dispatches everything currently allocated to an order.
-- Road/sea consignments over 30 kg are palletised: one PALLET with a CARTON per order line.
CREATE OR ALTER PROCEDURE Logistics.usp_ShipSalesOrder
    @OrderNumber     varchar(20),
    @ServiceCode     varchar(12),
    @DispatchAt      datetime2(0) = NULL,
    @EmployeeId      int          = NULL,
    @ShipmentNumber  varchar(20)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SalesOrderId int, @Status varchar(10), @SiteId int, @OrderedAt datetime2(0),
            @ServiceId int, @AllowsHazmat bit, @MaxWeight decimal(9,2), @BaseRate decimal(9,2),
            @RatePerKg decimal(9,4), @Transit tinyint, @CarrierCode varchar(10), @Mode varchar(8),
            @NetWeight decimal(12,3), @GrossWeight decimal(12,3), @CartonCount int, @UsePallet bit,
            @ShipmentId int, @Seq int, @PalletId int = NULL, @Msg nvarchar(2048),
            @Now datetime2(0) = COALESCE(@DispatchAt, SYSDATETIME());

    DECLARE @Pick TABLE
    (
        AllocationId      int PRIMARY KEY,
        SoLineId          int,
        LineNumber        smallint,
        StockBalanceId    int,
        ProductId         int,
        LotId             int NULL,
        LocationId        int,
        Quantity          decimal(12,3),
        UnitWeightKg      decimal(9,3),
        StandardCost      decimal(12,4),
        TemperatureClass  varchar(8)
    );

    -- ---- validation -------------------------------------------------------------
    SELECT @SalesOrderId = SalesOrderId, @Status = Status, @SiteId = FulfilSiteId, @OrderedAt = OrderedAt
      FROM Logistics.SalesOrder WHERE OrderNumber = @OrderNumber;

    IF @SalesOrderId IS NULL                      THROW 50060, 'Sales order not found.', 1;
    IF @Status NOT IN ('ALLOCATED','PARTIAL')     THROW 50061, 'Order has no allocated stock to ship.', 1;
    IF @Now < @OrderedAt                          THROW 50066, 'Dispatch time cannot be before the order time.', 1;
    IF @Now > DATEADD(minute, 5, SYSDATETIME())   THROW 50067, 'Dispatch time cannot be in the future.', 1;

    SELECT @ServiceId = cs.ServiceId, @AllowsHazmat = cs.AllowsHazmat, @MaxWeight = cs.MaxWeightKg,
           @BaseRate = cs.BaseRate, @RatePerKg = cs.RatePerKg, @Transit = cs.TransitDaysTarget,
           @CarrierCode = c.CarrierCode, @Mode = c.TransportMode
      FROM Logistics.CarrierService cs
      JOIN Logistics.Carrier c ON c.CarrierId = cs.CarrierId
     WHERE cs.ServiceCode = @ServiceCode AND c.IsActive = 1;

    IF @ServiceId IS NULL THROW 50062, 'Carrier service not found or carrier inactive.', 1;

    INSERT @Pick (AllocationId, SoLineId, LineNumber, StockBalanceId, ProductId, LotId, LocationId,
                  Quantity, UnitWeightKg, StandardCost, TemperatureClass)
    SELECT oa.AllocationId, oa.SoLineId, sol.LineNumber, sb.StockBalanceId, sb.ProductId, sb.LotId, sb.LocationId,
           oa.Quantity, p.UnitWeightKg, p.StandardCost, p.TemperatureClass
      FROM Logistics.OrderAllocation oa
      JOIN Logistics.SalesOrderLine sol ON sol.SoLineId      = oa.SoLineId
      JOIN Inventory.StockBalance sb    ON sb.StockBalanceId = oa.StockBalanceId
      JOIN Inventory.Product p          ON p.ProductId       = sb.ProductId
     WHERE sol.SalesOrderId = @SalesOrderId
       AND oa.ShipmentId IS NULL;

    IF NOT EXISTS (SELECT 1 FROM @Pick) THROW 50063, 'No open allocations found for this order.', 1;

    IF @AllowsHazmat = 0 AND EXISTS (SELECT 1 FROM @Pick WHERE TemperatureClass = 'HAZMAT')
        THROW 50064, 'The selected service cannot carry hazardous goods.', 1;

    SELECT @NetWeight = SUM(Quantity * UnitWeightKg) FROM @Pick;
    SELECT @CartonCount = COUNT(DISTINCT SoLineId) FROM @Pick;
    SET @UsePallet   = CASE WHEN @Mode IN ('ROAD','SEA') AND @NetWeight > 30 THEN 1 ELSE 0 END;
    SET @GrossWeight = @NetWeight + (@CartonCount * 0.4) + CASE WHEN @UsePallet = 1 THEN 22 ELSE 0 END;

    IF @GrossWeight > @MaxWeight
    BEGIN
        SET @Msg = CONCAT(N'Consignment weight ', CAST(@GrossWeight AS decimal(10,1)),
                          N' kg exceeds the ', @ServiceCode, N' limit of ', @MaxWeight, N' kg.');
        THROW 50065, @Msg, 1;
    END;

    -- ---- write ------------------------------------------------------------------
    BEGIN TRY
        BEGIN TRAN;

        SET @Seq = NEXT VALUE FOR Logistics.seq_ShipmentNo;
        SET @ShipmentNumber = CONCAT('SH-', @Seq);

        INSERT Logistics.Shipment (ShipmentNumber, SalesOrderId, OriginSiteId, ServiceId, TrackingNumber, Status,
                                   DispatchedAt, PromisedDelivery, DeliveredAt, GrossWeightKg, FreightCost, CreatedBy)
        VALUES (@ShipmentNumber, @SalesOrderId, @SiteId, @ServiceId,
                CONCAT(@CarrierCode, '-', @Seq, '-', RIGHT(CONCAT('0000', @SalesOrderId), 4)),
                'DISPATCHED', @Now, DATEADD(day, @Transit, CAST(@Now AS date)), NULL,
                @GrossWeight, CAST(@BaseRate + @RatePerKg * @GrossWeight AS decimal(10,2)), @EmployeeId);

        SET @ShipmentId = SCOPE_IDENTITY();

        -- packaging tree
        IF @UsePallet = 1
        BEGIN
            INSERT Logistics.ShipmentPackage (ShipmentId, ParentPackageId, PackageType, LabelCode, GrossWeightKg)
            VALUES (@ShipmentId, NULL, 'PALLET', CONCAT(@ShipmentNumber, '-P01'), @GrossWeight);
            SET @PalletId = SCOPE_IDENTITY();
        END;

        INSERT Logistics.ShipmentPackage (ShipmentId, ParentPackageId, PackageType, LabelCode, GrossWeightKg)
        SELECT @ShipmentId, @PalletId, 'CARTON',
               CONCAT(@ShipmentNumber, '-C', RIGHT(CONCAT('00', LineNumber), 2)),
               SUM(Quantity * UnitWeightKg) + 0.4
          FROM @Pick
         GROUP BY LineNumber;

        INSERT Logistics.PackageContent (PackageId, SoLineId, ProductId, LotId, Quantity)
        SELECT pk.PackageId, p.SoLineId, p.ProductId, p.LotId, SUM(p.Quantity)
          FROM @Pick p
          JOIN Logistics.ShipmentPackage pk
            ON pk.ShipmentId = @ShipmentId
           AND pk.LabelCode  = CONCAT(@ShipmentNumber, '-C', RIGHT(CONCAT('00', p.LineNumber), 2))
         GROUP BY pk.PackageId, p.SoLineId, p.ProductId, p.LotId;

        -- stock leaves the building
        UPDATE sb
           SET sb.QtyOnHand      = sb.QtyOnHand    - x.Qty,
               sb.QtyAllocated   = sb.QtyAllocated - x.Qty,
               sb.LastMovementAt = @Now
          FROM Inventory.StockBalance sb
          JOIN (SELECT StockBalanceId, SUM(Quantity) AS Qty FROM @Pick GROUP BY StockBalanceId) x
            ON x.StockBalanceId = sb.StockBalanceId;

        INSERT Inventory.StockTransaction (TxnType, ProductId, LotId, FromLocationId, ToLocationId, Quantity,
                                           UnitCost, ReferenceType, ReferenceId, EmployeeId, TxnAt, Notes)
        SELECT 'SHIP', ProductId, LotId, LocationId, NULL, SUM(Quantity), StandardCost,
               'SHIPMENT', @ShipmentId, @EmployeeId, @Now, CONCAT(N'Shipped on ', @ShipmentNumber)
          FROM @Pick
         GROUP BY ProductId, LotId, LocationId, StandardCost;

        UPDATE oa
           SET oa.ShipmentId = @ShipmentId
          FROM Logistics.OrderAllocation oa
          JOIN @Pick p ON p.AllocationId = oa.AllocationId;

        UPDATE sol
           SET sol.QtyShipped   = sol.QtyShipped   + x.Qty,
               sol.QtyAllocated = sol.QtyAllocated - x.Qty
          FROM Logistics.SalesOrderLine sol
          JOIN (SELECT SoLineId, SUM(Quantity) AS Qty FROM @Pick GROUP BY SoLineId) x
            ON x.SoLineId = sol.SoLineId;

        UPDATE Logistics.SalesOrder
           SET Status = CASE WHEN EXISTS (SELECT 1 FROM Logistics.SalesOrderLine l
                                           WHERE l.SalesOrderId = @SalesOrderId
                                             AND l.QtyShipped < l.QtyOrdered)
                             THEN 'PARTIAL' ELSE 'SHIPPED' END
         WHERE SalesOrderId = @SalesOrderId;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;

    SELECT IndentedPackage, GrossWeightKg, Contents
      FROM Logistics.vw_ShipmentPackageTree
     WHERE ShipmentNumber = @ShipmentNumber
     ORDER BY PackagePath;
END;
GO

CREATE OR ALTER PROCEDURE Logistics.usp_RecordTrackingEvent
    @TrackingNumber  varchar(30),
    @EventCode       varchar(20),
    @EventAt         datetime2(0)  = NULL,
    @LocationText    nvarchar(100) = NULL,
    @Notes           nvarchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ShipmentId int, @Status varchar(10), @SalesOrderId int, @DispatchedAt datetime2(0);
    SET @EventAt = COALESCE(@EventAt, SYSDATETIME());

    SELECT @ShipmentId = ShipmentId, @Status = Status, @SalesOrderId = SalesOrderId, @DispatchedAt = DispatchedAt
      FROM Logistics.Shipment WHERE TrackingNumber = @TrackingNumber;

    IF @ShipmentId IS NULL        THROW 50070, 'Tracking number not found.', 1;
    IF @Status = 'DELIVERED'      THROW 50071, 'Shipment is already delivered; no further events accepted.', 1;
    IF @EventAt < @DispatchedAt   THROW 50072, 'Event time cannot be before dispatch.', 1;

    BEGIN TRY
        BEGIN TRAN;

        INSERT Logistics.TrackingEvent (ShipmentId, EventCode, EventAt, LocationText, Notes)
        VALUES (@ShipmentId, @EventCode, @EventAt, @LocationText, @Notes);

        UPDATE Logistics.Shipment
           SET Status = CASE @EventCode
                            WHEN 'DELIVERED'      THEN 'DELIVERED'
                            WHEN 'DELAYED'        THEN 'EXCEPTION'
                            WHEN 'FAILED_ATTEMPT' THEN 'EXCEPTION'
                            ELSE 'IN_TRANSIT' END,
               DeliveredAt = CASE WHEN @EventCode = 'DELIVERED' THEN @EventAt ELSE NULL END
         WHERE ShipmentId = @ShipmentId;

        -- order is DELIVERED only when fully shipped AND every shipment is delivered
        IF @EventCode = 'DELIVERED'
           AND NOT EXISTS (SELECT 1 FROM Logistics.Shipment
                            WHERE SalesOrderId = @SalesOrderId AND Status <> 'DELIVERED')
           AND NOT EXISTS (SELECT 1 FROM Logistics.SalesOrderLine
                            WHERE SalesOrderId = @SalesOrderId AND QtyShipped < QtyOrdered)
        BEGIN
            UPDATE Logistics.SalesOrder SET Status = 'DELIVERED' WHERE SalesOrderId = @SalesOrderId;
        END;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE Logistics.usp_CarrierScorecard
    @FromDate  date,
    @ToDate    date
AS
BEGIN
    SET NOCOUNT ON;

    IF @ToDate < @FromDate THROW 50075, 'ToDate must be on or after FromDate.', 1;

    WITH S AS
    (
        SELECT  c.CarrierCode, cs.ServiceCode, cs.TransitDaysTarget,
                sh.DispatchedAt, sh.DeliveredAt, sh.FreightCost, sh.GrossWeightKg,
                CASE WHEN sh.Status = 'DELIVERED' THEN 1 ELSE 0 END AS IsDelivered,
                CASE WHEN sh.Status = 'DELIVERED'
                      AND CAST(sh.DeliveredAt AS date) <= sh.PromisedDelivery THEN 1 ELSE 0 END AS IsOnTime
          FROM Logistics.Shipment sh
          JOIN Logistics.CarrierService cs ON cs.ServiceId = sh.ServiceId
          JOIN Logistics.Carrier c         ON c.CarrierId  = cs.CarrierId
         WHERE sh.DispatchedAt >= @FromDate
           AND sh.DispatchedAt <  DATEADD(day, 1, @ToDate)
    ),
    Agg AS
    (
        SELECT  CarrierCode, ServiceCode, TransitDaysTarget,
                COUNT(*)         AS Shipments,
                SUM(IsDelivered) AS Delivered,
                SUM(IsOnTime)    AS OnTime,
                CAST(100.0 * SUM(IsOnTime) / NULLIF(SUM(IsDelivered), 0) AS decimal(5,1)) AS OnTimePct,
                CAST(AVG(CASE WHEN IsDelivered = 1
                              THEN DATEDIFF(hour, DispatchedAt, DeliveredAt) / 24.0 END) AS decimal(6,2)) AS AvgTransitDays,
                CAST(SUM(FreightCost) AS decimal(12,2)) AS FreightSpend,
                CAST(SUM(FreightCost) / NULLIF(SUM(GrossWeightKg), 0) AS decimal(10,4)) AS CostPerKg
          FROM S
         GROUP BY CarrierCode, ServiceCode, TransitDaysTarget
    )
    SELECT  CarrierCode, ServiceCode, TransitDaysTarget, Shipments, Delivered, OnTime, OnTimePct,
            AvgTransitDays, FreightSpend, CostPerKg,
            DENSE_RANK() OVER (ORDER BY OnTimePct DESC, CostPerKg ASC) AS ServiceRank,
            CASE WHEN OnTimePct IS NULL THEN 'NO DATA'
                 WHEN OnTimePct >= 95   THEN 'PREFERRED'
                 WHEN OnTimePct >= 80   THEN 'ACCEPTABLE'
                 ELSE 'REVIEW' END AS Rating
      FROM Agg
     ORDER BY ServiceRank, CarrierCode, ServiceCode;
END;
GO

/* ===================================================================================
   TRIGGERS
   =================================================================================== */

-- The ledger is the audit trail: corrections are new ADJUST rows, never edits.
CREATE OR ALTER TRIGGER Inventory.trg_StockTransaction_Immutable
ON Inventory.StockTransaction
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50090, 'The stock ledger is append-only. Post a correcting ADJUST transaction instead.', 1;
END;
GO

-- BOM integrity: parent must be a kit, and no kit may (directly or indirectly) contain itself.
CREATE OR ALTER TRIGGER Inventory.trg_KitComponent_Validate
ON Inventory.KitComponent
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM inserted i
                 JOIN Inventory.Product p ON p.ProductId = i.KitProductId
                WHERE p.IsKit = 0)
        THROW 50091, 'Only products flagged IsKit = 1 can have components.', 1;

    DECLARE @Cycles int;

    WITH Walk AS
    (
        SELECT i.KitProductId AS StartKit, i.ComponentProductId AS CurrentId, 1 AS Depth
          FROM inserted i
        UNION ALL
        SELECT w.StartKit, kc.ComponentProductId, w.Depth + 1
          FROM Walk w
          JOIN Inventory.KitComponent kc ON kc.KitProductId = w.CurrentId
         WHERE w.Depth < 20
    )
    SELECT @Cycles = COUNT(*) FROM Walk WHERE CurrentId = StartKit;

    IF @Cycles > 0
        THROW 50092, 'Bill of materials cycle detected: a kit cannot contain itself.', 1;
END;
GO

CREATE OR ALTER TRIGGER Inventory.trg_Product_PriceAudit
ON Inventory.Product
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT (UPDATE(StandardCost) OR UPDATE(ListPrice)) RETURN;

    INSERT Core.AuditLog (TableName, RecordKey, ActionType, ColumnName, OldValue, NewValue)
    SELECT 'Inventory.Product', i.Sku, 'UPDATE', v.ColumnName, v.OldValue, v.NewValue
      FROM inserted i
      JOIN deleted d ON d.ProductId = i.ProductId
     CROSS APPLY (VALUES
            (N'StandardCost', CAST(d.StandardCost AS nvarchar(40)), CAST(i.StandardCost AS nvarchar(40))),
            (N'ListPrice',    CAST(d.ListPrice    AS nvarchar(40)), CAST(i.ListPrice    AS nvarchar(40)))
         ) v(ColumnName, OldValue, NewValue)
     WHERE v.OldValue <> v.NewValue;
END;
GO

CREATE OR ALTER TRIGGER Logistics.trg_SalesOrder_StatusAudit
ON Logistics.SalesOrder
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(Status) RETURN;

    INSERT Core.AuditLog (TableName, RecordKey, ActionType, ColumnName, OldValue, NewValue)
    SELECT 'Logistics.SalesOrder', i.OrderNumber, 'UPDATE', 'Status', d.Status, i.Status
      FROM inserted i
      JOIN deleted d ON d.SalesOrderId = i.SalesOrderId
     WHERE i.Status <> d.Status;
END;
GO

PRINT 'Step 3 complete: 13 procedures and 4 triggers created.';
GO
