#!/usr/bin/env python3
"""Generate synthetic winmail.dat (TNEF) fixtures for tests.

Usage: python3 -I scripts/make_fixtures.py <output-dir>

Writes basic.dat, html.dat and rtf-only.dat. The files follow MS-OXTNEF and
MS-OXRTFCP closely enough that the `tnef` CLI can unpack them, which the tests
use as an independent check.
"""
import struct
import sys
import zlib
from pathlib import Path

# --- TNEF attribute ids (type in high word, id in low word) ---------------
ATT_FROM = 0x00008000
ATT_SUBJECT = 0x00018004
ATT_DATE_SENT = 0x00038005
ATT_BODY = 0x0002800C
ATT_MSG_PROPS = 0x00069003
ATT_TNEF_VERSION = 0x00089006
ATT_OEM_CODEPAGE = 0x00069007
ATT_MESSAGE_CLASS = 0x00078008
ATT_ATTACH_RENDDATA = 0x00069002
ATT_ATTACH_TITLE = 0x00018010
ATT_ATTACH_DATA = 0x0006800F
ATT_ATTACHMENT = 0x00069005

LVL_MESSAGE = 1
LVL_ATTACHMENT = 2

# --- MAPI property types / ids --------------------------------------------
PT_LONG = 0x0003
PT_BOOLEAN = 0x000B
PT_STRING8 = 0x001E
PT_UNICODE = 0x001F
PT_SYSTIME = 0x0040
PT_BINARY = 0x0102

PR_BODY = 0x1000
PR_RTF_COMPRESSED = 0x1009
PR_BODY_HTML = 0x1013
PR_INTERNET_CPID = 0x3FDE
PR_ATTACH_LONG_FILENAME = 0x3707
PR_ATTACH_MIME_TAG = 0x370E
PR_DISPLAY_NAME = 0x3001

RTF_PREBUF = (
    b"{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman "
    b"\\fswiss \\fmodern \\fscript \\fdecor MS Sans SerifSymbolArialTimes New "
    b"RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par "
    b"\\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx"
)
assert len(RTF_PREBUF) == 207, len(RTF_PREBUF)


def attribute(level: int, att_id: int, data: bytes) -> bytes:
    checksum = sum(data) & 0xFFFF
    return struct.pack("<BII", level, att_id, len(data)) + data + struct.pack("<H", checksum)


def pad4(data: bytes) -> bytes:
    return data + b"\0" * (-len(data) % 4)


def prop_variable(ptype: int, pid: int, value: bytes) -> bytes:
    return struct.pack("<HHII", ptype, pid, 1, len(value)) + pad4(value)


def prop_long(pid: int, value: int) -> bytes:
    return struct.pack("<HHI", PT_LONG, pid, value)


def unicode_z(text: str) -> bytes:
    return (text + "\0").encode("utf-16-le")


def mapi_props(*props: bytes) -> bytes:
    return struct.pack("<I", len(props)) + b"".join(props)


def dtr(year, month, day, hour, minute, second, weekday) -> bytes:
    return struct.pack("<7H", year, month, day, hour, minute, second, weekday)


def renddata() -> bytes:
    # attachment type 1 = file, position 0xFFFFFFFF, no width/height, flags 0
    return struct.pack("<HIHHI", 1, 0xFFFFFFFF, 0, 0, 0)


def crc32_rtf(data: bytes) -> int:
    # MS-OXRTFCP CRC: standard table, initial value 0, no final xor.
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xEDB88320 if crc & 1 else 0)
    return crc


def compress_rtf(raw: bytes) -> bytes:
    """Greedy LZFu compressor (MS-OXRTFCP) that also uses back references."""
    history = bytearray(RTF_PREBUF)
    out = bytearray()
    pos = 0
    finished = False
    while not finished:
        control = 0
        chunk = bytearray()
        for bit in range(8):
            if pos >= len(raw):
                # end marker: reference pointing at the current write offset
                chunk += struct.pack(">H", (len(history) % 4096) << 4)
                control |= 1 << bit
                finished = True
                break
            best_len, best_off = 0, 0
            start = max(0, len(history) - 4095)
            for cand in range(start, len(history)):
                length = 0
                while length < 17 and pos + length < len(raw):
                    src = cand + length
                    byte = history[src] if src < len(history) else raw[pos + (src - len(history))]
                    if byte != raw[pos + length]:
                        break
                    length += 1
                if length > best_len:
                    best_len, best_off = length, cand % 4096
            if best_len >= 2:
                chunk += struct.pack(">H", (best_off << 4) | (best_len - 2))
                control |= 1 << bit
                history += raw[pos:pos + best_len]
                pos += best_len
            else:
                chunk.append(raw[pos])
                history.append(raw[pos])
                pos += 1
        out.append(control)
        out += chunk
    body = bytes(out)
    header = struct.pack("<IIII", len(body) + 12, len(raw), 0x75465A4C, crc32_rtf(body))
    return header + body


