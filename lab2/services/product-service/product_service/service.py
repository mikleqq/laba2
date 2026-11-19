"""Business logic of the Product Service (catalog + stock reservation)."""

import logging
from collections import OrderedDict
from decimal import Decimal

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from shopcommon.errors import BadRequestError, ConflictError, NotFoundError
from shopcommon.logging import log_extra
from shopcommon.messaging import EventBus, safe_publish

from .models import Product
from .schemas import ProductCreate, ProductUpdate, ReservedItem, StockItem

logger = logging.getLogger("product_service")

DEMO_PRODUCTS = [
    ("Mechanical keyboard", "electronics", "89.99", 25, "Hot-swappable switches, RGB backlight"),
    ("Wireless mouse", "electronics", "29.50", 40, "Ergonomic, 2.4 GHz"),
    ("27\" 4K monitor", "electronics", "349.00", 10, "IPS panel, USB-C"),
    ("Clean Architecture (book)", "books", "32.00", 15, "Robert C. Martin"),
    ("Coffee mug", "home", "9.90", 100, "350 ml, ceramic"),
]


def merge_items(items: list[StockItem]) -> "OrderedDict[int, int]":
    merged: "OrderedDict[int, int]" = OrderedDict()
    for item in items:
        merged[item.product_id] = merged.get(item.product_id, 0) + item.quantity
    return merged


class ProductService:
    def __init__(self, session: AsyncSession, bus: EventBus | None = None, low_stock_threshold: int = 3) -> None:
        self.session = session
        self.bus = bus
        self.low_stock_threshold = low_stock_threshold

    # ---------- catalog ----------
    async def list_all(self, *, search: str | None, category: str | None, limit: int, offset: int):
        query = select(Product)
        if search:
            pattern = f"%{search.lower()}%"
            query = query.where(or_(func.lower(Product.name).like(pattern), func.lower(Product.description).like(pattern)))
        if category:
            query = query.where(Product.category == category)
        total = await self.session.scalar(select(func.count()).select_from(query.subquery()))
        rows = await self.session.scalars(query.order_by(Product.id).limit(limit).offset(offset))
        return list(rows), int(total or 0)

    async def get(self, product_id: int) -> Product:
        product = await self.session.get(Product, product_id)
        if product is None:
            raise NotFoundError(f"Product {product_id} not found")
        return product

    async def create(self, data: ProductCreate) -> Product:
        product = Product(**data.model_dump())
        self.session.add(product)
        await self.session.commit()
        logger.info("product created", extra=log_extra(product_id=product.id))
        return product

    async def update(self, product_id: int, data: ProductUpdate) -> Product:
        product = await self.get(product_id)
        changes = data.model_dump(exclude_unset=True, exclude_none=True)
        if not changes:
            raise BadRequestError("Nothing to update")
        for field, value in changes.items():
            setattr(product, field, value)
        await self.session.commit()
        logger.info("product updated", extra=log_extra(product_id=product_id, fields=sorted(changes)))
        return product

    async def delete(self, product_id: int) -> None:
        product = await self.get(product_id)
        await self.session.delete(product)
        await self.session.commit()
        logger.info("product deleted", extra=log_extra(product_id=product_id))

    # ---------- stock (internal API used by order-service) ----------
    async def reserve(self, items: list[StockItem]) -> list[ReservedItem]:
        """All-or-nothing stock reservation inside a single transaction."""
        merged = merge_items(items)
        rows = await self.session.scalars(
            select(Product).where(Product.id.in_(merged.keys())).with_for_update()
        )
        products = {p.id: p for p in rows}
        reserved: list[ReservedItem] = []
        for product_id, quantity in merged.items():
            product = products.get(product_id)
            if product is None:
                await self.session.rollback()
                raise NotFoundError(f"Product {product_id} not found")
            if product.stock < quantity:
                error = ConflictError(
                    f"Insufficient stock for '{product.name}': requested {quantity}, available {product.stock}",
                    code="insufficient_stock",
                )
                await self.session.rollback()  # undo decrements of previous items
                raise error
            product.stock -= quantity
            reserved.append(
                ReservedItem(product_id=product.id, name=product.name, unit_price=Decimal(product.price), quantity=quantity)
            )
        await self.session.commit()
        logger.info("stock reserved", extra=log_extra(items=dict(merged)))
        await self._notify_low_stock([products[pid] for pid in merged])
        return reserved

    async def release(self, items: list[StockItem]) -> None:
        merged = merge_items(items)
        rows = await self.session.scalars(select(Product).where(Product.id.in_(merged.keys())).with_for_update())
        for product in rows:
            product.stock += merged[product.id]
        await self.session.commit()
        logger.info("stock released", extra=log_extra(items=dict(merged)))

    async def _notify_low_stock(self, products: list[Product]) -> None:
        if self.bus is None:
            return
        for product in products:
            if product.stock <= self.low_stock_threshold:
                await safe_publish(
                    self.bus, "product.low_stock", {"product_id": product.id, "name": product.name, "stock": product.stock}
                )

    async def seed(self) -> None:
        count = await self.session.scalar(select(func.count()).select_from(Product))
        if count:
            return
        for name, category, price, stock, description in DEMO_PRODUCTS:
            self.session.add(Product(name=name, category=category, price=Decimal(price), stock=stock, description=description))
        await self.session.commit()
        logger.info("demo catalog seeded", extra=log_extra(products=len(DEMO_PRODUCTS)))
