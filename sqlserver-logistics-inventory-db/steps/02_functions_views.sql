/*
=====================================================================================
  VerdantStackDB  -  STEP 2 of 5 : Functions and Views
-------------------------------------------------------------------------------------
  Run after Step1_Structure.sql

  FUNCTIONS
    Inventory.ufn_LocationContext   inline TVF  - site, zone, inherited temperature, full path of any location
    Inventory.ufn_ExplodeKit        inline TVF  - multi-level bill-of-materials explosion (recursive CTE)

  VIEWS
    Org.vw_OrgChart                       hierarchyid org chart with manager, direct & total reports
    Inventory.vw_LocationTree             indented warehouse tree with inherited attributes
    Inventory.vw_CategoryTree             product taxonomy with full path & inherited hazard class
    Inventory.vw_StockPosition            bin-level stock with lot, expiry, value, volume
    Inventory.vw_StockRollupByLocation    stock & capacity rolled up to every level of the tree
    Inventory.vw_ReorderAlerts            available + inbound - backorders vs reorder point, suggested PO qty
    Inventory.vw_ExpiringLots             lots expiring within 90 days, value at risk
    Inventory.vw_KitBuildability          how many kits each site can build, and the limiting component
    Inventory.vw_AbcVelocity              90-day ABC classification and days of cover
    Logistics.vw_OpenPickList             unshipped allocations in warehouse walk order
    Logistics.vw_OrderFulfilment          order-level fill rate and overdue days
    Logistics.vw_ShipmentPackageTree      pallet > carton tree with contents (recursive CTE)
    Logistics.vw_CarrierPerformance       on-time %, transit time, cost per kg, exceptions
    Logistics.vw_CustomerHierarchy        account tree with subtree sales and group credit headroom
=====================================================================================
*/
USE VerdantStackDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ===================================================================================
   FUNCTIONS
   =================================================================================== */

-- Resolves the site, zone and inherited attributes of any location in the tree.
-- Inline TVF so the optimiser expands it like a view (no scalar-UDF row-by-row cost).
CREATE OR ALTER FUNCTION Inventory.ufn_LocationContext (@LocationId int)
RETURNS TABLE
AS
RETURN
SELECT
    l.LocationId,
    site.LocationId        AS SiteId,
    site.LocationCode      AS SiteCode,
    zone.LocationId        AS ZoneId,
    zone.LocationCode      AS ZoneCode,
    zone.TemperatureClass  AS TemperatureClass,
    zone.ZonePurpose       AS ZonePurpose,
    (SELECT STRING_AGG(a.LocationCode, ' > ') WITHIN GROUP (ORDER BY a.LocationLevel)
       FROM Inventory.Location a
      WHERE l.LocationNode.IsDescendantOf(a.LocationNode) = 1) AS FullPath
FROM Inventory.Location l
OUTER APPLY (SELECT TOP (1) s.LocationId, s.LocationCode
               FROM Inventory.Location s
              WHERE s.LocationType = 'SITE'
                AND l.LocationNode.IsDescendantOf(s.LocationNode) = 1) site
OUTER APPLY (SELECT TOP (1) z.LocationId, z.LocationCode, z.TemperatureClass, z.ZonePurpose
               FROM Inventory.Location z
              WHERE z.LocationType = 'ZONE'
                AND l.LocationNode.IsDescendantOf(z.LocationNode) = 1) zone
WHERE l.LocationId = @LocationId;
GO

-- Multi-level BOM explosion. A kit can contain kits; quantities multiply down the tree.
-- BomPath uses zero-padded ids so ORDER BY BomPath gives a correct depth-first listing.
CREATE OR ALTER FUNCTION Inventory.ufn_ExplodeKit (@KitProductId int, @Quantity decimal(12,3))
RETURNS TABLE
AS
RETURN
WITH Bom AS
(
    SELECT  kc.ComponentProductId,
            CAST(kc.QtyPer * @Quantity AS decimal(18,3))                                   AS ExtendedQty,
            1                                                                              AS BomLevel,
            CAST(CONCAT('/', RIGHT(CONCAT('000000', kc.ComponentProductId), 6)) AS varchar(400)) AS BomPath
    FROM Inventory.KitComponent kc
    WHERE kc.KitProductId = @KitProductId

    UNION ALL

    SELECT  kc.ComponentProductId,
            CAST(b.ExtendedQty * kc.QtyPer AS decimal(18,3)),
            b.BomLevel + 1,
            CAST(CONCAT(b.BomPath, '/', RIGHT(CONCAT('000000', kc.ComponentProductId), 6)) AS varchar(400))
    FROM Bom b
    JOIN Inventory.KitComponent kc ON kc.KitProductId = b.ComponentProductId
)
SELECT  b.BomLevel,
        b.BomPath,
        p.ProductId,
        p.Sku,
        p.ProductName,
        p.IsKit,
        b.ExtendedQty