def tiny_png() -> bytes:
    width = height = 16
    rows = b"".join(b"\0" + b"\xd0\x30\x30" * width for _ in range(height))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def tnef(*attributes: bytes) -> bytes:
    header = struct.pack("<IH", 0x223E9F78, 0x1234)
    preamble = attribute(LVL_MESSAGE, ATT_TNEF_VERSION, struct.pack("<I", 0x00010000))
    preamble += attribute(LVL_MESSAGE, ATT_OEM_CODEPAGE, struct.pack("<II", 1252, 0))
    preamble += attribute(LVL_MESSAGE, ATT_MESSAGE_CLASS, b"IPM.Microsoft Mail.Note\0")
    return header + preamble + b"".join(attributes)


def file_attachment(short_name: str, long_name: str, mime: str, data: bytes) -> bytes:
    return (
        attribute(LVL_ATTACHMENT, ATT_ATTACH_RENDDATA, renddata())
        + attribute(LVL_ATTACHMENT, ATT_ATTACH_TITLE, short_name.encode("cp1252") + b"\0")
        + attribute(LVL_ATTACHMENT, ATT_ATTACH_DATA, data)
        + attribute(
            LVL_ATTACHMENT,
            ATT_ATTACHMENT,
            mapi_props(
                prop_variable(PT_UNICODE, PR_ATTACH_LONG_FILENAME, unicode_z(long_name)),
                prop_variable(PT_STRING8, PR_ATTACH_MIME_TAG, mime.encode("ascii") + b"\0"),
            ),
        )
    )


RTF_BODY = (
    b"{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0 Calibri;}}\r\n"
    b"\\pard Hello Lothar,\\par\\par Please find the report attached. "
    b"The report covers the report period and the report findings.\\par\r\n"
    b"Gr\\'fc\\'dfe\\par}\r\n"
)


def basic() -> bytes:
    return tnef(
        attribute(LVL_MESSAGE, ATT_SUBJECT, "Quarterly report – Übersicht".encode("cp1252") + b"\0"),
        attribute(LVL_MESSAGE, ATT_DATE_SENT, dtr(2026, 11, 9, 14, 30, 5, 1)),
        attribute(
            LVL_MESSAGE,
            ATT_MSG_PROPS,
            mapi_props(
                prop_long(PR_INTERNET_CPID, 1252),
                prop_variable(PT_BINARY, PR_RTF_COMPRESSED, compress_rtf(RTF_BODY)),
            ),
        ),
        file_attachment("GRUSSE~1.TXT", "Grüße & Übersicht.txt", "text/plain", "Hallo Welt – äöü\n".encode("utf-8")),
        file_attachment("CHART~1.PNG", "chart.png", "image/png", tiny_png()),
    )


def html() -> bytes:
    page = (
        "<html><body><p>Hi,</p><p>see <b>attached</b> sheet.</p>"
        '<img src="https://tracker.example.com/pixel.gif"><script>alert(1)</script>'
        '<p><a href="https://example.com/">link</a></p></body></html>'
    )
    return tnef(
        attribute(LVL_MESSAGE, ATT_SUBJECT, b"HTML body\0"),
        attribute(
            LVL_MESSAGE,
            ATT_MSG_PROPS,
            mapi_props(
                prop_variable(PT_BINARY, PR_BODY_HTML, page.encode("utf-8")),
                prop_variable(PT_UNICODE, PR_BODY, unicode_z("Hi, see attached sheet.")),
            ),
        ),
        file_attachment("SHEET.CSV", "sheet.csv", "text/csv", b"a,b\n1,2\n"),
    )


def rtf_only() -> bytes:
    return tnef(
        attribute(LVL_MESSAGE, ATT_SUBJECT, b"Only RTF\0"),
        attribute(LVL_MESSAGE, ATT_BODY, b"Plain legacy body\0"),
        attribute(
            LVL_MESSAGE,
            ATT_MSG_PROPS,
            mapi_props(prop_variable(PT_BINARY, PR_RTF_COMPRESSED, compress_rtf(RTF_BODY))),
        ),
    )


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, build in (("basic.dat", basic), ("html.dat", html), ("rtf-only.dat", rtf_only)):
        (out / name).write_bytes(build())
        print(f"wrote {out / name}")
    (out / "rtf-body.rtf").write_bytes(RTF_BODY)
    return 0


if __name__ == "__main__":
    sys.exit(main())
