/* =================================================================================
   VerdantStackDB - COMPLETE BUILD SCRIPT (Steps 1-5 combined)
   Open in SSMS and press F5. Builds, loads and demonstrates the whole database.
   ================================================================================= */

/* >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>  Step1_Structure.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< */

/*
=====================================================================================
  VerdantStackDB  -  Logistics & Inventory Platform
  STEP 1 of 5 : Database, schemas, tables, constraints, sequences, indexes
-------------------------------------------------------------------------------------
  Fictional business : Verdant Stack Supply Co. (hydroponics & vertical-farming
                       equipment distributor; sites in Leeds, Bristol, Rotterdam)
  Target             : SQL Server 2019 or later
  Re-runnable        : drops and recreates the database

  Hierarchy techniques used on purpose (three different patterns):
    1. hierarchyid        -> Inventory.Location (network > region > site > zone > aisle > bin)
                             Inventory.Category  (product taxonomy)
                             Org.Employee        (org chart)
    2. Adjacency list     -> Logistics.Customer       (group > branch > franchise)
                             Logistics.ShipmentPackage (pallet > carton)
    3. Recursive BOM      -> Inventory.KitComponent   (kits containing kits)
=====================================================================================
*/
SET NOCOUNT ON;
GO
USE master;
GO
IF DB_ID(N'VerdantStackDB') IS NOT NULL
BEGIN
    ALTER DATABASE VerdantStackDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE VerdantStackDB;
END;
GO
CREATE DATABASE VerdantStackDB;
GO
ALTER DATABASE VerdantStackDB SET RECOVERY SIMPLE;
GO
USE VerdantStackDB;
GO
-- Required for filtered indexes and indexes on computed columns
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO

/* ===================================================================================
   0. SCHEMAS
   =================================================================================== */
CREATE SCHEMA Core;
GO
CREATE SCHEMA Org;
GO
CREATE SCHEMA Inventory;
GO
CREATE SCHEMA Logistics;
GO

/* ===================================================================================
   1. CORE (reference data + audit)
   =================================================================================== */
CREATE TABLE Core.Country
(
    CountryCode   char(2)       NOT NULL CONSTRAINT PK_Country PRIMARY KEY,
    CountryName   nvarchar(80)  NOT NULL CONSTRAINT UQ_Country_Name UNIQUE,
    CurrencyCode  char(3)       NOT NULL
);

CREATE TABLE Core.UnitOfMeasure
(
    UomCode   varchar(10)  NOT NULL CONSTRAINT PK_UnitOfMeasure PRIMARY KEY,
    UomName   nvarchar(40) NOT NULL,
    UomClass  varchar(10)  NOT NULL
        CONSTRAINT CK_Uom_Class CHECK (UomClass IN ('COUNT','VOLUME','WEIGHT','LENGTH'))
);

CREATE TABLE Core.AuditLog
(
    AuditId     bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditLog PRIMARY KEY,
    TableName   sysname       NOT NULL,
    RecordKey   nvarchar(100) NOT NULL,
    ActionType  varchar(10)   NOT NULL,
    ColumnName  sysname       NULL,
    OldValue    nvarchar(400) NULL,
    NewValue    nvarchar(400) NULL,
    ChangedBy   sysname       NOT NULL CONSTRAINT DF_AuditLog_ChangedBy DEFAULT (SUSER_SNAME()),
    ChangedAt   datetime2(0)  NOT NULL CONSTRAINT DF_AuditLog_ChangedAt DEFAULT (SYSDATETIME())
);
GO

/* ===================================================================================
   2. ORG (org chart with hierarchyid)
   =================================================================================== */
CREATE TABLE Org.Department
(
    DepartmentId    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Department PRIMARY KEY,
    DepartmentCode  varchar(10)  NOT NULL CONSTRAINT UQ_Department_Code UNIQUE,
    DepartmentName  nvarchar(60) NOT NULL
);

CREATE TABLE Org.Employee
(
    EmployeeId    int IDENTITY(1001,1) NOT NULL CONSTRAINT PK_Employee PRIMARY KEY,
    OrgNode       hierarchyid  NOT NULL CONSTRAINT UQ_Employee_OrgNode UNIQUE,   -- depth-first index
    OrgLevel      AS OrgNode.GetLevel(),                                         -- for breadth-first index
    FirstName     nvarchar(50) NOT NULL,
    LastName      nvarchar(50) NOT NULL,
    JobTitle      nvarchar(80) NOT NULL,
    DepartmentId  int NOT NULL CONSTRAINT FK_Employee_Department REFERENCES Org.Department(DepartmentId),
    HomeSiteId    int NULL,      -- FK added after Inventory.Location exists
    Email         varchar(120) NOT NULL CONSTRAINT UQ_Employee_Email UNIQUE,
    HireDate      date NOT NULL,
    IsActive      bit  NOT NULL CONSTRAINT DF_Employee_IsActive DEFAULT (1)
);
GO

/* ===================================================================================
   3. INVENTORY
   =================================================================================== */

-- 3.1 Product taxonomy (hierarchyid)
CREATE TABLE Inventory.Category
(
    CategoryId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Category PRIMARY KEY,
    CategoryNode   hierarchyid  NOT NULL CONSTRAINT UQ_Category_Node UNIQUE,
    CategoryLevel  AS CategoryNode.GetLevel(),
    CategoryCode   varchar(20)  NOT NULL CONSTRAINT UQ_Category_Code UNIQUE,
    CategoryName   nvarchar(80) NOT NULL,
    HazardClass    varchar(10)  NULL          -- inherited by descendants (resolved in views)
);

-- 3.2 Physical network (hierarchyid): NETWORK > REGION > SITE > ZONE > AISLE > BIN
CREATE TABLE Inventory.Location
(
    LocationId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Location PRIMARY KEY,
    LocationNode      hierarchyid   NOT NULL CONSTRAINT UQ_Location_Node UNIQUE,
    LocationLevel     AS LocationNode.GetLevel(),
    LocationCode      varchar(30)   NOT NULL CONSTRAINT UQ_Location_Code UNIQUE,
    LocationName      nvarchar(100) NOT NULL,
    LocationType      varchar(10)   NOT NULL
        CONSTRAINT CK_Location_Type CHECK (LocationType IN ('NETWORK','REGION','SITE','ZONE','AISLE','BIN')),
    TemperatureClass  varchar(8)    NULL
        CONSTRAINT CK_Location_Temp CHECK (TemperatureClass IN ('AMBIENT','CHILLED','HAZMAT')),
    ZonePurpose       varchar(10)   NULL
        CONSTRAINT CK_Location_ZonePurpose CHECK (ZonePurpose IN ('STORAGE','STAGING')),
    CountryCode       char(2)       NULL CONSTRAINT FK_Location_Country REFERENCES Core.Country(CountryCode),
    City              nvarchar(60)  NULL,
    MaxVolumeM3       decimal(9,3)  NULL,
    MaxWeightKg       decimal(10,2) NULL,
    IsActive          bit NOT NULL CONSTRAINT DF_Location_IsActive DEFAULT (1),
    -- temperature & purpose are defined once, on the ZONE, and inherited by aisles/bins
    CONSTRAINT CK_Location_ZoneAttrs CHECK (
        (LocationType =  'ZONE' AND ZonePurpose IS NOT NULL AND TemperatureClass IS NOT NULL) OR
        (LocationType <> 'ZONE' AND ZonePurpose IS NULL     AND TemperatureClass IS NULL)),
    CONSTRAINT CK_Location_BinCapacity CHECK (
        LocationType <> 'BIN' OR (MaxVolumeM3 > 0 AND MaxWeightKg > 0))
);

ALTER TABLE Org.Employee
    ADD CONSTRAINT FK_Employee_HomeSite FOREIGN KEY (HomeSiteId) REFERENCES Inventory.Location(LocationId);

-- 3.3 Suppliers
CREATE TABLE Inventory.Supplier
(
    SupplierId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Supplier PRIMARY KEY,
    SupplierCode   varchar(12)   NOT NULL CONSTRAINT UQ_Supplier_Code UNIQUE,
    SupplierName   nvarchar(100) NOT NULL,
    CountryCode    char(2)       NOT NULL CONSTRAINT FK_Supplier_Country REFERENCES Core.Country(CountryCode),
    LeadTimeDays   smallint      NOT NULL CONSTRAINT CK_Supplier_LeadTime CHECK (LeadTimeDays BETWEEN 0 AND 365),
    QualityRating  decimal(3,2)  NULL     CONSTRAINT CK_Supplier_Rating   CHECK (QualityRating BETWEEN 0 AND 5),
    IsActive       bit NOT NULL CONSTRAINT DF_Supplier_IsActive DEFAULT (1)
);

-- 3.4 Products
CREATE TABLE Inventory.Product
(
    ProductId         int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Product PRIMARY KEY,
    Sku               varchar(20)   NOT NULL CONSTRAINT UQ_Product_Sku UNIQUE,
    ProductName       nvarchar(120) NOT NULL,
    CategoryId        int           NOT NULL CONSTRAINT FK_Product_Category REFERENCES Inventory.Category(CategoryId),
    BaseUom           varchar(10)   NOT NULL CONSTRAINT FK_Product_Uom REFERENCES Core.UnitOfMeasure(UomCode),
    UnitWeightKg      decimal(9,3)  NOT NULL CONSTRAINT CK_Product_Weight CHECK (UnitWeightKg > 0),
    UnitVolumeM3      decimal(9,5)  NOT NULL CONSTRAINT CK_Product_Volume CHECK (UnitVolumeM3 > 0),
    StandardCost      decimal(12,4) NOT NULL CONSTRAINT CK_Product_Cost   CHECK (StandardCost >= 0),
    ListPrice         decimal(12,2) NOT NULL CONSTRAINT CK_Product_Price  CHECK (ListPrice >= 0),
    ReorderPoint      int NOT NULL CONSTRAINT DF_Product_ROP DEFAULT (0),
    ReorderQty        int NOT NULL CONSTRAINT DF_Product_ROQ DEFAULT (0),
    IsLotTracked      bit NOT NULL CONSTRAINT DF_Product_Lot DEFAULT (0),
    ShelfLifeDays     smallint NULL,
    IsKit             bit NOT NULL CONSTRAINT DF_Product_IsKit DEFAULT (0),
    TemperatureClass  varchar(8) NOT NULL CONSTRAINT DF_Product_Temp DEFAULT ('AMBIENT')
        CONSTRAINT CK_Product_Temp CHECK (TemperatureClass IN ('AMBIENT','CHILLED','HAZMAT')),
    IsActive          bit NOT NULL CONSTRAINT DF_Product_IsActive DEFAULT (1),
    CreatedAt         datetime2(0) NOT NULL CONSTRAINT DF_Product_CreatedAt DEFAULT (SYSDATETIME()),
    CONSTRAINT CK_Product_ShelfLife CHECK (ShelfLifeDays IS NULL OR (IsLotTracked = 1 AND ShelfLifeDays > 0)),
    CONSTRAINT CK_Product_Reorder   CHECK (ReorderPoint >= 0 AND ReorderQty >= 0)
);

-- 3.5 Product <-> Supplier (many-to-many, one preferred supplier enforced by filtered unique index)
CREATE TABLE Inventory.ProductSupplier
(
    ProductId    int NOT NULL CONSTRAINT FK_ProductSupplier_Product  REFERENCES Inventory.Product(ProductId),
    SupplierId   int NOT NULL CONSTRAINT FK_ProductSupplier_Supplier REFERENCES Inventory.Supplier(SupplierId),
    SupplierSku  varchar(30)   NOT NULL,
    UnitCost     decimal(12,4) NOT NULL CONSTRAINT CK_ProductSupplier_Cost CHECK (UnitCost >= 0),
    MinOrderQty  int NOT NULL CONSTRAINT DF_ProductSupplier_MOQ  DEFAULT (1)
        CONSTRAINT CK_ProductSupplier_MOQ CHECK (MinOrderQty >= 1),
    IsPreferred  bit NOT NULL CONSTRAINT DF_ProductSupplier_Pref DEFAULT (0),
    CONSTRAINT PK_ProductSupplier PRIMARY KEY (ProductId, SupplierId)
);

-- 3.6 Bill of materials (recursive: a kit may contain another kit)
CREATE TABLE Inventory.KitComponent
(
    KitProductId        int NOT NULL CONSTRAINT FK_KitComponent_Kit       REFERENCES Inventory.Product(ProductId),
    ComponentProductId  int NOT NULL CONSTRAINT FK_KitComponent_Component REFERENCES Inventory.Product(ProductId),
    QtyPer              decimal(9,3) NOT NULL CONSTRAINT CK_KitComponent_Qty CHECK (QtyPer > 0),
    CONSTRAINT PK_KitComponent PRIMARY KEY (KitProductId, ComponentProductId),
    CONSTRAINT CK_KitComponent_NotSelf CHECK (KitProductId <> ComponentProductId)
);

