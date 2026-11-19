from shopcommon.config import BaseServiceSettings


class Settings(BaseServiceSettings):
    service_name: str = "api-gateway"

    auth_service_url: str = "http://auth-service:8000"
    user_service_url: str = "http://user-service:8000"
    product_service_url: str = "http://product-service:8000"
    order_service_url: str = "http://order-service:8000"
    payment_service_url: str = "http://payment-service:8000"
    notification_service_url: str = "http://notification-service:8000"

    rate_limit_requests: int = 100
    rate_limit_window_seconds: int = 60
    http_timeout_seconds: float = 10.0

    def upstreams(self) -> dict[str, str]:
        """Public path segment (/api/<segment>) -> upstream base URL."""
        return {
            "auth": self.auth_service_url,
            "users": self.user_service_url,
            "products": self.product_service_url,
            "orders": self.order_service_url,
            "payments": self.payment_service_url,
            "notifications": self.notification_service_url,
        }