FROM Bom b
JOIN Inventory.Product p ON p.ProductId = b.ComponentProductId;
GO

/* ===================================================================================
   ORG VIEWS
   =================================================================================== */
CREATE OR ALTER VIEW Org.vw_OrgChart
AS
SELECT
    e.EmployeeId,
    REPLICATE(N'    ', e.OrgLevel) + e.FirstName + N' ' + e.LastName   AS IndentedName,
    e.JobTitle,
    d.DepartmentName,
    e.OrgLevel,
    e.OrgNode.ToString()                                               AS OrgPath,
    m.EmployeeId                                                       AS ManagerId,
    m.FirstName + N' ' + m.LastName                                    AS ManagerName,
    hs.LocationCode                                                    AS HomeSite,
    (SELECT COUNT(*) FROM Org.Employee r
      WHERE r.OrgNode.GetAncestor(1) = e.OrgNode)                      AS DirectReports,
    (SELECT COUNT(*) FROM Org.Employee r
      WHERE r.OrgNode.IsDescendantOf(e.OrgNode) = 1
        AND r.EmployeeId <> e.EmployeeId)                              AS TotalReports,
    e.IsActive,
    e.OrgNode                                                          -- sort key (depth-first)
FROM Org.Employee e
JOIN Org.Department d        ON d.DepartmentId = e.DepartmentId
LEFT JOIN Org.Employee m     ON m.OrgNode = e.OrgNode.GetAncestor(1)
LEFT JOIN Inventory.Location hs ON hs.LocationId = e.HomeSiteId;
GO

/* ===================================================================================
   INVENTORY VIEWS
   =================================================================================== */
CREATE OR ALTER VIEW Inventory.vw_LocationTree
AS
SELECT
    l.LocationId,
    l.LocationCode,
    REPLICATE(N'    ', l.LocationLevel) + l.LocationName  AS IndentedName,
    l.LocationType,
    l.LocationLevel,
    l.LocationNode.ToString()                             AS NodePath,
    p.LocationCode                                        AS ParentCode,
    ctx.SiteCode,
    ctx.ZoneCode,
    ctx.TemperatureClass                                  AS EffectiveTemperature,
    ctx.ZonePurpose,
    ctx.FullPath,
    (SELECT COUNT(*) FROM Inventory.Location c
      WHERE c.LocationNode.GetAncestor(1) = l.LocationNode) AS ChildCount,
    l.MaxVolumeM3,
    l.MaxWeightKg,
    l.IsActive,
    l.LocationNode
FROM Inventory.Location l
LEFT JOIN Inventory.Location p ON p.LocationNode = l.LocationNode.GetAncestor(1)
CROSS APPLY Inventory.ufn_LocationContext(l.LocationId) ctx;
GO

CREATE OR ALTER VIEW Inventory.vw_CategoryTree
AS
SELECT
    c.CategoryId,
    c.CategoryCode,
    REPLICATE(N'    ', c.CategoryLevel) + c.CategoryName  AS IndentedName,
    c.CategoryLevel,
    c.CategoryNode.ToString()                             AS NodePath,
    (SELECT STRING_AGG(CAST(a.CategoryName AS nvarchar(max)), N' > ')
                WITHIN GROUP (ORDER BY a.CategoryLevel)
       FROM Inventory.Category a
      WHERE c.CategoryNode.IsDescendantOf(a.CategoryNode) = 1)  AS FullPath,
    (SELECT TOP (1) a.HazardClass
       FROM Inventory.Category a
      WHERE c.CategoryNode.IsDescendantOf(a.CategoryNode) = 1
        AND a.HazardClass IS NOT NULL
      ORDER BY a.CategoryLevel DESC)                            AS EffectiveHazardClass,
    (SELECT COUNT(*)
       FROM Inventory.Product p
       JOIN Inventory.Category d ON d.CategoryId = p.CategoryId
      WHERE d.CategoryNode.IsDescendantOf(c.CategoryNode) = 1)  AS ProductsInSubtree,
    c.CategoryNode