-- 3.7 Lots / batches (expiry-driven FEFO picking)
CREATE TABLE Inventory.Lot
(
    LotId           int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Lot PRIMARY KEY,
    ProductId       int NOT NULL CONSTRAINT FK_Lot_Product  REFERENCES Inventory.Product(ProductId),
    LotNumber       varchar(30) NOT NULL,
    SupplierId      int NULL     CONSTRAINT FK_Lot_Supplier REFERENCES Inventory.Supplier(SupplierId),
    ManufacturedOn  date NOT NULL,
    ExpiresOn       date NULL,
    ReceivedOn      date NOT NULL,
    CONSTRAINT UQ_Lot_ProductLot UNIQUE (ProductId, LotNumber),
    CONSTRAINT CK_Lot_Dates CHECK (ExpiresOn IS NULL OR ExpiresOn > ManufacturedOn)
);

-- 3.8 Current stock per product / bin / lot
CREATE TABLE Inventory.StockBalance
(
    StockBalanceId  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_StockBalance PRIMARY KEY,
    ProductId       int NOT NULL CONSTRAINT FK_StockBalance_Product  REFERENCES Inventory.Product(ProductId),
    LocationId      int NOT NULL CONSTRAINT FK_StockBalance_Location REFERENCES Inventory.Location(LocationId),
    LotId           int NULL     CONSTRAINT FK_StockBalance_Lot      REFERENCES Inventory.Lot(LotId),
    QtyOnHand       decimal(12,3) NOT NULL CONSTRAINT DF_StockBalance_OnHand DEFAULT (0),
    QtyAllocated    decimal(12,3) NOT NULL CONSTRAINT DF_StockBalance_Alloc  DEFAULT (0),
    QtyAvailable    AS (QtyOnHand - QtyAllocated),
    LastMovementAt  datetime2(0) NULL,
    RowVer          rowversion,
    CONSTRAINT CK_StockBalance_Qty CHECK (QtyOnHand >= 0 AND QtyAllocated >= 0 AND QtyAllocated <= QtyOnHand)
);

-- 3.9 Stock ledger (append-only, protected by trigger in Step 3)
CREATE TABLE Inventory.StockTransaction
(
    TxnId           bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_StockTransaction PRIMARY KEY,
    TxnType         varchar(10) NOT NULL
        CONSTRAINT CK_StockTxn_Type CHECK (TxnType IN ('OPENING','RECEIPT','TRANSFER','ADJUST','SHIP','RETURN')),
    ProductId       int NOT NULL CONSTRAINT FK_StockTxn_Product  REFERENCES Inventory.Product(ProductId),
    LotId           int NULL     CONSTRAINT FK_StockTxn_Lot      REFERENCES Inventory.Lot(LotId),
    FromLocationId  int NULL     CONSTRAINT FK_StockTxn_From     REFERENCES Inventory.Location(LocationId),
    ToLocationId    int NULL     CONSTRAINT FK_StockTxn_To       REFERENCES Inventory.Location(LocationId),
    Quantity        decimal(12,3) NOT NULL CONSTRAINT CK_StockTxn_Qty CHECK (Quantity > 0),
    UnitCost        decimal(12,4) NULL,
    ReferenceType   varchar(12) NULL,
    ReferenceId     int NULL,
    EmployeeId      int NULL     CONSTRAINT FK_StockTxn_Employee REFERENCES Org.Employee(EmployeeId),
    TxnAt           datetime2(0) NOT NULL CONSTRAINT DF_StockTxn_At DEFAULT (SYSDATETIME()),
    Notes           nvarchar(200) NULL,
    -- direction rules per transaction type
    CONSTRAINT CK_StockTxn_Direction CHECK (
        (TxnType IN ('OPENING','RECEIPT','RETURN') AND FromLocationId IS NULL     AND ToLocationId IS NOT NULL) OR
        (TxnType = 'SHIP'                          AND FromLocationId IS NOT NULL AND ToLocationId IS NULL)     OR
        (TxnType = 'TRANSFER'                      AND FromLocationId IS NOT NULL AND ToLocationId IS NOT NULL
                                                   AND FromLocationId <> ToLocationId)                          OR
        (TxnType = 'ADJUST' AND ((FromLocationId IS NULL AND ToLocationId IS NOT NULL) OR
                                 (FromLocationId IS NOT NULL AND ToLocationId IS NULL))))
);

-- 3.10 Purchasing
CREATE TABLE Inventory.PurchaseOrder
(
    PurchaseOrderId  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrder PRIMARY KEY,
    PoNumber         varchar(20) NOT NULL CONSTRAINT UQ_PurchaseOrder_Number UNIQUE,
    SupplierId       int NOT NULL CONSTRAINT FK_PO_Supplier REFERENCES Inventory.Supplier(SupplierId),
    ShipToSiteId     int NOT NULL CONSTRAINT FK_PO_Site     REFERENCES Inventory.Location(LocationId),
    OrderDate        date NOT NULL,
    ExpectedDate     date NULL,
    Status           varchar(10) NOT NULL CONSTRAINT DF_PO_Status DEFAULT ('DRAFT')
        CONSTRAINT CK_PO_Status CHECK (Status IN ('DRAFT','SENT','PARTIAL','RECEIVED','CANCELLED')),
    CreatedBy        int NULL CONSTRAINT FK_PO_Employee REFERENCES Org.Employee(EmployeeId),
    CONSTRAINT CK_PO_Dates CHECK (ExpectedDate IS NULL OR ExpectedDate >= OrderDate)
);

CREATE TABLE Inventory.PurchaseOrderLine
(
    PoLineId         int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrderLine PRIMARY KEY,
    PurchaseOrderId  int NOT NULL CONSTRAINT FK_POLine_PO
                         REFERENCES Inventory.PurchaseOrder(PurchaseOrderId) ON DELETE CASCADE,
    LineNumber       smallint NOT NULL,
    ProductId        int NOT NULL CONSTRAINT FK_POLine_Product REFERENCES Inventory.Product(ProductId),
    QtyOrdered       decimal(12,3) NOT NULL CONSTRAINT CK_POLine_Ordered CHECK (QtyOrdered > 0),
    QtyReceived      decimal(12,3) NOT NULL CONSTRAINT DF_POLine_Received DEFAULT (0),
    UnitCost         decimal(12,4) NOT NULL,
    LineTotal        AS CAST(QtyOrdered * UnitCost AS decimal(14,2)),
    CONSTRAINT UQ_POLine UNIQUE (PurchaseOrderId, LineNumber),
    CONSTRAINT CK_POLine_Received CHECK (QtyReceived >= 0 AND QtyReceived <= QtyOrdered)
);
GO

/* ===================================================================================
   4. LOGISTICS
   =================================================================================== */

-- 4.1 Customers (adjacency-list hierarchy: group > branch > franchise outlet)
CREATE TABLE Logistics.Customer
(
    CustomerId          int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Customer PRIMARY KEY,
    CustomerCode        varchar(12)   NOT NULL CONSTRAINT UQ_Customer_Code UNIQUE,
    CustomerName        nvarchar(120) NOT NULL,
    CustomerType        varchar(12)   NOT NULL
        CONSTRAINT CK_Customer_Type CHECK (CustomerType IN ('RETAIL','COMMERCIAL','DISTRIBUTOR','EDUCATION')),
    ParentCustomerId    int NULL CONSTRAINT FK_Customer_Parent REFERENCES Logistics.Customer(CustomerId),
    CountryCode         char(2) NOT NULL CONSTRAINT FK_Customer_Country REFERENCES Core.Country(CountryCode),
    CreditLimit         decimal(12,2) NULL,      -- evaluated at group (root) level
    DefaultDiscountPct  decimal(5,2)  NULL       -- NULL = inherit from parent
        CONSTRAINT CK_Customer_Discount CHECK (DefaultDiscountPct BETWEEN 0 AND 50),
    IsActive            bit NOT NULL CONSTRAINT DF_Customer_IsActive DEFAULT (1),
    CONSTRAINT CK_Customer_NotOwnParent CHECK (ParentCustomerId IS NULL OR ParentCustomerId <> CustomerId)
);

CREATE TABLE Logistics.CustomerAddress
(
    AddressId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_CustomerAddress PRIMARY KEY,
    CustomerId    int NOT NULL CONSTRAINT FK_Address_Customer REFERENCES Logistics.Customer(CustomerId),
    AddressType   varchar(10) NOT NULL CONSTRAINT CK_Address_Type CHECK (AddressType IN ('BILLING','DELIVERY')),
    AddressLine1  nvarchar(120) NOT NULL,
    AddressLine2  nvarchar(120) NULL,
    City          nvarchar(60)  NOT NULL,
    PostCode      varchar(12)   NOT NULL,
    CountryCode   char(2) NOT NULL CONSTRAINT FK_Address_Country REFERENCES Core.Country(CountryCode),
    IsDefault     bit NOT NULL CONSTRAINT DF_Address_Default DEFAULT (0)
);

-- 4.2 Carriers and their service levels
CREATE TABLE Logistics.Carrier
(
    CarrierId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Carrier PRIMARY KEY,
    CarrierCode    varchar(10)  NOT NULL CONSTRAINT UQ_Carrier_Code UNIQUE,
    CarrierName    nvarchar(80) NOT NULL,
    TransportMode  varchar(8)   NOT NULL CONSTRAINT CK_Carrier_Mode CHECK (TransportMode IN ('ROAD','PARCEL','AIR','SEA')),
    IsActive       bit NOT NULL CONSTRAINT DF_Carrier_IsActive DEFAULT (1)
);

CREATE TABLE Logistics.CarrierService
(
    ServiceId          int IDENTITY(1,1) NOT NULL CONSTRAINT PK_CarrierService PRIMARY KEY,
    CarrierId          int NOT NULL CONSTRAINT FK_Service_Carrier REFERENCES Logistics.Carrier(CarrierId),
    ServiceCode        varchar(12)  NOT NULL CONSTRAINT UQ_Service_Code UNIQUE,
    ServiceName        nvarchar(60) NOT NULL,
    TransitDaysTarget  tinyint      NOT NULL CONSTRAINT CK_Service_Transit CHECK (TransitDaysTarget BETWEEN 1 AND 30),
    MaxWeightKg        decimal(9,2) NOT NULL CONSTRAINT CK_Service_MaxWeight CHECK (MaxWeightKg > 0),
    BaseRate           decimal(9,2) NOT NULL,
    RatePerKg          decimal(9,4) NOT NULL,
    AllowsHazmat       bit NOT NULL CONSTRAINT DF_Service_Hazmat DEFAULT (1)
);

-- 4.3 Sales orders
CREATE TABLE Logistics.SalesOrder
(
    SalesOrderId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SalesOrder PRIMARY KEY,
    OrderNumber         varchar(20) NOT NULL CONSTRAINT UQ_SalesOrder_Number UNIQUE,
    CustomerId          int NOT NULL CONSTRAINT FK_SO_Customer REFERENCES Logistics.Customer(CustomerId),
    DeliveryAddressId   int NOT NULL CONSTRAINT FK_SO_Address  REFERENCES Logistics.CustomerAddress(AddressId),
    FulfilSiteId        int NOT NULL CONSTRAINT FK_SO_Site     REFERENCES Inventory.Location(LocationId),
    RequestedServiceId  int NULL     CONSTRAINT FK_SO_Service  REFERENCES Logistics.CarrierService(ServiceId),
    OrderedAt           datetime2(0) NOT NULL CONSTRAINT DF_SO_OrderedAt DEFAULT (SYSDATETIME()),
    PromisedDate        date NOT NULL,
    Priority            tinyint NOT NULL CONSTRAINT DF_SO_Priority DEFAULT (2)
        CONSTRAINT CK_SO_Priority CHECK (Priority BETWEEN 1 AND 3),
    Status              varchar(10) NOT NULL CONSTRAINT DF_SO_Status DEFAULT ('NEW')
        CONSTRAINT CK_SO_Status CHECK (Status IN ('NEW','PARTIAL','ALLOCATED','SHIPPED','DELIVERED','CANCELLED')),
    CreatedBy           int NULL CONSTRAINT FK_SO_Employee REFERENCES Org.Employee(EmployeeId)
);

