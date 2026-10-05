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
