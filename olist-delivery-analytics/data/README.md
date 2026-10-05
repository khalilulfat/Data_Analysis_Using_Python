# Data

## Source
**Brazilian E-Commerce Public Dataset by Olist**
https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce

Real, anonymised commercial data published by Olist: ~100k orders placed between 2016 and 2018 on Brazilian marketplaces.

## Licence
[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) - free to share and adapt for
**non-commercial** use with **attribution**, under the same licence. The files here are unmodified, only gzip-compressed.

## Files (`raw/`)
| File | Rows | Grain |
|---|---:|---|
| `olist_orders_dataset.csv.gz` | 99,441 | one row per order (core table) |
| `olist_customers_dataset.csv.gz` | 99,441 | one row per order-customer id |
| `olist_order_items_dataset.csv.gz` | 112,650 | one row per item in an order |
| `olist_order_payments_dataset.csv.gz` | 103,886 | one row per payment of an order |
| `olist_order_reviews_dataset.csv.gz` | 99,224 | one row per review |
| `olist_products_dataset.csv.gz` | 32,951 | one row per product |
| `olist_sellers_dataset.csv.gz` | 3,095 | one row per seller |
| `olist_geolocation_dataset.csv.gz` | 1,000,163 | postcode prefix -> lat/lng points |
| `product_category_name_translation.csv.gz` | 71 | Portuguese -> English category names |

Row counts are checked against the official release.

## Re-downloading
If `raw/` is empty, run:
```bash
python scripts/download_data.py
```
It uses [`kagglehub`](https://github.com/Kaggle/kagglehub) (`pip install kagglehub`). Or download the zip from the Kaggle
page above and extract the CSV files into `data/raw/` - the code reads plain `.csv` as well as `.csv.gz`.

## Processed
`processed/orders_master.csv.gz` (one row per order, ~52 columns) is created by notebook 01. It is git-ignored and rebuilt
automatically if missing.