CREATE TABLE Logistics.SalesOrderLine
(
    SoLineId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SalesOrderLine PRIMARY KEY,
    SalesOrderId  int NOT NULL CONSTRAINT FK_SOLine_SO      REFERENCES Logistics.SalesOrder(SalesOrderId),
    LineNumber    smallint NOT NULL,
    ProductId     int NOT NULL CONSTRAINT FK_SOLine_Product REFERENCES Inventory.Product(ProductId),
    QtyOrdered    decimal(12,3) NOT NULL CONSTRAINT CK_SOLine_Ordered CHECK (QtyOrdered > 0),
    QtyAllocated  decimal(12,3) NOT NULL CONSTRAINT DF_SOLine_Alloc   DEFAULT (0),   -- reserved, not yet shipped
    QtyShipped    decimal(12,3) NOT NULL CONSTRAINT DF_SOLine_Shipped DEFAULT (0),
    UnitPrice     decimal(12,2) NOT NULL,
    DiscountPct   decimal(5,2)  NOT NULL CONSTRAINT DF_SOLine_Disc DEFAULT (0),
    LineTotal     AS CAST(QtyOrdered * UnitPrice * (1 - DiscountPct / 100) AS decimal(14,2)),
    CONSTRAINT UQ_SOLine UNIQUE (SalesOrderId, LineNumber),
    CONSTRAINT CK_SOLine_Qty CHECK (QtyAllocated >= 0 AND QtyShipped >= 0 AND QtyAllocated + QtyShipped <= QtyOrdered)
);

-- 4.4 Shipments
CREATE TABLE Logistics.Shipment
(
    ShipmentId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Shipment PRIMARY KEY,
    ShipmentNumber    varchar(20) NOT NULL CONSTRAINT UQ_Shipment_Number UNIQUE,
    SalesOrderId      int NOT NULL CONSTRAINT FK_Shipment_SO      REFERENCES Logistics.SalesOrder(SalesOrderId),
    OriginSiteId      int NOT NULL CONSTRAINT FK_Shipment_Site    REFERENCES Inventory.Location(LocationId),
    ServiceId         int NOT NULL CONSTRAINT FK_Shipment_Service REFERENCES Logistics.CarrierService(ServiceId),
    TrackingNumber    varchar(30) NOT NULL CONSTRAINT UQ_Shipment_Tracking UNIQUE,
    Status            varchar(10) NOT NULL
        CONSTRAINT CK_Shipment_Status CHECK (Status IN ('DISPATCHED','IN_TRANSIT','EXCEPTION','DELIVERED')),
    DispatchedAt      datetime2(0) NOT NULL,
    PromisedDelivery  date NOT NULL,
    DeliveredAt       datetime2(0) NULL,
    GrossWeightKg     decimal(10,3) NOT NULL,
    FreightCost       decimal(10,2) NOT NULL,
    CreatedBy         int NULL CONSTRAINT FK_Shipment_Employee REFERENCES Org.Employee(EmployeeId),
    CONSTRAINT CK_Shipment_Delivered CHECK (
        (Status =  'DELIVERED' AND DeliveredAt IS NOT NULL) OR
        (Status <> 'DELIVERED' AND DeliveredAt IS NULL))
);

-- 4.5 Nested packaging (adjacency list: PALLET contains CARTONs)
CREATE TABLE Logistics.ShipmentPackage
(
    PackageId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ShipmentPackage PRIMARY KEY,
    ShipmentId       int NOT NULL CONSTRAINT FK_Package_Shipment REFERENCES Logistics.Shipment(ShipmentId),
    ParentPackageId  int NULL     CONSTRAINT FK_Package_Parent   REFERENCES Logistics.ShipmentPackage(PackageId),
    PackageType      varchar(8) NOT NULL CONSTRAINT CK_Package_Type CHECK (PackageType IN ('PALLET','CARTON','TOTE')),
    LabelCode        varchar(30) NOT NULL CONSTRAINT UQ_Package_Label UNIQUE,
    GrossWeightKg    decimal(10,3) NOT NULL,
    CONSTRAINT CK_Package_NotOwnParent CHECK (ParentPackageId IS NULL OR ParentPackageId <> PackageId)
);

CREATE TABLE Logistics.PackageContent
(
    PackageContentId  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PackageContent PRIMARY KEY,
    PackageId         int NOT NULL CONSTRAINT FK_Content_Package REFERENCES Logistics.ShipmentPackage(PackageId),
    SoLineId          int NOT NULL CONSTRAINT FK_Content_SOLine  REFERENCES Logistics.SalesOrderLine(SoLineId),
    ProductId         int NOT NULL CONSTRAINT FK_Content_Product REFERENCES Inventory.Product(ProductId),
    LotId             int NULL     CONSTRAINT FK_Content_Lot     REFERENCES Inventory.Lot(LotId),
    Quantity          decimal(12,3) NOT NULL CONSTRAINT CK_Content_Qty CHECK (Quantity > 0)
);

-- 4.6 Stock reservations (link between an order line and a specific bin/lot balance)
CREATE TABLE Logistics.OrderAllocation
(
    AllocationId    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_OrderAllocation PRIMARY KEY,
    SoLineId        int NOT NULL CONSTRAINT FK_Alloc_SOLine   REFERENCES Logistics.SalesOrderLine(SoLineId),
    StockBalanceId  int NOT NULL CONSTRAINT FK_Alloc_Stock    REFERENCES Inventory.StockBalance(StockBalanceId),
    Quantity        decimal(12,3) NOT NULL CONSTRAINT CK_Alloc_Qty CHECK (Quantity > 0),
    AllocatedAt     datetime2(0) NOT NULL CONSTRAINT DF_Alloc_At DEFAULT (SYSDATETIME()),
    ShipmentId      int NULL     CONSTRAINT FK_Alloc_Shipment REFERENCES Logistics.Shipment(ShipmentId)  -- NULL = still to pick
);

-- 4.7 Carrier tracking events
CREATE TABLE Logistics.TrackingEvent
(
    EventId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_TrackingEvent PRIMARY KEY,
    ShipmentId    int NOT NULL CONSTRAINT FK_Tracking_Shipment REFERENCES Logistics.Shipment(ShipmentId),
    EventCode     varchar(20) NOT NULL CONSTRAINT CK_Tracking_Code CHECK (EventCode IN
                    ('PICKED_UP','DEPARTED','ARRIVED_HUB','OUT_FOR_DELIVERY','DELIVERED','DELAYED','FAILED_ATTEMPT')),
    EventAt       datetime2(0) NOT NULL,
    LocationText  nvarchar(100) NULL,
    Notes         nvarchar(200) NULL
);
GO

/* ===================================================================================
   5. SEQUENCES & TABLE TYPE
   =================================================================================== */
CREATE SEQUENCE Logistics.seq_SalesOrderNo AS int START WITH 50001 INCREMENT BY 1;
CREATE SEQUENCE Logistics.seq_ShipmentNo   AS int START WITH 70001 INCREMENT BY 1;
GO
-- Table-valued parameter used by usp_CreateSalesOrder (Step 3)
CREATE TYPE Logistics.OrderLineList AS TABLE
(
    Sku        varchar(20)   NOT NULL PRIMARY KEY,
    Quantity   decimal(12,3) NOT NULL CHECK (Quantity > 0),
    UnitPrice  decimal(12,2) NULL          -- NULL = list price less customer discount
);
GO

/* ===================================================================================
   6. INDEXES
   =================================================================================== */
-- hierarchyid: unique constraints above give depth-first indexes; these add breadth-first
CREATE INDEX IX_Employee_BreadthFirst  ON Org.Employee        (OrgLevel, OrgNode);
CREATE INDEX IX_Location_BreadthFirst  ON Inventory.Location  (LocationLevel, LocationNode);
CREATE INDEX IX_Category_BreadthFirst  ON Inventory.Category  (CategoryLevel, CategoryNode);
CREATE INDEX IX_Location_Type          ON Inventory.Location  (LocationType) INCLUDE (LocationNode, LocationCode);

CREATE INDEX IX_Product_Category       ON Inventory.Product (CategoryId) INCLUDE (Sku, ProductName);
CREATE UNIQUE INDEX UX_ProductSupplier_Preferred
                                       ON Inventory.ProductSupplier (ProductId) WHERE IsPreferred = 1;
CREATE INDEX IX_KitComponent_Component ON Inventory.KitComponent (ComponentProductId);
CREATE INDEX IX_Lot_Expiry             ON Inventory.Lot (ExpiresOn) INCLUDE (ProductId, LotNumber)
                                       WHERE ExpiresOn IS NOT NULL;

CREATE UNIQUE INDEX UX_StockBalance_Slot ON Inventory.StockBalance (ProductId, LocationId, LotId);
CREATE INDEX IX_StockBalance_Location  ON Inventory.StockBalance (LocationId)
                                       INCLUDE (ProductId, LotId, QtyOnHand, QtyAllocated);

CREATE INDEX IX_StockTxn_ProductDate   ON Inventory.StockTransaction (ProductId, TxnAt) INCLUDE (TxnType, Quantity);
CREATE INDEX IX_StockTxn_Reference     ON Inventory.StockTransaction (ReferenceType, ReferenceId);

CREATE INDEX IX_POLine_Product         ON Inventory.PurchaseOrderLine (ProductId) INCLUDE (QtyOrdered, QtyReceived);
CREATE INDEX IX_PO_Status              ON Inventory.PurchaseOrder (Status) INCLUDE (SupplierId, ExpectedDate);

CREATE INDEX IX_Customer_Parent        ON Logistics.Customer (ParentCustomerId);
CREATE UNIQUE INDEX UX_Address_Default ON Logistics.CustomerAddress (CustomerId, AddressType) WHERE IsDefault = 1;

CREATE INDEX IX_SO_Customer            ON Logistics.SalesOrder (CustomerId, OrderedAt);
CREATE INDEX IX_SO_OpenBySite          ON Logistics.SalesOrder (FulfilSiteId, PromisedDate)
                                       INCLUDE (Status, CustomerId, Priority)
                                       WHERE Status IN ('NEW','PARTIAL','ALLOCATED');
CREATE INDEX IX_SOLine_Product         ON Logistics.SalesOrderLine (ProductId);

CREATE INDEX IX_Alloc_SOLine           ON Logistics.OrderAllocation (SoLineId) INCLUDE (StockBalanceId, Quantity, ShipmentId);
CREATE INDEX IX_Alloc_Open             ON Logistics.OrderAllocation (StockBalanceId) WHERE ShipmentId IS NULL;

CREATE INDEX IX_Shipment_SO            ON Logistics.Shipment (SalesOrderId);
CREATE INDEX IX_Shipment_ServiceDispatch ON Logistics.Shipment (ServiceId, DispatchedAt)
                                       INCLUDE (Status, PromisedDelivery, DeliveredAt, FreightCost, GrossWeightKg);
CREATE INDEX IX_Package_Shipment       ON Logistics.ShipmentPackage (ShipmentId, ParentPackageId);
CREATE INDEX IX_Content_Package        ON Logistics.PackageContent (PackageId);
CREATE INDEX IX_Tracking_Shipment      ON Logistics.TrackingEvent (ShipmentId, EventAt);
GO

/* ===================================================================================
   7. DOCUMENTATION (extended properties - visible in SSMS and data-dictionary tools)
   =================================================================================== */
EXEC sys.sp_addextendedproperty @name = N'MS_Description',
     @value = N'Physical network as a hierarchyid tree: NETWORK > REGION > SITE > ZONE > AISLE > BIN. Temperature class and purpose are set on ZONE and inherited.',
     @level0type = N'SCHEMA', @level0name = N'Inventory', @level1type = N'TABLE', @level1name = N'Location';
EXEC sys.sp_addextendedproperty @name = N'MS_Description',
     @value = N'Current stock per product, bin and lot. QtyAvailable = OnHand - Allocated. RowVer supports optimistic concurrency.',
     @level0type = N'SCHEMA', @level0name = N'Inventory', @level1type = N'TABLE', @level1name = N'StockBalance';
EXEC sys.sp_addextendedproperty @name = N'MS_Description',
     @value = N'Append-only stock ledger. Every balance change is written here; updates and deletes are blocked by trigger.',
     @level0type = N'SCHEMA', @level0name = N'Inventory', @level1type = N'TABLE', @level1name = N'StockTransaction';
EXEC sys.sp_addextendedproperty @name = N'MS_Description',
     @value = N'Recursive bill of materials. A kit can contain other kits; cycles are rejected by trigger.',
     @level0type = N'SCHEMA', @level0name = N'Inventory', @level1type = N'TABLE', @level1name = N'KitComponent';
EXEC sys.sp_addextendedproperty @name = N'MS_Description',
     @value = N'Customer accounts as an adjacency list (group > branch > franchise). Credit limit is checked at the group root across all descendants.',
     @level0type = N'SCHEMA', @level0name = N'Logistics', @level1type = N'TABLE', @level1name = N'Customer';
EXEC sys.sp_addextendedproperty @name = N'MS_Description',
     @value = N'Nested packaging: cartons point to their parent pallet.',
     @level0type = N'SCHEMA', @level0name = N'Logistics', @level1type = N'TABLE', @level1name = N'ShipmentPackage';