FROM Inventory.Category c;
GO

CREATE OR ALTER VIEW Inventory.vw_StockPosition
AS
SELECT
    sb.StockBalanceId,
    ctx.SiteCode,
    ctx.ZoneCode,
    ctx.TemperatureClass                                          AS ZoneTemperature,
    b.LocationCode                                                AS BinCode,
    p.Sku,
    p.ProductName,
    p.BaseUom,
    lt.LotNumber,
    lt.ExpiresOn,
    DATEDIFF(day, CAST(SYSDATETIME() AS date), lt.ExpiresOn)      AS DaysToExpiry,
    sb.QtyOnHand,
    sb.QtyAllocated,
    sb.QtyAvailable,
    CAST(sb.QtyOnHand * p.StandardCost AS decimal(14,2))          AS StockValue,
    CAST(sb.QtyOnHand * p.UnitVolumeM3 AS decimal(12,4))          AS OccupiedM3,
    CAST(sb.QtyOnHand * p.UnitWeightKg AS decimal(12,3))          AS LoadKg,
    sb.LastMovementAt,
    b.LocationNode                                                AS BinNode
FROM Inventory.StockBalance sb
JOIN Inventory.Product  p ON p.ProductId  = sb.ProductId
JOIN Inventory.Location b ON b.LocationId = sb.LocationId
CROSS APPLY Inventory.ufn_LocationContext(b.LocationId) ctx
LEFT JOIN Inventory.Lot lt ON lt.LotId = sb.LotId
WHERE sb.QtyOnHand > 0;
GO

-- Every node of the tree (network, region, site, zone, aisle, bin) with stock summed
-- from all bins beneath it, plus capacity utilisation.
CREATE OR ALTER VIEW Inventory.vw_StockRollupByLocation
AS
WITH StockAgg AS
(
    SELECT  anc.LocationId,
            COUNT(DISTINCT sb.ProductId)               AS DistinctSkus,
            COUNT(DISTINCT sb.LocationId)              AS OccupiedBins,
            SUM(sb.QtyOnHand)                          AS BaseUnitsOnHand,
            SUM(sb.QtyAllocated)                       AS BaseUnitsAllocated,
            SUM(sb.QtyOnHand * p.StandardCost)         AS StockValue,
            SUM(sb.QtyOnHand * p.UnitVolumeM3)         AS OccupiedM3
    FROM Inventory.Location anc
    JOIN Inventory.Location bin
         ON bin.LocationType = 'BIN'
        AND bin.LocationNode.IsDescendantOf(anc.LocationNode) = 1
    JOIN Inventory.StockBalance sb ON sb.LocationId = bin.LocationId AND sb.QtyOnHand > 0
    JOIN Inventory.Product p       ON p.ProductId   = sb.ProductId
    GROUP BY anc.LocationId
)
SELECT
    l.LocationId,
    l.LocationCode,
    l.LocationType,
    l.LocationLevel,
    REPLICATE(N'    ', l.LocationLevel) + l.LocationName                     AS IndentedName,
    COALESCE(s.DistinctSkus, 0)                                              AS DistinctSkus,
    COALESCE(s.OccupiedBins, 0)                                              AS OccupiedBins,
    COALESCE(s.BaseUnitsOnHand, 0)                                           AS BaseUnitsOnHand,
    COALESCE(s.BaseUnitsAllocated, 0)                                        AS BaseUnitsAllocated,
    CAST(COALESCE(s.StockValue, 0) AS decimal(14,2))                         AS StockValue,
    CAST(COALESCE(s.OccupiedM3, 0) AS decimal(12,3))                         AS OccupiedM3,
    cap.CapacityM3,
    CAST(100.0 * COALESCE(s.OccupiedM3, 0) / NULLIF(cap.CapacityM3, 0) AS decimal(6,1)) AS UtilisationPct,
    l.LocationNode
FROM Inventory.Location l
LEFT JOIN StockAgg s ON s.LocationId = l.LocationId
OUTER APPLY (SELECT SUM(x.MaxVolumeM3) AS CapacityM3
               FROM Inventory.Location x
              WHERE x.LocationType = 'BIN'
                AND x.LocationNode.IsDescendantOf(l.LocationNode) = 1) cap;
