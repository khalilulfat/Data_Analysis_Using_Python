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
