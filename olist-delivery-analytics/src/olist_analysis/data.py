"""Loading, cleaning and modelling the Olist e-commerce dataset.

Everything in the notebooks goes through these functions, so the logic is
written (and tested) once.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[2]
RAW_DIR = PROJECT_ROOT / "data" / "raw"
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
FIGURES_DIR = PROJECT_ROOT / "reports" / "figures"

RAW_FILES = {
    "orders": "olist_orders_dataset",
    "customers": "olist_customers_dataset",
    "items": "olist_order_items_dataset",
    "payments": "olist_order_payments_dataset",
    "reviews": "olist_order_reviews_dataset",
    "products": "olist_products_dataset",
    "sellers": "olist_sellers_dataset",
    "geolocation": "olist_geolocation_dataset",
    "category_translation": "product_category_name_translation",
}

ORDER_DATE_COLUMNS = [
    "order_purchase_timestamp",
    "order_approved_at",
    "order_delivered_carrier_date",
    "order_delivered_customer_date",
    "order_estimated_delivery_date",
]

# Brazil's five official macro-regions
STATE_REGION = {
    **dict.fromkeys(["AC", "AM", "AP", "PA", "RO", "RR", "TO"], "North"),
    **dict.fromkeys(["AL", "BA", "CE", "MA", "PB", "PE", "PI", "RN", "SE"], "Northeast"),
    **dict.fromkeys(["DF", "GO", "MS", "MT"], "Center-West"),
    **dict.fromkeys(["ES", "MG", "RJ", "SP"], "Southeast"),
    **dict.fromkeys(["PR", "RS", "SC"], "South"),
}

# Rough bounding box of Brazil, used to drop mis-geocoded postcodes
BRAZIL_LAT = (-34.0, 5.5)
BRAZIL_LNG = (-74.0, -34.0)


# --------------------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------------------
def _find_file(stem: str) -> Path:
    """Accept either the compressed (.csv.gz) or plain (.csv) version of a file."""
    for suffix in (".csv.gz", ".csv"):
        path = RAW_DIR / f"{stem}{suffix}"
        if path.exists():
            return path
    raise FileNotFoundError(
        f"{stem}.csv(.gz) not found in {RAW_DIR}. "
        "Run `python scripts/download_data.py` or see data/README.md."
    )


def load_raw() -> dict[str, pd.DataFrame]:
    """Load all nine raw tables into a dict of DataFrames."""
    tables = {name: pd.read_csv(_find_file(stem)) for name, stem in RAW_FILES.items()}

    for col in ORDER_DATE_COLUMNS:
        tables["orders"][col] = pd.to_datetime(tables["orders"][col])
    tables["items"]["shipping_limit_date"] = pd.to_datetime(tables["items"]["shipping_limit_date"])
    for col in ("review_creation_date", "review_answer_timestamp"):
        tables["reviews"][col] = pd.to_datetime(tables["reviews"][col])
    return tables


# --------------------------------------------------------------------------------------
# Data-quality checks
# --------------------------------------------------------------------------------------
def key_checks(t: dict[str, pd.DataFrame]) -> pd.DataFrame:
    """Primary-key uniqueness and foreign-key coverage between the tables."""
    rows = []

    def pk(table, cols):
        dupes = int(t[table].duplicated(subset=cols).sum())
        rows.append({"check": f"PK {table}({', '.join(cols)})", "violations": dupes})

    def fk(child, child_col, parent, parent_col):
        missing = int((~t[child][child_col].isin(t[parent][parent_col])).sum())
        rows.append({"check": f"FK {child}.{child_col} -> {parent}.{parent_col}", "violations": missing})

    pk("orders", ["order_id"])
    pk("customers", ["customer_id"])
    pk("items", ["order_id", "order_item_id"])
    pk("payments", ["order_id", "payment_sequential"])
    pk("products", ["product_id"])
    pk("sellers", ["seller_id"])
    pk("reviews", ["review_id", "order_id"])
    fk("orders", "customer_id", "customers", "customer_id")
    fk("items", "order_id", "orders", "order_id")
    fk("items", "product_id", "products", "product_id")
    fk("items", "seller_id", "sellers", "seller_id")
    fk("payments", "order_id", "orders", "order_id")
    fk("reviews", "order_id", "orders", "order_id")
    return pd.DataFrame(rows)


# --------------------------------------------------------------------------------------
# Cleaning helpers
# --------------------------------------------------------------------------------------
def zip_centroids(geo: pd.DataFrame) -> pd.DataFrame:
    """One median lat/lng per 5-digit postcode prefix, after removing points outside Brazil."""
    inside = geo["geolocation_lat"].between(*BRAZIL_LAT) & geo["geolocation_lng"].between(*BRAZIL_LNG)
    return (
        geo.loc[inside]
        .groupby("geolocation_zip_code_prefix", as_index=False)[["geolocation_lat", "geolocation_lng"]]
        .median()
        .rename(columns={"geolocation_zip_code_prefix": "zip_prefix", "geolocation_lat": "lat", "geolocation_lng": "lng"})
    )


def haversine_km(lat1, lng1, lat2, lng2) -> np.ndarray:
    """Great-circle distance in km (vectorised)."""
    lat1, lng1, lat2, lng2 = map(np.radians, (lat1, lng1, lat2, lng2))
    a = np.sin((lat2 - lat1) / 2) ** 2 + np.cos(lat1) * np.cos(lat2) * np.sin((lng2 - lng1) / 2) ** 2
    return 6371.0 * 2 * np.arcsin(np.sqrt(a))


def english_products(products: pd.DataFrame, translation: pd.DataFrame) -> pd.DataFrame:
    """Products with English category names; untranslated / missing become 'other'."""
    out = products.merge(translation, on="product_category_name", how="left")
    out["category"] = (
        out["product_category_name_english"]
        .fillna(out["product_category_name"])
        .fillna("unknown")
        .str.replace("_", " ")
    )
    return out


def latest_review_per_order(reviews: pd.DataFrame) -> pd.DataFrame:
    """Some orders have several reviews: keep the most recently answered one."""
    return (
        reviews.sort_values("review_answer_timestamp")
        .drop_duplicates(subset="order_id", keep="last")
        [["order_id", "review_score", "review_comment_title", "review_comment_message", "review_creation_date"]]
    )


# --------------------------------------------------------------------------------------
# Master table: one row per order
# --------------------------------------------------------------------------------------
def build_order_table(t: dict[str, pd.DataFrame]) -> pd.DataFrame:
    """Join the nine raw tables into a single analysis-ready table, one row per order."""
    orders, customers, items, payments = t["orders"], t["customers"], t["items"], t["payments"]
    products = english_products(t["products"], t["category_translation"])
    centroids = zip_centroids(t["geolocation"])

    # ---- items -> order level --------------------------------------------------------
    items_p = items.merge(products[["product_id", "category", "product_weight_g"]], on="product_id", how="left")
    # "main" item of an order = the most expensive one; its category and seller describe the order
    main_item = (
        items_p.sort_values(["order_id", "price"], ascending=[True, False])
        .drop_duplicates("order_id")[["order_id", "category", "seller_id"]]
        .rename(columns={"category": "main_category", "seller_id": "main_seller_id"})
    )
    item_agg = items_p.groupby("order_id").agg(
        n_items=("order_item_id", "count"),
        n_sellers=("seller_id", "nunique"),
        items_value=("price", "sum"),
        freight_value=("freight_value", "sum"),
        total_weight_kg=("product_weight_g", lambda s: s.sum() / 1000),
        shipping_limit=("shipping_limit_date", "max"),
    )

    # ---- payments -> order level -----------------------------------------------------
    pay_agg = payments.groupby("order_id").agg(
        payment_value=("payment_value", "sum"),
        max_installments=("payment_installments", "max"),
    )
    main_payment = (
        payments.sort_values(["order_id", "payment_value"], ascending=[True, False])
        .drop_duplicates("order_id")[["order_id", "payment_type"]]
    )

    # ---- assemble --------------------------------------------------------------------
    df = (
        orders.merge(customers, on="customer_id", how="left")
        .merge(item_agg, on="order_id", how="left")
        .merge(main_item, on="order_id", how="left")
        .merge(pay_agg, on="order_id", how="left")
        .merge(main_payment, on="order_id", how="left")
        .merge(latest_review_per_order(t["reviews"]), on="order_id", how="left")
        .merge(
            t["sellers"].rename(columns={
                "seller_id": "main_seller_id",
                "seller_zip_code_prefix": "seller_zip_prefix",
                "seller_city": "seller_city",
                "seller_state": "seller_state",
            }),
            on="main_seller_id", how="left",
        )
    )

    # ---- geography -------------------------------------------------------------------
    df = df.merge(
        centroids.rename(columns={"zip_prefix": "customer_zip_code_prefix", "lat": "customer_lat", "lng": "customer_lng"}),
        on="customer_zip_code_prefix", how="left",
    ).merge(
        centroids.rename(columns={"zip_prefix": "seller_zip_prefix", "lat": "seller_lat", "lng": "seller_lng"}),
        on="seller_zip_prefix", how="left",
    )
    df["distance_km"] = haversine_km(df["seller_lat"], df["seller_lng"], df["customer_lat"], df["customer_lng"])

    # ---- delivery timeline -----------------------------------------------------------
    purchase = df["order_purchase_timestamp"]
    delivered = df["order_delivered_customer_date"]
    estimated = df["order_estimated_delivery_date"]

    df["approval_hours"] = (df["order_approved_at"] - purchase).dt.total_seconds() / 3600
    df["handling_days"] = (df["order_delivered_carrier_date"] - purchase).dt.total_seconds() / 86400
    df["transit_days"] = (delivered - df["order_delivered_carrier_date"]).dt.total_seconds() / 86400
    # stage timings only where the timeline is consistent (carrier scan between purchase and delivery)
    df["timeline_consistent"] = df["handling_days"].ge(0) & df["transit_days"].ge(0)
    df.loc[~df["timeline_consistent"], ["handling_days", "transit_days"]] = np.nan
    df["delivery_days"] = (delivered - purchase).dt.total_seconds() / 86400
    df["promised_days"] = (estimated - purchase).dt.total_seconds() / 86400
    # positive = late; the estimate is a date, so compare calendar dates
    df["delay_days"] = (delivered.dt.normalize() - estimated.dt.normalize()).dt.days
    df["is_delivered"] = df["order_status"].eq("delivered") & delivered.notna()
    df["is_late"] = np.where(df["is_delivered"], df["delay_days"] > 0, np.nan)
    df["seller_missed_handover"] = df["order_delivered_carrier_date"] > df["shipping_limit"]

    # ---- calendar & ratios -----------------------------------------------------------
    df["purchase_month"] = purchase.dt.to_period("M").dt.to_timestamp()
    df["purchase_weekday"] = purchase.dt.day_name()
    df["purchase_hour"] = purchase.dt.hour
    df["freight_ratio"] = df["freight_value"] / df["items_value"]
    df["is_low_review"] = np.where(df["review_score"].notna(), df["review_score"] <= 2, np.nan)
    df["same_state"] = df["customer_state"].eq(df["seller_state"])
    df["customer_region"] = df["customer_state"].map(STATE_REGION)

    return df


def save_order_table(df: pd.DataFrame, name: str = "orders_master.csv.gz") -> Path:
    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    path = PROCESSED_DIR / name
    df.to_csv(path, index=False, compression="gzip")
    return path


def load_order_table(name: str = "orders_master.csv.gz") -> pd.DataFrame:
    """Load the master table written by notebook 01 (rebuilds it if missing)."""
    path = PROCESSED_DIR / name
    if not path.exists():
        save_order_table(build_order_table(load_raw()), name)
    date_cols = ORDER_DATE_COLUMNS + ["shipping_limit", "purchase_month", "review_creation_date"]
    df = pd.read_csv(path, parse_dates=date_cols, low_memory=False)
    for col in ("is_late", "is_low_review"):
        df[col] = df[col].astype("float")
    return df