GO

-- Projected position = available + inbound PO qty - unallocated backorders.
-- Suggested qty is rounded up to the preferred supplier's minimum order multiple.
CREATE OR ALTER VIEW Inventory.vw_ReorderAlerts
AS
WITH OnHand AS
(
    SELECT ProductId, SUM(QtyOnHand) AS QtyOnHand, SUM(QtyAvailable) AS QtyAvailable
    FROM Inventory.StockBalance
    GROUP BY ProductId
),
Inbound AS
(
    SELECT pol.ProductId,
           SUM(pol.QtyOrdered - pol.QtyReceived) AS QtyInbound,
           MIN(po.ExpectedDate)                  AS NextExpected
    FROM Inventory.PurchaseOrderLine pol
    JOIN Inventory.PurchaseOrder po ON po.PurchaseOrderId = pol.PurchaseOrderId
    WHERE po.Status IN ('SENT','PARTIAL') AND pol.QtyReceived < pol.QtyOrdered
    GROUP BY pol.ProductId
),
Backorder AS
(
    SELECT sol.ProductId,
           SUM(sol.QtyOrdered - sol.QtyAllocated - sol.QtyShipped) AS QtyBackordered
    FROM Logistics.SalesOrderLine sol
    JOIN Logistics.SalesOrder so ON so.SalesOrderId = sol.SalesOrderId
    WHERE so.Status IN ('NEW','PARTIAL')
    GROUP BY sol.ProductId
)
SELECT
    p.ProductId,
    p.Sku,
    p.ProductName,
    p.ReorderPoint,
    p.ReorderQty,
    COALESCE(oh.QtyOnHand, 0)        AS QtyOnHand,
    COALESCE(oh.QtyAvailable, 0)     AS QtyAvailable,
    COALESCE(bo.QtyBackordered, 0)   AS QtyBackordered,
    COALESCE(ib.QtyInbound, 0)       AS QtyInbound,
    ib.NextExpected,
    pos.ProjectedPosition,
    CASE WHEN COALESCE(oh.QtyAvailable, 0) = 0         THEN 'STOCKOUT'
         WHEN pos.ProjectedPosition < p.ReorderPoint / 2.0 THEN 'CRITICAL'
         ELSE 'LOW' END              AS Urgency,
    s.SupplierCode                   AS PreferredSupplier,
    s.LeadTimeDays,
    ps.MinOrderQty,
    sug.SuggestedOrderQty,
    CAST(sug.SuggestedOrderQty * ps.UnitCost AS decimal(14,2)) AS SuggestedOrderValue
FROM Inventory.Product p
LEFT JOIN OnHand    oh ON oh.ProductId = p.ProductId
LEFT JOIN Inbound   ib ON ib.ProductId = p.ProductId
LEFT JOIN Backorder bo ON bo.ProductId = p.ProductId
LEFT JOIN Inventory.ProductSupplier ps ON ps.ProductId = p.ProductId AND ps.IsPreferred = 1
LEFT JOIN Inventory.Supplier s         ON s.SupplierId = ps.SupplierId
CROSS APPLY (SELECT COALESCE(oh.QtyAvailable, 0) + COALESCE(ib.QtyInbound, 0)
                    - COALESCE(bo.QtyBackordered, 0) AS ProjectedPosition) pos
CROSS APPLY (SELECT CASE WHEN p.ReorderPoint - pos.ProjectedPosition > p.ReorderQty
                         THEN p.ReorderPoint - pos.ProjectedPosition
                         ELSE p.ReorderQty END AS RawQty) r
CROSS APPLY (SELECT CAST(CEILING(r.RawQty / COALESCE(ps.MinOrderQty, 1)) * COALESCE(ps.MinOrderQty, 1)
                         AS decimal(12,0)) AS SuggestedOrderQty) sug
WHERE p.IsKit = 0
  AND p.IsActive = 1
  AND pos.ProjectedPosition < p.ReorderPoint;
GO