EXEC sys.sp_addextendedproperty @name = N'MS_Description',
     @value = N'Org chart as a hierarchyid tree. Subtrees are moved with GetReparentedValue.',
     @level0type = N'SCHEMA', @level0name = N'Org', @level1type = N'TABLE', @level1name = N'Employee';
GO

PRINT 'Step 1 complete: 27 tables, 2 sequences, 1 table type, indexes and documentation created.';
GO


/* >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>  Step2_Functions_Views.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< */

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


/* >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>  Step3_Procedures_Triggers.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< */

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


/* >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>  Step4_Seed_Data.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< */

/*
=====================================================================================
  VerdantStackDB  -  STEP 4 of 5 : Seed Data
-------------------------------------------------------------------------------------
  Run after Step3_Procedures_Triggers.sql

  All business data is invented for this portfolio (Verdant Stack Supply Co.).
  Every date is relative to SYSDATETIME(), so expiry alerts, overdue orders and
  90-day analytics look current whenever the script is run.

  Natural keys (codes, SKUs, emails) are used for every lookup - no hard-coded
  identity values - so the load is order-independent and safe to re-run on a
  fresh database.

  LOAD ORDER
    1  Reference data       countries, units, departments
    2  Warehouse network    5 upper levels by hand, bins generated set-based
    3  Organisation         17 employees in a hierarchyid tree, home site by subtree
    4  Product catalogue    category tree, suppliers, 26 products, sourcing, kit BOMs
    5  Lots & opening stock lots (some expiring / expired), balances, opening ledger
    6  Customers            3-level account tree with addresses
    7  Carriers             4 carriers, 6 service levels
    8  Purchasing           5 purchase orders in different states
    9  Order history        18 delivered orders, shipments and tracking events (last 90 days)
=====================================================================================
*/
USE VerdantStackDB;
GO
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ===================================================================================
   1. REFERENCE DATA
   =================================================================================== */
INSERT INTO Core.Country (CountryCode, CountryName, CurrencyCode)
VALUES ('GB', N'United Kingdom', 'GBP'),
       ('IE', N'Ireland',        'EUR'),
       ('NL', N'Netherlands',    'EUR'),
       ('DE', N'Germany',        'EUR'),
       ('DK', N'Denmark',        'DKK'),
       ('TW', N'Taiwan',         'TWD'),
       ('US', N'United States',  'USD');

INSERT INTO Core.UnitOfMeasure (UomCode, UomName, UomClass)
VALUES ('EA',  N'Each',     'COUNT'),
       ('BAG', N'Bag',      'COUNT'),
       ('L',   N'Litre',    'VOLUME'),
       ('KG',  N'Kilogram', 'WEIGHT'),
       ('M',   N'Metre',    'LENGTH');

INSERT INTO Org.Department (DepartmentCode, DepartmentName)
VALUES ('EXEC',  N'Executive'),
       ('WHOPS', N'Warehouse Operations'),
       ('TRANS', N'Transport & Distribution'),
       ('PROC',  N'Procurement'),
       ('INVC',  N'Inventory Control'),
       ('CSVC',  N'Customer Service');
GO

/* ===================================================================================
   2. WAREHOUSE NETWORK (hierarchyid)
   =================================================================================== */
-- 2.1 Network, regions, sites, zones and aisles
INSERT INTO Inventory.Location (LocationNode, LocationCode, LocationName, LocationType,
                                TemperatureClass, ZonePurpose, CountryCode, City)
SELECT hierarchyid::Parse(v.Node), v.Code, v.Name, v.LocType, v.Temp, v.Purpose, v.Country, v.City
FROM (VALUES
    ('/',          'NET',          N'Verdant Stack Distribution Network', 'NETWORK', NULL,      NULL,      NULL, NULL),
    ('/1/',        'R-UK',         N'United Kingdom Region',              'REGION',  NULL,      NULL,      'GB', NULL),
    ('/1/1/',      'LDS1',         N'Leeds Distribution Centre',          'SITE',    NULL,      NULL,      'GB', N'Leeds'),
    ('/1/1/1/',    'LDS1-AMB',     N'Leeds Ambient Storage',              'ZONE',    'AMBIENT', 'STORAGE', NULL, NULL),
    ('/1/1/1/1/',  'LDS1-AMB-A01', N'Leeds Ambient Aisle A01',            'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/1/1/1/2/',  'LDS1-AMB-A02', N'Leeds Ambient Aisle A02',            'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/1/1/1/3/',  'LDS1-AMB-A03', N'Leeds Ambient Aisle A03',            'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/1/1/2/',    'LDS1-CHL',     N'Leeds Chilled Room (2-8 C)',         'ZONE',    'CHILLED', 'STORAGE', NULL, NULL),
    ('/1/1/2/1/',  'LDS1-CHL-C01', N'Leeds Chilled Aisle C01',            'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/1/1/3/',    'LDS1-HAZ',     N'Leeds Hazmat Cage (ADR)',            'ZONE',    'HAZMAT',  'STORAGE', NULL, NULL),
    ('/1/1/3/1/',  'LDS1-HAZ-H01', N'Leeds Hazmat Aisle H01',             'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/1/1/4/',    'LDS1-DCK',     N'Leeds Dock & Staging',               'ZONE',    'AMBIENT', 'STAGING', NULL, NULL),
    ('/1/1/4/1/',  'LDS1-DCK-IN',  N'Leeds Inbound Staging',              'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/1/1/4/2/',  'LDS1-DCK-OUT', N'Leeds Outbound Staging',             'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/1/2/',      'BRS1',         N'Bristol Fulfilment Centre',          'SITE',    NULL,      NULL,      'GB', N'Bristol'),
    ('/1/2/1/',    'BRS1-AMB',     N'Bristol Ambient Storage',            'ZONE',    'AMBIENT', 'STORAGE', NULL, NULL),
    ('/1/2/1/1/',  'BRS1-AMB-A01', N'Bristol Ambient Aisle A01',          'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/1/2/1/2/',  'BRS1-AMB-A02', N'Bristol Ambient Aisle A02',          'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/1/2/2/',    'BRS1-CHL',     N'Bristol Chilled Room (2-8 C)',       'ZONE',    'CHILLED', 'STORAGE', NULL, NULL),
    ('/1/2/2/1/',  'BRS1-CHL-C01', N'Bristol Chilled Aisle C01',          'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/1/2/3/',    'BRS1-DCK',     N'Bristol Dock & Staging',             'ZONE',    'AMBIENT', 'STAGING', NULL, NULL),
    ('/1/2/3/1/',  'BRS1-DCK-IN',  N'Bristol Inbound Staging',            'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/2/',        'R-EU',         N'Continental Europe Region',          'REGION',  NULL,      NULL,      'NL', NULL),
    ('/2/1/',      'RTM1',         N'Rotterdam Cross-Dock Hub',           'SITE',    NULL,      NULL,      'NL', N'Rotterdam'),
    ('/2/1/1/',    'RTM1-AMB',     N'Rotterdam Ambient Storage',          'ZONE',    'AMBIENT', 'STORAGE', NULL, NULL),
    ('/2/1/1/1/',  'RTM1-AMB-A01', N'Rotterdam Ambient Aisle A01',        'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/2/1/2/',    'RTM1-HAZ',     N'Rotterdam Hazmat Cage (ADR)',        'ZONE',    'HAZMAT',  'STORAGE', NULL, NULL),
    ('/2/1/2/1/',  'RTM1-HAZ-H01', N'Rotterdam Hazmat Aisle H01',         'AISLE',   NULL,      NULL,      NULL, NULL),
    ('/2/1/3/',    'RTM1-DCK',     N'Rotterdam Dock & Staging',           'ZONE',    'AMBIENT', 'STAGING', NULL, NULL),
    ('/2/1/3/1/',  'RTM1-DCK-IN',  N'Rotterdam Inbound Staging',          'AISLE',   NULL,      NULL,      NULL, NULL)
) v(Node, Code, Name, LocType, Temp, Purpose, Country, City);

-- 2.2 Bins generated set-based under every aisle.
--     Bin count and capacity depend on the parent zone:
--       storage ambient : 6 bins, 4.0 m3 / 1500 kg (pallet floor positions)
--       chilled/hazmat  : 4 bins, 2.0 m3 /  800 kg
--       staging         : 2 bins, 12.0 m3 / 4000 kg (dock lanes)
WITH n AS
(
    SELECT TOP (6) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int) AS n
    FROM sys.all_objects
)
INSERT INTO Inventory.Location (LocationNode, LocationCode, LocationName, LocationType, MaxVolumeM3, MaxWeightKg)
SELECT  hierarchyid::Parse(a.LocationNode.ToString() + CAST(n.n AS varchar(3)) + '/'),
        CONCAT(a.LocationCode, '-B', RIGHT(CONCAT('0', n.n), 2)),
        CONCAT(a.LocationName, N' / Bin ', RIGHT(CONCAT('0', n.n), 2)),
        'BIN',
        cap.Vol,
        cap.Wt
FROM Inventory.Location a
CROSS APPLY (SELECT z.TemperatureClass, z.ZonePurpose
               FROM Inventory.Location z
              WHERE z.LocationNode = a.LocationNode.GetAncestor(1)) zn
CROSS APPLY (SELECT CASE WHEN zn.ZonePurpose = 'STAGING'                    THEN 2
                         WHEN zn.TemperatureClass IN ('CHILLED','HAZMAT')   THEN 4
                         ELSE 6 END AS BinCount,
                    CAST(CASE WHEN zn.ZonePurpose = 'STAGING'                  THEN 12.0
                              WHEN zn.TemperatureClass IN ('CHILLED','HAZMAT') THEN 2.0
                              ELSE 4.0 END AS decimal(9,3)) AS Vol,
                    CAST(CASE WHEN zn.ZonePurpose = 'STAGING'                  THEN 4000
                              WHEN zn.TemperatureClass IN ('CHILLED','HAZMAT') THEN 800
                              ELSE 1500 END AS decimal(10,2)) AS Wt) cap
CROSS JOIN n
WHERE a.LocationType = 'AISLE'
  AND n.n <= cap.BinCount;
GO

/* ===================================================================================
   3. ORGANISATION (hierarchyid)
   =================================================================================== */
INSERT INTO Org.Employee (OrgNode, FirstName, LastName, JobTitle, DepartmentId, Email, HireDate)
SELECT hierarchyid::Parse(v.Node), v.FirstName, v.LastName, v.JobTitle, d.DepartmentId, v.Email,
       DATEADD(day, -v.TenureDays, CAST(SYSDATETIME() AS date))
FROM (VALUES
    ( 1, '/',          N'Isolde',   N'Marchetti',     N'Managing Director',               'EXEC',  'isolde.marchetti@verdantstack.example',     3650),
    ( 2, '/1/',        N'Tobias',   N'Okonkwo-Reid',  N'Head of Operations',              'WHOPS', 'tobias.okonkwo-reid@verdantstack.example',  2900),
    ( 3, '/1/1/',      N'Priya',    N'Venkataraman',  N'Site Manager - Leeds DC',         'WHOPS', 'priya.venkataraman@verdantstack.example',   2100),
    ( 4, '/1/1/1/',    N'Callum',   N'Fairweather',   N'Shift Lead - Ambient',            'WHOPS', 'callum.fairweather@verdantstack.example',   1500),
    ( 5, '/1/1/1/1/',  N'Desmond',  N'Achterberg',    N'Warehouse Picker',                'WHOPS', 'desmond.achterberg@verdantstack.example',    600),
    ( 6, '/1/1/1/2/',  N'Ruby',     N'Thistlewood',   N'Reach Truck Operator',            'WHOPS', 'ruby.thistlewood@verdantstack.example',      820),
    ( 7, '/1/1/2/',    N'Ewa',      N'Brzezinska',    N'Shift Lead - Chilled & Hazmat',   'WHOPS', 'ewa.brzezinska@verdantstack.example',       1300),
    ( 8, '/1/1/2/1/',  N'Mateus',   N'Carvalho',      N'Warehouse Picker (ADR trained)',  'WHOPS', 'mateus.carvalho@verdantstack.example',       410),
    ( 9, '/1/2/',      N'Hamish',   N'Delacroix',     N'Site Manager - Bristol FC',       'WHOPS', 'hamish.delacroix@verdantstack.example',     1700),
    (10, '/1/2/1/',    N'Noor',     N'Al-Haddad',     N'Warehouse Operative',             'WHOPS', 'noor.alhaddad@verdantstack.example',         380),
    (11, '/1/3/',      N'Annelies', N'van der Sluis', N'Hub Manager - Rotterdam',         'WHOPS', 'annelies.vandersluis@verdantstack.example', 1100),
    (12, '/1/4/',      N'Gideon',   N'Ashworth',      N'Transport Planner',               'TRANS', 'gideon.ashworth@verdantstack.example',       950),
    (13, '/2/',        N'Saoirse',  N'Kavanagh',      N'Head of Procurement',             'PROC',  'saoirse.kavanagh@verdantstack.example',     2400),
    (14, '/2/1/',      N'Felix',    N'Grunewald',     N'Senior Buyer',                    'PROC',  'felix.grunewald@verdantstack.example',      1250),
    (15, '/2/2/',      N'Imogen',   N'Pryce-Lacey',   N'Inventory Controller',            'INVC',  'imogen.prycelacey@verdantstack.example',     990),
    (16, '/3/',        N'Yusuf',    N'Demirci',       N'Customer Service Lead',           'CSVC',  'yusuf.demirci@verdantstack.example',        1600),
    (17, '/3/1/',      N'Leona',    N'Whitcombe',     N'Customer Service Agent',          'CSVC',  'leona.whitcombe@verdantstack.example',       300)
) v(Seq, Node, FirstName, LastName, JobTitle, DeptCode, Email, TenureDays)
JOIN Org.Department d ON d.DepartmentCode = v.DeptCode
ORDER BY v.Seq;     -- deterministic identity values (1001 = Managing Director)

