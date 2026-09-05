#!/usr/bin/env python3
"""Dependency-free PNG comparison for the WPT reftest runner."""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import BinaryIO
import zlib


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


@dataclass(frozen=True)
class Image:
    width: int
    height: int
    pixels: bytes


def _unfilter(raw: bytes, width: int, height: int, channels: int) -> bytes:
    stride = width * channels
    expected = height * (stride + 1)
    if len(raw) != expected:
        raise ValueError("PNG scanline data has an unexpected length")
    output = bytearray(height * stride)
    offset = 0
    for row in range(height):
        filter_type = raw[offset]
        offset += 1
        current = bytearray(raw[offset : offset + stride])
        offset += stride
        previous_start = (row - 1) * stride
        current_start = row * stride
        for index in range(stride):
            left = current[index - channels] if index >= channels else 0
            above = output[previous_start + index] if row else 0
            upper_left = output[previous_start + index - channels] if row and index >= channels else 0
            if filter_type == 1:
                current[index] = (current[index] + left) & 0xFF
            elif filter_type == 2:
                current[index] = (current[index] + above) & 0xFF
            elif filter_type == 3:
                current[index] = (current[index] + ((left + above) // 2)) & 0xFF
            elif filter_type == 4:
                estimate = left + above - upper_left
                distance_left = abs(estimate - left)
                distance_above = abs(estimate - above)
                distance_upper_left = abs(estimate - upper_left)
                predictor = (
                    left
                    if distance_left <= distance_above and distance_left <= distance_upper_left
                    else above
                    if distance_above <= distance_upper_left
                    else upper_left
                )
                current[index] = (current[index] + predictor) & 0xFF
            elif filter_type != 0:
                raise ValueError(f"unsupported PNG filter {filter_type}")
        output[current_start : current_start + stride] = current
    return bytes(output)


def read_png(stream: BinaryIO) -> Image:
    if stream.read(8) != PNG_SIGNATURE:
        raise ValueError("not a PNG image")
    width = height = bit_depth = color_type = interlace = None
    compressed = bytearray()
    while True:
        header = stream.read(8)
        if len(header) != 8:
            raise ValueError("truncated PNG chunk")
        length, chunk_type = struct.unpack(">I4s", header)
        data = stream.read(length)
        checksum = stream.read(4)
        if len(data) != length or len(checksum) != 4:
            raise ValueError("truncated PNG chunk data")
        if chunk_type == b"IHDR":
            if length != 13:
                raise ValueError("invalid PNG header")
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
                ">IIBBBBB", data
            )
            if bit_depth != 8 or compression != 0 or filtering != 0 or interlace != 0:
                raise ValueError("PNG must be 8-bit, non-interlaced RGBA or RGB")
            if color_type not in (2, 6):
                raise ValueError("PNG must use RGB or RGBA pixels")
        elif chunk_type == b"IDAT":
            compressed.extend(data)
        elif chunk_type == b"IEND":
            break
    if width is None or height is None or color_type is None:
        raise ValueError("PNG is missing IHDR")
    channels = 4 if color_type == 6 else 3
    decoded = _unfilter(zlib.decompress(bytes(compressed)), width, height, channels)
    if channels == 4:
        return Image(width, height, decoded)
    rgba = bytearray(width * height * 4)
    for source, destination in zip(range(0, len(decoded), 3), range(0, len(rgba), 4)):
        rgba[destination : destination + 3] = decoded[source : source + 3]
        rgba[destination + 3] = 255
    return Image(width, height, bytes(rgba))


def load_png(path: str) -> Image:
    with open(path, "rb") as stream:
        return read_png(stream)


def compare_png(
    expected_path: str,
    actual_path: str,
    *,
    ignored_top_rows: int = 70,
    max_difference: int = 0,
    max_different_pixels: int = 0,
) -> dict[str, int | bool | list[int] | None]:
    """Compare page pixels and return serializable diagnostics.

    Zibra's current screenshot command includes a stable chrome strip above the
    page. Reftests ignore that strip while comparing the page viewport. WPT's
    fuzzy metadata maps to a maximum per-channel difference and a maximum
    number of differing pixels.
    """
    expected = load_png(expected_path)
    actual = load_png(actual_path)
    if (expected.width, expected.height) != (actual.width, actual.height):
        return {
            "passed": False,
            "width": actual.width,
            "height": actual.height,
            "expected_width": expected.width,
            "expected_height": expected.height,
            "different_pixels": -1,
            "max_channel_delta": -1,
            "first_difference": None,
        }
    first_row = min(max(ignored_top_rows, 0), expected.height)
    different_pixels = 0
    max_channel_delta = 0
    first_difference: list[int] | None = None
    for row in range(first_row, expected.height):
        for column in range(expected.width):
            expected_offset = (row * expected.width + column) * 4
            actual_pixel = actual.pixels[expected_offset : expected_offset + 4]
            expected_pixel = expected.pixels[expected_offset : expected_offset + 4]
            delta = max(abs(left - right) for left, right in zip(expected_pixel, actual_pixel))
            if delta == 0:
                continue
            different_pixels += 1
            max_channel_delta = max(max_channel_delta, delta)
            if first_difference is None:
                first_difference = [column, row]
    passed = (
        different_pixels <= max_different_pixels
        and max_channel_delta <= max_difference
    )
    return {
        "passed": passed,
        "width": expected.width,
        "height": expected.height,
        "different_pixels": different_pixels,
        "max_channel_delta": max_channel_delta,
        "first_difference": first_difference,
    }