CREATE OR ALTER VIEW Inventory.vw_ExpiringLots
AS
SELECT
    ctx.SiteCode,
    b.LocationCode                                             AS BinCode,
    p.Sku,
    p.ProductName,
    lt.LotNumber,
    lt.ExpiresOn,
    DATEDIFF(day, CAST(SYSDATETIME() AS date), lt.ExpiresOn)   AS DaysToExpiry,
    CASE WHEN lt.ExpiresOn <= CAST(SYSDATETIME() AS date)                     THEN 'EXPIRED'
         WHEN lt.ExpiresOn <= DATEADD(day, 30, CAST(SYSDATETIME() AS date))   THEN 'WITHIN 30 DAYS'
         ELSE 'WITHIN 90 DAYS' END                             AS ExpiryBucket,
    sb.QtyOnHand,
    sb.QtyAllocated,
    sb.QtyAvailable,
    CAST(sb.QtyAvailable * p.StandardCost AS decimal(14,2))    AS ValueAtRisk
FROM Inventory.StockBalance sb
JOIN Inventory.Lot      lt ON lt.LotId      = sb.LotId
JOIN Inventory.Product  p  ON p.ProductId   = sb.ProductId
JOIN Inventory.Location b  ON b.LocationId  = sb.LocationId
CROSS APPLY Inventory.ufn_LocationContext(b.LocationId) ctx
WHERE sb.QtyOnHand > 0
  AND lt.ExpiresOn <= DATEADD(day, 90, CAST(SYSDATETIME() AS date));
GO

-- Kits buildable per site from DIRECT components (a nested kit counts as a stocked unit).
CREATE OR ALTER VIEW Inventory.vw_KitBuildability
AS
WITH ComponentCover AS
(
    SELECT  site.LocationId                          AS SiteId,
            site.LocationCode                        AS SiteCode,
            k.ProductId                              AS KitId,
            k.Sku                                    AS KitSku,
            k.ProductName                            AS KitName,
            comp.Sku                                 AS ComponentSku,
            kc.QtyPer,
            COALESCE(av.QtyAvailable, 0)             AS ComponentAvailable,
            FLOOR(COALESCE(av.QtyAvailable, 0) / kc.QtyPer) AS BuildableFromComponent
    FROM Inventory.Product k
    JOIN Inventory.KitComponent kc ON kc.KitProductId = k.ProductId
    JOIN Inventory.Product comp    ON comp.ProductId  = kc.ComponentProductId
    CROSS JOIN Inventory.Location site
    OUTER APPLY (SELECT SUM(sb.QtyAvailable) AS QtyAvailable
                   FROM Inventory.StockBalance sb
                   JOIN Inventory.Location b ON b.LocationId = sb.LocationId
                  WHERE sb.ProductId = kc.ComponentProductId
                    AND b.LocationNode.IsDescendantOf(site.LocationNode) = 1) av
    WHERE k.IsKit = 1
      AND site.LocationType = 'SITE'
),
Ranked AS
(
    SELECT  SiteId, SiteCode, KitId, KitSku, KitName, ComponentSku, ComponentAvailable, BuildableFromComponent,
            ROW_NUMBER() OVER (PARTITION BY SiteId, KitId
                               ORDER BY BuildableFromComponent, ComponentSku) AS rn
    FROM ComponentCover
)
SELECT  SiteCode,
        KitSku,
        KitName,
        CAST(BuildableFromComponent AS int) AS BuildableQty,
        ComponentSku                        AS LimitingComponent,
        ComponentAvailable                  AS LimitingComponentAvailable
FROM Ranked
WHERE rn = 1;
GO