-- Home site assigned by SUBTREE: everyone under a site manager belongs to that site.
UPDATE e
   SET HomeSiteId = s.LocationId
  FROM Org.Employee e
  JOIN Org.Employee mgr ON e.OrgNode.IsDescendantOf(mgr.OrgNode) = 1
  JOIN (VALUES ('priya.venkataraman@verdantstack.example',   'LDS1'),
               ('hamish.delacroix@verdantstack.example',     'BRS1'),
               ('annelies.vandersluis@verdantstack.example', 'RTM1')) v(Email, SiteCode)
    ON v.Email = mgr.Email
  JOIN Inventory.Location s ON s.LocationCode = v.SiteCode;

-- Head office staff are based at Leeds
UPDATE Org.Employee
   SET HomeSiteId = (SELECT LocationId FROM Inventory.Location WHERE LocationCode = 'LDS1')
 WHERE HomeSiteId IS NULL;
GO

/* ===================================================================================
   4. PRODUCT CATALOGUE
   =================================================================================== */
-- 4.1 Category tree (hierarchyid). Hazard class set once on NU-PH, inherited below it.
INSERT INTO Inventory.Category (CategoryNode, CategoryCode, CategoryName, HazardClass)
SELECT hierarchyid::Parse(v.Node), v.Code, v.Name, v.Hazard
FROM (VALUES
    ('/',      'ALL',      N'All Products',               NULL),
    ('/1/',    'GROW-SYS', N'Growing Systems',            NULL),
    ('/1/1/',  'GS-NFT',   N'NFT Channels',               NULL),
    ('/1/2/',  'GS-DWC',   N'Deep Water Culture',         NULL),
    ('/1/3/',  'GS-VERT',  N'Vertical Towers',            NULL),
    ('/2/',    'NUTRI',    N'Nutrients & Additives',      NULL),
    ('/2/1/',  'NU-BASE',  N'Base Nutrients',             NULL),
    ('/2/2/',  'NU-PH',    N'pH Control',                 'UN-CL8'),
    ('/2/3/',  'NU-BIO',   N'Biological Additives',       NULL),
    ('/3/',    'LIGHT',    N'Lighting',                   NULL),
    ('/3/1/',  'LT-LED',   N'LED Fixtures',               NULL),
    ('/3/2/',  'LT-CTRL',  N'Lighting Controllers',       NULL),
    ('/4/',    'MEDIA',    N'Growing Media',              NULL),
    ('/4/1/',  'MD-ROCK',  N'Stone Wool',                 NULL),
    ('/4/2/',  'MD-COCO',  N'Coco Coir',                  NULL),
    ('/5/',    'HW',       N'Pumps & Hardware',           NULL),
    ('/5/1/',  'HW-PUMP',  N'Pumps',                      NULL),
    ('/5/2/',  'HW-TUBE',  N'Tubing & Fittings',          NULL),
    ('/5/3/',  'HW-SENS',  N'Sensors & Monitoring',       NULL),
    ('/6/',    'KITS',     N'Kits & Bundles',             NULL)
) v(Node, Code, Name, Hazard);

-- 4.2 Suppliers
INSERT INTO Inventory.Supplier (SupplierCode, SupplierName, CountryCode, LeadTimeDays, QualityRating)
VALUES ('SUP-AQL', N'Aqualith Fertigation BV',      'NL',  6, 4.60),
       ('SUP-RZB', N'RhizoBloom Biologicals Ltd',   'IE',  5, 4.35),
       ('SUP-LUM', N'Lumenreach Photonics Co.',     'TW', 21, 4.20),
       ('SUP-SUB', N'Substrata Growing Media ApS',  'DK',  9, 4.40),
       ('SUP-FLX', N'Flowlux Pumpworks GmbH',       'DE', 12, 4.10),
       ('SUP-PEN', N'Pennine Polymer Fittings Ltd', 'GB',  3, 4.80),
       ('SUP-SEN', N'Sensoria Agritech Inc.',       'US', 18, 3.90);

-- 4.3 Products
INSERT INTO Inventory.Product (Sku, ProductName, CategoryId, BaseUom, UnitWeightKg, UnitVolumeM3, StandardCost,
                               ListPrice, ReorderPoint, ReorderQty, IsLotTracked, ShelfLifeDays, IsKit, TemperatureClass)
SELECT v.Sku, v.Name, c.CategoryId, v.Uom, v.Wt, v.Vol, v.Cost, v.Price, v.Rop, v.Roq, v.Lot, v.Shelf, v.Kit, v.Temp
FROM (VALUES
    ('VS-NU-A1L',   N'Verdant Base Grow Part A - 1 L',             'NU-BASE', 'EA',   1.150, 0.00120,   3.4000,   8.95, 150,  400, 1,  730, 0, 'AMBIENT'),
    ('VS-NU-B1L',   N'Verdant Base Grow Part B - 1 L',             'NU-BASE', 'EA',   1.150, 0.00120,   3.4000,   8.95, 150,  400, 1,  730, 0, 'AMBIENT'),
    ('VS-NU-A5L',   N'Verdant Base Grow Part A - 5 L',             'NU-BASE', 'EA',   5.600, 0.00580,  13.2000,  32.50,  60,  120, 1,  730, 0, 'AMBIENT'),
    ('VS-PHD-1L',   N'pH Down 81% Phosphoric - 1 L',               'NU-PH',   'EA',   1.600, 0.00120,   4.1000,  11.50,  80,  200, 1, 1095, 0, 'HAZMAT'),
    ('VS-PHU-1L',   N'pH Up Potassium Hydroxide - 1 L',            'NU-PH',   'EA',   1.400, 0.00120,   4.3000,  11.50,  60,  150, 1, 1095, 0, 'HAZMAT'),
    ('VS-BIO-MYC',  N'RhizoBloom Mycorrhizal Inoculant 250 ml',    'NU-BIO',  'EA',   0.300, 0.00040,   6.8000,  19.99,  40,  100, 1,  180, 0, 'CHILLED'),
    ('VS-BIO-ENZ',  N'RhizoBloom Enzyme Root Cleanser 500 ml',     'NU-BIO',  'EA',   0.550, 0.00070,   5.1000,  14.75,  40,  100, 1,  270, 0, 'CHILLED'),
    ('VS-LED-320',  N'Spectra 320 W Full-Spectrum Bar Fixture',    'LT-LED',  'EA',   7.800, 0.04200, 182.0000, 399.00,  15,   30, 0, NULL, 0, 'AMBIENT'),
    ('VS-LED-640',  N'Spectra 640 W Full-Spectrum Bar Fixture',    'LT-LED',  'EA',  12.400, 0.06600, 318.0000, 699.00,  10,   20, 0, NULL, 0, 'AMBIENT'),
    ('VS-LTC-DMX',  N'DimLink 8-Zone Lighting Controller',         'LT-CTRL', 'EA',   0.900, 0.00300,  46.0000, 119.00,  12,   24, 0, NULL, 0, 'AMBIENT'),
    ('VS-RW-CUBE',  N'Stone Wool Starter Cubes (98 pack)',         'MD-ROCK', 'EA',   1.100, 0.01200,   4.2000,  11.99, 100,  300, 0, NULL, 0, 'AMBIENT'),
    ('VS-RW-SLAB',  N'Stone Wool Grow Slab 100x15x7.5 cm',         'MD-ROCK', 'EA',   0.850, 0.01100,   2.1000,   5.49, 200,  500, 0, NULL, 0, 'AMBIENT'),
    ('VS-CC-50L',   N'Buffered Coco Coir - 50 L Bag',              'MD-COCO', 'BAG', 12.500, 0.05500,   6.4000,  15.95,  80,  200, 1, NULL, 0, 'AMBIENT'),
    ('VS-PMP-2K',   N'Flowlux Submersible Pump 2000 L/h',          'HW-PUMP', 'EA',   1.900, 0.00400,  28.5000,  64.00,  25,   50, 0, NULL, 0, 'AMBIENT'),
    ('VS-PMP-4K',   N'Flowlux Submersible Pump 4000 L/h',          'HW-PUMP', 'EA',   3.100, 0.00600,  41.0000,  92.00,  15,   30, 0, NULL, 0, 'AMBIENT'),
    ('VS-AIR-8',    N'Flowlux Air Pump 8-Outlet 60 L/min',         'HW-PUMP', 'EA',   4.400, 0.00900,  35.0000,  79.00,  15,   30, 0, NULL, 0, 'AMBIENT'),
    ('VS-TUB-16',   N'LDPE Irrigation Tubing 16 mm',               'HW-TUBE', 'M',    0.060, 0.00020,   0.3200,   0.95, 500, 1500, 0, NULL, 0, 'AMBIENT'),
    ('VS-FIT-16T',  N'16 mm Barbed Tee Fitting',                   'HW-TUBE', 'EA',   0.010, 0.00002,   0.0900,   0.35,1000, 3000, 0, NULL, 0, 'AMBIENT'),
    ('VS-SEN-ECP',  N'EC/pH Combo Probe Monitor',                  'HW-SENS', 'EA',   0.450, 0.00150,  54.0000, 139.00,  10,   20, 0, NULL, 0, 'AMBIENT'),
    ('VS-SEN-WIFI', N'Climate Node Wi-Fi Sensor',                  'HW-SENS', 'EA',   0.120, 0.00040,  22.0000,  59.00,  20,   40, 0, NULL, 0, 'AMBIENT'),
    ('VS-NFT-CH4',  N'NFT Channel 4 m, 12 Sites',                  'GS-NFT',  'EA',   3.200, 0.02800,  18.5000,  44.00,  30,   80, 0, NULL, 0, 'AMBIENT'),
    ('VS-DWC-BKT',  N'DWC Bucket 20 L with Net Lid',               'GS-DWC',  'EA',   0.900, 0.02500,   6.1000,  15.50,  40,  100, 0, NULL, 0, 'AMBIENT'),
    ('VS-TWR-FRM',  N'Vertical Tower Frame 1.8 m',                 'GS-VERT', 'EA',   9.800, 0.09000,  72.0000, 165.00,   8,   20, 0, NULL, 0, 'AMBIENT'),
    ('VS-KIT-PMA',  N'Pump Assembly Kit (pump, 3 m tubing, 4 tees)','KITS',   'EA',   2.200, 0.00800,  34.0000,  89.00,   0,    0, 0, NULL, 1, 'AMBIENT'),
    ('VS-KIT-TWR',  N'Pro Grow Tower Starter Kit',                 'KITS',    'EA',  26.000, 0.16000, 190.0000, 449.00,   0,    0, 0, NULL, 1, 'AMBIENT'),
    ('VS-KIT-DWC4', N'DWC 4-Bucket Starter Bundle',                'KITS',    'EA',  10.800, 0.12000,  58.0000, 139.00,   0,    0, 0, NULL, 1, 'AMBIENT')
) v(Sku, Name, CatCode, Uom, Wt, Vol, Cost, Price, Rop, Roq, Lot, Shelf, Kit, Temp)
JOIN Inventory.Category c ON c.CategoryCode = v.CatCode;

