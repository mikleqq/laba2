from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class ProfileCreate(BaseModel):
    id: int = Field(gt=0)
    email: EmailStr
    full_name: str = Field(min_length=1, max_length=100)


class ProfileUpdate(BaseModel):
    full_name: Optional[str] = Field(default=None, min_length=1, max_length=100)
    phone: Optional[str] = Field(default=None, pattern=r"^\+?[0-9 ()-]{6,20}$")
    address: Optional[str] = Field(default=None, min_length=3, max_length=255)

    model_config = ConfigDict(
        json_schema_extra={"example": {"full_name": "Alice Smith", "phone": "+373 69 123456", "address": "Chisinau"}}
    )


class ProfileOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    email: str
    full_name: str
    phone: Optional[str]
    address: Optional[str]
    created_at: datetime
    updated_at: datetime


class ProfilePage(BaseModel):
    items: list[ProfileOut]
    total: int
    limit: int
    offset: int