-- ABC analysis on last-90-day revenue (A = first 80 %, B = next 15 %, C = rest).
CREATE OR ALTER VIEW Inventory.vw_AbcVelocity
AS
WITH Demand AS
(
    SELECT  sol.ProductId,
            SUM(sol.QtyShipped)                                              AS Units90d,
            SUM(sol.QtyShipped * sol.UnitPrice * (1 - sol.DiscountPct / 100)) AS Revenue90d
    FROM Logistics.SalesOrderLine sol
    WHERE sol.QtyShipped > 0
      AND EXISTS (SELECT 1 FROM Logistics.Shipment sh
                   WHERE sh.SalesOrderId = sol.SalesOrderId
                     AND sh.DispatchedAt >= DATEADD(day, -90, SYSDATETIME()))
    GROUP BY sol.ProductId
),
Stock AS
(
    SELECT ProductId, SUM(QtyAvailable) AS QtyAvailable
    FROM Inventory.StockBalance
    GROUP BY ProductId
),
Ranked AS
(
    SELECT  p.ProductId,
            p.Sku,
            p.ProductName,
            COALESCE(d.Units90d, 0)   AS Units90d,
            COALESCE(d.Revenue90d, 0) AS Revenue90d,
            COALESCE(s.QtyAvailable, 0) AS QtyAvailable,
            SUM(COALESCE(d.Revenue90d, 0)) OVER (ORDER BY COALESCE(d.Revenue90d, 0) DESC, p.ProductId
                                                 ROWS UNBOUNDED PRECEDING) AS CumRevenue,
            SUM(COALESCE(d.Revenue90d, 0)) OVER ()                         AS TotalRevenue
    FROM Inventory.Product p
    LEFT JOIN Demand d ON d.ProductId = p.ProductId
    LEFT JOIN Stock  s ON s.ProductId = p.ProductId
    WHERE p.IsActive = 1
)
SELECT
    ProductId,
    Sku,
    ProductName,
    Units90d,
    CAST(Revenue90d AS decimal(14,2))                                       AS Revenue90d,
    CAST(100.0 * CumRevenue / NULLIF(TotalRevenue, 0) AS decimal(5,1))      AS CumulativeSharePct,
    CASE WHEN Revenue90d = 0                                                     THEN 'D'
         WHEN 100.0 * (CumRevenue - Revenue90d) / NULLIF(TotalRevenue, 0) < 80  THEN 'A'
         WHEN 100.0 * (CumRevenue - Revenue90d) / NULLIF(TotalRevenue, 0) < 95  THEN 'B'
         ELSE 'C' END                                                       AS AbcClass,
    CAST(Units90d / 90.0 AS decimal(10,3))                                  AS AvgDailyUnits,
    QtyAvailable,
    CAST(QtyAvailable / NULLIF(Units90d / 90.0, 0) AS decimal(10,1))        AS DaysOfCover
FROM Ranked;
GO

/* ===================================================================================
   LOGISTICS VIEWS
   =================================================================================== */

-- hierarchyid depth-first order = physical walk order through the warehouse,
-- so ORDER BY LocationNode produces an efficient pick path for free.
CREATE OR ALTER VIEW Logistics.vw_OpenPickList
AS
SELECT
    so.OrderNumber,
    so.Priority,
    ROW_NUMBER() OVER (PARTITION BY so.SalesOrderId ORDER BY b.LocationNode) AS PickSequence,
    ctx.SiteCode,
    ctx.ZoneCode,
    b.LocationCode   AS BinCode,
    sol.LineNumber,
    p.Sku,
    p.ProductName,
    lt.LotNumber,
    lt.ExpiresOn,
    oa.Quantity,
    oa.AllocatedAt
FROM Logistics.OrderAllocation oa
JOIN Logistics.SalesOrderLine sol ON sol.SoLineId      = oa.SoLineId
JOIN Logistics.SalesOrder so      ON so.SalesOrderId   = sol.SalesOrderId
JOIN Inventory.StockBalance sb    ON sb.StockBalanceId = oa.StockBalanceId
JOIN Inventory.Location b         ON b.LocationId      = sb.LocationId
JOIN Inventory.Product p          ON p.ProductId       = sb.ProductId
LEFT JOIN Inventory.Lot lt        ON lt.LotId          = sb.LotId
CROSS APPLY Inventory.ufn_LocationContext(b.LocationId) ctx
WHERE oa.ShipmentId IS NULL;
GO

CREATE OR ALTER VIEW Logistics.vw_OrderFulfilment
AS
SELECT
    so.SalesOrderId,
    so.OrderNumber,
    c.CustomerCode,
    c.CustomerName,
    site.LocationCode                                       AS FulfilSite,
    so.OrderedAt,
    so.PromisedDate,
    so.Priority,
    so.Status,
    COUNT(*)                                                AS LineCount,
    SUM(sol.QtyOrdered)                                     AS UnitsOrdered,
    SUM(sol.QtyAllocated)                                   AS UnitsAllocated,
    SUM(sol.QtyShipped)                                     AS UnitsShipped,
    CAST(SUM(sol.LineTotal) AS decimal(14,2))               AS OrderValue,
    CAST(100.0 * SUM(CASE WHEN sol.QtyAllocated + sol.QtyShipped >= sol.QtyOrdered THEN 1 ELSE 0 END)
               / COUNT(*) AS decimal(5,1))                  AS LineFillRatePct,
    CAST(100.0 * SUM(sol.QtyShipped) / NULLIF(SUM(sol.QtyOrdered), 0) AS decimal(5,1)) AS UnitsShippedPct,
    CASE WHEN so.Status IN ('NEW','PARTIAL','ALLOCATED')
          AND so.PromisedDate < CAST(SYSDATETIME() AS date)
         THEN DATEDIFF(day, so.PromisedDate, CAST(SYSDATETIME() AS date))
         ELSE 0 END                                         AS DaysOverdue