-- 4.4 Sourcing (one preferred supplier per product; some products dual-sourced)
INSERT INTO Inventory.ProductSupplier (ProductId, SupplierId, SupplierSku, UnitCost, MinOrderQty, IsPreferred)
SELECT p.ProductId, s.SupplierId, v.SupplierSku, v.UnitCost, v.Moq, v.Pref
FROM (VALUES
    ('VS-NU-A1L',   'SUP-AQL', 'AQ-GA-1000',    3.2500,  48, 1),
    ('VS-NU-B1L',   'SUP-AQL', 'AQ-GB-1000',    3.2500,  48, 1),
    ('VS-NU-A5L',   'SUP-AQL', 'AQ-GA-5000',   12.8000,  12, 1),
    ('VS-PHD-1L',   'SUP-AQL', 'AQ-PHD-81',     3.9500,  24, 1),
    ('VS-PHU-1L',   'SUP-AQL', 'AQ-PHU-KOH',    4.1500,  24, 1),
    ('VS-BIO-MYC',  'SUP-RZB', 'RB-MYC-250',    6.6000,  20, 1),
    ('VS-BIO-ENZ',  'SUP-RZB', 'RB-ENZ-500',    4.9500,  20, 1),
    ('VS-LED-320',  'SUP-LUM', 'LR-SB320-EU', 178.0000,  10, 1),
    ('VS-LED-640',  'SUP-LUM', 'LR-SB640-EU', 312.0000,   5, 1),
    ('VS-LTC-DMX',  'SUP-LUM', 'LR-DL8Z',      44.5000,  12, 1),
    ('VS-SEN-WIFI', 'SUP-LUM', 'LR-CN-WIFI',   23.1000,  20, 0),
    ('VS-RW-CUBE',  'SUP-SUB', 'SG-SC98',       4.0500,  50, 1),
    ('VS-RW-SLAB',  'SUP-SUB', 'SG-SL100',      2.0200, 100, 1),
    ('VS-CC-50L',   'SUP-SUB', 'SG-CCB50',      6.2000,  40, 1),
    ('VS-PMP-2K',   'SUP-FLX', 'FX-SUB2000',   27.9000,  10, 1),
    ('VS-PMP-4K',   'SUP-FLX', 'FX-SUB4000',   40.2000,  10, 1),
    ('VS-AIR-8',    'SUP-FLX', 'FX-AIR8-60',   34.1000,   6, 1),
    ('VS-TUB-16',   'SUP-FLX', 'FX-T16-LD',     0.3600, 500, 0),
    ('VS-TUB-16',   'SUP-PEN', 'PP-LDPE16',     0.3000, 250, 1),
    ('VS-FIT-16T',  'SUP-PEN', 'PP-TEE16',      0.0850, 500, 1),
    ('VS-NFT-CH4',  'SUP-PEN', 'PP-NFT4M12',   17.9000,  10, 1),
    ('VS-DWC-BKT',  'SUP-PEN', 'PP-DWC20',      5.9500,  20, 1),
    ('VS-TWR-FRM',  'SUP-PEN', 'PP-VT180',     70.5000,   4, 1),
    ('VS-SEN-ECP',  'SUP-SEN', 'SA-ECPH-2',    52.0000,   5, 1),
    ('VS-SEN-WIFI', 'SUP-SEN', 'SA-CLIM-W',    21.4000,  10, 1)
) v(Sku, SupplierCode, SupplierSku, UnitCost, Moq, Pref)
JOIN Inventory.Product  p ON p.Sku = v.Sku
JOIN Inventory.Supplier s ON s.SupplierCode = v.SupplierCode;

-- 4.5 Bill of materials. VS-KIT-TWR contains VS-KIT-PMA (a kit inside a kit).
INSERT INTO Inventory.KitComponent (KitProductId, ComponentProductId, QtyPer)
SELECT k.ProductId, c.ProductId, v.QtyPer
FROM (VALUES
    ('VS-KIT-PMA',  'VS-PMP-2K',   1),
    ('VS-KIT-PMA',  'VS-TUB-16',   3),
    ('VS-KIT-PMA',  'VS-FIT-16T',  4),
    ('VS-KIT-TWR',  'VS-TWR-FRM',  1),
    ('VS-KIT-TWR',  'VS-KIT-PMA',  1),
    ('VS-KIT-TWR',  'VS-LED-320',  1),
    ('VS-KIT-TWR',  'VS-RW-CUBE',  1),
    ('VS-KIT-TWR',  'VS-NU-A1L',   1),
    ('VS-KIT-TWR',  'VS-NU-B1L',   1),
    ('VS-KIT-TWR',  'VS-SEN-WIFI', 1),
    ('VS-KIT-DWC4', 'VS-DWC-BKT',  4),
    ('VS-KIT-DWC4', 'VS-AIR-8',    1),
    ('VS-KIT-DWC4', 'VS-NU-A1L',   1),
    ('VS-KIT-DWC4', 'VS-NU-B1L',   1)
) v(KitSku, ComponentSku, QtyPer)
JOIN Inventory.Product k ON k.Sku = v.KitSku
JOIN Inventory.Product c ON c.Sku = v.ComponentSku;
GO

/* ===================================================================================
   5. LOTS & OPENING STOCK
   =================================================================================== */
-- Offsets chosen so some lots expire soon and one has already expired:
--   AQL-L7702 expires in ~30 days, RZB-0412 in ~18, RZB-E221 in ~15, RZB-E190 expired ~10 days ago.
INSERT INTO Inventory.Lot (ProductId, LotNumber, SupplierId, ManufacturedOn, ExpiresOn, ReceivedOn)
SELECT p.ProductId, v.LotNumber, s.SupplierId, d.Mfg,
       CASE WHEN p.ShelfLifeDays IS NULL THEN NULL ELSE DATEADD(day, p.ShelfLifeDays, d.Mfg) END,
       DATEADD(day, 14, d.Mfg)
FROM (VALUES
    ('AQL-L7702', 'VS-NU-A1L',  'SUP-AQL', -700),
    ('AQL-L7781', 'VS-NU-A1L',  'SUP-AQL', -120),
    ('AQL-L7782', 'VS-NU-B1L',  'SUP-AQL', -118),
    ('AQL-L7790', 'VS-NU-A5L',  'SUP-AQL',  -95),
    ('AQL-P5510', 'VS-PHD-1L',  'SUP-AQL', -300),
    ('AQL-P5531', 'VS-PHD-1L',  'SUP-AQL',  -60),
    ('AQL-P5522', 'VS-PHU-1L',  'SUP-AQL', -210),
    ('SUB-C3310', 'VS-CC-50L',  'SUP-SUB', -150),
    ('SUB-C3342', 'VS-CC-50L',  'SUP-SUB',  -40),
    ('RZB-0412',  'VS-BIO-MYC', 'SUP-RZB', -162),
    ('RZB-0468',  'VS-BIO-MYC', 'SUP-RZB',  -45),
    ('RZB-E190',  'VS-BIO-ENZ', 'SUP-RZB', -280),
    ('RZB-E221',  'VS-BIO-ENZ', 'SUP-RZB', -255),
    ('RZB-E260',  'VS-BIO-ENZ', 'SUP-RZB',  -70)
) v(LotNumber, Sku, SupplierCode, MfgOffset)
JOIN Inventory.Product  p ON p.Sku = v.Sku
JOIN Inventory.Supplier s ON s.SupplierCode = v.SupplierCode
CROSS APPLY (SELECT DATEADD(day, v.MfgOffset, CAST(SYSDATETIME() AS date)) AS Mfg) d;

-- Opening balances (migrated from a "legacy WMS" 91 days ago)
INSERT INTO Inventory.StockBalance (ProductId, LocationId, LotId, QtyOnHand, QtyAllocated, LastMovementAt)
SELECT p.ProductId, b.LocationId, lt.LotId, v.Qty, 0, DATEADD(day, -91, SYSDATETIME())
FROM (VALUES
    ('LDS1-AMB-A01-B01', 'VS-NU-A1L',   'AQL-L7702',   40),
    ('LDS1-AMB-A01-B02', 'VS-NU-A1L',   'AQL-L7781',  220),
    ('LDS1-AMB-A01-B03', 'VS-NU-B1L',   'AQL-L7782',  210),
    ('LDS1-AMB-A01-B04', 'VS-NU-A5L',   'AQL-L7790',   45),
    ('LDS1-AMB-A01-B05', 'VS-CC-50L',   'SUB-C3310',   60),
    ('LDS1-AMB-A01-B06', 'VS-RW-CUBE',  NULL,         260),
    ('LDS1-AMB-A02-B01', 'VS-LED-320',  NULL,          22),
    ('LDS1-AMB-A02-B02', 'VS-LED-640',  NULL,           7),
    ('LDS1-AMB-A02-B03', 'VS-LTC-DMX',  NULL,          18),
    ('LDS1-AMB-A02-B04', 'VS-PMP-2K',   NULL,          60),
    ('LDS1-AMB-A02-B04', 'VS-KIT-PMA',  NULL,          15),
    ('LDS1-AMB-A02-B05', 'VS-PMP-4K',   NULL,          12),
    ('LDS1-AMB-A02-B05', 'VS-KIT-DWC4', NULL,           9),
    ('LDS1-AMB-A02-B06', 'VS-AIR-8',    NULL,          20),
    ('LDS1-AMB-A02-B06', 'VS-KIT-TWR',  NULL,           6),
    ('LDS1-AMB-A03-B01', 'VS-TUB-16',   NULL,        1800),
    ('LDS1-AMB-A03-B02', 'VS-FIT-16T',  NULL,        4200),
    ('LDS1-AMB-A03-B03', 'VS-SEN-ECP',  NULL,           9),
    ('LDS1-AMB-A03-B04', 'VS-SEN-WIFI', NULL,          35),
    ('LDS1-AMB-A03-B05', 'VS-NFT-CH4',  NULL,          48),
    ('LDS1-AMB-A03-B06', 'VS-DWC-BKT',  NULL,          90),
    ('LDS1-AMB-A03-B06', 'VS-TWR-FRM',  NULL,          14),
    ('LDS1-CHL-C01-B01', 'VS-BIO-MYC',  'RZB-0412',    25),
    ('LDS1-CHL-C01-B02', 'VS-BIO-MYC',  'RZB-0468',    80),
    ('LDS1-CHL-C01-B03', 'VS-BIO-ENZ',  'RZB-E221',    30),
    ('LDS1-CHL-C01-B04', 'VS-BIO-ENZ',  'RZB-E260',    70),
    ('LDS1-HAZ-H01-B01', 'VS-PHD-1L',   'AQL-P5510',  160),
    ('LDS1-HAZ-H01-B02', 'VS-PHU-1L',   'AQL-P5522',   45),
    ('BRS1-AMB-A01-B01', 'VS-NU-A1L',   'AQL-L7781',   90),
    ('BRS1-AMB-A01-B02', 'VS-NU-B1L',   'AQL-L7782',   85),
    ('BRS1-AMB-A01-B03', 'VS-RW-SLAB',  NULL,         300),
    ('BRS1-AMB-A01-B04', 'VS-PMP-4K',   NULL,           2),
    ('BRS1-AMB-A02-B01', 'VS-LED-320',  NULL,           8),
    ('BRS1-AMB-A02-B02', 'VS-KIT-TWR',  NULL,           3),
    ('BRS1-AMB-A02-B03', 'VS-RW-CUBE',  NULL,          40),
    ('BRS1-CHL-C01-B01', 'VS-BIO-MYC',  'RZB-0468',    30),
    ('BRS1-CHL-C01-B02', 'VS-BIO-ENZ',  'RZB-E190',     6),
    ('RTM1-AMB-A01-B01', 'VS-CC-50L',   'SUB-C3342',   70),
    ('RTM1-AMB-A01-B02', 'VS-NFT-CH4',  NULL,          60),
    ('RTM1-HAZ-H01-B01', 'VS-PHD-1L',   'AQL-P5531',  120)
) v(BinCode, Sku, LotNumber, Qty)
JOIN Inventory.Product  p ON p.Sku = v.Sku
JOIN Inventory.Location b ON b.LocationCode = v.BinCode AND b.LocationType = 'BIN'
LEFT JOIN Inventory.Lot lt ON lt.ProductId = p.ProductId AND lt.LotNumber = v.LotNumber;

-- Every opening balance is also an OPENING entry in the ledger, so balances
-- can always be rebuilt from the ledger alone.
INSERT INTO Inventory.StockTransaction (TxnType, ProductId, LotId, FromLocationId, ToLocationId, Quantity,
                                        UnitCost, ReferenceType, ReferenceId, TxnAt, Notes)
SELECT 'OPENING', sb.ProductId, sb.LotId, NULL, sb.LocationId, sb.QtyOnHand, p.StandardCost,
       'MIGRATION', NULL, sb.LastMovementAt, N'Opening balance migrated from legacy WMS'
FROM Inventory.StockBalance sb
JOIN Inventory.Product p ON p.ProductId = sb.ProductId;
GO

/* ===================================================================================
   6. CUSTOMERS (3-level adjacency list)
   =================================================================================== */
-- Level 0: group / independent accounts (credit limit lives here)
INSERT INTO Logistics.Customer (CustomerCode, CustomerName, CustomerType, ParentCustomerId, CountryCode,
                                CreditLimit, DefaultDiscountPct)
