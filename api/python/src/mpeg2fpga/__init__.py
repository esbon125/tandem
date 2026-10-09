"""Python client for the mpeg2fpga MPEG-2 decoder appliance (protocol v1).

    from mpeg2fpga import Device

    dev = Device("192.168.18.5", token="...")
    for frame in dev.decode("clip.m2v"):
        frame.y, frame.u, frame.v

See api/PROTOCOL-v1.md for the protocol this speaks.
"""

from ._version import __version__
from .client import DecodeResult, Device, Frame
from .errors import (BadRequest, DecodeIncomplete, DecoderUnavailable, DeviceBusy,
                     DeviceError, FingerprintMismatch, NotFound, ProtocolError,
                     TooManyAttempts, Unauthorized)

__all__ = [
    "__version__", "Device", "DecodeResult", "Frame",
    "DeviceError", "BadRequest", "Unauthorized", "NotFound", "DeviceBusy",
    "TooManyAttempts", "DecoderUnavailable", "DecodeIncomplete",
    "FingerprintMismatch", "ProtocolError",
]