FROM Logistics.SalesOrder so
JOIN Logistics.Customer c         ON c.CustomerId     = so.CustomerId
JOIN Inventory.Location site      ON site.LocationId  = so.FulfilSiteId
JOIN Logistics.SalesOrderLine sol ON sol.SalesOrderId = so.SalesOrderId
GROUP BY so.SalesOrderId, so.OrderNumber, c.CustomerCode, c.CustomerName, site.LocationCode,
         so.OrderedAt, so.PromisedDate, so.Priority, so.Status;
GO

-- Recursive walk of the pallet > carton tree with an aggregated content list per package.
CREATE OR ALTER VIEW Logistics.vw_ShipmentPackageTree
AS
WITH Tree AS
(
    SELECT  pk.PackageId, pk.ShipmentId, pk.ParentPackageId, pk.PackageType, pk.LabelCode, pk.GrossWeightKg,
            0 AS Depth,
            CAST(pk.LabelCode AS varchar(400)) AS PackagePath
    FROM Logistics.ShipmentPackage pk
    WHERE pk.ParentPackageId IS NULL

    UNION ALL

    SELECT  c.PackageId, c.ShipmentId, c.ParentPackageId, c.PackageType, c.LabelCode, c.GrossWeightKg,
            t.Depth + 1,
            CAST(t.PackagePath + ' / ' + c.LabelCode AS varchar(400))
    FROM Logistics.ShipmentPackage c
    JOIN Tree t ON c.ParentPackageId = t.PackageId
)
SELECT
    sh.ShipmentNumber,
    sh.TrackingNumber,
    t.Depth,
    REPLICATE('    ', t.Depth) + t.PackageType + ' ' + t.LabelCode   AS IndentedPackage,
    t.PackagePath,
    t.GrossWeightKg,
    (SELECT STRING_AGG(CONCAT(p.Sku, ' x', CAST(pc.Quantity AS decimal(12,0)),
                              CASE WHEN lt.LotNumber IS NOT NULL THEN CONCAT(' [lot ', lt.LotNumber, ']') END), ', ')
       FROM Logistics.PackageContent pc
       JOIN Inventory.Product p ON p.ProductId = pc.ProductId
       LEFT JOIN Inventory.Lot lt ON lt.LotId = pc.LotId
      WHERE pc.PackageId = t.PackageId)                              AS Contents,
    t.PackageId,
    t.ParentPackageId
FROM Tree t
JOIN Logistics.Shipment sh ON sh.ShipmentId = t.ShipmentId;
GO

CREATE OR ALTER VIEW Logistics.vw_CarrierPerformance
AS
SELECT
    c.CarrierCode,
    c.CarrierName,
    c.TransportMode,
    cs.ServiceCode,
    cs.ServiceName,
    cs.TransitDaysTarget,
    COUNT(*)                                                               AS Shipments,
    SUM(CASE WHEN sh.Status = 'DELIVERED' THEN 1 ELSE 0 END)               AS Delivered,
    SUM(CASE WHEN sh.Status = 'DELIVERED'
              AND CAST(sh.DeliveredAt AS date) <= sh.PromisedDelivery THEN 1 ELSE 0 END) AS OnTime,
    CAST(100.0 * SUM(CASE WHEN sh.Status = 'DELIVERED'
                           AND CAST(sh.DeliveredAt AS date) <= sh.PromisedDelivery THEN 1 ELSE 0 END)
               / NULLIF(SUM(CASE WHEN sh.Status = 'DELIVERED' THEN 1 ELSE 0 END), 0)
         AS decimal(5,1))                                                  AS OnTimePct,
    CAST(AVG(CASE WHEN sh.Status = 'DELIVERED'
                  THEN DATEDIFF(hour, sh.DispatchedAt, sh.DeliveredAt) / 24.0 END) AS decimal(6,2)) AS AvgTransitDays,
    SUM(COALESCE(ex.HadException, 0))                                      AS ShipmentsWithException,
    CAST(SUM(sh.FreightCost) AS decimal(12,2))                             AS FreightSpend,
    CAST(SUM(sh.FreightCost) / NULLIF(SUM(sh.GrossWeightKg), 0) AS decimal(10,4)) AS CostPerKg