VALUES ('C-GRN', N'Greenhaven Urban Farms Group',     'COMMERCIAL',  NULL, 'GB', 50000.00,  7.50),
       ('C-LOF', N'Loftleaf Microgreens Ltd',         'COMMERCIAL',  NULL, 'GB', 15000.00,  5.00),
       ('C-HYD', N'Hydroponic Hut Retail Group',      'RETAIL',      NULL, 'GB', 80000.00, 12.00),
       ('C-BLM', N'Bloemrijk Teeltsystemen BV',       'DISTRIBUTOR', NULL, 'NL', 60000.00, 15.00),
       ('C-ATH', N'Atherton College of Horticulture', 'EDUCATION',   NULL, 'GB',  5000.00, 10.00),
       ('C-KLW', N'Kilnworth Vertical Greens',        'COMMERCIAL',  NULL, 'IE', 20000.00,  5.00);

-- Level 1: branches
INSERT INTO Logistics.Customer (CustomerCode, CustomerName, CustomerType, ParentCustomerId, CountryCode,
                                CreditLimit, DefaultDiscountPct)
SELECT v.Code, v.Name, v.CustType, par.CustomerId, v.Country, NULL, v.Disc
FROM (VALUES
    ('C-GRN-MAN', N'Greenhaven - Manchester Rooftop Farm',        'COMMERCIAL',  'C-GRN', 'GB', CAST(NULL AS decimal(5,2))),
    ('C-GRN-SHF', N'Greenhaven - Sheffield Arches',               'COMMERCIAL',  'C-GRN', 'GB', NULL),
    ('C-GRN-NCL', N'Greenhaven - Newcastle Quayside',             'COMMERCIAL',  'C-GRN', 'GB', NULL),
    ('C-HYD-YRK', N'Hydroponic Hut - York',                       'RETAIL',      'C-HYD', 'GB', NULL),
    ('C-HYD-LDS', N'Hydroponic Hut - Leeds Kirkstall',            'RETAIL',      'C-HYD', 'GB', NULL),
    ('C-HYD-NTH', N'Hydroponic Hut - Northern Franchise Cluster', 'RETAIL',      'C-HYD', 'GB', 10.00),
    ('C-BLM-UTR', N'Bloemrijk - Utrecht Depot',                   'DISTRIBUTOR', 'C-BLM', 'NL', NULL)
) v(Code, Name, CustType, ParentCode, Country, Disc)
JOIN Logistics.Customer par ON par.CustomerCode = v.ParentCode;

-- Level 2: franchise outlets (inherit 10 % from the cluster, not 12 % from the group)
INSERT INTO Logistics.Customer (CustomerCode, CustomerName, CustomerType, ParentCustomerId, CountryCode,
                                CreditLimit, DefaultDiscountPct)
SELECT v.Code, v.Name, 'RETAIL', par.CustomerId, 'GB', NULL, NULL
FROM (VALUES
    ('C-HYD-DUR', N'Hydroponic Hut - Durham (franchise)',    'C-HYD-NTH'),
    ('C-HYD-HGT', N'Hydroponic Hut - Harrogate (franchise)', 'C-HYD-NTH')
) v(Code, Name, ParentCode)
JOIN Logistics.Customer par ON par.CustomerCode = v.ParentCode;

INSERT INTO Logistics.CustomerAddress (CustomerId, AddressType, AddressLine1, City, PostCode, CountryCode, IsDefault)
SELECT c.CustomerId, v.AddrType, v.Line1, v.City, v.PostCode, v.Country, 1
FROM (VALUES
    ('C-GRN',     'BILLING',  N'Unit 3, Fallowfield Works',          N'Sheffield',           'S3 8GT',   'GB'),
    ('C-GRN',     'DELIVERY', N'Unit 3, Fallowfield Works',          N'Sheffield',           'S3 8GT',   'GB'),
    ('C-GRN-MAN', 'DELIVERY', N'Roof Level, 22 Ancoats Mill Yard',   N'Manchester',          'M4 6EP',   'GB'),
    ('C-GRN-SHF', 'DELIVERY', N'Arch 41, Wicker Viaduct',            N'Sheffield',           'S3 8HS',   'GB'),
    ('C-GRN-NCL', 'DELIVERY', N'9 Quayside Lane',                    N'Newcastle upon Tyne', 'NE1 3JD',  'GB'),
    ('C-LOF',     'DELIVERY', N'Loft 2, Brunswick Dye Works',        N'Halifax',             'HX1 2QL',  'GB'),
    ('C-HYD',     'BILLING',  N'Head Office, 5 Marygate Court',      N'York',                'YO30 7BH', 'GB'),
    ('C-HYD',     'DELIVERY', N'Head Office, 5 Marygate Court',      N'York',                'YO30 7BH', 'GB'),
    ('C-HYD-YRK', 'DELIVERY', N'118 Gillygate',                      N'York',                'YO31 7EQ', 'GB'),
    ('C-HYD-LDS', 'DELIVERY', N'Unit 7, Kirkstall Forge Trade Park', N'Leeds',               'LS5 3BF',  'GB'),
    ('C-HYD-NTH', 'DELIVERY', N'c/o 5 Marygate Court',               N'York',                'YO30 7BH', 'GB'),
    ('C-HYD-DUR', 'DELIVERY', N'42 Claypath',                        N'Durham',              'DH1 1QS',  'GB'),
    ('C-HYD-HGT', 'DELIVERY', N'3 Cold Bath Road',                   N'Harrogate',           'HG2 0NA',  'GB'),
    ('C-BLM',     'BILLING',  N'Teeltweg 88',                        N'Westland',            '2671 DL',  'NL'),
    ('C-BLM',     'DELIVERY', N'Teeltweg 88',                        N'Westland',            '2671 DL',  'NL'),
    ('C-BLM-UTR', 'DELIVERY', N'Depotstraat 12',                     N'Utrecht',             '3542 AD',  'NL'),
    ('C-ATH',     'DELIVERY', N'Glasshouse Block C, Mill Lane',      N'Atherton',            'M46 0RX',  'GB'),
    ('C-KLW',     'DELIVERY', N'Unit 14, Kilnworth Business Park',   N'Kildare',             'W91 KX27', 'IE')
) v(Code, AddrType, Line1, City, PostCode, Country)
JOIN Logistics.Customer c ON c.CustomerCode = v.Code;
GO

/* ===================================================================================
   7. CARRIERS & SERVICES
   =================================================================================== */
INSERT INTO Logistics.Carrier (CarrierCode, CarrierName, TransportMode)
VALUES ('CR-NTH', N'Northbound Freightways',       'ROAD'),
       ('CR-PKT', N'Parcelkite Express',           'PARCEL'),
       ('CR-ORT', N'Oranje Rail & Road Logistics', 'ROAD'),
       ('CR-SKY', N'Skyline Air Cargo',            'AIR');

INSERT INTO Logistics.CarrierService (CarrierId, ServiceCode, ServiceName, TransitDaysTarget, MaxWeightKg,
                                      BaseRate, RatePerKg, AllowsHazmat)
SELECT c.CarrierId, v.Code, v.Name, v.Transit, v.MaxKg, v.Base, v.PerKg, v.Hazmat
FROM (VALUES
    ('NTH-PAL48', 'CR-NTH', N'Pallet Economy 48h',        2, 1000.00, 38.00, 0.0450, 1),
    ('NTH-PAL24', 'CR-NTH', N'Pallet Next Day',           1, 1000.00, 52.00, 0.0600, 1),
    ('PKT-STD',   'CR-PKT', N'Parcel Standard',           3,   30.00,  6.50, 0.3500, 0),
    ('PKT-NXT',   'CR-PKT', N'Parcel Next Day',           1,   30.00,  9.90, 0.5500, 0),
    ('ORT-EU72',  'CR-ORT', N'EU Groupage 72h',           3, 1500.00, 85.00, 0.0800, 1),
    ('SKY-EXP',   'CR-SKY', N'Air Express International', 2,   70.00, 45.00, 2.1000, 0)
) v(Code, CarrierCode, Name, Transit, MaxKg, Base, PerKg, Hazmat)
JOIN Logistics.Carrier c ON c.CarrierCode = v.CarrierCode;
GO

/* ===================================================================================
   8. PURCHASING
   =================================================================================== */
INSERT INTO Inventory.PurchaseOrder (PoNumber, SupplierId, ShipToSiteId, OrderDate, ExpectedDate, Status, CreatedBy)
SELECT v.PoNumber, s.SupplierId, l.LocationId,
       DATEADD(day, v.OrderOffset,    CAST(SYSDATETIME() AS date)),
       DATEADD(day, v.ExpectedOffset, CAST(SYSDATETIME() AS date)),
       v.Status, e.EmployeeId
FROM (VALUES
    ('PO-30101', 'SUP-AQL', 'LDS1', -104, -97, 'RECEIVED'),
    ('PO-30102', 'SUP-LUM', 'LDS1',  -24,   4, 'SENT'),
    ('PO-30103', 'SUP-RZB', 'LDS1',   -6,   0, 'SENT'),
    ('PO-30104', 'SUP-FLX', 'BRS1',   -9,   3, 'SENT'),
    ('PO-30105', 'SUP-PEN', 'LDS1',   -1,   2, 'DRAFT')
) v(PoNumber, SupplierCode, SiteCode, OrderOffset, ExpectedOffset, Status)
JOIN Inventory.Supplier s ON s.SupplierCode = v.SupplierCode
JOIN Inventory.Location l ON l.LocationCode = v.SiteCode
CROSS JOIN (SELECT EmployeeId FROM Org.Employee WHERE Email = 'felix.grunewald@verdantstack.example') e;

INSERT INTO Inventory.PurchaseOrderLine (PurchaseOrderId, LineNumber, ProductId, QtyOrdered, QtyReceived, UnitCost)
SELECT po.PurchaseOrderId, v.LineNumber, p.ProductId, v.Qty, v.Received, ps.UnitCost
FROM (VALUES
    ('PO-30101', 1, 'VS-NU-A1L',  300, 300),
    ('PO-30101', 2, 'VS-NU-B1L',  300, 300),
    ('PO-30102', 1, 'VS-LED-640',  20,   0),
    ('PO-30102', 2, 'VS-LTC-DMX',  24,   0),
    ('PO-30103', 1, 'VS-BIO-MYC', 100,   0),
    ('PO-30103', 2, 'VS-BIO-ENZ',  60,   0),
    ('PO-30104', 1, 'VS-PMP-4K',   30,   0),
    ('PO-30105', 1, 'VS-TWR-FRM',  20,   0)
) v(PoNumber, LineNumber, Sku, Qty, Received)
JOIN Inventory.PurchaseOrder po ON po.PoNumber = v.PoNumber
JOIN Inventory.Product p        ON p.Sku = v.Sku
JOIN Inventory.ProductSupplier ps ON ps.ProductId = p.ProductId AND ps.SupplierId = po.SupplierId;
GO

/* ===================================================================================
   9. ORDER HISTORY (last 90 days, all delivered)
      Drives carrier KPIs, ABC analysis and customer sales roll-ups.
      ActualTransit > target transit = late delivery (generates a DELAYED event).
   =================================================================================== */
DROP TABLE IF EXISTS #HistOrders;
DROP TABLE IF EXISTS #HistLines;

CREATE TABLE #HistOrders
(
    OrderNumber    varchar(20) PRIMARY KEY,
    CustomerCode   varchar(12),
    SiteCode       varchar(30),
    ServiceCode    varchar(12),
    OrderOffset    int,
    ActualTransit  int,
    Priority       tinyint
);

INSERT INTO #HistOrders VALUES
    ('SO-41001', 'C-GRN-MAN', 'LDS1', 'NTH-PAL48', -88, 2, 2),
    ('SO-41002', 'C-LOF',     'LDS1', 'PKT-STD',   -85, 3, 2),
    ('SO-41003', 'C-HYD-YRK', 'LDS1', 'PKT-NXT',   -80, 2, 1),   -- late
    ('SO-41004', 'C-BLM-UTR', 'RTM1', 'ORT-EU72',  -78, 3, 2),
    ('SO-41005', 'C-GRN-SHF', 'LDS1', 'NTH-PAL24', -74, 1, 1),
    ('SO-41006', 'C-KLW',     'LDS1', 'SKY-EXP',   -70, 2, 1),
    ('SO-41007', 'C-HYD-LDS', 'LDS1', 'NTH-PAL48', -66, 3, 3),   -- late
    ('SO-41008', 'C-ATH',     'BRS1', 'PKT-STD',   -60, 3, 2),
    ('SO-41009', 'C-GRN-NCL', 'LDS1', 'NTH-PAL48', -55, 3, 2),   -- late
    ('SO-41010', 'C-BLM-UTR', 'RTM1', 'ORT-EU72',  -50, 3, 2),
    ('SO-41011', 'C-LOF',     'BRS1', 'PKT-NXT',   -44, 1, 1),
    ('SO-41012', 'C-HYD-DUR', 'LDS1', 'NTH-PAL48', -38, 2, 2),
    ('SO-41013', 'C-KLW',     'LDS1', 'SKY-EXP',   -30, 4, 1),   -- late
    ('SO-41014', 'C-GRN-MAN', 'LDS1', 'NTH-PAL24', -24, 1, 1),
    ('SO-41015', 'C-ATH',     'BRS1', 'PKT-STD',   -18, 2, 3),
    ('SO-41016', 'C-HYD-HGT', 'LDS1', 'PKT-NXT',   -12, 1, 2),
    ('SO-41017', 'C-BLM-UTR', 'RTM1', 'ORT-EU72',   -9, 4, 2),   -- late
    ('SO-41018', 'C-HYD-YRK', 'LDS1', 'PKT-NXT',    -6, 1, 2);

