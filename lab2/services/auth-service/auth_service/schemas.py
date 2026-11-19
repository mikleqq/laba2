from pydantic import BaseModel, ConfigDict, EmailStr, Field


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    full_name: str = Field(min_length=1, max_length=100)

    model_config = ConfigDict(
        json_schema_extra={"example": {"email": "alice@example.com", "password": "Secret123!", "full_name": "Alice"}}
    )


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)

    model_config = ConfigDict(json_schema_extra={"example": {"email": "alice@example.com", "password": "Secret123!"}})


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    email: str
    role: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int = Field(description="Lifetime in seconds")
    user: UserOut
