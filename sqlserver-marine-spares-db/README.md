# Marine Spares Database - SQL Server

[![Build database](https://github.com/khalilulfat/sqlserver-marine-spares-db/actions/workflows/build-database.yml/badge.svg)](https://github.com/YOUR-USERNAME/sqlserver-marine-spares-db/actions/workflows/build-database.yml)
![SQL Server](https://img.shields.io/badge/SQL%20Server-2017%2B-CC2927)
![T-SQL](https://img.shields.io/badge/T--SQL-procedures%20%7C%20views-blue)

**HarbourlineDB** is a compact, clean design for a fictional marine spare-parts distributor with stores in Southampton,
Aberdeen and Falmouth - **10 tables, 7 views, 7 stored procedures** in one script. All data is invented.

Every hierarchy is exactly **two levels** deep:

| Parent | Child | Purpose |
|---|---|---|
| Warehouse | StorageBin | where stock is kept |
| ProductGroup | Product | what is sold |
| SalesOrder | SalesOrderLine | what was ordered |

…connected through Supplier, Customer, StockLevel (product × bin) and StockMovement (the stock ledger).

## Highlights

- **Two-level tree in one view** - `vw_WarehouseBinTree` returns each warehouse with totals, followed by its bins (`UNION ALL` + sort key).
- **Group subtotals with `ROLLUP`** - `vw_SalesByGroup` gives product detail, group subtotals and a grand total in one query.
- **Committed vs available stock** - open orders reserve stock per warehouse; inter-warehouse transfers cannot take promised stock.
- **Set-based picking** - `usp_ShipOrder` picks every line in one statement using a running total, emptying the smallest bins first.
- **Business rules in procedures** - bin weight limits, secure storage for distress beacons, credit limits, no double shipping.
- **Ledger reconciliation** - stock rebuilt from `StockMovement` must equal `StockLevel` (the demo checks it: 0 mismatches expected).

## Run it

Open **`HarbourlineDB_Complete.sql`** in SSMS and press **F5**. It builds the database, loads the data, runs a demo through the
procedures (with five deliberately rejected actions) and prints nine showcase result sets. The database diagram is at the end of
the file and below. Requires SQL Server 2017 or later.

## Entity-relationship diagram

```mermaid
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
```

---
**YOUR NAME** · [LinkedIn](https://www.linkedin.com/in/khalil-aulfat) · [GitHub](https://github.com/khalilulfat)
