"""Asynchronous messaging (RabbitMQ topic exchange) with an in-memory twin for tests.

Event envelope::

    {"event_id": "...", "event_type": "order.created", "occurred_at": "...",
     "request_id": "...", "data": {...}}

Delivery guarantees (RabbitMQ): durable exchange & queues, persistent messages,
manual ack. A message whose handler fails is rejected to a per-queue dead-letter
queue (``<queue>.dlq``). Consumers are written to be idempotent.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable, Optional

from .logging import log_extra, request_id_var, service_var

logger = logging.getLogger("shopcommon.messaging")

Event = dict[str, Any]
Handler = Callable[[Event], Awaitable[None]]


def make_event(event_type: str, data: dict[str, Any]) -> Event:
    return {
        "event_id": uuid.uuid4().hex,
        "event_type": event_type,
        "occurred_at": datetime.now(timezone.utc).isoformat(),
        "request_id": request_id_var.get(),
        "data": data,
    }


def topic_matches(pattern: str, key: str) -> bool:
    """AMQP topic matching: ``*`` = exactly one word, ``#`` = zero or more words."""
    p, k = pattern.split("."), key.split(".")

    def match(i: int, j: int) -> bool:
        if i == len(p):
            return j == len(k)
        if p[i] == "#":
            return any(match(i + 1, jj) for jj in range(j, len(k) + 1))
        if j == len(k):
            return False
        return p[i] in ("*", k[j]) and match(i + 1, j + 1)

    return match(0, 0)


async def run_handler(handler: Handler, event: Event, service_name: str) -> bool:
    rid = request_id_var.set(event.get("request_id") or uuid.uuid4().hex)
    svc = service_var.set(service_name)
    try:
        logger.info(
            "event received", extra=log_extra(event_type=event.get("event_type"), event_id=event.get("event_id"))
        )
        await handler(event)
        return True
    except Exception:  # noqa: BLE001
        logger.exception(
            "event handler failed", extra=log_extra(event_type=event.get("event_type"), event_id=event.get("event_id"))
        )
        return False
    finally:
        request_id_var.reset(rid)
        service_var.reset(svc)


class EventBus(ABC):
    @abstractmethod
    async def connect(self, retries: int = 30, delay: float = 2.0) -> None: ...

    @abstractmethod
    async def close(self) -> None: ...

    @abstractmethod
    async def publish(self, event_type: str, data: dict[str, Any]) -> Event: ...

    @abstractmethod
    async def subscribe(self, queue_name: str, routing_keys: list[str], handler: Handler, *, service_name: str) -> None: ...

    @abstractmethod
    async def is_healthy(self) -> bool: ...


async def safe_publish(bus: EventBus, event_type: str, data: dict[str, Any]) -> Optional[Event]:
    """Publish without failing the caller's already-committed operation."""
    try:
        return await bus.publish(event_type, data)
    except Exception:  # noqa: BLE001
        logger.exception("event publish failed", extra=log_extra(event_type=event_type))
        return None


class InMemoryEventBus(EventBus):
    """Process-local bus with the same semantics (topics, async delivery). Used in tests."""

    def __init__(self) -> None:
        # (queue, routing keys, handler, service, lock). The lock makes delivery to one
        # queue sequential and FIFO, like a single RabbitMQ consumer.
        self.subscriptions: list[tuple[str, list[str], Handler, str, asyncio.Lock]] = []
        self.published: list[Event] = []
        self._tasks: set[asyncio.Task] = set()

    async def connect(self, retries: int = 30, delay: float = 2.0) -> None:
        return None

    async def close(self) -> None:
        await self.join()

    async def publish(self, event_type: str, data: dict[str, Any]) -> Event:
        # Round-trip through JSON to behave exactly like a real broker.
        event = json.loads(json.dumps(make_event(event_type, data), default=str))
        self.published.append(event)
        logger.info("event published", extra=log_extra(event_type=event_type, event_id=event["event_id"]))
        for _queue, keys, handler, service_name, lock in self.subscriptions:
            if any(topic_matches(k, event_type) for k in keys):
                task = asyncio.create_task(self._deliver(lock, handler, event, service_name))
                self._tasks.add(task)
                task.add_done_callback(self._tasks.discard)
        return event

    async def subscribe(self, queue_name: str, routing_keys: list[str], handler: Handler, *, service_name: str) -> None:
        self.subscriptions.append((queue_name, list(routing_keys), handler, service_name, asyncio.Lock()))

    @staticmethod
    async def _deliver(lock: asyncio.Lock, handler: Handler, event: Event, service_name: str) -> None:
        async with lock:
            await run_handler(handler, event, service_name)

    async def is_healthy(self) -> bool:
        return True

    async def join(self) -> None:
        """Wait until all (transitively triggered) handlers have finished."""
        while True:
            pending = [t for t in self._tasks if not t.done()]
            if not pending:
                return
            await asyncio.gather(*pending, return_exceptions=True)

    def events_of(self, event_type: str) -> list[Event]:
        return [e for e in self.published if e["event_type"] == event_type]