CREATE TABLE #HistLines
(
    OrderNumber  varchar(20),
    LineNumber   smallint,
    Sku          varchar(20),
    Qty          decimal(12,3),
    PRIMARY KEY (OrderNumber, LineNumber)
);

INSERT INTO #HistLines VALUES
    ('SO-41001', 1, 'VS-NU-A1L',   24), ('SO-41001', 2, 'VS-NU-B1L',   24), ('SO-41001', 3, 'VS-NFT-CH4', 10),
    ('SO-41002', 1, 'VS-RW-CUBE',  20), ('SO-41002', 2, 'VS-BIO-MYC',   4),
    ('SO-41003', 1, 'VS-SEN-WIFI',  6), ('SO-41003', 2, 'VS-PMP-2K',    4),
    ('SO-41004', 1, 'VS-CC-50L',   40), ('SO-41004', 2, 'VS-PHD-1L',   24),
    ('SO-41005', 1, 'VS-LED-320',   6), ('SO-41005', 2, 'VS-LTC-DMX',   1),
    ('SO-41006', 1, 'VS-SEN-ECP',   3), ('SO-41006', 2, 'VS-KIT-PMA',   2),
    ('SO-41007', 1, 'VS-NU-A1L',   12), ('SO-41007', 2, 'VS-PHD-1L',    6), ('SO-41007', 3, 'VS-DWC-BKT',  8),
    ('SO-41008', 1, 'VS-RW-SLAB',  10), ('SO-41008', 2, 'VS-NU-A1L',    4),
    ('SO-41009', 1, 'VS-KIT-TWR',   4), ('SO-41009', 2, 'VS-NU-A5L',    6),
    ('SO-41010', 1, 'VS-NFT-CH4',  30), ('SO-41010', 2, 'VS-CC-50L',   20),
    ('SO-41011', 1, 'VS-BIO-ENZ',   5), ('SO-41011', 2, 'VS-RW-CUBE',  10),
    ('SO-41012', 1, 'VS-LED-640',   4), ('SO-41012', 2, 'VS-KIT-DWC4',  3),
    ('SO-41013', 1, 'VS-LED-320',   2), ('SO-41013', 2, 'VS-SEN-WIFI',  4),
    ('SO-41014', 1, 'VS-TUB-16',  200), ('SO-41014', 2, 'VS-FIT-16T', 150), ('SO-41014', 3, 'VS-PMP-4K',   3),
    ('SO-41015', 1, 'VS-RW-CUBE',   6), ('SO-41015', 2, 'VS-NU-B1L',    4),
    ('SO-41016', 1, 'VS-AIR-8',     2), ('SO-41016', 2, 'VS-DWC-BKT',   6),
    ('SO-41017', 1, 'VS-CC-50L',   30), ('SO-41017', 2, 'VS-NFT-CH4',  12),
    ('SO-41018', 1, 'VS-SEN-ECP',   2), ('SO-41018', 2, 'VS-BIO-MYC',   6);

-- 9.1 Order headers (ordered at 10:00 on the offset day)
INSERT INTO Logistics.SalesOrder (OrderNumber, CustomerId, DeliveryAddressId, FulfilSiteId, RequestedServiceId,
                                  OrderedAt, PromisedDate, Priority, Status, CreatedBy)
SELECT  h.OrderNumber, c.CustomerId, a.AddressId, s.LocationId, cs.ServiceId,
        DATEADD(hour, 10, CAST(DATEADD(day, h.OrderOffset, CAST(SYSDATETIME() AS date)) AS datetime2(0))),
        DATEADD(day, h.OrderOffset + 1 + cs.TransitDaysTarget, CAST(SYSDATETIME() AS date)),
        h.Priority, 'DELIVERED', agent.EmployeeId
FROM #HistOrders h
JOIN Logistics.Customer c        ON c.CustomerCode = h.CustomerCode
JOIN Logistics.CustomerAddress a ON a.CustomerId = c.CustomerId AND a.AddressType = 'DELIVERY' AND a.IsDefault = 1
JOIN Inventory.Location s        ON s.LocationCode = h.SiteCode
JOIN Logistics.CarrierService cs ON cs.ServiceCode = h.ServiceCode
CROSS JOIN (SELECT EmployeeId FROM Org.Employee WHERE Email = 'leona.whitcombe@verdantstack.example') agent;

-- 9.2 Order lines; discount resolved up to two levels of the account tree
INSERT INTO Logistics.SalesOrderLine (SalesOrderId, LineNumber, ProductId, QtyOrdered, QtyAllocated, QtyShipped,
                                      UnitPrice, DiscountPct)
SELECT  so.SalesOrderId, hl.LineNumber, p.ProductId, hl.Qty, 0, hl.Qty, p.ListPrice,
        COALESCE(c.DefaultDiscountPct, par.DefaultDiscountPct, gpar.DefaultDiscountPct, 0)
FROM #HistLines hl
JOIN Logistics.SalesOrder so      ON so.OrderNumber = hl.OrderNumber
JOIN Inventory.Product p          ON p.Sku = hl.Sku
JOIN Logistics.Customer c         ON c.CustomerId = so.CustomerId
LEFT JOIN Logistics.Customer par  ON par.CustomerId  = c.ParentCustomerId
LEFT JOIN Logistics.Customer gpar ON gpar.CustomerId = par.ParentCustomerId;

-- 9.3 Shipments: dispatched next day 15:00, delivered ActualTransit days later at 11:00.
--     Weight = goods + 0.4 kg per carton + 22 kg pallet (road/sea over 30 kg).
INSERT INTO Logistics.Shipment (ShipmentNumber, SalesOrderId, OriginSiteId, ServiceId, TrackingNumber, Status,
                                DispatchedAt, PromisedDelivery, DeliveredAt, GrossWeightKg, FreightCost, CreatedBy)
SELECT  CONCAT('SH-', RIGHT(h.OrderNumber, 5)),
        so.SalesOrderId,
        so.FulfilSiteId,
        cs.ServiceId,
        CONCAT(car.CarrierCode, '-', RIGHT(h.OrderNumber, 5), '-H'),
        'DELIVERED',
        t.DispatchedAt,
        DATEADD(day, cs.TransitDaysTarget, CAST(t.DispatchedAt AS date)),
        DATEADD(hour, 24 * h.ActualTransit - 4, t.DispatchedAt),
        w.GrossKg,
        CAST(cs.BaseRate + cs.RatePerKg * w.GrossKg AS decimal(10,2)),
        planner.EmployeeId
FROM #HistOrders h
JOIN Logistics.SalesOrder so      ON so.OrderNumber = h.OrderNumber
JOIN Logistics.CarrierService cs  ON cs.ServiceCode = h.ServiceCode
JOIN Logistics.Carrier car        ON car.CarrierId  = cs.CarrierId
CROSS APPLY (SELECT DATEADD(hour, 29, so.OrderedAt) AS DispatchedAt) t
CROSS APPLY (SELECT SUM(sol.QtyOrdered * p.UnitWeightKg) AS NetKg, COUNT(*) AS Cartons
               FROM Logistics.SalesOrderLine sol
               JOIN Inventory.Product p ON p.ProductId = sol.ProductId
              WHERE sol.SalesOrderId = so.SalesOrderId) n
CROSS APPLY (SELECT CAST(n.NetKg + n.Cartons * 0.4
                         + CASE WHEN car.TransportMode IN ('ROAD','SEA') AND n.NetKg > 30 THEN 22 ELSE 0 END
                         AS decimal(10,3)) AS GrossKg) w
CROSS JOIN (SELECT EmployeeId FROM Org.Employee WHERE Email = 'gideon.ashworth@verdantstack.example') planner;

-- 9.4 Tracking events generated from each shipment's timeline
INSERT INTO Logistics.TrackingEvent (ShipmentId, EventCode, EventAt, LocationText, Notes)
SELECT sh.ShipmentId, e.EventCode, e.EventAt, e.LocationText, e.Notes
FROM Logistics.Shipment sh
JOIN #HistOrders h               ON CONCAT('SH-', RIGHT(h.OrderNumber, 5)) = sh.ShipmentNumber
JOIN Logistics.CarrierService cs ON cs.ServiceId = sh.ServiceId
JOIN Inventory.Location site     ON site.LocationId = sh.OriginSiteId
CROSS APPLY (VALUES
    ('PICKED_UP',        DATEADD(minute, 20, sh.DispatchedAt), CAST(site.City AS nvarchar(100)),
                         CAST(NULL AS nvarchar(200)), 1),
    ('DEPARTED',         DATEADD(hour,    2, sh.DispatchedAt), CONCAT(site.City, N' depot'), NULL, 1),
    ('ARRIVED_HUB',      DATEADD(hour,   12, sh.DispatchedAt), N'Carrier sortation hub', NULL,
                         CASE WHEN h.ActualTransit > 1 THEN 1 ELSE 0 END),
    ('DELAYED',          DATEADD(hour,   30, sh.DispatchedAt), N'Carrier sortation hub',
                         N'Trunk capacity shortfall - rolled to next departure',
                         CASE WHEN h.ActualTransit > cs.TransitDaysTarget THEN 1 ELSE 0 END),
    ('OUT_FOR_DELIVERY', DATEADD(hour,   -3, sh.DeliveredAt),  N'Local delivery unit', NULL, 1),
    ('DELIVERED',        sh.DeliveredAt,                       N'Customer premises', N'Signed for', 1)
) e(EventCode, EventAt, LocationText, Notes, IsIncluded)
WHERE e.IsIncluded = 1;

DROP TABLE #HistOrders;
DROP TABLE #HistLines;
GO

/* ===================================================================================
   LOAD SUMMARY
   =================================================================================== */
SELECT 'Org.Employee'              AS TableName, COUNT(*) AS RowsLoaded FROM Org.Employee
UNION ALL SELECT 'Inventory.Location',          COUNT(*) FROM Inventory.Location
UNION ALL SELECT '   of which BIN',             COUNT(*) FROM Inventory.Location WHERE LocationType = 'BIN'
UNION ALL SELECT 'Inventory.Category',          COUNT(*) FROM Inventory.Category
UNION ALL SELECT 'Inventory.Supplier',          COUNT(*) FROM Inventory.Supplier
UNION ALL SELECT 'Inventory.Product',           COUNT(*) FROM Inventory.Product
UNION ALL SELECT 'Inventory.ProductSupplier',   COUNT(*) FROM Inventory.ProductSupplier
UNION ALL SELECT 'Inventory.KitComponent',      COUNT(*) FROM Inventory.KitComponent
UNION ALL SELECT 'Inventory.Lot',               COUNT(*) FROM Inventory.Lot
UNION ALL SELECT 'Inventory.StockBalance',      COUNT(*) FROM Inventory.StockBalance
UNION ALL SELECT 'Inventory.StockTransaction',  COUNT(*) FROM Inventory.StockTransaction
UNION ALL SELECT 'Inventory.PurchaseOrder',     COUNT(*) FROM Inventory.PurchaseOrder
UNION ALL SELECT 'Inventory.PurchaseOrderLine', COUNT(*) FROM Inventory.PurchaseOrderLine
UNION ALL SELECT 'Logistics.Customer',          COUNT(*) FROM Logistics.Customer
UNION ALL SELECT 'Logistics.CustomerAddress',   COUNT(*) FROM Logistics.CustomerAddress
UNION ALL SELECT 'Logistics.Carrier',           COUNT(*) FROM Logistics.Carrier
UNION ALL SELECT 'Logistics.CarrierService',    COUNT(*) FROM Logistics.CarrierService
UNION ALL SELECT 'Logistics.SalesOrder',        COUNT(*) FROM Logistics.SalesOrder
UNION ALL SELECT 'Logistics.SalesOrderLine',    COUNT(*) FROM Logistics.SalesOrderLine
UNION ALL SELECT 'Logistics.Shipment',          COUNT(*) FROM Logistics.Shipment
UNION ALL SELECT 'Logistics.TrackingEvent',     COUNT(*) FROM Logistics.TrackingEvent;
GO

PRINT 'Step 4 complete: seed data loaded.';
GO


/* >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>  Step5_Demo_Showcase.sql  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< */

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

