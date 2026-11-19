from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

from shopcommon.schemas import Money


class OrderItemIn(BaseModel):
    product_id: int = Field(gt=0)
    quantity: int = Field(gt=0, le=1000)


class OrderCreate(BaseModel):
    items: list[OrderItemIn] = Field(min_length=1, max_length=50)

    model_config = ConfigDict(json_schema_extra={"example": {"items": [{"product_id": 1, "quantity": 2}]}})


class OrderItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    product_id: int
    product_name: str
    unit_price: Money
    quantity: int


class OrderOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    user_id: int
    status: str
    total_amount: Money
    items: list[OrderItemOut]
    created_at: datetime
    updated_at: datetime


class OrderPage(BaseModel):
    items: list[OrderOut]
    total: int
    limit: int
    offset: int
