/*
=====================================================================================
  VerdantStackDB  -  STEP 5 of 5 : Live Demo Transactions and Showcase Queries
-------------------------------------------------------------------------------------
  Run after Step4_Seed_Data.sql

  PART A  runs a realistic working day THROUGH THE STORED PROCEDURES ONLY:
          goods-in, putaway, cycle count, order entry, FEFO allocation, packing,
          dispatch, carrier tracking, back-order recovery, reorganisation, site expansion.
          Deliberate failures are included (and caught) to prove the business rules work.

  PART B  showcase queries - one result grid per capability, ready for screenshots.

  Tip: in SSMS open the "Messages" tab to follow the step-by-step narration.
=====================================================================================
*/
USE VerdantStackDB;
GO
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ===================================================================================
   PART A - LIVE DEMO (single batch: variables carry state between steps)
   =================================================================================== */
DECLARE
    -- people
    @Isolde  int = (SELECT EmployeeId FROM Org.Employee WHERE Email = 'isolde.marchetti@verdantstack.example'),
    @Ewa     int = (SELECT EmployeeId FROM Org.Employee WHERE Email = 'ewa.brzezinska@verdantstack.example'),
    @Ruby    int = (SELECT EmployeeId FROM Org.Employee WHERE Email = 'ruby.thistlewood@verdantstack.example'),
    @Desmond int = (SELECT EmployeeId FROM Org.Employee WHERE Email = 'desmond.achterberg@verdantstack.example'),
    @Imogen  int = (SELECT EmployeeId FROM Org.Employee WHERE Email = 'imogen.prycelacey@verdantstack.example'),
    @Leona   int = (SELECT EmployeeId FROM Org.Employee WHERE Email = 'leona.whitcombe@verdantstack.example'),
    @Gideon  int = (SELECT EmployeeId FROM Org.Employee WHERE Email = 'gideon.ashworth@verdantstack.example'),
    -- working variables
    @Mfg date, @When datetime2(0), @EventAt datetime2(0), @Dispatched datetime2(0),
    @OrdA varchar(20), @OrdB varchar(20), @OrdC varchar(20), @OrdD varchar(20), @OrdE varchar(20),
    @ShipA varchar(20), @ShipB varchar(20), @ShipC varchar(20), @Trk varchar(30),
    @NewMgr int, @NewCoord int, @NewLoc int;

DECLARE @Lines Logistics.OrderLineList;

PRINT '=====================================================================';
PRINT ' A1. GOODS-IN: receive PO-30103 (RhizoBloom biologicals) at Leeds dock';
PRINT '=====================================================================';
SET @Mfg = DATEADD(day, -8, CAST(SYSDATETIME() AS date));
EXEC Inventory.usp_ReceivePurchaseOrderLine
     @PoNumber = 'PO-30103', @LineNumber = 1, @QtyReceived = 100, @BinCode = 'LDS1-DCK-IN-B01',
     @LotNumber = 'RZB-0531', @ManufacturedOn = @Mfg, @EmployeeId = @Ewa;
PRINT '   Line 1: 100 x VS-BIO-MYC received into new lot RZB-0531';

SET @Mfg = DATEADD(day, -10, CAST(SYSDATETIME() AS date));
EXEC Inventory.usp_ReceivePurchaseOrderLine
     @PoNumber = 'PO-30103', @LineNumber = 2, @QtyReceived = 40, @BinCode = 'LDS1-DCK-IN-B01',
     @LotNumber = 'RZB-E288', @ManufacturedOn = @Mfg, @EmployeeId = @Ewa;
PRINT '   Line 2: 40 of 60 x VS-BIO-ENZ received (short delivery) -> PO status PARTIAL';

PRINT '';
PRINT ' A2. PUTAWAY: move chilled goods from dock staging into the chilled room';
EXEC Inventory.usp_TransferStock @Sku = 'VS-BIO-MYC', @FromBinCode = 'LDS1-DCK-IN-B01',
     @ToBinCode = 'LDS1-CHL-C01-B02', @Quantity = 100, @LotNumber = 'RZB-0531', @EmployeeId = @Desmond;
