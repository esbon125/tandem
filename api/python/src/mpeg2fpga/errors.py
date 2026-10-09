"""Exceptions for protocol v1 errors (api/PROTOCOL-v1.md, section 2.3)."""

from .protocol import ProtocolError  # noqa: F401  (re-exported)


class DeviceError(Exception):
    """The device answered with an error. `code` is the protocol's error code."""

    def __init__(self, status, code, message, retryable=False):
        super().__init__("%d %s: %s" % (status, code, message))
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable


class BadRequest(DeviceError):
    pass


class Unauthorized(DeviceError):
    pass


class NotFound(DeviceError):
    pass


class DeviceBusy(DeviceError):
    """Another decode is running; the device has one decoder."""

    def __init__(self, *args, retry_after=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.retry_after = retry_after


class TooManyAttempts(DeviceError):
    pass


class DecoderUnavailable(DeviceError):
    """The hardware is not responding; Device.reset() may recover it."""


class DecodeIncomplete(Exception):
    """The frame stream ended without its END record (connection lost)."""


class FingerprintMismatch(Exception):
    """TLS certificate does not match the pinned fingerprint."""


_BY_STATUS = {400: BadRequest, 401: Unauthorized, 404: NotFound, 409: DeviceBusy,
              429: TooManyAttempts, 503: DecoderUnavailable}


def from_response(status, body, headers):
    """Build the right exception for an HTTP error response."""
    import json

    try:
        err = json.loads(body.decode("utf-8"))["error"]
        code, message, retryable = err["code"], err.get("message", ""), err.get("retryable", False)
    except Exception:  # noqa: BLE001 - a non-protocol error body still deserves an exception
        code, message, retryable = "http_%d" % status, body[:200].decode("utf-8", "replace"), False
    cls = _BY_STATUS.get(status, DeviceError)
    if cls is DeviceBusy:
        retry_after = headers.get("retry-after")
        return DeviceBusy(status, code, message, retryable,
                          retry_after=float(retry_after) if retry_after else None)
    return cls(status, code, message, retryable)