class RabbitMQEventBus(EventBus):
    def __init__(self, url: str, *, service_name: str, exchange_name: str = "shop.events") -> None:
        self.url = url
        self.service_name = service_name
        self.exchange_name = exchange_name
        self._connection = None
        self._channel = None
        self._exchange = None
        self._dlx = None

    async def connect(self, retries: int = 30, delay: float = 2.0) -> None:
        import aio_pika

        for attempt in range(1, retries + 1):
            try:
                self._connection = await aio_pika.connect_robust(self.url)
                break
            except Exception as exc:  # noqa: BLE001
                if attempt == retries:
                    logger.error("message broker unavailable, giving up", extra=log_extra(error=str(exc)))
                    raise
                logger.warning("message broker not ready, retrying", extra=log_extra(attempt=attempt, error=str(exc)))
                await asyncio.sleep(delay)
        self._channel = await self._connection.channel()
        await self._channel.set_qos(prefetch_count=10)
        self._exchange = await self._channel.declare_exchange(
            self.exchange_name, aio_pika.ExchangeType.TOPIC, durable=True
        )
        self._dlx = await self._channel.declare_exchange(
            f"{self.exchange_name}.dlx", aio_pika.ExchangeType.DIRECT, durable=True
        )
        logger.info("connected to message broker", extra=log_extra(exchange=self.exchange_name))

    async def close(self) -> None:
        if self._connection is not None:
            await self._connection.close()

    async def publish(self, event_type: str, data: dict[str, Any]) -> Event:
        import aio_pika

        if self._exchange is None:
            raise RuntimeError("event bus is not connected")
        event = make_event(event_type, data)
        message = aio_pika.Message(
            body=json.dumps(event, default=str).encode(),
            content_type="application/json",
            delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
            message_id=event["event_id"],
            type=event_type,
            headers={"x-request-id": event["request_id"]},
        )
        await self._exchange.publish(message, routing_key=event_type)
        logger.info("event published", extra=log_extra(event_type=event_type, event_id=event["event_id"]))
        return event

    async def subscribe(self, queue_name: str, routing_keys: list[str], handler: Handler, *, service_name: str) -> None:
        dlq = await self._channel.declare_queue(f"{queue_name}.dlq", durable=True)
        await dlq.bind(self._dlx, routing_key=queue_name)
        queue = await self._channel.declare_queue(
            queue_name,
            durable=True,
            arguments={"x-dead-letter-exchange": f"{self.exchange_name}.dlx", "x-dead-letter-routing-key": queue_name},
        )
        for key in routing_keys:
            await queue.bind(self._exchange, routing_key=key)

        async def on_message(message) -> None:
            try:
                event = json.loads(message.body)
            except ValueError:
                logger.error("malformed message rejected", extra=log_extra(queue=queue_name))
                await message.reject(requeue=False)
                return
            if await run_handler(handler, event, service_name):
                await message.ack()
            else:
                await message.reject(requeue=False)  # -> dead-letter queue

        await queue.consume(on_message)
        logger.info("subscribed", extra=log_extra(queue=queue_name, routing_keys=routing_keys))

    async def is_healthy(self) -> bool:
        return self._connection is not None and not self._connection.is_closed