EXEC Inventory.usp_TransferStock @Sku = 'VS-BIO-ENZ', @FromBinCode = 'LDS1-DCK-IN-B01',
     @ToBinCode = 'LDS1-CHL-C01-B04', @Quantity = 40, @LotNumber = 'RZB-E288', @EmployeeId = @Desmond;
PRINT '   Both lots now in LDS1-CHL (chilled storage).';

PRINT '';
PRINT ' A3. RULE CHECK: try to put a chilled product into ambient storage';
BEGIN TRY
    EXEC Inventory.usp_TransferStock @Sku = 'VS-BIO-ENZ', @FromBinCode = 'LDS1-CHL-C01-B04',
         @ToBinCode = 'LDS1-AMB-A01-B01', @Quantity = 5, @LotNumber = 'RZB-E260', @EmployeeId = @Desmond;
    PRINT '   !! Unexpected: transfer was accepted';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    PRINT CONCAT('   Rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

PRINT '';
PRINT ' A4. CYCLE COUNT: tee fittings counted short by 15';
EXEC Inventory.usp_RecordCycleCount @Sku = 'VS-FIT-16T', @BinCode = 'LDS1-AMB-A03-B02',
     @CountedQty = 4185, @EmployeeId = @Imogen, @Reason = N'Quarterly cycle count';

PRINT '';
PRINT ' A5. PRICE CHANGE: list price update captured by audit trigger';
UPDATE Inventory.Product SET ListPrice = 419.00 WHERE Sku = 'VS-LED-320';

PRINT '';
PRINT ' A6. RULE CHECK: try to edit the stock ledger';
BEGIN TRY
    UPDATE Inventory.StockTransaction SET Quantity = 1 WHERE TxnId = 1;
    PRINT '   !! Unexpected: ledger was edited';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    PRINT CONCAT('   Rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

PRINT '';
PRINT ' A7. RULE CHECK: try to create a BOM cycle (Pump kit containing the Tower kit)';
BEGIN TRY
    INSERT Inventory.KitComponent (KitProductId, ComponentProductId, QtyPer)
    SELECT k.ProductId, c.ProductId, 1
      FROM Inventory.Product k, Inventory.Product c
     WHERE k.Sku = 'VS-KIT-PMA' AND c.Sku = 'VS-KIT-TWR';
    PRINT '   !! Unexpected: cycle was accepted';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    PRINT CONCAT('   Rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

PRINT '';
PRINT '=====================================================================';
PRINT ' A8. ORDER ENTRY (table-valued parameter, inherited discounts, credit check)';
PRINT '=====================================================================';
-- Order A: Greenhaven Sheffield branch (inherits 7.5 % from group), placed 2 days ago
DELETE @Lines;
INSERT @Lines (Sku, Quantity) VALUES ('VS-NU-A1L', 60), ('VS-PHD-1L', 12), ('VS-KIT-TWR', 2), ('VS-BIO-MYC', 10);
SET @When = DATEADD(day, -2, SYSDATETIME());
EXEC Logistics.usp_CreateSalesOrder @CustomerCode = 'C-GRN-SHF', @FulfilSiteCode = 'LDS1', @Lines = @Lines,
     @Priority = 1, @RequestedServiceCode = 'NTH-PAL48', @OrderedAt = @When, @EmployeeId = @Leona,
     @OrderNumber = @OrdA OUTPUT;
PRINT CONCAT('   ', @OrdA, ' created for C-GRN-SHF (Leeds)');

-- Order B: Hydroponic Hut York, wants more 640 W fixtures than are in stock
DELETE @Lines;
INSERT @Lines (Sku, Quantity) VALUES ('VS-LED-640', 10), ('VS-SEN-WIFI', 8);
SET @When = DATEADD(day, -1, SYSDATETIME());
EXEC Logistics.usp_CreateSalesOrder @CustomerCode = 'C-HYD-YRK', @FulfilSiteCode = 'LDS1', @Lines = @Lines,
     @RequestedServiceCode = 'NTH-PAL24', @OrderedAt = @When, @EmployeeId = @Leona,
     @OrderNumber = @OrdB OUTPUT;
PRINT CONCAT('   ', @OrdB, ' created for C-HYD-YRK (Leeds) - will be short on VS-LED-640');

-- Order C: Bloemrijk Utrecht from Rotterdam, one line at a negotiated price
DELETE @Lines;
INSERT @Lines (Sku, Quantity, UnitPrice) VALUES ('VS-CC-50L', 50, 13.50), ('VS-PHD-1L', 30, NULL);
SET @When = DATEADD(day, -4, SYSDATETIME());
EXEC Logistics.usp_CreateSalesOrder @CustomerCode = 'C-BLM-UTR', @FulfilSiteCode = 'RTM1', @Lines = @Lines,
     @RequestedServiceCode = 'ORT-EU72', @OrderedAt = @When, @EmployeeId = @Leona,
     @OrderNumber = @OrdC OUTPUT;
PRINT CONCAT('   ', @OrdC, ' created for C-BLM-UTR (Rotterdam)');

-- Order D: Loftleaf from Bristol - left unallocated to populate backlog reports
DELETE @Lines;
INSERT @Lines (Sku, Quantity) VALUES ('VS-BIO-MYC', 6), ('VS-NU-B1L', 10);
EXEC Logistics.usp_CreateSalesOrder @CustomerCode = 'C-LOF', @FulfilSiteCode = 'BRS1', @Lines = @Lines,
     @RequestedServiceCode = 'PKT-NXT', @EmployeeId = @Leona, @OrderNumber = @OrdD OUTPUT;
PRINT CONCAT('   ', @OrdD, ' created for C-LOF (Bristol) - stays NEW');

-- Order E: college with a 5,000 limit orders 15 tower kits -> must be refused
PRINT '';
PRINT ' A9. RULE CHECK: order that breaches the group credit limit';
DELETE @Lines;
INSERT @Lines (Sku, Quantity) VALUES ('VS-KIT-TWR', 15);
BEGIN TRY
    EXEC Logistics.usp_CreateSalesOrder @CustomerCode = 'C-ATH', @FulfilSiteCode = 'BRS1', @Lines = @Lines,
         @EmployeeId = @Leona, @OrderNumber = @OrdE OUTPUT;
    PRINT '   !! Unexpected: order accepted';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    PRINT CONCAT('   Rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

PRINT '';
PRINT '=====================================================================';
PRINT ' A10. FEFO ALLOCATION (earliest expiry first, expired lots skipped)';
PRINT '=====================================================================';
EXEC Logistics.usp_AllocateSalesOrder @OrderNumber = @OrdA;
PRINT CONCAT('   ', @OrdA, ': VS-NU-A1L takes all 40 from lot AQL-L7702 (expiring) before AQL-L7781');
EXEC Logistics.usp_AllocateSalesOrder @OrderNumber = @OrdB;
PRINT CONCAT('   ', @OrdB, ': only 7 of 10 VS-LED-640 available -> status PARTIAL');
EXEC Logistics.usp_AllocateSalesOrder @OrderNumber = @OrdC;
PRINT CONCAT('   ', @OrdC, ': fully allocated from Rotterdam stock');

PRINT '';
PRINT '=====================================================================';
PRINT ' A11. PACK & DISPATCH';
PRINT '=====================================================================';
-- Order C dispatched 3 days ago and delivered yesterday
SET @Dispatched = DATEADD(day, -3, SYSDATETIME());
EXEC Logistics.usp_ShipSalesOrder @OrderNumber = @OrdC, @ServiceCode = 'ORT-EU72',
     @DispatchAt = @Dispatched, @EmployeeId = @Gideon, @ShipmentNumber = @ShipC OUTPUT;
PRINT CONCAT('   ', @OrdC, ' -> ', @ShipC, ' (palletised road groupage, hazmat permitted)');

-- Order A dispatched yesterday, still in transit
SET @Dispatched = DATEADD(day, -1, SYSDATETIME());
EXEC Logistics.usp_ShipSalesOrder @OrderNumber = @OrdA, @ServiceCode = 'NTH-PAL48',
     @DispatchAt = @Dispatched, @EmployeeId = @Gideon, @ShipmentNumber = @ShipA OUTPUT;
PRINT CONCAT('   ', @OrdA, ' -> ', @ShipA, ' (1 pallet, 4 cartons)');

PRINT '';
PRINT ' A12. RULE CHECK: try to send 88 kg of lighting by 30 kg parcel service';
BEGIN TRY
    EXEC Logistics.usp_ShipSalesOrder @OrderNumber = @OrdB, @ServiceCode = 'PKT-STD',
         @EmployeeId = @Gideon, @ShipmentNumber = @ShipB OUTPUT;
    PRINT '   !! Unexpected: shipment accepted';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    PRINT CONCAT('   Rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

SET @ShipB = NULL;
EXEC Logistics.usp_ShipSalesOrder @OrderNumber = @OrdB, @ServiceCode = 'NTH-PAL24',
     @EmployeeId = @Gideon, @ShipmentNumber = @ShipB OUTPUT;
PRINT CONCAT('   ', @OrdB, ' -> ', @ShipB, ' partial shipment (3 x VS-LED-640 back-ordered)');

PRINT '';
PRINT '=====================================================================';
PRINT ' A13. CARRIER TRACKING';
PRINT '=====================================================================';
-- Shipment C: full journey to delivery (drives order C to DELIVERED)
SELECT @Trk = TrackingNumber, @Dispatched = DispatchedAt FROM Logistics.Shipment WHERE ShipmentNumber = @ShipC;
SET @EventAt = DATEADD(hour, 1, @Dispatched);
EXEC Logistics.usp_RecordTrackingEvent @TrackingNumber = @Trk, @EventCode = 'PICKED_UP', @EventAt = @EventAt, @LocationText = N'Rotterdam';
SET @EventAt = DATEADD(hour, 3, @Dispatched);
EXEC Logistics.usp_RecordTrackingEvent @TrackingNumber = @Trk, @EventCode = 'DEPARTED', @EventAt = @EventAt, @LocationText = N'Rotterdam Waalhaven depot';
SET @EventAt = DATEADD(hour, 20, @Dispatched);
EXEC Logistics.usp_RecordTrackingEvent @TrackingNumber = @Trk, @EventCode = 'ARRIVED_HUB', @EventAt = @EventAt, @LocationText = N'Nieuwegein cross-dock';
SET @EventAt = DATEADD(hour, 50, @Dispatched);
EXEC Logistics.usp_RecordTrackingEvent @TrackingNumber = @Trk, @EventCode = 'OUT_FOR_DELIVERY', @EventAt = @EventAt, @LocationText = N'Utrecht';
SET @EventAt = DATEADD(hour, 54, @Dispatched);
EXEC Logistics.usp_RecordTrackingEvent @TrackingNumber = @Trk, @EventCode = 'DELIVERED', @EventAt = @EventAt,
     @LocationText = N'Depotstraat 12, Utrecht', @Notes = N'Tail-lift delivery, signed J. de Vries';
PRINT CONCAT('   ', @ShipC, ' delivered on time -> ', @OrdC, ' is now DELIVERED');

-- Shipment A: in transit
SELECT @Trk = TrackingNumber, @Dispatched = DispatchedAt FROM Logistics.Shipment WHERE ShipmentNumber = @ShipA;
SET @EventAt = DATEADD(minute, 30, @Dispatched);
EXEC Logistics.usp_RecordTrackingEvent @TrackingNumber = @Trk, @EventCode = 'PICKED_UP', @EventAt = @EventAt, @LocationText = N'Leeds';
SET @EventAt = DATEADD(hour, 2, @Dispatched);
EXEC Logistics.usp_RecordTrackingEvent @TrackingNumber = @Trk, @EventCode = 'DEPARTED', @EventAt = @EventAt, @LocationText = N'Leeds Stourton depot';
SET @EventAt = DATEADD(hour, 14, @Dispatched);
EXEC Logistics.usp_RecordTrackingEvent @TrackingNumber = @Trk, @EventCode = 'ARRIVED_HUB', @EventAt = @EventAt, @LocationText = N'Wakefield trunk hub';
PRINT CONCAT('   ', @ShipA, ' in transit');

-- Shipment B: just collected
SELECT @Trk = TrackingNumber FROM Logistics.Shipment WHERE ShipmentNumber = @ShipB;
EXEC Logistics.usp_RecordTrackingEvent @TrackingNumber = @Trk, @EventCode = 'PICKED_UP', @LocationText = N'Leeds';
PRINT CONCAT('   ', @ShipB, ' collected');

PRINT '';
PRINT '=====================================================================';
PRINT ' A14. BACK-ORDER RECOVERY: Lumenreach delivery arrives, order B re-allocated';
PRINT '=====================================================================';
EXEC Inventory.usp_ReceivePurchaseOrderLine @PoNumber = 'PO-30102', @LineNumber = 1, @QtyReceived = 20,
     @BinCode = 'LDS1-DCK-IN-B02', @EmployeeId = @Ruby;
EXEC Inventory.usp_TransferStock @Sku = 'VS-LED-640', @FromBinCode = 'LDS1-DCK-IN-B02',
     @ToBinCode = 'LDS1-AMB-A02-B02', @Quantity = 20, @EmployeeId = @Ruby;
EXEC Logistics.usp_AllocateSalesOrder @OrderNumber = @OrdB;
PRINT CONCAT('   ', @OrdB, ' back-order of 3 now allocated and on the pick list');

PRINT '';
PRINT '=====================================================================';
PRINT ' A15. REORGANISATION: new Head of Transport, planner team moves under her';
PRINT '=====================================================================';
EXEC Org.usp_AddEmployee @ManagerEmployeeId = @Gideon, @FirstName = N'Ola', @LastName = N'Nwachukwu',
     @JobTitle = N'Transport Coordinator', @DepartmentCode = 'TRANS',
     @Email = 'ola.nwachukwu@verdantstack.example', @HomeSiteCode = 'LDS1', @NewEmployeeId = @NewCoord OUTPUT;
EXEC Org.usp_AddEmployee @ManagerEmployeeId = @Isolde, @FirstName = N'Marguerite', @LastName = N'Osei',
     @JobTitle = N'Head of Transport', @DepartmentCode = 'TRANS',
     @Email = 'marguerite.osei@verdantstack.example', @HomeSiteCode = 'LDS1', @NewEmployeeId = @NewMgr OUTPUT;
EXEC Org.usp_MoveEmployeeSubtree @EmployeeId = @Gideon, @NewManagerId = @NewMgr;
PRINT '   Gideon Ashworth AND his report moved in one statement (GetReparentedValue).';

BEGIN TRY
    EXEC Org.usp_MoveEmployeeSubtree @EmployeeId = @NewMgr, @NewManagerId = @NewCoord;
    PRINT '   !! Unexpected: circular move accepted';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    PRINT CONCAT('   Circular move rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

PRINT '';
PRINT '=====================================================================';
PRINT ' A16. SITE EXPANSION: new mezzanine aisle with bins at Leeds';
PRINT '=====================================================================';
EXEC Inventory.usp_AddLocation @ParentCode = 'LDS1-AMB', @LocationCode = 'LDS1-AMB-A04',
     @LocationName = N'Leeds Ambient Aisle A04 (mezzanine)', @LocationType = 'AISLE', @NewLocationId = @NewLoc OUTPUT;
EXEC Inventory.usp_AddLocation @ParentCode = 'LDS1-AMB-A04', @LocationCode = 'LDS1-AMB-A04-B01',
     @LocationName = N'Leeds Ambient Aisle A04 / Bin 01', @LocationType = 'BIN',
     @MaxVolumeM3 = 2.5, @MaxWeightKg = 600, @NewLocationId = @NewLoc OUTPUT;
EXEC Inventory.usp_AddLocation @ParentCode = 'LDS1-AMB-A04', @LocationCode = 'LDS1-AMB-A04-B02',
     @LocationName = N'Leeds Ambient Aisle A04 / Bin 02', @LocationType = 'BIN',
     @MaxVolumeM3 = 2.5, @MaxWeightKg = 600, @NewLocationId = @NewLoc OUTPUT;
PRINT '   Aisle A04 and 2 bins added via GetDescendant.';

BEGIN TRY
    EXEC Inventory.usp_AddLocation @ParentCode = 'LDS1-AMB', @LocationCode = 'LDS1-AMB-XBIN',
         @LocationName = N'Bin placed directly in a zone', @LocationType = 'BIN',
         @MaxVolumeM3 = 1, @MaxWeightKg = 100, @NewLocationId = @NewLoc OUTPUT;
    PRINT '   !! Unexpected: invalid level accepted';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    PRINT CONCAT('   Rejected as expected -> ', ERROR_MESSAGE());
END CATCH;

PRINT '';
PRINT 'PART A complete - see PART B result grids.';
GO

/* ===================================================================================
   PART B - SHOWCASE QUERIES
   =================================================================================== */
PRINT 'B1  Organisation chart (hierarchyid, depth-first)';
SELECT IndentedName, JobTitle, DepartmentName, ManagerName, DirectReports, TotalReports, HomeSite, OrgPath
  FROM Org.vw_OrgChart
 ORDER BY OrgNode;

PRINT 'B2  Warehouse network down to aisle level, with inherited zone attributes';
SELECT IndentedName, LocationCode, LocationType, EffectiveTemperature, ZonePurpose, ChildCount, FullPath
  FROM Inventory.vw_LocationTree
 WHERE LocationType <> 'BIN'
 ORDER BY LocationNode;

PRINT 'B3  Stock value and capacity rolled up to every level (network -> zone)';
SELECT IndentedName, LocationType, DistinctSkus, OccupiedBins, StockValue, OccupiedM3, CapacityM3, UtilisationPct
  FROM Inventory.vw_StockRollupByLocation
 WHERE LocationType IN ('NETWORK','REGION','SITE','ZONE')
 ORDER BY LocationNode;

PRINT 'B4  Drill into one branch of the tree (procedure)';
EXEC Inventory.usp_GetLocationSubtree @LocationCode = 'LDS1', @IncludeBins = 0;

PRINT 'B5  Product taxonomy with inherited hazard class';
SELECT IndentedName, CategoryCode, EffectiveHazardClass, ProductsInSubtree, FullPath
  FROM Inventory.vw_CategoryTree
 ORDER BY CategoryNode;

PRINT 'B6  Reorder alerts with suggested purchase quantities';
SELECT Sku, ProductName, Urgency, QtyAvailable, QtyInbound, QtyBackordered, ProjectedPosition,
       ReorderPoint, PreferredSupplier, LeadTimeDays, SuggestedOrderQty, SuggestedOrderValue
  FROM Inventory.vw_ReorderAlerts
 ORDER BY CASE Urgency WHEN 'STOCKOUT' THEN 1 WHEN 'CRITICAL' THEN 2 ELSE 3 END, Sku;

PRINT 'B7  Expiring and expired lots (value at risk)';
SELECT SiteCode, BinCode, Sku, LotNumber, ExpiresOn, DaysToExpiry, ExpiryBucket, QtyOnHand, QtyAllocated, ValueAtRisk
  FROM Inventory.vw_ExpiringLots
 ORDER BY DaysToExpiry;

PRINT 'B8  Kit buildability per site and limiting component';
SELECT SiteCode, KitSku, KitName, BuildableQty, LimitingComponent, LimitingComponentAvailable
  FROM Inventory.vw_KitBuildability
 ORDER BY KitSku, SiteCode;

PRINT 'B9  Multi-level BOM explosion for 10 tower kits at Leeds (procedure, 2 result sets)';
EXEC Inventory.usp_GetKitRequirements @KitSku = 'VS-KIT-TWR', @KitQty = 10, @SiteCode = 'LDS1';

PRINT 'B10 ABC classification and days of cover (90 days)';
SELECT Sku, ProductName, Units90d, Revenue90d, CumulativeSharePct, AbcClass, AvgDailyUnits, QtyAvailable, DaysOfCover
  FROM Inventory.vw_AbcVelocity
 ORDER BY Revenue90d DESC, Sku;

PRINT 'B11 Order fulfilment status';
SELECT OrderNumber, CustomerCode, FulfilSite, Status, Priority, LineCount, UnitsOrdered, UnitsAllocated,
       UnitsShipped, OrderValue, LineFillRatePct, UnitsShippedPct, DaysOverdue
  FROM Logistics.vw_OrderFulfilment
 ORDER BY OrderedAt DESC;

PRINT 'B12 Open pick list in warehouse walk order';
SELECT OrderNumber, PickSequence, ZoneCode, BinCode, Sku, LotNumber, ExpiresOn, Quantity
  FROM Logistics.vw_OpenPickList
 ORDER BY OrderNumber, PickSequence;

PRINT 'B13 Packaging tree: pallet > cartons with contents';
SELECT ShipmentNumber, TrackingNumber, IndentedPackage, GrossWeightKg, Contents
  FROM Logistics.vw_ShipmentPackageTree
 ORDER BY ShipmentNumber, PackagePath;

PRINT 'B14 Tracking timeline of the live shipments';
SELECT sh.ShipmentNumber, sh.Status, te.EventAt, te.EventCode, te.LocationText, te.Notes
  FROM Logistics.TrackingEvent te
  JOIN Logistics.Shipment sh ON sh.ShipmentId = te.ShipmentId
 WHERE sh.ShipmentNumber LIKE 'SH-7%'
 ORDER BY sh.ShipmentNumber, te.EventAt;

PRINT 'B15 Customer account tree with group credit headroom';
SELECT IndentedName, CustomerCode, CustomerType, GroupAccount, EffectiveDiscountPct,
       OwnOrderValue, SubtreeOrderValue, GroupCreditLimit, GroupOpenExposure, GroupCreditHeadroom
  FROM Logistics.vw_CustomerHierarchy
 ORDER BY AccountPath;

PRINT 'B16 Carrier performance (all time) and ranked scorecard (last 120 days)';
SELECT CarrierCode, ServiceCode, TransportMode, TransitDaysTarget, Shipments, Delivered, OnTime, OnTimePct,
       AvgTransitDays, ShipmentsWithException, FreightSpend, CostPerKg
  FROM Logistics.vw_CarrierPerformance
 ORDER BY OnTimePct DESC, CarrierCode;

DECLARE @From date = DATEADD(day, -120, CAST(SYSDATETIME() AS date)),
        @To   date = CAST(SYSDATETIME() AS date);
EXEC Logistics.usp_CarrierScorecard @FromDate = @From, @ToDate = @To;

PRINT 'B17 Ledger reconciliation: balances rebuilt from the ledger must equal StockBalance';
WITH LedgerNet AS
(
    SELECT ProductId, LotId, LocationId, SUM(Qty) AS LedgerQty
    FROM (
        SELECT ProductId, LotId, ToLocationId   AS LocationId,  Quantity AS Qty
          FROM Inventory.StockTransaction WHERE ToLocationId IS NOT NULL
        UNION ALL
        SELECT ProductId, LotId, FromLocationId AS LocationId, -Quantity AS Qty
          FROM Inventory.StockTransaction WHERE FromLocationId IS NOT NULL
    ) m
    GROUP BY ProductId, LotId, LocationId
)
SELECT
    COUNT(*)                                                                AS BalanceRows,
    SUM(CASE WHEN COALESCE(l.LedgerQty, 0) = sb.QtyOnHand THEN 1 ELSE 0 END) AS Matching,
    SUM(CASE WHEN COALESCE(l.LedgerQty, 0) <> sb.QtyOnHand THEN 1 ELSE 0 END) AS Mismatches
FROM Inventory.StockBalance sb
LEFT JOIN LedgerNet l
       ON l.ProductId  = sb.ProductId
      AND l.LocationId = sb.LocationId
      AND (l.LotId = sb.LotId OR (l.LotId IS NULL AND sb.LotId IS NULL));

PRINT 'B18 Latest stock ledger entries';
SELECT TOP (15) st.TxnId, st.TxnAt, st.TxnType, p.Sku, lt.LotNumber,
       f.LocationCode AS FromBin, t.LocationCode AS ToBin, st.Quantity, st.ReferenceType, st.Notes
  FROM Inventory.StockTransaction st
  JOIN Inventory.Product p        ON p.ProductId  = st.ProductId
  LEFT JOIN Inventory.Lot lt      ON lt.LotId     = st.LotId
  LEFT JOIN Inventory.Location f  ON f.LocationId = st.FromLocationId
  LEFT JOIN Inventory.Location t  ON t.LocationId = st.ToLocationId
 ORDER BY st.TxnId DESC;

PRINT 'B19 Audit trail (trigger-captured)';
SELECT AuditId, ChangedAt, TableName, RecordKey, ColumnName, OldValue, NewValue, ChangedBy
  FROM Core.AuditLog
 ORDER BY AuditId;
GO

PRINT 'Step 5 complete. VerdantStackDB is fully built and demonstrated.';
GO