FROM Logistics.Shipment sh
JOIN Logistics.CarrierService cs ON cs.ServiceId = sh.ServiceId
JOIN Logistics.Carrier c         ON c.CarrierId  = cs.CarrierId
OUTER APPLY (SELECT TOP (1) 1 AS HadException
               FROM Logistics.TrackingEvent te
              WHERE te.ShipmentId = sh.ShipmentId
                AND te.EventCode IN ('DELAYED','FAILED_ATTEMPT')) ex
GROUP BY c.CarrierCode, c.CarrierName, c.TransportMode, cs.ServiceCode, cs.ServiceName, cs.TransitDaysTarget;
GO

-- Account tree: own sales, whole-subtree sales, and group-level credit exposure/headroom.
-- AccountPath ends with '/' so LIKE path + '%' matches exactly the subtree.
CREATE OR ALTER VIEW Logistics.vw_CustomerHierarchy
AS
WITH Tree AS
(
    SELECT  c.CustomerId,
            c.CustomerId AS RootCustomerId,
            0            AS Depth,
            CAST(CONCAT('/', c.CustomerCode, '/') AS varchar(400)) AS AccountPath
    FROM Logistics.Customer c
    WHERE c.ParentCustomerId IS NULL

    UNION ALL

    SELECT  c.CustomerId,
            t.RootCustomerId,
            t.Depth + 1,
            CAST(CONCAT(t.AccountPath, c.CustomerCode, '/') AS varchar(400))
    FROM Logistics.Customer c
    JOIN Tree t ON c.ParentCustomerId = t.CustomerId
),
Sales AS
(
    SELECT  so.CustomerId,
            SUM(sol.LineTotal) AS OrderValue,
            SUM(CASE WHEN so.Status IN ('NEW','PARTIAL','ALLOCATED','SHIPPED') THEN sol.LineTotal ELSE 0 END) AS OpenValue
    FROM Logistics.SalesOrder so
    JOIN Logistics.SalesOrderLine sol ON sol.SalesOrderId = so.SalesOrderId
    WHERE so.Status <> 'CANCELLED'
    GROUP BY so.CustomerId
),
Enriched AS
(
    SELECT  t.CustomerId, t.RootCustomerId, t.Depth, t.AccountPath,
            COALESCE(s.OrderValue, 0) AS OwnOrderValue,
            COALESCE(s.OpenValue, 0)  AS OwnOpenValue
    FROM Tree t
    LEFT JOIN Sales s ON s.CustomerId = t.CustomerId
)
SELECT
    e.AccountPath,
    REPLICATE(N'    ', e.Depth) + c.CustomerName                 AS IndentedName,
    c.CustomerCode,
    c.CustomerType,
    e.Depth,
    root.CustomerCode                                           AS GroupAccount,
    COALESCE(c.DefaultDiscountPct, par.DefaultDiscountPct, root.DefaultDiscountPct, 0) AS EffectiveDiscountPct,
    CAST(e.OwnOrderValue AS decimal(14,2))                      AS OwnOrderValue,
    CAST((SELECT SUM(x.OwnOrderValue) FROM Enriched x
           WHERE x.AccountPath LIKE e.AccountPath + '%') AS decimal(14,2)) AS SubtreeOrderValue,
    root.CreditLimit                                            AS GroupCreditLimit,
    CAST(g.GroupExposure AS decimal(14,2))                      AS GroupOpenExposure,
    CAST(root.CreditLimit - g.GroupExposure AS decimal(14,2))   AS GroupCreditHeadroom
FROM Enriched e
JOIN Logistics.Customer c        ON c.CustomerId    = e.CustomerId
JOIN Logistics.Customer root     ON root.CustomerId = e.RootCustomerId
LEFT JOIN Logistics.Customer par ON par.CustomerId  = c.ParentCustomerId
CROSS APPLY (SELECT SUM(x.OwnOpenValue) AS GroupExposure
               FROM Enriched x
              WHERE x.RootCustomerId = e.RootCustomerId) g;
GO

PRINT 'Step 2 complete: 2 functions and 14 views created.';
GO
